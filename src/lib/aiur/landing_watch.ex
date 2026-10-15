defmodule Aiur.LandingWatch do
  @moduledoc "Daemon-side owner for approved pull requests through the merge queue."
  use GenServer
  require Logger

  alias Aiur.Alerts
  alias Aiur.GitHub.{CiReadiness, CIRecovery, Client, HumanReviewGate, Transport}
  alias Aiur.LandingWatch.{Attribution, Classifier, Journal, MergeGroups, Observer}
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
    send(self(), :poll)
    {:ok, %{watcher: :running, last_poll_at_ms: nil, last_error: nil, interval_ms: interval, opts: opts, task: nil}}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, Map.take(state, [:watcher, :last_poll_at_ms, :last_error]), state}

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

  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    now = System.system_time(:millisecond)

    case result do
      :ok ->
        {:noreply, %{state | task: nil, watcher: :running, last_poll_at_ms: now, last_error: nil}}

      {:error, reason} ->
        Logger.warning("landing watcher poll unavailable: #{inspect(reason)}")
        {:noreply, %{state | task: nil, watcher: :unavailable, last_poll_at_ms: now, last_error: inspect(reason)}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = state) do
    Logger.warning("landing watcher poll crashed: #{inspect(reason)}")
    {:noreply, %{state | task: nil, watcher: :unavailable, last_error: inspect(reason)}}
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
  def rework(observation, failures, opts), do: route_rework(observation, failures, opts)

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

  defp handle_verdict(observation, %{decision: :pending, pending_reason: :ci_cancelled}, runs, opts),
    do: handle_person_cancel(observation, runs, opts)

  defp handle_verdict(%{mergeable: "MERGEABLE", merge_state_status: "CLEAN"} = observation, %{decision: :pending}, _runs, opts),
    do: landing_eligibility(observation, opts)

  defp handle_verdict(%{mergeable: "CONFLICTING", merge_queue_entry: nil} = observation, %{decision: :pending}, _runs, opts),
    do: route_rework(observation, [%{name: "Merge conflict with base"}], opts)

  defp handle_verdict(_observation, %{decision: :pending}, _runs, _opts), do: :ok

  defp handle_verdict(observation, %{decision: :failed} = result, runs, opts) do
    if Classifier.infra_failure?(result, runs) do
      request_infra_reruns(observation, runs, opts)
    else
      route_rework(observation, result.failures, opts)
    end
  end

  defp handle_verdict(observation, %{decision: :passed}, _runs, opts), do: landing_eligibility(observation, opts)

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

  defp request_infra_reruns(observation, runs, opts) do
    failed = Enum.filter(runs, &(Map.get(&1, "conclusion") in ["cancelled", "failure", "timed_out", "startup_failure"]))

    now = Keyword.get(opts, :now_ms, System.system_time(:millisecond))

    case Journal.reserve_rerun(observation.number, observation.head, now, opts) do
      :ok -> Enum.reduce(failed, :ok, &rerun_if_ok(&1, &2, observation, opts))
      {:error, reason} -> normalize_recovery_result(handle_rerun_error(observation, reason, opts))
    end
  end

  defp rerun_if_ok(_run, {:error, _} = error, _observation, _opts), do: error

  defp rerun_if_ok(run, :ok, observation, opts) do
    case rerun_one(observation, run, opts) do
      :ok -> :ok
      {:error, reason} -> normalize_recovery_result(handle_rerun_error(observation, reason, opts))
    end
  end

  defp normalize_recovery_result({:halt, :ok}), do: :ok
  defp normalize_recovery_result({:halt, {:error, _} = error}), do: error

  defp handle_rerun_error(observation, :rerun_limit_reached, opts) do
    issue = TicketBranch.ticket_id(get_in(observation.rest || %{}, ["head", "ref"]))
    message = "Approved PR ##{observation.number} exhausted its infra rerun budget for head #{observation.head}; manual CI recovery is needed."
    topic = if is_binary(issue), do: "ticket.#{issue}.pr.ci_recovery.rerun_limit", else: "system.pr.ci_recovery.rerun_limit"

    case emit_once(observation, "rerun-budget-exhausted", topic, message, "rerun_limit_reached", true, opts) do
      :ok -> {:halt, :ok}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp handle_rerun_error(_observation, :rerun_backoff, _opts), do: {:halt, :ok}
  defp handle_rerun_error(_observation, reason, _opts), do: {:halt, {:error, reason}}

  defp emit_once(observation, marker, topic, message, reason, needs_attention, opts) do
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

  defp rerun_one(_observation, run, opts) do
    id = Map.get(run, "run_id")

    with true <- is_integer(id) and id > 0,
         {:ok, _} <- Keyword.get(opts, :rerun_fun, &CIRecovery.rerun/2).(id, opts) do
      :ok
    else
      false -> {:error, :missing_actions_run_id}
      {:error, _} = error -> error
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
        revalidate_attribution_and_enqueue(observation, opts)
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
    message = "Approved PR ##{observation.number} moved ticket ##{issue} to rework: " <> Enum.map_join(failures, "; ", &failure_text/1)
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

  defp fetch_ticket_state(issue, opts) do
    with {:ok, raw, _freshness} <- Client.fetch_issue_raw_conditional(issue, Keyword.put(opts, :revalidate, true)) do
      case Enum.find(Map.get(raw, "labels", []), &(Map.get(&1, "name") in ["agent:human-review", "agent:ci-wait", "agent:merging"])) do
        %{"name" => "agent:human-review"} -> {:ok, "human-review"}
        %{"name" => "agent:ci-wait"} -> {:ok, "ci-wait"}
        %{"name" => "agent:merging"} -> {:ok, "merging"}
        _ -> {:ok, "other"}
      end
    end
  end

  defp failure_text(%{name: name, excerpt: excerpt}) when is_binary(excerpt) and excerpt != "", do: "#{name}: #{excerpt}"
  defp failure_text(%{name: name}), do: to_string(name)
  defp failure_text(value), do: inspect(value)
end
