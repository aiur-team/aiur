defmodule Aiur.BuildOrder.GraphAnalysisTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.GraphAnalysis

  test "builds deterministic forward, reverse, SCC, cycle, and component order" do
    nodes = [:e, :d, :c, :b, :a]
    edges = [{:d, :e}, {:c, :d}, {:b, :c}, {:c, :b}, {:a, :b}, {:e, :e}]

    analysis = GraphAnalysis.analyze(nodes, edges)

    assert analysis.adjacency == %{
             a: [:b],
             b: [:c],
             c: [:b, :d],
             d: [:e],
             e: [:e]
           }

    assert analysis.reverse_adjacency == %{
             a: [],
             b: [:a, :c],
             c: [:b],
             d: [:c],
             e: [:d, :e]
           }

    assert analysis.strongly_connected_components == [[:a], [:b, :c], [:d], [:e]]
    assert analysis.cyclic_nodes == MapSet.new([:b, :c, :e])
    assert analysis.cyclic_edges == MapSet.new([{:b, :c}, {:c, :b}, {:e, :e}])
    assert analysis.topological_order == [:a, :b, :c, :d, :e]

    assert GraphAnalysis.analyze(Enum.reverse(nodes), Enum.reverse(edges)) == analysis
  end

  test "bounds nodes, drops malformed and nonmember edges, and stays total" do
    nodes = Enum.to_list(1..120)
    edges = [{1, 2}, {100, 101}, {1, :outside}, :malformed]
    analysis = GraphAnalysis.analyze(nodes, edges)

    assert map_size(analysis.adjacency) == 100
    assert analysis.adjacency[1] == [2]
    refute Map.has_key?(analysis.adjacency, 101)
    assert analysis.cyclic_nodes == MapSet.new()

    assert GraphAnalysis.analyze(:invalid, :invalid) == %GraphAnalysis{}
  end

  test "keeps independent cyclic components distinct" do
    analysis =
      GraphAnalysis.analyze(
        [:a, :b, :c, :d],
        [{:a, :b}, {:b, :a}, {:b, :c}, {:c, :d}, {:d, :c}]
      )

    assert analysis.strongly_connected_components == [[:a, :b], [:c, :d]]
    refute MapSet.member?(analysis.cyclic_edges, {:b, :c})
    assert analysis.topological_order == [:a, :b, :c, :d]
  end
end
