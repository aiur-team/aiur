defmodule Aiur.BrowserHarness.Fixtures do
  @moduledoc false

  @supported_sizes [0, 1, 20, 50, 100]

  @type fixture :: %{
          schema_version: pos_integer(),
          kind: atom(),
          nodes: [map()],
          edges: [map()],
          roots: [String.t()],
          diagnostics: [map()]
        }

  @spec supported_sizes() :: [non_neg_integer()]
  def supported_sizes, do: @supported_sizes

  @spec graph(non_neg_integer()) :: fixture()
  def graph(size) when size in @supported_sizes do
    nodes = nodes(size)

    fixture(:graph, nodes, linear_edges(nodes), root_ids(nodes), [])
  end

  @spec catalog(pos_integer(), pos_integer()) :: fixture()
  def catalog(size, root_count) when size in [1, 20, 50, 100] and root_count in 1..size//1 do
    nodes = nodes(size)
    roots = Enum.take(nodes, root_count)

    edges =
      nodes
      |> Enum.drop(root_count)
      |> Enum.with_index(root_count)
      |> Enum.map(fn {node, index} -> edge(Enum.at(nodes, rem(index, root_count)).id, node.id) end)

    fixture(:catalog, nodes, edges, Enum.map(roots, & &1.id), [])
  end

  @spec scenario(
          :dag
          | :cycle
          | :self_loop
          | :external_endpoint
          | :missing_endpoint
          | :invalid
          | :degraded
        ) :: fixture()
  def scenario(:dag) do
    nodes = nodes(20)

    edges =
      nodes
      |> Enum.drop(1)
      |> Enum.with_index(1)
      |> Enum.map(fn {node, index} -> edge(Enum.at(nodes, div(index - 1, 2)).id, node.id) end)

    fixture(:dag, nodes, edges, root_ids(nodes), [])
  end

  def scenario(:cycle) do
    nodes = nodes(3)

    fixture(
      :cycle,
      nodes,
      [edge(node_id(1), node_id(2)), edge(node_id(2), node_id(3)), edge(node_id(3), node_id(1))],
      root_ids(nodes),
      []
    )
  end

  def scenario(:self_loop) do
    nodes = nodes(1)
    fixture(:self_loop, nodes, [edge(node_id(1), node_id(1))], root_ids(nodes), [])
  end

  def scenario(:external_endpoint) do
    nodes = nodes(1)
    fixture(:external_endpoint, nodes, [edge(node_id(1), "external:fixture-node")], root_ids(nodes), [])
  end

  def scenario(:missing_endpoint) do
    nodes = nodes(1)
    fixture(:missing_endpoint, nodes, [edge(node_id(1), "missing:fixture-node")], root_ids(nodes), [])
  end

  def scenario(:invalid),
    do: fixture(:invalid, [], [], [], [%{code: :invalid_fixture, message: "synthetic invalid fixture"}])

  def scenario(:degraded),
    do:
      fixture(:degraded, nodes(20), linear_edges(nodes(20)), root_ids(nodes(20)), [
        %{code: :degraded_fixture, message: "synthetic degraded fixture"}
      ])

  @spec live_updates() :: %{initial: fixture(), next: fixture(), sequence: [fixture()]}
  def live_updates do
    initial = graph(20)
    next = catalog(50, 2)

    %{initial: initial, next: next, sequence: [initial, next]}
  end

  @spec counts(fixture()) :: %{nodes: non_neg_integer(), edges: non_neg_integer(), roots: non_neg_integer()}
  def counts(fixture), do: %{nodes: length(fixture.nodes), edges: length(fixture.edges), roots: length(fixture.roots)}

  @spec adapt(fixture(), (fixture() -> term())) :: term()
  def adapt(fixture, adapter) when is_function(adapter, 1), do: adapter.(fixture)

  defp fixture(kind, nodes, edges, roots, diagnostics) do
    %{schema_version: 1, kind: kind, nodes: nodes, edges: edges, roots: roots, diagnostics: diagnostics}
  end

  defp nodes(0), do: []
  defp nodes(size), do: Enum.map(1..size, &%{id: node_id(&1), ordinal: &1})

  defp linear_edges(nodes) do
    nodes
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [from, to] -> edge(from.id, to.id) end)
  end

  defp root_ids([]), do: []
  defp root_ids([root | _]), do: [root.id]

  defp edge(from, to), do: %{from: from, to: to}
  defp node_id(ordinal), do: "fixture-node-" <> String.pad_leading(Integer.to_string(ordinal), 3, "0")
end
