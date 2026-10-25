defmodule Aiur.Orchestrator.DispatchOutcome do
  @moduledoc "Records empty dispatch cycles without guessing a cause."

  alias Aiur.Orchestrator.{DispatchPolicy, Slots, State}

  @doc """
  Records whether a finished dispatch cycle left ready tickets unstarted with
  free slots, and why.

  `stop_reason` names why the candidate batch ended before it reached every
  ticket (`:orchestrator_backlog`, `:stale_load_sample`). A ticket the batch
  never reached has no decline of its own, so it carries that reason instead of
  `:unknown` (#3683).
  """
  @spec record(State.t(), State.t(), [Aiur.Issue.t()], (String.t() -> term()), atom() | nil) :: State.t()
  def record(before, after_cycle, issues, log_fun, stop_reason \\ nil) do
    ready = Enum.filter(issues, &ready?(&1, before))

    if ready != [] and Slots.available_slots(after_cycle) > 0 and
         not Enum.any?(ready, &Map.has_key?(after_cycle.running, &1.id)) and is_nil(after_cycle.capacity_hold) do
      hold = %{
        reasons: reasons(after_cycle, ready, stop_reason),
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

  defp selection_reason(issue, state, stop_reason) do
    case DispatchPolicy.dispatch_decision(issue, state) do
      {:skip, reason} -> reason
      :dispatch -> stop_reason || :unknown
    end
  end

  defp reasons(state, ready, stop_reason) do
    gates = Enum.map(state.dispatch_capacity_constraints, & &1.kind)
    declines = Enum.map(ready, &Map.get(state.dispatch_declines, &1.id, selection_reason(&1, state, stop_reason)))
    if gates == [], do: Enum.uniq(declines), else: Enum.uniq(gates)
  end
end
