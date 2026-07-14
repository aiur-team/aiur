defmodule Aiur.Codex.Interrupts do
  @moduledoc """
  Codex-specific interrupt error tolerance.
  """

  alias Aiur.AppServer.TurnState
  alias Aiur.Codex.NotificationPolicy

  @spec handle_interrupt_error(map(), term()) ::
          {:ok, :turn_completed} | {:continue, map()} | {:error, term()}
  def handle_interrupt_error(state, error) do
    if NotificationPolicy.no_active_turn_error?(error) do
      # Codex says "no active turn to interrupt" (-32600). The turn
      # ended on its own between us deciding to interrupt and codex
      # processing the request. There's nothing left to interrupt —
      # treat it the same as a successful interrupt so the Executor
      # message / pause request gets handled on the next cycle.
      # Without this, the AgentRunner Task crashes with
      # `{:turn_interrupt_failed, ...}` and the orchestrator dumps a
      # `system:` line into the chat pane (recurrent issue
      # triggered by U5's reactivation flow, where a fresh agent
      # task receives an Executor-queue update before its first
      # codex turn has spawned).
      next_state = %{state | pending_interrupt_request_id: nil, interrupt_action: nil}

      if Map.get(state, :interrupt_idle_seen?, false) do
        TurnState.complete_all_provider_turns(next_state)
      else
        {:continue, next_state}
      end
    else
      {:error, {:turn_interrupt_failed, error}}
    end
  end
end
