defmodule Aiur.LandingWatch do
  @moduledoc "Daemon-side owner for approved pull requests through the merge queue."
  use GenServer
  require Logger

  alias Aiur.Alerts
  alias Aiur.Events
  alias Aiur.GitHub.{CiReadiness, CIRecovery, Client, HumanReviewGate, Transport}
  alias Aiur.LandingWatch.{Attribution, Classifier, Journal, MergeGroups, Observer, PrRerun}
  alias Aiur.LandingWatch.RecoveryRuntime
  alias Aiur.Orchestrator.TicketTransition
  alias Aiur.PrMerge.Queue
  alias Aiur.TicketBranch

  @default_interval_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec state(GenServer.server()) :: map()
  def state(server \\ __MODULE__) do
    GenServer.call(server, :state)
  catch
    :exit, {:noproc, _} -> %{watcher: :not_running}
    :exit, _ -> %{watcher: :unavailable}
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    # CI-file merges let older failed PR runs rerun instead of routing to rework.
    if Keyword.get(opts, :subscribe, true), do: Enum.each(["system.pr.merged", "ticket.*.pr.merged", "system.main.ci.failed.resolved"], &Events.subscribe/1)
    send(self(), :poll)

    {:ok,
     %{watcher: :running, last_poll_at_ms: nil, last_error: nil, interval_ms: interval, opts: opts, task: nil, pending_recovery_window: nil, active_recovery_window: nil, active_recovery_attempt: 0}}
  end

  @impl true
  def handle_call(:state, _from, state) do
    extra = %{merge_group_requeues_by_hour: Journal.merge_group_requeues_by_hour(state.opts), rerun_backlog: Journal.rerun_backlog(state.opts)}
    {:reply, Map.merge(Map.take(state, [:watcher, :last_poll_at_ms, :last_error]), extra), state}
  end

  @impl true
  def handle_info(:poll, %{task: task} = state) when not is_nil(task) do
    Process.send_after(self(), :poll, state.interval_ms)
    {:noreply, state}
  end

  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, state.interval_ms)
    task = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn -> poll(state.opts) end)
    {:noreply, %{state | task: task, watcher: :running}}
  rescue
    error ->
      Logger.warning("landing watcher could not start poll: #{Exception.message(error)}")
      {:noreply, %{state | watcher: :unavailable, last_error: :poll_start_failed}}
  end

  def handle_info({:event, %{topic: "system.main.ci.failed.resolved", red_since: red_since, recovered_at: recovered_at}}, state)
      when is_integer(red_since) and is_integer(recovered_at) and red_since <= recovered_at do
    window = {red_since, recovered_at}

    case state.task do
      nil ->
        send(self(), {:poll_recovery, window, 0})
        {:noreply, state}

      _task ->
        {:noreply, %{state | pending_recovery_window: {window, 0}}}
    end
  end

  def handle_info({:poll_recovery, window, attempt}, state) do
    if state.task do
      {:noreply, %{state | pending_recovery_window: {window, attempt}}}
    else
      task = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn -> poll(Keyword.put(state.opts, :main_ci_recovery_window, window)) end)
      {:noreply, %{state | task: task, active_recovery_window: window, active_recovery_attempt: attempt}}
    end
  end

  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    now = System.system_time(:millisecond)

    case result do
      :ok ->
        next = %{state | task: nil, watcher: :running, last_poll_at_ms: now, last_error: nil, active_recovery_window: nil, active_recovery_attempt: 0}
        if next.pending_recovery_window, do: send(self(), RecoveryRuntime.message(next.pending_recovery_window))
        {:noreply, %{next | pending_recovery_window: nil}}

      {:error, reason} ->
        Logger.warning("landing watcher poll unavailable: #{inspect(reason)}")
        next = %{state | task: nil, watcher: :unavailable, last_poll_at_ms: now, last_error: inspect(reason)}
        {:noreply, RecoveryRuntime.retry_or_drain(next)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = state) do
    Logger.warning("landing watcher poll crashed: #{inspect(reason)}")
    next = %{state | task: nil, watcher: :unavailable, last_error: inspect(reason)}
    {:noreply, RecoveryRuntime.retry_or_drain(next)}
  end

  def handle_info({:event, %{topic: topic} = event}, state) when is_binary(topic) do
    Task.Supervisor.start_child(Aiur.TaskSupervisor, fn -> PrRerun.record_merge(event, state.opts) end)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  @spec poll(keyword()) :: :ok | {:error, term()}
  def poll(opts \\ []) do
    case Keyword.get(opts, :observe_fun, &Observer.observe/1).(opts) do
      {:ok, observations} when is_list(observations) -> poll_observations(observations, opts)
      {:error, _} = error -> error
      _ -> {:error, :invalid_observations}
    end
  end

  defp poll_observations(observations, opts) do
    if Enum.all?(observations, &is_map/1) do
      case Keyword.get(opts, :journal_prune_fun, &Journal.retain_current_heads/2).(observations, opts) do
        :ok ->
          process_and_reconcile(observations, opts)

        {:error, _} = error ->
          error

        _ ->
          {:error, :journal_prune_unconfirmed}
      end
    else
      {:error, :invalid_observations}
    end
  end

  defp process_and_reconcile(observations, opts) do
    opts = poll_required_checks(observations, opts)
    result = process_all(observations, opts)
    reconcile = Keyword.get(opts, :queue_reconcile_fun, &MergeGroups.cancel_stale/2).(observations, opts)
    if result == :ok, do: reconcile, else: result
  end

  defp process_all(observations, opts) do
    Enum.reduce(observations, :ok, fn observation, first_error ->
      result = process_observation(observation, opts)
      if first_error == :ok, do: result, else: first_error
    end)
  end

  defp process_observation(observation, opts) do
    case Keyword.get(opts, :process_fun, &process/2).(observation, opts) do
      :ok -> :ok
      {:error, _} = error -> error
    end
  end

  @doc false
  @spec process(map(), keyword()) :: :ok | {:error, term()}
  def process(%{number: number, raw: raw, head: head} = observation, opts) when is_integer(number) and is_binary(head) do
    current_approval = Keyword.get(opts, :approved_fun, &HumanReviewGate.pull_request_approved_at_head?/2)
    required_checks = Keyword.get(opts, :required_checks_fun, &CiReadiness.fetch_required_checks/1)
    ci_status = Keyword.get(opts, :ci_status_fun, &Client.fetch_commit_ci_status/2)
    required_result = Keyword.get(opts, :required_checks_snapshot, :not_fetched)
    required_result = if required_result == :not_fetched, do: required_checks.(opts), else: required_result

    with true <- Classifier.approved_at_head?(raw),
         {:ok, true} <- current_approval.(number, opts),
         {:ok, required} <- required_result,
         {:ok, %{check_runs: runs, commit_status: commit_status}} <- ci_status.(head, opts) do
      result = Classifier.ci_verdict(runs, commit_status, %{"head" => %{"sha" => head}, "draft" => Map.get(raw, "isDraft")}, required_checks: {:ok, required})

      with {:ok, runs} <- hydrate_failed_jobs(runs, opts) do
        handle_verdict(observation, result, runs, opts)
      end
    else
      {:ok, false} -> :ok
      false -> :ok
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_approved_pull_request_observation}
    end
  end

  def process(_observation, _opts), do: :ok

  @doc false
  @spec rework(map(), [map()], keyword()) :: :ok | {:error, term()}
  def rework(observation, failures, opts) do
    if Keyword.get(opts, :hold_rework, false), do: :ok, else: route_rework(observation, failures, opts)
  end

  defp hydrate_failed_jobs(runs, opts) do
    runs
    |> Enum.reduce_while({:ok, []}, fn run, {:ok, acc} ->
      case hydrate_run(run, opts) do
        {:ok, hydrated} -> {:cont, {:ok, acc ++ [hydrated]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp hydrate_run(run, opts) do
    if run["status"] == "completed" and run["conclusion"] in ["failure", "timed_out", "startup_failure"] and is_integer(run["run_id"]) do
      case Keyword.get(opts, :jobs_fun, &CIRecovery.jobs/2).(run["run_id"], opts) do
        {:ok, jobs} ->
          {:ok,
           run
           |> Map.put("workflow_jobs", jobs)
           |> Map.put("jobs", Enum.filter(jobs, &(&1["name"] == run["name"])))}

        {:error, reason} ->
          {:error, {:required_check_job_evidence_unavailable, run["name"], reason}}
      end
    else
      {:ok, run}
    end
  end

  defp handle_verdict(%{merge_queue_entry: entry}, %{decision: :pending, pending_reason: :ci_cancelled}, _runs, _opts) when is_map(entry),
    do: :ok

  defp handle_verdict(observation, %{decision: :pending, pending_reason: :ci_cancelled}, runs, opts),
    do: handle_person_cancel(observation, runs, opts)

  defp handle_verdict(%{mergeable: "MERGEABLE", merge_state_status: "CLEAN"} = observation, %{decision: :pending}, _runs, opts),
    do: landing_eligibility(observation, opts)

  defp handle_verdict(%{mergeable: "CONFLICTING", merge_queue_entry: nil} = observation, %{decision: :pending}, _runs, opts),
    do: route_rework(observation, [%{name: "Merge conflict with base"}], opts)

  defp handle_verdict(_observation, %{decision: :pending}, _runs, _opts), do: :ok

  defp handle_verdict(observation, %{decision: :failed} = result, runs, opts) do
    case approved_landing?(observation) do
      :landing ->
        :ok

      :unknown ->
        emit_landing_state_attention(observation, opts)

      :not_landing ->
        PrRerun.handle_failure(observation, result, runs, opts)

      # Auto-merge never enqueues a red head, so only a rerun or refresh lands it (#4930); rework stays held (#4684).
      :auto_merge ->
        case Keyword.get(opts, :main_ci_recovery_window) do
          {red_since, recovered_at} = window when is_integer(red_since) and is_integer(recovered_at) ->
            PrRerun.recover_main_ci(observation, runs, window, opts)

          _ ->
            PrRerun.handle_failure(observation, result, runs, Keyword.put(opts, :hold_rework, true))
        end
    end
  end

  defp handle_verdict(observation, %{decision: :passed}, _runs, opts), do: landing_eligibility(observation, opts)

  # `process/2` only reaches here for a PR approved at its head, and this poll's
  # own GraphQL read carries the landing fields, so no extra request is needed.
  defp approved_landing?(%{merge_queue_entry: entry}) when is_map(entry), do: :landing
  defp approved_landing?(%{auto_merge_request: auto_merge, merge_queue_entry: nil}) when is_map(auto_merge), do: :auto_merge
  defp approved_landing?(%{auto_merge_request: nil, merge_queue_entry: nil}), do: :not_landing
  defp approved_landing?(_observation), do: :unknown

  defp emit_landing_state_attention(observation, opts) do
    issue = TicketBranch.ticket_id(get_in(observation.rest || %{}, ["head", "ref"]))
    emitter = Keyword.get(opts, :alert_emitter, &Alerts.emit_system/2)
    message = "Landing state for approved PR ##{observation.number} could not be confirmed; rework routing was held."

    emitter.("system.pr.landing.state_unavailable", central: true, durable: true, needs_attention: true, issue: issue, message: message, reason: message)
    :ok
  end

  defp handle_person_cancel(observation, runs, opts) do
    issue = TicketBranch.ticket_id(get_in(observation.rest || %{}, ["head", "ref"]))

    if is_binary(issue) do
      emit_cancel_alerts(observation, issue, runs, opts)
    else
      :ok
    end
  end

  defp emit_cancel_alerts(observation, issue, runs, opts) do
    runs
    |> Enum.filter(&(&1["conclusion"] == "cancelled"))
    |> Enum.reduce(:ok, fn run, result ->
      if result == :ok, do: emit_cancel_alert(observation, issue, run, opts), else: result
    end)
  end

  defp emit_cancel_alert(observation, issue, run, opts) do
    message = "Approved PR ##{observation.number} has a person-cancelled CI run with no newer run; rerun was skipped."
    marker = "person-cancelled-#{run["run_id"] || run["id"]}"
    topic = "ticket.#{issue}.pr.ci_recovery.rerun_skipped"
    emit_once(observation, marker, topic, message, "cancelled_run", true, opts)
  end

  @doc false
  @spec emit_once(map(), String.t(), String.t(), String.t(), String.t(), boolean(), keyword()) :: :ok | {:error, term()}
  def emit_once(observation, marker, topic, message, reason, needs_attention, opts) do
    case Journal.claim_alert(observation.number, observation.head, marker, opts) do
      {:ok, :new} ->
        emitter = Keyword.get(opts, :alert_emitter, &Alerts.emit_system/2)

        case emitter.(topic, central: true, durable: true, needs_attention: needs_attention, message: message, reason: reason) do
          :ok ->
            :ok

          {:error, _} = error ->
            _ = Journal.release_alert(observation.number, observation.head, marker, opts)
            error

          _ ->
            _ = Journal.release_alert(observation.number, observation.head, marker, opts)
            {:error, :alert_publication_unconfirmed}
        end

      {:ok, :already_claimed} ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  defp landing_eligibility(observation, opts) do
    cond do
      is_map(observation.merge_queue_entry) or is_map(observation.auto_merge_request) ->
        :ok

      observation.draft? != false ->
        :ok

      observation.review_decision != "APPROVED" ->
        :ok

      not Classifier.approved_at_head?(observation.raw) ->
        :ok

      true ->
        land_unless_ticket_active(observation, opts)
    end
  end

  # A ticket back in rework or with a running agent owns its PR; an Executor dequeue must stick (#4772).
  defp land_unless_ticket_active(observation, opts) do
    case fetch_ticket(observation, opts) do
      {:ok, _issue, state} when state in ["rework", "in-progress", "todo"] -> :ok
      {:ok, _issue, _state} -> revalidate_attribution_and_enqueue(observation, opts)
      {:error, :pull_request_not_linked_to_ticket_branch} -> revalidate_attribution_and_enqueue(observation, opts)
      {:error, _} = error -> error
    end
  end

  defp poll_required_checks(observations, opts) do
    if Enum.any?(observations, fn observation -> Classifier.approved_at_head?(Map.get(observation, :raw, %{})) end) do
      required_checks = Keyword.get(opts, :required_checks_fun, &CiReadiness.fetch_required_checks/1)
      Keyword.put(opts, :required_checks_snapshot, required_checks.(opts))
    else
      opts
    end
  end

  defp revalidate_attribution_and_enqueue(observation, opts) do
    with :ok <- Keyword.get(opts, :revalidate_fun, &Observer.revalidate_approved_head/3).(observation.number, observation.head, opts) do
      case Keyword.get(opts, :attribution_fun, fn pr -> Attribution.pull_request_clean?(pr.number, opts) end).(observation) do
        {:ok, :clean} -> maybe_enqueue(observation, opts)
        {:ok, {:ai_attribution, detail}} -> route_rework(observation, [%{name: "AI commit attribution", excerpt: detail}], opts)
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_attribution_result}
      end
    end
  end

  defp maybe_enqueue(%{merge_queue_entry: entry}, _opts) when is_map(entry), do: :ok
  defp maybe_enqueue(%{auto_merge_request: request}, _opts) when is_map(request), do: :ok

  defp maybe_enqueue(%{node_id: id, head: head} = observation, opts) when is_binary(id) and is_binary(head) do
    enqueue = Keyword.get(opts, :enqueue_fun, &enqueue_pull_request/1)

    case enqueue.(observation) do
      {:ok, entry} when is_binary(entry) -> Journal.mark_landed(observation.number, head, entry, opts)
      {:error, reason} -> {:error, reason}
      _ -> {:error, :enqueue_not_confirmed}
    end
  end

  defp maybe_enqueue(_observation, _opts), do: {:error, :missing_pull_request_identity}

  defp enqueue_pull_request(observation) do
    api = fn "post", "graphql", %{query: query, variables: variables} ->
      with {:ok, token} <- Transport.require_token([]),
           do: Transport.github_graphql(&Transport.default_request_fun/1, token, query, variables, caller: "landing_watch_enqueue")
    end

    Queue.enqueue(api, %{node_id: observation.node_id, head: observation.head})
  end

  defp route_rework(observation, failures, opts) do
    case Keyword.get(opts, :rework_fun) do
      writer when is_function(writer, 3) ->
        writer.(observation, failures, opts)

      _ ->
        case transition_rework(observation, failures, opts) do
          {:error, :pull_request_not_linked_to_ticket_branch} ->
            log_unlinked_head_once(observation, opts)
            :ok

          result ->
            result
        end
    end
  end

  defp log_unlinked_head_once(observation, opts) do
    case Journal.claim_alert(observation.number, observation.head, "unlinked-rework-skipped", opts) do
      {:ok, :new} ->
        Logger.debug("landing watcher skipped rework routing for unlinked PR ##{observation.number} head #{observation.head}")

      _ ->
        :ok
    end
  end

  defp transition_rework(observation, failures, opts) do
    case fetch_ticket(observation, opts) do
      {:ok, issue, state} when state in ["human-review", "ci-wait", "merging"] ->
        transition = Keyword.get(opts, :transition_fun, fn identifier, target, options -> TicketTransition.write_state(identifier, target, options) end)

        case transition.(issue, "rework", writer: :landing_watch, expected_state: state) do
          :ok -> emit_rework_alert(observation, failures, issue, opts)
          {:error, reason} -> {:error, reason}
          _ -> {:error, :ticket_rework_transition_unconfirmed}
        end

      {:ok, _issue, _state} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp emit_rework_alert(observation, failures, issue, opts) do
    run_link = Keyword.get(opts, :run_url)
    evidence = Enum.map_join(failures, "; ", &failure_text/1)
    evidence = if is_binary(run_link), do: evidence <> " (#{run_link})", else: evidence
    message = "Approved PR ##{observation.number} moved ticket ##{issue} to rework: " <> evidence
    emitter = Keyword.get(opts, :alert_emitter, &Alerts.emit_system/2)
    emitter.("system.pr.landing.rework", central: true, needs_attention: false, message: message, reason: message)
    :ok
  end

  defp fetch_ticket(observation, opts) do
    case TicketBranch.ticket_id(get_in(observation.rest || %{}, ["head", "ref"])) do
      nil ->
        {:error, :pull_request_not_linked_to_ticket_branch}

      issue ->
        case Keyword.get(opts, :ticket_state_fun, &fetch_ticket_state/2).(issue, opts) do
          {:ok, state} -> {:ok, issue, state}
          {:error, _} = error -> error
          _ -> {:error, :ticket_state_unavailable}
        end
    end
  end

  @ticket_states ["rework", "in-progress", "todo", "human-review", "ci-wait", "merging"]

  defp fetch_ticket_state(issue, opts) do
    with {:ok, raw, _freshness} <- Client.fetch_issue_raw_conditional(issue, Keyword.put(opts, :revalidate, true)) do
      names = Enum.map(Map.get(raw, "labels", []), &Map.get(&1, "name"))
      # Gating states win: label edits add before they remove, so a ticket can briefly hold both.
      {:ok, Enum.find(@ticket_states, "other", &("agent:#{&1}" in names))}
    end
  end

  defp failure_text(%{name: name, excerpt: excerpt}) when is_binary(excerpt) and excerpt != "", do: "#{name}: #{excerpt}"
  defp failure_text(%{name: name}), do: to_string(name)
  defp failure_text(value), do: inspect(value)
end
