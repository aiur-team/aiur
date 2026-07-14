defmodule Aiur.BuildOrder.Graph do
  @moduledoc "Bounded cycle detection for native Build Order dependency links."

  @max_edges 10_000

  @spec cyclic_nodes(term()) :: MapSet.t()
  def cyclic_nodes(edges) when is_list(edges) do
    graph = edges |> Enum.take(@max_edges) |> adjacency()
    reverse = reverse(graph)

    {_, order} = Enum.reduce(Map.keys(graph), {MapSet.new(), []}, &finish(&1, graph, &2))

    order
    |> Enum.reduce({MapSet.new(), MapSet.new()}, &collect_component(&1, graph, reverse, &2))
    |> elem(1)
  end

  def cyclic_nodes(_edges), do: MapSet.new()

  defp adjacency(edges) do
    Enum.reduce(edges, %{}, fn
      {source, target}, graph ->
        graph
        |> Map.put_new(source, [])
        |> Map.update!(source, &[target | &1])
        |> Map.put_new(target, [])

      _edge, graph ->
        graph
    end)
  end

  defp reverse(graph) do
    Enum.reduce(graph, Map.new(Map.keys(graph), &{&1, []}), fn {source, targets}, reverse ->
      Enum.reduce(targets, reverse, fn target, reverse ->
        Map.update!(reverse, target, fn sources -> [source | sources] end)
      end)
    end)
  end

  defp finish(node, graph, {visited, order}) do
    if MapSet.member?(visited, node) do
      {visited, order}
    else
      {visited, order} =
        Enum.reduce(Map.get(graph, node, []), {MapSet.put(visited, node), order}, &finish(&1, graph, &2))

      {visited, [node | order]}
    end
  end

  defp collect_component(node, graph, reverse, {visited, cyclic}) do
    if MapSet.member?(visited, node) do
      {visited, cyclic}
    else
      {visited, members} = component(node, reverse, visited, MapSet.new())
      cyclic = if cyclic?(members, graph), do: MapSet.union(cyclic, members), else: cyclic
      {visited, cyclic}
    end
  end

  defp component(node, reverse, visited, members) do
    if MapSet.member?(visited, node) do
      {visited, members}
    else
      visited = MapSet.put(visited, node)
      members = MapSet.put(members, node)

      Enum.reduce(Map.get(reverse, node, []), {visited, members}, fn neighbor, {visited, members} ->
        component(neighbor, reverse, visited, members)
      end)
    end
  end

  defp cyclic?(members, graph) do
    if MapSet.size(members) > 1 do
      true
    else
      node = Enum.at(members, 0)
      node in Map.get(graph, node, [])
    end
  end
end
