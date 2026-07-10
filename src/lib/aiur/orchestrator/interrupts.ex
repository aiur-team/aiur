defmodule Aiur.Orchestrator.Interrupts do
  @moduledoc """
  Owns Ctrl+C and pane-interrupt decisions for running agents.
  All functions execute inside the orchestrator GenServer process.
  """

  alias Aiur.Claude.ReplAgent
  alias Aiur.Opencode.ActiveTurns
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{OperatorMessages, PauseResume, State}

  # Out-of-band interrupt: send Ctrl+C straight to the REPL pane so Claude
  # cuts its active turn and its native queue drains the waiting message.
  # Only the persistent-REPL backend exposes a pane to interrupt; every
  # other backend folds operator input at a turn boundary instead, so they
  # report `:interrupt_not_supported`.
  @doc false
  @spec interrupt_agent_reply(State.t(), String.t()) :: term()
  def interrupt_agent_reply(state, issue_identifier) do
    case State.find_running_by_identifier(state.running, issue_identifier) do
      %{repl_pane_id: pane_id} when is_binary(pane_id) ->
        ReplAgent.interrupt(%{tmux: Aiur.Tmux, pane_id: pane_id})

      running_entry when is_map(running_entry) ->
        {:error, :interrupt_not_supported}

      _ ->
        {:error, :not_running}
    end
  end

  # Operator pressed Ctrl+C on the agent's opencode pane. The action is
  # derived from the agent's live state, matching the Claude/Codex mental
  # model: a queued message drains right away, an idle agent pauses, and a
  # second press on an already-paused agent closes the pane (the caller
  # performs the kill; the agent stays parked and paused). Only the
  # persistent-REPL backend exposes a pane to drain, so other backends
  # report `:interrupt_not_supported` and the caller falls back to a plain
  # pane close.
  @doc false
  @spec pane_interrupt_reply(State.t(), String.t()) :: {term(), State.t()}
  def pane_interrupt_reply(state, issue_identifier) do
    case State.find_running_by_identifier(state.running, issue_identifier) do
      %{repl_pane_id: pane_id} = entry when is_binary(pane_id) ->
        action =
          pane_interrupt_action(
            State.paused_running_entry?(entry),
            OperatorMessages.queue_depth_for_issue(state, issue_identifier)
          )

        perform_pane_interrupt(action, state, entry, issue_identifier, pane_id)

      running_entry when is_map(running_entry) ->
        # opencode/codex own their queue and turn; Aiur cannot see them via
        # AgentQueueStore. The one turn-activity signal Aiur owns is
        # ActiveTurns — a live aiur-mediated codex turn registers there. So a
        # Ctrl+C on a working agent sends opencode's native interrupt (the
        # caller forwards Esc to the pane), which drains its queued message and
        # keeps it working. Only a genuinely idle agent pauses; a second press
        # on the now-paused agent closes the pane.
        working? = ActiveTurns.active_turn_ids(issue_identifier) != []

        action =
          pane_interrupt_action_no_pane(
            State.paused_running_entry?(running_entry),
            working?
          )

        perform_pane_interrupt(action, state, running_entry, issue_identifier, nil)

      _ ->
        {{:error, :not_running}, state}
    end
  end

  defp perform_pane_interrupt(:close_pane, state, _entry, _issue_identifier, _pane_id),
    do: {{:ok, :close_pane}, state}

  # The agent is mid-turn. opencode owns the interrupt: the bridge forwards its
  # native interrupt key (Esc) to the pane, which drains opencode's queued
  # operator message and continues the turn. Aiur mutates no state — it does
  # not flip control status or send a pause message — and the bridge keeps the
  # pane open on this reply.
  defp perform_pane_interrupt(:send_interrupt, state, _entry, _issue_identifier, _pane_id),
    do: {{:ok, :send_interrupt}, state}

  defp perform_pane_interrupt(:interrupt, state, _entry, _issue_identifier, pane_id) do
    # `:interrupt` is only ever chosen when a message is queued. The hardware
    # interrupt is best-effort: a failure (repl pane already gone, tmux hiccup)
    # must not close the pane out from under the pending message — propagating
    # the error makes the bridge controller map it to :close_pane and the
    # helper kill the pane, dropping the queued input. Keep the pane open so
    # the message folds at the next turn boundary.
    _ = ReplAgent.interrupt(%{tmux: Aiur.Tmux, pane_id: pane_id})
    {{:ok, :interrupted}, state}
  end

  # Optimistically flip the entry to `:paused` (mirrors `maybe_pause_on_request`)
  # so a second Ctrl+C reads the agent as paused and closes the pane. An idle
  # agent emits no `:worker_control_state :paused` confirmation, so depending on
  # that async signal alone would strand the agent reporting `:pause` forever
  # and the close branch would never be reachable. The queued control message
  # still drives the worker loop when it is mid-turn; its reply is ignored
  # because the optimistic transition is the source of truth for the UI.
  defp perform_pane_interrupt(:pause, state, entry, issue_identifier, _pane_id) do
    _ = PauseResume.send_pause_control_message(state, issue_identifier)
    paused_entry = Map.put(entry, :paused_reason, :pane_ctrl_c)
    {{:ok, :paused}, Orchestrator.transition_control_status(state, paused_entry, :paused, "pane.ctrl_c.pause")}
  end

  @doc """
  Pure 3-state Ctrl+C decision. A paused agent closes its pane; an agent
  with a queued message drains it; an idle agent pauses. Public so the
  mapping can be unit-tested without scaffolding the REPL pane or queue.
  """
  @spec pane_interrupt_action(boolean(), non_neg_integer()) ::
          :close_pane | :interrupt | :pause
  def pane_interrupt_action(paused?, queue_depth)
      when is_boolean(paused?) and is_integer(queue_depth) do
    cond do
      paused? -> :close_pane
      queue_depth > 0 -> :interrupt
      true -> :pause
    end
  end

  @doc """
  Pure Ctrl+C decision for backends with no Aiur-interruptible pane
  (codex/opencode), which own their own queue and turn. `working?` is the
  ActiveTurns signal: true when a live aiur-mediated turn is in flight. A
  working agent gets opencode's native interrupt forwarded (the caller sends
  Esc to the pane) so its queued message drains and it keeps working — Aiur
  takes no destructive action and mutates no state. A genuinely idle agent
  pauses (pane stays open); a second press on the now-paused agent closes it.
  Public so the mapping can be unit-tested without scaffolding a worker.
  """
  @spec pane_interrupt_action_no_pane(boolean(), boolean()) ::
          :send_interrupt | :close_pane | :pause
  def pane_interrupt_action_no_pane(paused?, working?)
      when is_boolean(paused?) and is_boolean(working?) do
    cond do
      paused? -> :close_pane
      working? -> :send_interrupt
      true -> :pause
    end
  end
end
