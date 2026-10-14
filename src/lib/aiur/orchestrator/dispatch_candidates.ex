defmodule Aiur.Orchestrator.DispatchCandidates do
  @moduledoc "Orders ready, optimistic, then held candidates using cached dependency evidence only."

  alias Aiur.BuildQueue.Hints
  alias Aiur.{Config, Issue}
  alias Aiur.GitHub.Tracker
  alias Aiur.Orchestrator.{DependencyGate, DispatchPolicy, QueueSetSlots}
  alias Aiur.StartTrigger.CriticalPath

  @spec order([Issue.t()], MapSet.t(), [Issue.t()]) :: [Issue.t()]
  def order(issues, terminal_states, polled \\ []) do
    groups = issues |> DispatchPolicy.sort_issues_for_dispatch() |> Enum.group_by(&tier(&1, terminal_states))
    optimistic = optimistic_order(Map.get(groups, :optimistic, []), polled ++ issues, terminal_states)

    ordering = QueueSetSlots.ordering()

    Enum.sort_by(Map.get(groups, :ready, []), &QueueSetSlots.sort_key(&1.id, ordering)) ++
      Enum.sort_by(optimistic, fn issue ->
        {member, rank, _position} = QueueSetSlots.sort_key(issue.id, ordering)
        {member, rank}
      end) ++ Map.get(groups, :held, [])
  end

  @doc "Returns `{chain, held}`; fresh cached dependency holds skip validation."
  @spec partition([Issue.t()], MapSet.t(), [Issue.t()]) :: {[Issue.t()], [Issue.t()]}
  def partition(issues, terminal_states, polled \\ []) do
    github? = Config.settings!().tracker.kind == "github"
    ordered = order(issues, terminal_states, polled)
    {held, chain} = Enum.split_with(ordered, &fresh_cached_hold?(&1, terminal_states, github?))
    stale = Enum.filter(chain, &last_known_hold?(&1, terminal_states, github?))
    stale_ids = MapSet.new(stale, & &1.id)
    {Enum.reject(chain, &MapSet.member?(stale_ids, &1.id)) ++ stale, hydrate_holds(held, github?)}
  end

  defp hydrate_holds(issues, true) do
    Enum.map(issues, fn issue ->
      case Tracker.cached_blocked_by(issue) do
        {:ok, hydrated} -> hydrated
        {:error, _unknown} -> issue
      end
    end)
  end

  defp hydrate_holds(issues, false), do: issues

  defp fresh_cached_hold?(issue, terminal_states, true) do
    if DispatchPolicy.normalize_issue_state(issue.state) == "todo" do
      case Tracker.cached_blocked_by(issue) do
        {:ok, hydrated} -> open_blocker?(hydrated, terminal_states)
        {:error, _unknown} -> false
      end
    else
      false
    end
  end

  defp fresh_cached_hold?(issue, terminal_states, false), do: open_blocker?(issue, terminal_states)

  defp last_known_hold?(issue, terminal_states, true) do
    case Tracker.last_known_blocked_by(issue) do
      {:ok, hydrated} -> open_blocker?(hydrated, terminal_states)
      {:error, _none} -> false
    end
  end

  defp last_known_hold?(issue, terminal_states, false), do: open_blocker?(issue, terminal_states)

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

    if fresh_cached_hold?(issue, terminal_states, Config.settings!().tracker.kind == "github"),
      do: :held,
      else: cached_tier(issue, hydrated, terminal_states)
  end

  defp cached_tier(issue, hydrated, terminal_states) do
    case DependencyGate.classify(hydrated, terminal_states) do
      :held -> if DispatchPolicy.normalize_issue_state(issue.state) == "todo", do: :held, else: :ready
      tier -> if Hints.held?(issue.id), do: :held, else: tier
    end
  end
end
