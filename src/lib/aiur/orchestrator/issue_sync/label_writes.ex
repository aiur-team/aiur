defmodule Aiur.Orchestrator.IssueSync.LabelWrites do
  @moduledoc """
  Schedules guarded state-label writes and applies current reconciliation results.
  """

  alias Aiur.Orchestrator.Lifecycle
  alias Aiur.Orchestrator.Reconciler
  alias Aiur.Orchestrator.TicketTransition
  alias Aiur.Orchestrator.TrackerTasks

  @doc false
  @spec schedule_label_heal(Aiur.Orchestrator.State.t(), Aiur.Issue.t(), String.t(), function(), function()) :: {nil, Aiur.Orchestrator.State.t()}
  def schedule_label_heal(state, issue, target, update_state_fun, apply_heal) do
    input = Reconciler.issue_input(state, issue.id)

    state =
      TrackerTasks.run(state, {:label_heal, issue.id}, fn -> write_label_heal({issue, target, update_state_fun}) end, fn arg1, arg2 -> apply_label_heal(arg1, arg2, {apply_heal, input, issue}) end)

    # Until the guarded write finishes, dispatch has no authoritative healed issue.
    {nil, state}
  end

  @doc false
  @spec guarded_update_fun([Aiur.Issue.t()], (Aiur.Issue.t(), String.t() -> term())) ::
          (String.t(), String.t() -> term())
  def guarded_update_fun(issues, update_fun \\ &write_ticket_state/2) do
    fn identifier, target ->
      case Enum.find(issues, &(&1.identifier == identifier)) do
        nil -> {:error, :outside_tracker_scope}
        issue -> update_fun.(issue, target)
      end
    end
  end

  defp write_ticket_state(issue, target),
    do: TicketTransition.write_state(issue.identifier, target, writer: :issue_sync, expected_state: issue.state)

  defp write_label_heal({issue, target, update_state_fun}), do: update_state_fun.(issue.identifier, target)

  defp apply_label_heal(current, result, {apply_heal, input, issue}) do
    if Reconciler.issue_input(current, issue.id) == input do
      {_issue, current} = apply_heal.(issue, current, fn _identifier, _target -> result end)
      Lifecycle.wake_tick(current)
    else
      Lifecycle.wake_tick(current)
    end
  end
end
