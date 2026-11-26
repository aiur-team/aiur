defmodule Aiur.Orchestrator.DispatchCandidates do
  @moduledoc "Orders ready, optimistic, then held candidates using cached dependency evidence only."

  alias Aiur.BuildQueue.Hints
  alias Aiur.{Config, Issue, MergePolicy}
  alias Aiur.GitHub.Tracker
  alias Aiur.Orchestrator.{DependencyGate, DispatchPolicy, QueueSetSlots}
  alias Aiur.StartTrigger.CriticalPath

  @spec order([Issue.t()], MapSet.t(), [Issue.t()]) :: [Issue.t()]
  def order(issues, terminal_states, polled \\ []) do
    {ready, optimistic, held} = ordered_tiers(issues, terminal_states, polled)
    ready ++ optimistic ++ held
  end

  defp ordered_tiers(issues, terminal_states, polled) do
    groups = issues |> DispatchPolicy.sort_issues_for_dispatch() |> Enum.group_by(&tier(&1, terminal_states))
    optimistic = optimistic_order(Map.get(groups, :optimistic, []), polled ++ issues, terminal_states)

    ordering = QueueSetSlots.ordering()

    ready =
      Enum.sort_by(Map.get(groups, :ready, []), fn issue ->
        {member, rank, position} = QueueSetSlots.sort_key(issue.id, ordering)
        {DispatchPolicy.priority_rank(issue.priority), if(MergePolicy.fixer_ticket?(issue), do: 0, else: 1), member, rank, position, Hints.sort_key(issue.id), DispatchPolicy.work_kind_rank(issue)}
      end)

    optimistic =
      Enum.sort_by(optimistic, fn issue ->
        {member, rank, _position} = QueueSetSlots.sort_key(issue.id, ordering)
        {member, rank}
      end)

    {ready, optimistic, Map.get(groups, :held, [])}
  end

  @doc "Partitions candidates into the validation chain, cached holds, and reasons for deferring lower admission tiers."
  @spec partition([Issue.t()], MapSet.t(), [Issue.t()]) :: {[Issue.t()], [Issue.t()], [{Issue.t(), atom()}]}
  def partition(issues, terminal_states, polled \\ []) do
    github? = Config.settings!().tracker.kind == "github"
    {ready, optimistic, held} = ordered_tiers(issues, terminal_states, polled)

    classified = Enum.map(ready ++ optimistic ++ held, &classify(&1, terminal_states, github?))
    chain = pick(classified, :chain)
    last = pick(classified, :last)
    deferred = Enum.map(optimistic, &{&1, :optimistic_tier}) ++ Enum.map(last, &{&1, :dependency_recheck})

    {chain ++ last, pick(classified, :held), deferred}
  end

  defp pick(classified, class), do: for({^class, issue} <- classified, do: issue)

  defp classify(issue, terminal_states, github?) do
    cond do
      github? and DispatchPolicy.normalize_issue_state(issue.state) == "todo" -> classify_cached(issue, terminal_states)
      open_blocker?(issue, terminal_states) -> {:last, issue}
      true -> {:chain, issue}
    end
  end

  defp classify_cached(issue, terminal_states) do
    case Tracker.cached_blocked_by(issue) do
      {:ok, hydrated} -> if open_blocker?(hydrated, terminal_states), do: {:held, hydrated}, else: {:chain, issue}
      {:error, _unknown} -> if last_known_hold?(issue, terminal_states), do: {:last, issue}, else: {:chain, issue}
    end
  end

  defp last_known_hold?(issue, terminal_states) do
    case Tracker.last_known_blocked_by(issue) do
      {:ok, hydrated} -> open_blocker?(hydrated, terminal_states)
      {:error, _none} -> false
    end
  end

  defp open_blocker?(%Issue{state: state, blocked_by: blockers}, terminal_states)
       when is_binary(state) and is_list(blockers) do
    DispatchPolicy.normalize_issue_state(state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          not DispatchPolicy.terminal_issue_state?(blocker_state, terminal_states)

        _unknown ->
          true
      end)
  end

  defp open_blocker?(_issue, _terminal_states), do: false

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
    cached_tier(issue, hydrated, terminal_states)
  end

  defp cached_tier(issue, hydrated, terminal_states) do
    case DependencyGate.classify(hydrated, terminal_states) do
      :held -> if DispatchPolicy.normalize_issue_state(issue.state) == "todo", do: :held, else: :ready
      tier -> if Hints.held?(issue.id), do: :held, else: tier
    end
  end
end
