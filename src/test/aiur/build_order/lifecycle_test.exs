defmodule Aiur.BuildOrder.LifecycleTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.{Activity, EdgeState, Graph, Lifecycle, ProviderHealth, Readiness}

  @healthy ProviderHealth.new(1, :healthy, true)

  test "classifies every GitHub lifecycle outcome conservatively" do
    for {state, reason, expected} <- [
          {"CLOSED", "COMPLETED", :cleared},
          {"CLOSED", "NOT_PLANNED", :terminal_unsatisfied},
          {"CLOSED", "DUPLICATE", :unknown},
          {"CLOSED", "REOPENED", :unknown},
          {"CLOSED", nil, :unknown},
          {"CLOSED", "UNRECOGNIZED", :unknown},
          {"OPEN", "COMPLETED", :blocking},
          {"OPEN", "NOT_PLANNED", :blocking},
          {"OPEN", "DUPLICATE", :blocking},
          {"OPEN", "REOPENED", :blocking},
          {"OPEN", nil, :blocking},
          {"UNKNOWN", "COMPLETED", :unknown}
        ] do
      assert EdgeState.classify(Lifecycle.from_github(state, reason), @healthy) == expected
    end
  end

  test "missing, stale, and incomplete provider facts never clear an edge" do
    lifecycle = Lifecycle.from_github("CLOSED", "COMPLETED")

    for health <- [
          ProviderHealth.new(nil, :healthy, false),
          ProviderHealth.new(nil, :healthy, true),
          ProviderHealth.new(1, :stale, true),
          ProviderHealth.new(1, :unavailable, false)
        ] do
      assert EdgeState.classify(lifecycle, health) == :unknown
    end
  end

  test "Aiur progress remains distinct from native edge satisfaction" do
    assert %Activity{progress: 100} = Activity.new(:running, :work, 100)
    assert EdgeState.classify(Lifecycle.from_github("OPEN", nil), @healthy) == :blocking
  end

  test "applies the documented readiness precedence" do
    assert Readiness.from_edges([]) == :ready
    assert Readiness.from_edges([:cleared, :blocking]) == :blocking
    assert Readiness.from_edges([:blocking, :terminal_unsatisfied]) == :terminal_unsatisfied
    assert Readiness.from_edges([:terminal_unsatisfied, :unknown]) == :unknown
    assert Readiness.from_edges([:unknown, :cyclic]) == :cyclic
    assert Readiness.from_edges([:cleared, :unexpected]) == :unknown
  end

  test "finds self-loops and every member of a strongly connected component" do
    assert Graph.cyclic_nodes([{:self, :self}]) == MapSet.new([:self])

    assert Graph.cyclic_nodes([{:a, :b}, {:b, :c}, {:c, :a}, {:c, :outside}]) ==
             MapSet.new([:a, :b, :c])
  end

  test "terminates on a dense acyclic graph within the configured edge bound" do
    edges = for left <- 1..99, right <- (left + 1)..100, do: {left, right}

    assert Graph.cyclic_nodes(edges) == MapSet.new()
  end
end
