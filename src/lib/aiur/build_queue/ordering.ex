defmodule Aiur.BuildQueue.Ordering do
  @moduledoc "Pure downstream counts and start-order keys over the union queue graph."

  alias Aiur.BuildQueue.Model.{Edge, Item}

  @doc """
  Counts distinct reachable open members, excluding the starting issue itself.

  Pass issue IDs with confirmed `open?: true` that remain queue members.
  Closed, removed and unknown-open-state members are excluded from this set.
  """
  @spec downstream_open([Edge.t()], Enumerable.t()) :: %{String.t() => non_neg_integer()}
  def downstream_open(edges, open_items) do
    open = MapSet.new(open_items)
    graph = Enum.group_by(edges, & &1.prerequisite, & &1.dependent)
    nodes = edges |> Enum.flat_map(&[&1.prerequisite, &1.dependent]) |> Enum.concat(open) |> Enum.uniq()

    Map.new(nodes, fn node ->
      reachable = walk([node], graph, MapSet.new()) |> MapSet.delete(node)
      {node, reachable |> MapSet.intersection(open) |> MapSet.size()}
    end)
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

  defp walk([], _graph, seen), do: seen

  defp walk([node | rest], graph, seen) do
    if MapSet.member?(seen, node) do
      walk(rest, graph, seen)
    else
      walk(Map.get(graph, node, []) ++ rest, graph, MapSet.put(seen, node))
    end
  end
end
