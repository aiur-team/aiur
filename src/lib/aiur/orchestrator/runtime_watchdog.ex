defmodule Aiur.Orchestrator.RuntimeWatchdog do
  @moduledoc """
  Owns orchestrator RuntimeWatchdog behavior.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger

  alias Aiur.{Alerts, Config, Issue}
  alias Aiur.Orchestrator.{AgentTeardown, PauseResume, RetryEngine, State}

  @spec apply_overrun_check(State.t(), non_neg_integer()) :: State.t()
  def apply_overrun_check(%State{} = state, max_seconds)
      when is_integer(max_seconds) and max_seconds >= 0 do
    now = DateTime.utc_now()

    Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
      maybe_pause_overrunning_entry(state_acc, issue_id, running_entry, now, max_seconds)
    end)
  end

  @spec apply_stall_check(State.t(), pos_integer()) :: State.t()
  def apply_stall_check(%State{} = state, timeout_ms) when is_integer(timeout_ms) do
    now = DateTime.utc_now()

    Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
      restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
    end)
  end

  # Safety check-in, not a kill: pause any agent that has been actively
  # running longer than `agent.max_agent_duration_minutes` (paused/blocked
  # time excluded via `running_seconds/2`). The duration cap is almost
  # always "I want to check in," not "this work is done" — pausing keeps
  # the agent in the list, retaining its session/turn context so the
  # Executor can review and resume with one keystroke instead of
  # restarting from scratch. The pause releases its fleet reservation
  # (`@non_reserving_pause_reasons`), so a parked agent cannot pin a
  # capacity slot indefinitely (#2329).
  @doc false
  @spec reconcile_overrunning_agents(State.t()) :: State.t()
  def reconcile_overrunning_agents(%State{} = state) do
    max_seconds = Config.max_agent_duration_minutes() * 60

    cond do
      max_seconds <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          maybe_pause_overrunning_entry(state_acc, issue_id, running_entry, now, max_seconds)
        end)
    end
  end

  # True when an entry has exceeded the duration cap: actively running
  # (not paused/deactivated) past `max_seconds`. Paused entries are
  # excluded so a duration-paused agent is never re-paused on the next
  # tick (its `running_seconds` is frozen while paused, but the guard
  # makes the intent explicit).
  @doc false
  @spec overrunning_entry?(map(), DateTime.t(), non_neg_integer()) :: boolean()
  def overrunning_entry?(running_entry, now, max_seconds) when is_map(running_entry) do
    not State.paused_running_entry?(running_entry) and
      not State.deactivated_running_entry?(running_entry) and
      State.running_seconds(Map.get(running_entry, :started_at), now) > max_seconds
  end

  # Route a cooperative pause through the control lifecycle. The duration
  # cap becomes authoritative only after matching worker evidence confirms
  # that the worker actually parked.
  @doc false
  @spec maybe_pause_overrunning_entry(State.t(), term(), map(), DateTime.t(), non_neg_integer()) :: State.t()
  def maybe_pause_overrunning_entry(state, issue_id, running_entry, now, max_seconds) do
    if overrunning_entry?(running_entry, now, max_seconds) do
      identifier = Map.get(running_entry, :identifier, issue_id)
      seconds = State.running_seconds(Map.get(running_entry, :started_at), now)

      Logger.warning("orchestrator.pause issue_id=#{issue_id} issue_identifier=#{identifier} cause=max_agent_duration running_seconds=#{seconds} cap_seconds=#{max_seconds}")

      {_reply, state} =
        PauseResume.request_pause(
          state,
          running_entry,
          Map.get(running_entry, :issue),
          :max_agent_duration
        )

      state
    else
      state
    end
  end

  @doc false
  @spec reconcile_stalled_running_issues(State.t()) :: State.t()
  def reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.agent_stall_timeout_ms()

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  @doc false
  @spec restart_stalled_issue(State.t(), term(), map(), DateTime.t(), non_neg_integer()) :: State.t()
  def restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    cond do
      # Runaway safety net: a duration-capped pause asked the worker to
      # park cooperatively at its next turn boundary, but a truly wedged
      # agent (single never-ending codex turn) never reaches one, so it
      # keeps streaming past the pause. Such an entry would otherwise sit
      # `:paused` forever — the duration cap can never re-fire (paused
      # entries are excluded) and the Executor’s resume never comes. Once
      # it has been wedged past the grace window, force-terminate it. This
      # is the only place a duration cap escalates to a kill; a cooperative
      # park stops the codex stream and is left alone.
      wedged_overcap_entry?(running_entry, now, timeout_ms) ->
        terminate_wedged_overcap_entry(state, issue_id, running_entry, now)

      # Paused agents are INTENTIONALLY idle — the agent emitted
      # pause.request because it declared a blocker and has nothing to
      # do until the blocker emits. The stall watchdog must not
      # interpret deliberate idleness as a stuck codex stream. The
      # explicit-unblocked auto-resume hook in handle_info({:event, ...})
      # will reawaken the entry when its blocker emits readiness. If no signal
      # Executor-driven resume (label flip or chat) is the path
      # forward, not a restart that throws away the agent's workpad.
      State.paused_running_entry?(running_entry) ->
        state

      # Deactivated entries don't have a live codex stream to stall on
      # in the first place — the worker task was killed when the entry
      # was deactivated. Skip them; the reactivate path is the only
      # transition back to :working.
      State.deactivated_running_entry?(running_entry) ->
        state

      true ->
        maybe_restart_stalled_entry(state, issue_id, running_entry, now, timeout_ms)
    end
  end

  # True when a duration-capped paused entry is WEDGED rather than parked:
  # it kept streaming codex after the cooperative `{:pause_agent}` was sent
  # (so `last_codex_timestamp` is newer than `paused_at`) and has stayed
  # that way longer than the grace window (`timeout_ms`, the stall budget).
  # A cooperatively-parked agent stops streaming at its turn boundary, so
  # its `last_codex_timestamp` does not advance past `paused_at` — those
  # are left to the Executor/blocker resume, never killed here.
  @doc false
  @spec wedged_overcap_entry?(map(), DateTime.t(), non_neg_integer()) :: boolean()
  def wedged_overcap_entry?(running_entry, now, timeout_ms) when is_map(running_entry) do
    with true <- State.paused_running_entry?(running_entry),
         :max_agent_duration <- Map.get(running_entry, :paused_reason),
         %DateTime{} = paused_at <- Map.get(running_entry, :paused_at),
         %DateTime{} = last_codex <- Map.get(running_entry, :last_codex_timestamp) do
      # Streamed after we asked it to park -> never honored the park.
      still_streaming? = DateTime.compare(last_codex, paused_at) == :gt
      grace_elapsed? = DateTime.diff(now, paused_at, :millisecond) > timeout_ms

      still_streaming? and grace_elapsed?
    else
      _ -> false
    end
  end

  def wedged_overcap_entry?(_running_entry, _now, _timeout_ms), do: false

  defp terminate_wedged_overcap_entry(state, issue_id, running_entry, now) do
    identifier = Map.get(running_entry, :identifier, issue_id)
    wedged_for_ms = DateTime.diff(now, Map.get(running_entry, :paused_at), :millisecond)

    Logger.warning("Wedged over-cap agent escalated to terminate: issue_id=#{issue_id} issue_identifier=#{identifier} wedged_ms=#{wedged_for_ms}; never parked after max_agent_duration pause")

    AgentTeardown.terminate_running_issue(state, issue_id, false)
  end

  defp maybe_restart_stalled_entry(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = State.running_entry_session_id(running_entry)

      Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

      _ =
        Alerts.emit_custom(
          "ticket.#{identifier}.agent.stalled",
          "Agent command made no progress for #{elapsed_ms}ms; terminating it and scheduling a retry",
          issue: Map.get(running_entry, :issue),
          workspace: Map.get(running_entry, :workspace_path),
          worker_host: Map.get(running_entry, :worker_host),
          reason: "agent command exceeded the #{timeout_ms}ms no-progress window without completing or returning an error",
          needs_attention: true,
          severity: "warning"
        )

      next_attempt = RetryEngine.next_retry_attempt_from_running(running_entry)

      state
      |> AgentTeardown.terminate_running_issue(issue_id, false)
      |> RetryEngine.schedule_issue_retry(issue_id, next_attempt, %{
        identifier: identifier,
        tracker_identity: Issue.tracker_identity(Map.get(running_entry, :issue)),
        issue_state: Map.get(Map.get(running_entry, :issue) || %{}, :state),
        error: "stalled for #{elapsed_ms}ms without codex activity",
        prior_work: RetryEngine.prior_work_for_retry?(running_entry),
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path)
      })
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end
end
