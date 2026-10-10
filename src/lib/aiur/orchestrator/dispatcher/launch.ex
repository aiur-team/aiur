defmodule Aiur.Orchestrator.Dispatcher.Launch do
  @moduledoc """
  Dispatch commit: revalidation, worker selection, runner spawn and pending answers.
  """

  require Logger

  alias Aiur.AgentRunner
  alias Aiur.Alerts
  alias Aiur.BuildOrder.History
  alias Aiur.CodingAgent
  alias Aiur.Commands
  alias Aiur.GitHub.LocalHold
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.Dispatcher.Budgets
  alias Aiur.Orchestrator.Dispatcher.BudgetTrip
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.RetryEngine
  alias Aiur.Orchestrator.ReworkGate
  alias Aiur.Orchestrator.Slots
  alias Aiur.Orchestrator.State
  alias Aiur.RunTelemetry.Lifecycle, as: TelemetryLifecycle

  @doc false
  @spec recover_orphaned_claim(State.t(), Issue.t(), term(), term()) :: {State.t(), term()}
  def recover_orphaned_claim(state, issue, active_states, terminal_states) do
    case DispatchPolicy.dispatch_decision(issue, state, active_states, terminal_states) do
      {:skip, :claimed_without_runtime} ->
        Logger.warning("Releasing orphaned dispatch claim: #{State.issue_context(issue)}")
        recovered = %{state | claimed: MapSet.delete(state.claimed, issue.id)}
        {recovered, DispatchPolicy.dispatch_decision(issue, recovered, active_states, terminal_states)}

      decision ->
        {state, decision}
    end
  end

  @doc false
  @spec dispatch_prevalidated_issue(State.t(), Issue.t()) ::
          {{:ok, :started} | {:error, term()}, State.t()}
  def dispatch_prevalidated_issue(%State{} = state, %Issue{} = issue) do
    next_state = do_dispatch_issue(state, issue, nil, nil)

    result =
      cond do
        MapSet.member?(next_state.claimed, issue.id) ->
          {:ok, :started}

        match?({:lifetime, _, _}, Budgets.dispatch_latch_status(next_state, issue.id)) ->
          {:error, :lifetime_dispatch_latch}

        Map.has_key?(next_state.retry_attempts, issue.id) ->
          {:error, :dispatch_retry_scheduled}

        MapSet.member?(next_state.model_fallback_waiting, issue.id) ->
          {:error, :all_model_backends_limited}

        match?(%{tripped: :window}, get_in(next_state.dispatch_recovery, [:codex_thrash_budget, issue.id])) ->
          {:error, :thrash_circuit_open}

        true ->
          {:error, :dispatch_not_started}
      end

    {result, next_state}
  end

  @spec do_dispatch_issue(State.t(), term(), term(), term()) :: State.t()
  def do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host) do
    do_dispatch_issue(state, issue, attempt, preferred_worker_host, [])
  end

  @doc false
  @spec do_dispatch_issue(State.t(), term(), term(), term(), keyword()) :: State.t()
  def do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, opts) when is_list(opts) do
    case CodingAgent.select_for_dispatch(issue) do
      {:all_limited, candidates} ->
        if MapSet.member?(state.model_fallback_waiting, issue.id) do
          state
        else
          Alerts.emit_system("ticket.#{issue.identifier}.agent.model_fallback_waiting",
            issue: issue.identifier,
            reason: "All configured fallback backends are usage-limited: #{Enum.join(candidates, ", ")}. Waiting for a reset before retrying.",
            needs_attention: true,
            severity: "warning"
          )

          %{state | model_fallback_waiting: MapSet.put(state.model_fallback_waiting, issue.id)}
        end

      {:ok, selected_issue} ->
        state = %{state | model_fallback_waiting: MapSet.delete(state.model_fallback_waiting, selected_issue.id)}

        dispatch_after_workspace_wait_or_thrash_check(state, selected_issue, attempt, preferred_worker_host, opts)
    end
  end

  defp dispatch_after_workspace_wait_or_thrash_check(state, selected_issue, attempt, preferred_worker_host, opts) do
    workspace_ownership = state.dispatch_recovery.workspace_ownership

    case Map.pop(workspace_ownership.ready, selected_issue.id) do
      {nil, _ready} ->
        case Budgets.check_thrash_budget(state, selected_issue.id, System.monotonic_time(:millisecond)) do
          {:trip, tripped_state} ->
            BudgetTrip.trip_thrash_breaker(tripped_state, selected_issue)

          {:ok, budgeted_state} ->
            dispatch_to_worker(
              budgeted_state,
              selected_issue,
              attempt,
              preferred_worker_host,
              opts
            )
        end

      {envelope, ready} ->
        workspace_ownership = %{
          workspace_ownership
          | ready: ready
        }

        state = put_in(state.dispatch_recovery.workspace_ownership, workspace_ownership)
        envelope_attempt = Map.get(envelope, :retry_attempt, attempt) || attempt
        envelope_host = Map.get(envelope, :worker_host, preferred_worker_host) || preferred_worker_host

        envelope_opts =
          Keyword.put(
            opts,
            :prior_work,
            Map.get(envelope, :prior_work, Keyword.get(opts, :prior_work, false))
          )

        dispatch_to_worker(state, selected_issue, envelope_attempt, envelope_host, envelope_opts)
    end
  end

  @spec revalidate_issue_for_dispatch(Issue.t(), function(), MapSet.t(), keyword()) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_states, opts \\ [])

  def revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states, opts)
      when is_binary(issue_id) and is_function(issue_fetcher, 1) and is_list(opts) do
    # A dispatch-time revalidation is exactly the "GitHub call that gives up on
    # a self-clearing hold" #2444 is about: the issue refresh is held by the
    # local budget guard seconds before its own `reset_at`, and declining the
    # dispatch on it turned a four-second hold into a `tracker_revalidation_failed`
    # decline (#2311, #2393, #2420). The shared helper waits the short hold out
    # and retries the fetch; a hold beyond the ceiling or past the cap still
    # fails, so real starvation is not masked.
    result =
      LocalHold.run(
        fn -> issue_fetcher.([issue_id]) end,
        LocalHold.caller_opts(opts)
      )

    case result do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if Orchestrator.retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states, _opts), do: {:ok, issue}

  @spec retry_dispatch_ready?(Issue.t(), State.t(), String.t() | nil) :: boolean()
  def retry_dispatch_ready?(%Issue{} = issue, %State{} = state, worker_host) do
    terminal_states = DispatchPolicy.terminal_state_set()

    DispatchPolicy.retry_candidate_issue?(issue, terminal_states) and
      Slots.dispatch_slots_available?(issue, state) and
      Slots.worker_slots_available?(state, worker_host)
  end

  defp dispatch_to_worker(%State{} = state, issue, attempt, preferred_worker_host, opts) do
    recipient = self()

    case select_worker_host(state, issue, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{State.issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")

        state

      :preferred_worker_unavailable ->
        Logger.warning("Backend cannot use the preferred SSH worker for #{State.issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")

        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host, opts)
    end
  end

  @doc false
  @spec select_worker_host(State.t(), term(), term()) :: term()
  def select_worker_host(state, issue, preferred_worker_host) do
    if CodingAgent.remote_worker?(CodingAgent.backend_for(issue)) do
      Slots.select_worker_host(state, preferred_worker_host)
    else
      if is_nil(preferred_worker_host), do: nil, else: :preferred_worker_unavailable
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host, opts) do
    runner = Keyword.get(opts, :runner, &AgentRunner.run/3)
    worker_generation = System.unique_integer([:positive, :monotonic])
    lifecycle_attempt_id = TelemetryLifecycle.new_attempt_id(dispatch_attempt_ticket(issue))

    if TelemetryLifecycle.enabled?() do
      TelemetryLifecycle.record(issue.identifier, lifecycle_attempt_id, :dispatch, :point, %{
        outcome: :requested,
        complexity: CodingAgent.complexity_level(issue),
        dispatch_selection: issue.dispatch_selection && issue.dispatch_selection.summary,
        worker_host: worker_host,
        remote: is_binary(worker_host),
        retry_attempt: RetryEngine.normalize_retry_attempt(attempt)
      })
    end

    rework_head_sha = Keyword.get(opts, :rework_head_sha) || :pending

    runner_context = %{
      attempt: attempt,
      worker_host: worker_host,
      worker_generation: worker_generation,
      lifecycle_attempt_id: lifecycle_attempt_id,
      rework_head_sha: rework_head_sha
    }

    case start_runner_task(issue, runner, recipient, runner_context, opts) do
      {:ok, pid} ->
        History.note_start(issue.identifier, :dispatch, DateTime.utc_now())
        ref = Process.monitor(pid)
        Logger.info("Dispatching issue to agent: #{State.issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")
        record_rework_resume(issue, lifecycle_attempt_id)

        running_entry =
          %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            worker_host: worker_host,
            workspace_path: nil,
            session_id: nil,
            session_execution: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            repl_pane_id: nil,
            repl_os_pid: nil,
            headless_os_pid: nil,
            headless_process_group_id: nil,
            agent_input_tokens: 0,
            agent_output_tokens: 0,
            agent_total_tokens: 0,
            agent_last_reported_input_tokens: 0,
            agent_last_reported_output_tokens: 0,
            agent_last_reported_total_tokens: 0,
            turn_count: 0,
            completed_turn_count: 0,
            control: default_running_control(issue, worker_generation),
            telemetry_attempt_id: lifecycle_attempt_id,
            retry_attempt: RetryEngine.normalize_retry_attempt(attempt),
            prior_work: Keyword.get(opts, :prior_work, false),
            rework_head_sha: rework_head_sha,
            started_at: DateTime.utc_now()
          }
          |> inherit_redispatch_safety(Map.get(state.running, issue.id))

        running = Map.put(state.running, issue.id, running_entry)
        deliver_pending_answers(issue, opts)

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id),
            released_claims: Map.delete(state.released_claims, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{State.issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        RetryEngine.schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          tracker_identity: Issue.tracker_identity(issue),
          issue_state: issue.state,
          error: "failed to spawn agent: #{inspect(reason)}",
          prior_work: Keyword.get(opts, :prior_work, false),
          worker_host: worker_host
        })
    end
  end

  defp start_runner_task(issue, runner, recipient, context, opts) do
    Task.Supervisor.start_child(Aiur.TaskSupervisor, fn ->
      rework_head_sha = capture_rework_head(issue, context.rework_head_sha, opts)
      maybe_report_rework_head(recipient, issue, rework_head_sha)

      runner.(issue, recipient,
        attempt: context.attempt,
        prior_work: Keyword.get(opts, :prior_work, false),
        account_name: Keyword.get(opts, :account_name),
        resume_thread_id: Keyword.get(opts, :resume_thread_id),
        telemetry_attempt_id: context.lifecycle_attempt_id,
        worker_host: context.worker_host,
        orchestrator: recipient,
        worker_generation: context.worker_generation,
        rework_head_sha: rework_head_sha
      )
    end)
  end

  defp capture_rework_head(_issue, initial_head, _opts) when initial_head != :pending, do: initial_head

  defp capture_rework_head(issue, :pending, opts) do
    fetcher = Keyword.get(opts, :rework_head_fetcher, &Aiur.CodeHost.fetch_open_pull_request_for_branch/1)

    case fetcher.(issue.identifier) do
      {:ok, %{} = pr} -> ReworkGate.head_sha(pr) || :lookup_failed
      {:error, _reason} -> :lookup_failed
      _ -> nil
    end
  end

  defp maybe_report_rework_head(recipient, issue, rework_head_sha) when is_pid(recipient),
    do: send(recipient, {:worker_runtime_info, issue.id, %{rework_head_sha: rework_head_sha}})

  # An agent that files a blocking Command ends its run, so the answer usually
  # arrives when no worker runs the ticket and its delivery fails (#2713). The
  # answer stays durable in the DecisionStore; this new worker is where it must
  # land. The store dispatches each undelivered answer of the ticket again, and
  # it reaches this worker through its queue.
  #
  # The spawn runs inside an Orchestrator handler, often a whole poll. The
  # store's dispatch task calls back into the Orchestrator, so a request sent
  # now would wait behind the rest of that handler and could time out on a
  # slow poll. The request is therefore posted to this process and sent to the
  # store only after the handler returns (`handle_pending_answer_delivery/1`).
  defp deliver_pending_answers(%Issue{identifier: identifier}, opts) when is_binary(identifier) do
    send(self(), {:deliver_pending_answers, identifier, Keyword.get(opts, :decision_store, Commands.default_store())})
    :ok
  end

  defp deliver_pending_answers(_issue, _opts), do: :ok

  @doc """
  Handles the `{:deliver_pending_answers, identifier, store}` message that a
  worker spawn posts to the Orchestrator. It runs after the spawning handler
  has returned, so the store's dispatch task finds the Orchestrator free and
  the new running entry in its state (#2713).
  """
  @spec handle_pending_answer_delivery({:deliver_pending_answers, String.t(), GenServer.server()}) :: :ok
  def handle_pending_answer_delivery({:deliver_pending_answers, identifier, store}) when is_binary(identifier),
    do: Commands.deliver_pending_answers(identifier, store)

  defp dispatch_attempt_ticket(%Issue{} = issue) do
    case dispatch_attempt_identity(issue) do
      identity when is_binary(identity) ->
        "ticket-" <> (:crypto.hash(:sha256, identity) |> Base.encode16(case: :lower))

      nil ->
        "ticket-" <> (10 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
    end
  end

  # Backend replacement leaves a parked entry in place until a new Task is
  # admitted. Transfer only the deliberately staged safety context; ordinary
  # dispatches never carry arbitrary state from an older worker.
  defp inherit_redispatch_safety(entry, %{redispatch_safety: safety} = previous) when is_map(safety) do
    entry
    |> Map.put(:redispatch_safety, safety)
    |> Map.put(:rate_limit_fallback_replacement, Map.get(previous, :rate_limit_fallback_replacement) == true)
    |> maybe_put_redispatch_fence(Map.get(previous, :lifecycle_fence))
    |> maybe_put_redispatch_workspace(Map.get(safety, :workspace_path))
  end

  defp inherit_redispatch_safety(entry, _previous), do: entry

  defp maybe_put_redispatch_fence(entry, fence) when is_map(fence), do: Map.put(entry, :lifecycle_fence, fence)

  defp maybe_put_redispatch_fence(entry, _fence), do: entry

  defp maybe_put_redispatch_workspace(entry, path) when is_binary(path), do: Map.put(entry, :workspace_path, path)

  defp maybe_put_redispatch_workspace(entry, _path), do: entry

  # Attempt IDs are retained in Decision provenance, whose identity fields are
  # deliberately bounded and exclude arbitrary tracker payload. Hash the stable
  # tracker identity so accepted Decisions keep a collision-resistant correlator
  # without persisting a raw identifier such as `repo#1` or an overlong value.
  defp dispatch_attempt_identity(%Issue{identifier: identifier, id: issue_id}) do
    Enum.find([identifier, issue_id], &(is_binary(&1) and &1 != ""))
  end

  defp record_rework_resume(%Issue{} = issue, attempt_id) do
    if DispatchPolicy.normalize_issue_state(issue.state) == "rework" do
      TelemetryLifecycle.record(
        issue.identifier,
        attempt_id,
        :agent_resume,
        :point,
        %{cause: :rework_dispatch}
      )
    end
  end

  defp default_running_control(%Issue{} = issue, worker_generation) when is_integer(worker_generation) do
    backend = CodingAgent.backend_for(issue)

    %{
      can_interrupt: CodingAgent.can_interrupt?(backend),
      safe_checkpoints: CodingAgent.safe_checkpoints(backend),
      immediate_delivery: CodingAgent.immediate_delivery?(backend),
      application_confirmation: CodingAgent.control_application_confirmation(backend),
      generation: worker_generation,
      version: 0,
      status: :working
    }
  end
end
