defmodule Aiur.BuildQueue.Ordering do
  @moduledoc "Pure downstream counts and start-order keys over the union queue graph."

  alias Aiur.BuildQueue.Model.{Edge, Item}
  alias Aiur.StartTrigger.CriticalPath

  @doc """
  Counts distinct reachable open members, excluding the starting issue itself.

  Pass issue IDs with confirmed `open?: true` that remain queue members.
  Closed, removed and unknown-open-state members are excluded from this set.
  """
  @spec downstream_open([Edge.t()], Enumerable.t()) :: %{String.t() => non_neg_integer()}
  def downstream_open(edges, open_items) do
    edges |> critical_ranks(open_items) |> Map.new(fn {id, {_depth, count}} -> {id, count} end)
  end

  @spec critical_ranks([Edge.t()], Enumerable.t()) :: map()
  def critical_ranks(edges, open_items), do: CriticalPath.ranks(Enum.map(edges, &{&1.prerequisite, &1.dependent}), open_items)

  @doc "Distinct dependents in breadth-first order, with direct dependents first."
  @spec dependents([Edge.t()], String.t()) :: [String.t()]
  def dependents(edges, root) do
    graph = Enum.group_by(edges, & &1.prerequisite, & &1.dependent)
    breadth([root], graph, MapSet.new([root]), [])
  end

  defp breadth([], _graph, _seen, ordered), do: ordered

  defp breadth(frontier, graph, seen, ordered) do
    next = frontier |> Enum.flat_map(&Map.get(graph, &1, [])) |> Enum.uniq() |> Enum.reject(&MapSet.member?(seen, &1)) |> Enum.sort_by(&String.to_integer/1)
    breadth(next, graph, MapSet.union(seen, MapSet.new(next)), ordered ++ next)
  end

  @doc "Orders by downstream count, supplied priority rank, position, age, then string issue ID (matching dispatch)."
  @spec rank(Item.t(), non_neg_integer(), 1..5, DateTime.t() | nil) :: tuple()
  def rank(item, downstream, priority, created_at) do
    {downstream_rank, position} = hint(item, downstream)
    {downstream_rank, priority, position, created_at_key(created_at), item.issue_id}
  end

  @doc "Dispatch hint; build-order items have no position and use zero."
  @spec hint(Item.t(), non_neg_integer()) :: {integer(), non_neg_integer()}
  def hint(item, downstream), do: {-downstream, item.position || 0}

  defp created_at_key(nil), do: 9_223_372_036_854_775_807
  defp created_at_key(created_at), do: DateTime.to_unix(created_at, :microsecond)
end
