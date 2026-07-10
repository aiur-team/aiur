defmodule Aiur.Orchestrator.Dispatcher do
  @moduledoc """
  Dispatch execution: choose loop, revalidation, thrash breaker, worker spawn.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger

  alias Aiur.{AgentRunner, Alerts, CodingAgent, Config, Issue, Tracker}
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{DispatchPolicy, Slots, State}
  alias Aiur.Orchestrator.RetryEngine

  @spec choose_issues(State.t(), [Issue.t()]) :: State.t()
  def choose_issues(state, issues) do
    active_states = DispatchPolicy.active_state_set()
    terminal_states = DispatchPolicy.terminal_state_set()
    initial_dispatch_cycle? = state.initial_dispatch_cycle == true

    {state, _startup_todo_index} =
      issues
      |> DispatchPolicy.sort_issues_for_dispatch()
      |> Enum.reduce({state, 0}, fn issue, {state_acc, startup_todo_index} ->
        if DispatchPolicy.should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
          next_state = dispatch_issue(state_acc, issue)

          startup_todo_index =
            maybe_schedule_startup_todo_alert(
              state_acc,
              next_state,
              issue,
              startup_todo_index,
              initial_dispatch_cycle?
            )

          {next_state, startup_todo_index}
        else
          {state_acc, startup_todo_index}
        end
      end)

    state
  end

  @spec dispatch_issue(State.t(), term(), term(), term()) :: State.t()
  def dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
    case revalidate_issue_for_dispatch(
           issue,
           &Tracker.fetch_issue_states_by_ids/1,
           DispatchPolicy.terminal_state_set()
         ) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{State.issue_context(issue)}")

        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{State.issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{State.issue_context(issue)}: #{inspect(reason)}")

        state
    end
  end

  @spec do_dispatch_issue(State.t(), term(), term(), term()) :: State.t()
  def do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host) do
    case CodingAgent.select_for_dispatch(issue) do
      {:all_limited, candidates} ->
        Alerts.emit_system("ticket.#{issue.identifier}.agent.model_fallback_waiting",
          issue: issue.identifier,
          reason: "All configured fallback backends are usage-limited: #{Enum.join(candidates, ", ")}. Waiting for a reset before retrying.",
          needs_attention: true,
          severity: "warning"
        )

        state

      {:ok, selected_issue} ->
        case check_thrash_budget(state, selected_issue.id, System.monotonic_time(:millisecond)) do
          {:trip, tripped_state} -> trip_thrash_breaker(tripped_state, selected_issue)
          {:ok, budgeted_state} -> dispatch_to_worker(budgeted_state, selected_issue, attempt, preferred_worker_host)
        end
    end
  end

  # Time-windowed restart budget. Independent of the willRetry:false
  # hard-failure path: catches thrash that never surfaces willRetry
  # (transport timeouts, sandbox refusals, future error classes that
  # still complete a turn as :normal and reschedule as a continuation,
  # bypassing max_retry_attempts). Counts (re)dispatches per issue per
  # window and trips once they exceed `codex_thrash_max_per_window`
  # within `codex_thrash_window_seconds`. Gating here, before
  # spawn_issue_on_worker_host, means a tripped attempt pays no workspace
  # clone cost. The breaker resets when the window lapses, so the issue
  # gets another window on the next poll tick.
  @spec check_thrash_budget(State.t(), String.t(), integer()) ::
          {:ok, State.t()} | {:trip, State.t()}
  def check_thrash_budget(%State{} = state, issue_id, now_ms) do
    window_ms = Config.codex_thrash_window_seconds() * 1_000

    entry =
      case Map.get(state.codex_thrash_budget, issue_id) do
        %{window_start_ms: start, count: count} when now_ms - start < window_ms ->
          %{window_start_ms: start, count: count + 1}

        _ ->
          %{window_start_ms: now_ms, count: 1}
      end

    state = %{state | codex_thrash_budget: Map.put(state.codex_thrash_budget, issue_id, entry)}

    if entry.count > Config.codex_thrash_max_per_window() do
      {:trip, state}
    else
      {:ok, state}
    end
  end

  @spec reset_thrash_budget(State.t(), String.t()) :: State.t()
  def reset_thrash_budget(%State{} = state, issue_id) do
    %{state | codex_thrash_budget: Map.delete(state.codex_thrash_budget, issue_id)}
  end

  @spec revalidate_issue_for_dispatch(Issue.t(), function(), MapSet.t()) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
      when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
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

  def revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp maybe_schedule_startup_todo_alert(
         previous_state,
         next_state,
         %Issue{} = issue,
         index,
         true
       ) do
    if DispatchPolicy.normalize_issue_state(issue.state) == "todo" and
         not MapSet.member?(previous_state.claimed, issue.id) and
         MapSet.member?(next_state.claimed, issue.id) do
      delay_ms = index * 1_000
      worker_host = Orchestrator.running_worker_host(next_state, issue.id)
      topic = "ticket.#{issue.identifier}.issue.label.added.agent.todo"
      Process.send_after(self(), {:emit_system_alert, topic, issue, worker_host}, delay_ms)
      index + 1
    else
      index
    end
  end

  defp maybe_schedule_startup_todo_alert(
         _previous_state,
         _next_state,
         _issue,
         index,
         _initial_dispatch_cycle?
       ),
       do: index

  defp dispatch_to_worker(%State{} = state, issue, attempt, preferred_worker_host) do
    recipient = self()

    case Slots.select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{State.issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")

        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host)
    end
  end

  defp trip_thrash_breaker(%State{} = state, issue) do
    count = get_in(state.codex_thrash_budget, [issue.id, :count]) || 0

    Logger.warning("Codex thrash detected: issue_id=#{issue.id} issue_identifier=#{issue.identifier} restarts=#{count} window_seconds=#{Config.codex_thrash_window_seconds()}; skipping dispatch")

    Alerts.emit_system("ticket.#{issue.identifier}.agent.thrash_circuit_open",
      issue: issue.identifier,
      reason: "Codex restart loop exceeded the configured thrash limit; dispatch was skipped.",
      needs_attention: true,
      severity: "warning"
    )

    state
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host) do
    case Task.Supervisor.start_child(Aiur.TaskSupervisor, fn ->
           AgentRunner.run(issue, recipient,
             attempt: attempt,
             worker_host: worker_host,
             orchestrator: recipient
           )
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{State.issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            worker_host: worker_host,
            workspace_path: nil,
            session_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            repl_pane_id: nil,
            repl_os_pid: nil,
            headless_os_pid: nil,
            agent_input_tokens: 0,
            agent_output_tokens: 0,
            agent_total_tokens: 0,
            agent_last_reported_input_tokens: 0,
            agent_last_reported_output_tokens: 0,
            agent_last_reported_total_tokens: 0,
            turn_count: 0,
            control: default_running_control(issue),
            retry_attempt: RetryEngine.normalize_retry_attempt(attempt),
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{State.issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        RetryEngine.schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host
        })
    end
  end

  defp default_running_control(%Issue{} = issue) do
    backend = CodingAgent.backend_for(issue)

    %{
      can_interrupt: CodingAgent.can_interrupt?(backend),
      safe_checkpoints: CodingAgent.safe_checkpoints(backend),
      immediate_delivery: CodingAgent.immediate_delivery?(backend),
      status: :working
    }
  end
end
