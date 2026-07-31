defmodule Aiur.Orchestrator.Interrupts do
  @moduledoc """
  Owns Ctrl+C and pane-interrupt decisions for running agents.
  All functions execute inside the orchestrator GenServer process.
  """

  alias Aiur.Claude.ReplAgent
  alias Aiur.Opencode.ActiveTurns
  alias Aiur.Orchestrator.{OperatorMessages, PauseResume, State}

  @spec interrupt_agent(String.t()) :: :ok | {:error, term()}
  def interrupt_agent(issue_identifier),
    do: interrupt_agent(Aiur.Orchestrator, issue_identifier)

  @spec interrupt_agent(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def interrupt_agent(server, issue_identifier),
    do: control_api_call(server, {:interrupt_agent, issue_identifier})

  @spec pane_interrupt(String.t()) ::
          {:ok, :interrupted | :pause_requested | :paused | :close_pane | :send_interrupt} | {:error, term()}
  def pane_interrupt(issue_identifier),
    do: pane_interrupt(Aiur.Orchestrator, issue_identifier)

  @spec pane_interrupt(GenServer.server(), String.t()) ::
          {:ok, :interrupted | :pause_requested | :paused | :close_pane | :send_interrupt} | {:error, term()}
  def pane_interrupt(server, issue_identifier),
    do: control_api_call(server, {:pane_interrupt, issue_identifier})

  @spec pane_interrupt_by_pane_id(String.t()) ::
          {:ok, :interrupted | :pause_requested | :paused | :close_pane | :send_interrupt} | {:error, term()}
  def pane_interrupt_by_pane_id(pane_id),
    do: pane_interrupt_by_pane_id(Aiur.Orchestrator, pane_id)

  @spec pane_interrupt_by_pane_id(GenServer.server(), String.t()) ::
          {:ok, :interrupted | :pause_requested | :paused | :close_pane | :send_interrupt} | {:error, term()}
  def pane_interrupt_by_pane_id(server, pane_id) when is_binary(pane_id),
    do: control_api_call(server, {:pane_interrupt_by_pane_id, pane_id})

  @spec interrupt_agent_call(State.t(), String.t()) :: {:reply, term(), State.t()}
  def interrupt_agent_call(%State{} = state, issue_identifier) do
    {:reply, interrupt_agent_reply(state, issue_identifier), state}
  end

  @spec pane_interrupt_call(State.t(), String.t()) :: {:reply, term(), State.t()}
  def pane_interrupt_call(%State{} = state, issue_identifier) do
    {reply, state} = pane_interrupt_reply(state, issue_identifier)
    {:reply, reply, state}
  end

  @spec pane_interrupt_by_pane_id_call(State.t(), String.t()) ::
          {:reply, term(), State.t()}
  def pane_interrupt_by_pane_id_call(%State{} = state, pane_id) when is_binary(pane_id) do
    case State.find_running_by_repl_pane_id(state.running, pane_id) do
      %{identifier: identifier} ->
        pane_interrupt_call(state, to_string(identifier))

      nil ->
        {:reply, {:error, :no_pane_agent}, state}
    end
  end

  # Out-of-band interrupt: send Ctrl+C straight to the REPL pane so Claude
  # cuts its active turn and its native queue drains the waiting message.
  # Only the persistent-REPL backend exposes a pane to interrupt; every
  # other backend folds Executor input at a turn boundary instead, so they
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

  # Executor pressed Ctrl+C on the agent's opencode pane. The action is
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
        # on the now-paused agent closes the pane. A deactivated (human-review)
        # agent has no active turn and no recoverable state — any Ctrl+C closes
        # the finished pane immediately.
        if State.deactivated_running_entry?(running_entry) do
          # Remove the entry from running so AttachPool reclaims the slot on
          # the next seed (the entry disappears from retain_ids). PaneManager
          # broadcasts agent_inactive and performs the real pane close/deselect,
          # superseding the bridge's hide_pane fallback. Without this deletion,
          # repeated human-review completions accumulate retained-but-hidden
          # slots and eventually exhaust the pre-warm pool.
          issue_id = State.find_running_key_by_identifier(state.running, issue_identifier)

          new_state =
            if issue_id,
              do: %{state | running: Map.delete(state.running, issue_id)},
              else: state

          {{:ok, :close_pane}, new_state}
        else
          working? = ActiveTurns.active_turn_ids(issue_identifier) != []

          action =
            pane_interrupt_action_no_pane(
              State.paused_running_entry?(running_entry),
              working?
            )

          perform_pane_interrupt(action, state, running_entry, issue_identifier, nil)
        end

      _ ->
        {{:error, :not_running}, state}
    end
  end

  defp perform_pane_interrupt(:close_pane, state, _entry, _issue_identifier, _pane_id),
    do: {{:ok, :close_pane}, state}

  # The agent is mid-turn. opencode owns the interrupt: the bridge forwards its
  # native interrupt key (Esc) to the pane, which drains opencode's queued
  # Executor message and continues the turn. Aiur mutates no state — it does
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

  # A Ctrl+C pause shares the worker-confirmed control lifecycle. Returning
  # `:pause_requested` keeps the pane open without presenting the agent as
  # paused before its current worker generation acknowledges the transition.
  defp perform_pane_interrupt(:pause, state, _entry, issue_identifier, _pane_id) do
    case PauseResume.pause_agent_reply(state, issue_identifier) do
      {{:ok, _request_id}, state} -> {{:ok, :pause_requested}, state}
      {error, state} -> {error, state}
    end
  end

  defp control_api_call(server, request) do
    if GenServer.whereis(server) do
      GenServer.call(server, request, 5_000)
    else
      {:error, :unavailable}
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
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
