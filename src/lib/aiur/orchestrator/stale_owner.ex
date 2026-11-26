defmodule Aiur.Orchestrator.StaleOwner do
  @moduledoc """
  Stops the agent of a ticket whose ownership ref moved to another owner (MPG-105).

  The fence reports a moved claim once per {ticket, epoch}. The workspace is kept, no retry is
  scheduled, and one `system.ownership.stale_agent` alert names the ticket and epoch.
  """

  alias Aiur.Orchestrator.{AgentTeardown, State}
  alias Aiur.Signal

  @spec handle(State.t(), String.t(), integer()) :: State.t()
  def handle(%State{} = state, identifier, epoch) do
    case State.find_running_key_by_identifier(state.running, identifier) do
      nil ->
        state

      issue_id ->
        state = AgentTeardown.terminate_running_issue(state, issue_id, false, :ownership_moved)

        reason = "Ownership of #{identifier} moved past epoch #{epoch}; its agent was stopped and the workspace kept."

        Signal.alert("system.ownership.stale_agent",
          issue: identifier,
          message: reason,
          reason: reason,
          needs_attention: true,
          severity: "warning"
        )

        state
    end
  end
end
