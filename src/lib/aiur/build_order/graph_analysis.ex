defmodule Aiur.BuildOrder.GraphAnalysis do
  @moduledoc """
  Deterministic, bounded adjacency and strongly-connected-component analysis.

  Edges are always directed from blocker to blocked. Unknown and external
  endpoints stay in the presenter as diagnostics, but never enter this native
  member graph.
  """

  @max_nodes 100
  @max_edges @max_nodes * @max_nodes

  @type node_key :: term()
  @type edge :: {node_key(), node_key()}
  @type t :: %__MODULE__{
          adjacency: %{optional(node_key()) => [node_key()]},
          reverse_adjacency: %{optional(node_key()) => [node_key()]},
          strongly_connected_components: [[node_key()]],
          cyclic_nodes: MapSet.t(node_key()),
          cyclic_edges: MapSet.t(edge()),
          topological_order: [node_key()]
        }

  defstruct adjacency: %{},
            reverse_adjacency: %{},
            strongly_connected_components: [],
            cyclic_nodes: MapSet.new(),
            cyclic_edges: MapSet.new(),
            topological_order: []

  @spec analyze(term(), term()) :: t()
  def analyze(nodes, edges) when is_list(nodes) and is_list(edges) do
    nodes = nodes |> Enum.uniq() |> Enum.sort() |> Enum.take(@max_nodes)
    node_set = MapSet.new(nodes)

    edges =
      edges
      |> Enum.filter(&native_edge?(&1, node_set))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.take(@max_edges)

    adjacency = adjacency(nodes, edges)
    reverse_adjacency = adjacency(nodes, Enum.map(edges, fn {source, target} -> {target, source} end))
    components = strongly_connected_components(nodes, adjacency, reverse_adjacency)
    component_by_node = component_index(components)
    cyclic_nodes = cyclic_nodes(components, adjacency)

    cyclic_edges =
      edges
      |> Enum.filter(&cyclic_edge?(&1, component_by_node, cyclic_nodes))
      |> MapSet.new()

    %__MODULE__{
      adjacency: adjacency,
      reverse_adjacency: reverse_adjacency,
      strongly_connected_components: components,
      cyclic_nodes: cyclic_nodes,
      cyclic_edges: cyclic_edges,
      topological_order: component_topological_order(components, component_by_node, edges)
    }
  end

  def analyze(_nodes, _edges), do: %__MODULE__{}

  @doc """
  Node keys that have no blockers, and are therefore ready at the plan's start.

  Derives from the native reverse adjacency only: a member with an empty blocker
  set can begin immediately at kickoff. Deterministically sorted.
  """
  @spec ready_at_start(t()) :: [node_key()]
  def ready_at_start(%__MODULE__{reverse_adjacency: reverse}) do
    reverse
    |> Enum.filter(fn {_node, blockers} -> blockers == [] end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  def ready_at_start(_graph), do: []

  @doc """
  Length, in members, of the longest dependency chain in the native graph.

  Computed as the longest path over the topological order using the reverse
  adjacency. Cyclic members never inflate the count: a back edge whose
  predecessor has no assigned depth contributes zero, so the result stays a
  bounded lower bound rather than diverging.
  """
  @spec longest_chain_length(t()) :: non_neg_integer()
  def longest_chain_length(%__MODULE__{topological_order: order, reverse_adjacency: reverse}) do
    order
    |> Enum.reduce({%{}, 0}, fn node, {depths, longest} ->
      depth = 1 + max_predecessor_depth(Map.get(reverse, node, []), depths)
      {Map.put(depths, node, depth), max(longest, depth)}
    end)
    |> elem(1)
  end

  def longest_chain_length(_graph), do: 0

  defp max_predecessor_depth([], _depths), do: 0

  defp max_predecessor_depth(predecessors, depths),
    do: predecessors |> Enum.map(&Map.get(depths, &1, 0)) |> Enum.max()

  defp native_edge?({source, target}, nodes),
    do: MapSet.member?(nodes, source) and MapSet.member?(nodes, target)

  defp native_edge?(_edge, _nodes), do: false

  defp adjacency(nodes, edges) do
    edges
    |> Enum.reduce(Map.new(nodes, &{&1, []}), fn {source, target}, graph ->
      Map.update!(graph, source, &[target | &1])
    end)
    |> Map.new(fn {node, neighbors} -> {node, neighbors |> Enum.uniq() |> Enum.sort()} end)
  end

  defp strongly_connected_components(nodes, adjacency, reverse_adjacency) do
    {_, finish_order} =
      Enum.reduce(nodes, {MapSet.new(), []}, fn node, state ->
        finish(node, adjacency, state)
      end)

    finish_order
    |> Enum.reduce({MapSet.new(), []}, fn node, {visited, components} ->
      if MapSet.member?(visited, node) do
        {visited, components}
      else
        {visited, component} = collect(node, reverse_adjacency, visited, [])
        {visited, [Enum.sort(component) | components]}
      end
    end)
    |> elem(1)
    |> Enum.sort_by(&hd/1)
  end

  defp finish(node, graph, {visited, order}) do
    if MapSet.member?(visited, node) do
      {visited, order}
    else
      visited = MapSet.put(visited, node)

      {visited, order} =
        Enum.reduce(Map.get(graph, node, []), {visited, order}, fn neighbor, state ->
          finish(neighbor, graph, state)
        end)

      {visited, [node | order]}
    end
  end

  defp collect(node, graph, visited, component) do
    if MapSet.member?(visited, node) do
      {visited, component}
    else
      visited = MapSet.put(visited, node)

      Enum.reduce(Map.get(graph, node, []), {visited, [node | component]}, fn neighbor, {visited, component} ->
        collect(neighbor, graph, visited, component)
      end)
    end
  end

  defp component_index(components) do
    components
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {component, index}, by_node ->
      Enum.reduce(component, by_node, &Map.put(&2, &1, index))
    end)
  end

  defp cyclic_nodes(components, adjacency) do
    Enum.reduce(components, MapSet.new(), fn
      component, cyclic when length(component) > 1 ->
        Enum.reduce(component, cyclic, &MapSet.put(&2, &1))

      [node], cyclic ->
        if node in Map.get(adjacency, node, []), do: MapSet.put(cyclic, node), else: cyclic
    end)
  end

  defp cyclic_edge?({source, target}, component_by_node, cyclic_nodes) do
    MapSet.member?(cyclic_nodes, source) and
      Map.fetch!(component_by_node, source) == Map.fetch!(component_by_node, target)
  end

  defp component_topological_order(components, component_by_node, edges) do
    component_edges =
      edges
      |> Enum.map(fn {source, target} ->
        {Map.fetch!(component_by_node, source), Map.fetch!(component_by_node, target)}
      end)
      |> Enum.reject(fn {source, target} -> source == target end)
      |> Enum.uniq()

    adjacency =
      Enum.reduce(component_edges, Map.new(0..(max(length(components), 1) - 1), &{&1, []}), fn
        {source, target}, graph -> Map.update!(graph, source, &[target | &1])
      end)

    indegree =
      Enum.reduce(component_edges, Map.new(0..(max(length(components), 1) - 1), &{&1, 0}), fn
        {_source, target}, counts -> Map.update!(counts, target, &(&1 + 1))
      end)

    ready =
      indegree
      |> Enum.filter(fn {_component, count} -> count == 0 end)
      |> Enum.map(&elem(&1, 0))
      |> sort_components(components)

    ready
    |> drain_components(adjacency, indegree, components, [])
    |> Enum.flat_map(&Enum.at(components, &1, []))
  end

  defp drain_components([], _adjacency, _indegree, _components, ordered), do: Enum.reverse(ordered)

  defp drain_components([component | rest], adjacency, indegree, components, ordered) do
    {indegree, newly_ready} =
      adjacency
      |> Map.get(component, [])
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reduce({indegree, []}, fn target, {counts, ready} ->
        counts = Map.update!(counts, target, &(&1 - 1))
        ready = if Map.fetch!(counts, target) == 0, do: [target | ready], else: ready
        {counts, ready}
      end)

    next = sort_components(rest ++ newly_ready, components)
    drain_components(next, adjacency, indegree, components, [component | ordered])
  end

  defp sort_components(indices, components) do
    Enum.sort_by(indices, fn index -> components |> Enum.at(index, []) |> List.first() end)
  end
end
