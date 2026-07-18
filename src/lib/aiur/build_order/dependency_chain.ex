defmodule Aiur.BuildOrder.DependencyChain do
  @moduledoc """
  Deterministic upstream/downstream dependency-chain closures.

  The Build Order graph highlights a focused node together with everything it
  depends on (upstream) and everything that depends on it (downstream). This
  module derives those closures from the already-computed native adjacency maps
  in `Aiur.BuildOrder.GraphAnalysis`; it never invents adjacency of its own, so
  the client interaction hook can apply highlight state without reinterpreting
  graph truth.

  Edges are directed blocker → blocked. `adjacency[node]` therefore lists the
  nodes a node blocks (its downstream dependents) and `reverse_adjacency[node]`
  lists the nodes that block it (its upstream dependencies).
  """

  @type node_key :: term()
  @type adjacency :: %{optional(node_key()) => [node_key()]}
  @type closure :: %{upstream: [node_key()], downstream: [node_key()]}

  @doc """
  Return `%{node_key => %{upstream: [...], downstream: [...]}}` for every node.

  Both closures are transitive, exclude the node itself, and are deterministically
  sorted. A node with no relations still receives an entry with empty lists.
  """
  @spec closures(adjacency(), adjacency()) :: %{optional(node_key()) => closure()}
  def closures(adjacency, reverse_adjacency) when is_map(adjacency) and is_map(reverse_adjacency) do
    nodes = adjacency |> Map.keys() |> Enum.concat(Map.keys(reverse_adjacency)) |> Enum.uniq()

    Map.new(nodes, fn node ->
      {node,
       %{
         upstream: reachable(node, reverse_adjacency),
         downstream: reachable(node, adjacency)
       }}
    end)
  end

  def closures(_adjacency, _reverse_adjacency), do: %{}

  @doc "Transitive set of nodes reachable from `node` through `graph`, excluding `node`."
  @spec reachable(node_key(), adjacency()) :: [node_key()]
  def reachable(node, graph) when is_map(graph) do
    node
    |> walk(graph, MapSet.new())
    |> MapSet.delete(node)
    |> Enum.sort()
  end

  defp walk(node, graph, seen) do
    if MapSet.member?(seen, node) do
      seen
    else
      seen = MapSet.put(seen, node)

      graph
      |> Map.get(node, [])
      |> Enum.reduce(seen, fn neighbor, acc -> walk(neighbor, graph, acc) end)
    end
  end
end
