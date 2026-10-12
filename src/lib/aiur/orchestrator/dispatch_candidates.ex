defmodule Aiur.Orchestrator.DispatchCandidates do
  @moduledoc "Orders ready, optimistic, then held candidates using cached dependency evidence only."

  alias Aiur.BuildQueue.Hints
  alias Aiur.Issue
  alias Aiur.Orchestrator.{DependencyGate, DispatchPolicy}
  alias Aiur.StartTrigger.CriticalPath

  @spec order([Issue.t()], MapSet.t(), [Issue.t()]) :: [Issue.t()]
  def order(issues, terminal_states, polled \\ []) do
    groups = issues |> DispatchPolicy.sort_issues_for_dispatch() |> Enum.group_by(&tier(&1, terminal_states))
    optimistic = optimistic_order(Map.get(groups, :optimistic, []), polled ++ issues, terminal_states)
    Map.get(groups, :ready, []) ++ optimistic ++ Map.get(groups, :held, [])
  end

  defp optimistic_order([], _issues, _terminal), do: []

  defp optimistic_order(optimistic, issues, terminal_states) do
    snapshot = Enum.uniq_by(issues, & &1.id) |> Enum.map(&DependencyGate.cached_issue/1)
    native = native_ranks(snapshot, terminal_states)

    Enum.sort_by(optimistic, fn issue ->
      {depth, count} = Hints.critical_rank(issue.id) || Map.get(native, issue.id, {0, 0})
      {-depth, -count}
    end)
  end

  defp native_ranks(issues, terminal_states) do
    edges = for issue <- issues, blocker <- issue.blocked_by || [], is_binary(blocker[:id]), do: {blocker.id, issue.id}
    open = for issue <- issues, not DispatchPolicy.terminal_issue_state?(issue.state, terminal_states), do: issue.id
    CriticalPath.ranks(edges, open)
  end

  defp tier(issue, terminal_states) do
    hydrated = DependencyGate.cached_issue(issue)

    case DependencyGate.classify(hydrated, terminal_states) do
      :held -> if DispatchPolicy.normalize_issue_state(issue.state) == "todo", do: :held, else: :ready
      tier -> if Hints.held?(issue.id), do: :held, else: tier
    end
  end
end
