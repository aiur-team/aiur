defmodule Aiur.DecisionStore.CorrectiveFollowUp do
  @moduledoc false

  alias Aiur.Commands.Overrides
  alias Aiur.DecisionStore.{Audit, Revisions}

  @spec reconcile(map(), Aiur.Decision.t()) :: {:ok, map()} | {:error, term(), map()}
  def reconcile(state, decision) do
    action = decision.active_action_id
    record = Enum.find(decision.overrides, &(&1.action_id == action))

    case {record, Map.get(Map.get(decision, :revision_follow_ups, %{}), action)} do
      {%{corrective_ticket: ticket}, %{handled_at: nil}} when is_map(ticket) ->
        detail = "Replaced by corrective ticket ##{Overrides.target_ticket(decision).identifier}"

        case Revisions.do_handle_revision_follow_up(decision.decision_id, action, [actor: Audit.system_actor(), detail: detail], state) do
          {:reply, {:ok, _result}, next} -> {:ok, next}
          {:reply, {:error, reason}, next} -> {:error, reason, next}
        end

      _no_unhandled_follow_up ->
        {:ok, state}
    end
  end
end
