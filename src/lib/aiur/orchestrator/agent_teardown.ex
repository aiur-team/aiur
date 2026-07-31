defmodule Aiur.Orchestrator.AgentTeardown do
  @moduledoc """
  Owns orchestrator AgentTeardown behavior.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger

  alias Aiur.AgentPubSub
  alias Aiur.Claude.RemoteControl
  alias Aiur.Opencode.ActiveTurns
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{RetryEngine, State, TokenAccounting, WorkspaceCleanup}

  # Broadcast `aiur_turn_done` for every currently-active aiur turn on
  # `identifier`. The opencode bridge's chat-completion SSE handlers
  # subscribe to `agent:<identifier>` and rely on this broadcast to
  # close cleanly. Without it, killing the AgentRunner mid-turn (via
  # `terminate_task/1`) leaves the SSE streams subscribed until their
  # 10-minute watchdog fires, then they dump duplicate system messages
  # into the chat pane (one per pre-warmed opencode slot).
  @doc false
  @spec close_active_chat_streams(String.t(), term()) :: :ok
  def close_active_chat_streams(identifier, reason) when is_binary(identifier) do
    for aiur_turn_id <- ActiveTurns.active_turn_ids(identifier) do
      AgentPubSub.broadcast_aiur_turn_done(identifier, aiur_turn_id, reason)
      ActiveTurns.mark_closed(identifier, aiur_turn_id, reason)
    end

    :ok
  end

  def close_active_chat_streams(_identifier, _reason), do: :ok

  defp terminate_reason(true), do: :terminal
  defp terminate_reason(false), do: :replaced

  @doc false
  @spec terminate_running_issue(State.t(), String.t(), boolean()) :: State.t()
  def terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    state = Orchestrator.cancel_ci_wait_rewake(state, issue_id)

    case Map.get(state.running, issue_id) do
      nil ->
        RetryEngine.release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = TokenAccounting.record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)

        # `terminate_task/1` brutally kills the runner task, skipping the
        # `after stop_session` cleanup — kill the tracked REPL pane + pid
        # here so neither orphans on abort/terminal-state teardown.
        kill_repl_session(running_entry)

        if cleanup_workspace do
          WorkspaceCleanup.cleanup_terminal_issue_artifacts(identifier, worker_host)
        end

        # Close any open chat-completion SSE streams BEFORE killing the
        # task. `terminate_task/1` brutally kills the AgentRunner,
        # bypassing the normal `close_aiur_turn_streams` path; without
        # the explicit close the bridge streams stay subscribed at the
        # old `aiur_turn_id` and miss every event the next-dispatched
        # agent emits. The Executor sees an empty chat pane until the
        # 10-minute watchdog fires.
        close_active_chat_streams(identifier, terminate_reason(cleanup_workspace))

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        RetryEngine.release_issue_claim(state, issue_id)
    end
  end

  # Mirrors `terminate_running_issue/3`'s task-teardown half (kill the
  # codex pid, demonitor the ref) but KEEPS the entry in `state.running`
  # with `control.status: :deactivated` and `pid: nil`. The row stays
  # visible in the AgentList at 🏁 / 100% green while the slot is freed.
  # Idempotent — re-running on an already-deactivated entry is a no-op.
  #
  # Mutates the entry directly via `put_in/2` rather than calling
  # `put_running_control_status/3`, whose guard whitelist only accepts
  # `[:paused, :working]` (it gates pause/resume control messages, which
  # `:deactivated` is not).
  @spec deactivate_running_issue(State.t(), term()) :: State.t()
  def deactivate_running_issue(%State{} = state, issue_id) do
    case Map.get(state.running, issue_id) do
      nil ->
        state

      %{control: %{status: :deactivated}} ->
        # Already deactivated — observed the same label again.
        state

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        Logger.info("Issue deactivated (human-review): issue_id=#{issue_id} identifier=#{identifier}; keeping running entry, freeing slot")

        completed_provenance? = State.completed_provenance?(running_entry)

        state =
          if completed_provenance?,
            do: TokenAccounting.record_session_completion_totals(state, running_entry),
            else: state

        # Close any open chat-completion SSE streams for this identifier
        # BEFORE killing the task. `terminate_task/1` brutally kills the
        # AgentRunner, bypassing the normal `close_aiur_turn_streams`
        # path — without an explicit close, the bridge streams stay
        # subscribed for 10 minutes, hit their watchdog, and dump
        # duplicate "No turn activity in 10 minutes" system messages
        # into the chat pane (one per pre-warm slot).
        close_active_chat_streams(identifier, :deactivated)

        # Kill the OS-level claude/node subtree so no orphaned processes
        # linger after the runner task dies, but leave the REPL pane open
        # for inspection — the operator still needs to see the finished
        # conversation. (contrast with terminate_running_issue, which kills
        # both pane and pids on a hard abort/cancel).
        kill_repl_session_os_only(running_entry)

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        existing_control = Map.get(running_entry, :control, %{})

        new_entry =
          running_entry
          |> Map.put(:pid, nil)
          |> Map.put(:ref, nil)
          |> Map.put(:control, Map.put(existing_control, :status, :deactivated))
          |> maybe_preserve_completed_provenance(completed_provenance?)

        new_state =
          %{
            state
            | running: Map.put(state.running, issue_id, new_entry),
              retry_attempts: Map.delete(state.retry_attempts, issue_id)
          }
          |> evict_prior_deactivated(issue_id)

        # Drop the id from the publisher's tracked set so in-flight events
        # from the just-killed codex task don't pass the gate and overwrite
        # the synthetic 100 bar sample.
        Orchestrator.refresh_tracked_set(new_state)
    end
  end

  # Removes all previously-deactivated entries from state.running except the
  # one just deactivated (current_issue_id). Without this, each human-review
  # completion accumulates a retained AttachPool slot indefinitely (until the
  # PR is merged or the daemon restarts), and a pool of 3 pre-warmed sessions
  # would be exhausted by 3 sequential completions. The most recently finished
  # agent's pane remains open for inspection; older ones are freed immediately
  # so the pool stays available for new dispatches.
  defp evict_prior_deactivated(%State{} = state, current_issue_id) do
    to_evict =
      for {id, entry} <- state.running,
          id != current_issue_id,
          State.deactivated_running_entry?(entry),
          do: {id, entry}

    # Reap the OS subtree of each evicted entry. The current entry's
    # repl_os_pid is intentionally left alive (its open pane depends on it);
    # these older entries no longer have a pane to preserve.
    Enum.each(to_evict, fn {_id, entry} ->
      RemoteControl.graceful_kill_tree(Map.get(entry, :repl_os_pid))
    end)

    evict_ids = Enum.map(to_evict, &elem(&1, 0))

    %{
      state
      | running: Map.drop(state.running, evict_ids),
        claimed: Enum.reduce(evict_ids, state.claimed, &MapSet.delete(&2, &1))
    }
  end

  @doc false
  @spec terminate_task(term()) :: :ok
  def terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(Aiur.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :kill)
    end
  end

  def terminate_task(_pid), do: :ok

  defp maybe_preserve_completed_provenance(entry, true) do
    entry
    |> Map.put(:completed_provenance, true)
    |> Map.put(:completion_totals_recorded, true)
  end

  defp maybe_preserve_completed_provenance(entry, false), do: entry

  # Kill the persistent-REPL pane + claude OS pid tracked on the running
  # entry. Idempotent and tolerant of a half-dead session (pane gone but
  # pid alive, or vice versa) — each kill is independent and a missing
  # pane/pid is a no-op.
  @doc false
  @spec kill_repl_session(map()) :: :ok
  def kill_repl_session(running_entry) do
    pane_id = Map.get(running_entry, :repl_pane_id)
    os_pid = Map.get(running_entry, :repl_os_pid)

    if is_binary(pane_id), do: Aiur.Tmux.kill_pane(pane_id)

    # The REPL pane's `exec claude` can spawn tool/MCP children that would
    # orphan and keep working on a single-pid kill, so reap the subtree.
    RemoteControl.graceful_kill_tree(os_pid)

    # The headless fallback has no pane; its `bash -lc` wrapper leaves
    # claude/node grandchildren that reparent to init, so reap the subtree.
    RemoteControl.graceful_kill_tree(Map.get(running_entry, :headless_os_pid))

    :ok
  end

  # Like kill_repl_session but leaves the REPL pane open. Used on the
  # human-review deactivation path so the finished conversation stays
  # visible for operator inspection.
  #
  # Does NOT kill repl_os_pid: for persistent-REPL agents, `exec claude`
  # makes claude the pane's top process, so killing repl_os_pid would
  # close the pane via tmux's remain-on-exit behavior. Headless pids have
  # no associated pane and are safe to reap.
  @doc false
  @spec kill_repl_session_os_only(map()) :: :ok
  def kill_repl_session_os_only(running_entry) do
    case RemoteControl.graceful_kill_tree(Map.get(running_entry, :headless_os_pid)) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("headless pid kill failed on deactivation", reason: reason)
    end

    :ok
  end
end
