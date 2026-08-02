defmodule Aiur.BuildOrder.DependencyChainTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.{DependencyChain, GraphAnalysis}

  test "computes transitive upstream and downstream closures excluding self" do
    # a -> b -> c -> d (blocker -> blocked chain)
    analysis = GraphAnalysis.analyze([:a, :b, :c, :d], [{:a, :b}, {:b, :c}, {:c, :d}])

    closures = DependencyChain.closures(analysis.adjacency, analysis.reverse_adjacency)

    assert closures[:c].upstream == [:a, :b]
    assert closures[:c].downstream == [:d]
    assert closures[:a].upstream == []
    assert closures[:a].downstream == [:b, :c, :d]
    assert closures[:d].downstream == []
    assert closures[:d].upstream == [:a, :b, :c]
  end

  test "every node receives an entry even without relations" do
    analysis = GraphAnalysis.analyze([:lonely, :x], [])

    closures = DependencyChain.closures(analysis.adjacency, analysis.reverse_adjacency)

    assert closures[:lonely] == %{upstream: [], downstream: []}
    assert Map.has_key?(closures, :x)
  end

  test "closures terminate and stay deduplicated on cyclic graphs" do
    # b <-> c cycle, a upstream of the cycle, d downstream
    analysis = GraphAnalysis.analyze([:a, :b, :c, :d], [{:a, :b}, {:b, :c}, {:c, :b}, {:c, :d}])

    closures = DependencyChain.closures(analysis.adjacency, analysis.reverse_adjacency)

    assert closures[:b].downstream == [:c, :d]
    assert closures[:b].upstream == [:a, :c]
    assert closures[:c].downstream == [:b, :d]
  end

  test "output is deterministically sorted" do
    analysis = GraphAnalysis.analyze([:root, :m, :z, :a], [{:root, :z}, {:root, :a}, {:root, :m}])

    closures = DependencyChain.closures(analysis.adjacency, analysis.reverse_adjacency)

    assert closures[:root].downstream == [:a, :m, :z]
  end

  test "non-map input yields an empty result" do
    assert DependencyChain.closures(nil, %{}) == %{}
    assert DependencyChain.closures(%{}, "nope") == %{}
  end
end
