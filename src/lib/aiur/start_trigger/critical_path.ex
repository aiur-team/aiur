defmodule Aiur.StartTrigger.CriticalPath do
  @moduledoc "Pure open-dependent depths and distinct downstream counts over cached dependency edges."

  @spec ranks([{String.t(), String.t()}], Enumerable.t()) :: %{String.t() => {non_neg_integer(), non_neg_integer()}}
  def ranks(edges, open_nodes) do
    open = MapSet.new(open_nodes)
    graph = Enum.group_by(edges, &elem(&1, 0), &elem(&1, 1))
    nodes = edges |> Enum.flat_map(&Tuple.to_list/1) |> Enum.concat(open) |> Enum.uniq()

    {ranks, _memo} =
      Enum.map_reduce(nodes, %{}, fn node, memo ->
        {depth, memo, _cyclic?} = depth(node, graph, open, MapSet.new(), memo)
        downstream = reachable([node], graph, MapSet.new()) |> MapSet.delete(node) |> MapSet.intersection(open) |> MapSet.size()
        {{node, {depth, downstream}}, memo}
      end)

    Map.new(ranks)
  end

  defp depth(node, graph, open, seen, memo) do
    cond do
      MapSet.member?(seen, node) -> {0, memo, true}
      Map.has_key?(memo, node) -> {memo[node], memo, false}
      true -> children_depth(node, graph, open, MapSet.put(seen, node), memo)
    end
  end

  defp children_depth(node, graph, open, seen, memo) do
    children = Enum.filter(Map.get(graph, node, []), &(MapSet.member?(open, &1) and not MapSet.member?(seen, &1)))
    cycle? = Enum.any?(Map.get(graph, node, []), &(MapSet.member?(open, &1) and MapSet.member?(seen, &1)))

    {value, memo, cyclic?} =
      Enum.reduce(children, {0, memo, cycle?}, fn child, {value, memo, cyclic?} ->
        {depth, memo, child_cycle?} = depth(child, graph, open, seen, memo)
        {max(value, depth + 1), memo, cyclic? or child_cycle?}
      end)

    {value, if(cyclic?, do: memo, else: Map.put(memo, node, value)), cyclic?}
  end

  defp reachable([], _graph, seen), do: seen

  defp reachable([node | rest], graph, seen) do
    if MapSet.member?(seen, node), do: reachable(rest, graph, seen), else: reachable(Map.get(graph, node, []) ++ rest, graph, MapSet.put(seen, node))
  end
end
