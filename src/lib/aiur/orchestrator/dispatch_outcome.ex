defmodule Aiur.Orchestrator.DispatchOutcome do
  @moduledoc "Records empty dispatch cycles without guessing a cause."

  alias Aiur.Orchestrator.{DispatchPolicy, Slots, State}

  @spec record(State.t(), State.t(), [Aiur.Issue.t()], (String.t() -> term())) :: State.t()
  def record(before, after_cycle, issues, log_fun) do
    ready = Enum.filter(issues, &ready?(&1, before))

    if ready != [] and Slots.available_slots(after_cycle) > 0 and
         not Enum.any?(ready, &Map.has_key?(after_cycle.running, &1.id)) and is_nil(after_cycle.capacity_hold) do
      hold = %{
        reasons: reasons(after_cycle, ready),
        candidates: length(ready),
        measured_at: DateTime.utc_now()
      }

      identities = Enum.map(ready, &%{issue_id: &1.id, issue_identifier: &1.identifier})
      log_fun.("orchestrator.dispatch outcome=empty despite free slots hold=#{inspect(hold)} issues=#{inspect(identities)}")
      %{after_cycle | dispatch_selection_hold: hold}
    else
      %{after_cycle | dispatch_selection_hold: nil}
    end
  end

  defp ready?(issue, state) do
    DispatchPolicy.candidate_issue?(issue, DispatchPolicy.active_state_set(), DispatchPolicy.terminal_state_set()) and
      not Map.has_key?(state.running, issue.id)
  end

  defp selection_reason(issue, state) do
    case DispatchPolicy.dispatch_decision(issue, state) do
      {:skip, reason} -> reason
      :dispatch -> :unknown
    end
  end

  defp reasons(state, ready) do
    gates = Enum.map(state.dispatch_capacity_constraints, & &1.kind)
    declines = Enum.map(ready, &Map.get(state.dispatch_declines, &1.id, selection_reason(&1, state)))
    if gates == [], do: Enum.uniq(declines), else: Enum.uniq(gates)
  end
end
