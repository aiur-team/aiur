defmodule Aiur.BrowserHarness.FixturesTest do
  use ExUnit.Case, async: true

  alias Aiur.BrowserHarness.Fixtures

  test "builds each supported graph size with deterministic identities and exact counts" do
    for size <- [0, 1, 20, 50, 100] do
      fixture = Fixtures.graph(size)

      assert fixture == Fixtures.graph(size)
      assert Fixtures.counts(fixture) == %{nodes: size, edges: max(size - 1, 0), roots: min(size, 1)}
      assert Enum.map(fixture.nodes, & &1.id) == expected_ids(size)
    end
  end

  test "keeps multi-root catalog membership neutral and bounded" do
    for size <- [1, 20, 50, 100] do
      root_count = min(size, 3)
      fixture = Fixtures.catalog(size, root_count)

      assert fixture == Fixtures.catalog(size, root_count)
      assert fixture.kind == :catalog
      assert Fixtures.counts(fixture) == %{nodes: size, edges: size - root_count, roots: root_count}
      assert fixture.roots == Enum.map(1..root_count, &node_id/1)
      assert Enum.map(fixture.nodes, & &1.id) == expected_ids(size)
      refute Map.has_key?(hd(fixture.nodes), :readiness)
      refute Map.has_key?(hd(fixture.nodes), :provider)
    end
  end

  test "makes graph edge cases explicit rather than inferring product semantics" do
    expected_counts = %{
      dag: %{nodes: 20, edges: 19, roots: 1},
      cycle: %{nodes: 3, edges: 3, roots: 1},
      self_loop: %{nodes: 1, edges: 1, roots: 1},
      external_endpoint: %{nodes: 1, edges: 1, roots: 1},
      missing_endpoint: %{nodes: 1, edges: 1, roots: 1},
      invalid: %{nodes: 0, edges: 0, roots: 0},
      degraded: %{nodes: 20, edges: 19, roots: 1}
    }

    for {scenario, counts} <- expected_counts do
      fixture = Fixtures.scenario(scenario)

      assert fixture == Fixtures.scenario(scenario)
      assert fixture.kind == scenario
      assert Fixtures.counts(fixture) == counts
      assert Enum.map(fixture.nodes, & &1.id) == expected_ids(counts.nodes)
    end

    assert Fixtures.scenario(:cycle).edges == [
             %{from: node_id(1), to: node_id(2)},
             %{from: node_id(2), to: node_id(3)},
             %{from: node_id(3), to: node_id(1)}
           ]

    assert Fixtures.scenario(:self_loop).edges == [%{from: node_id(1), to: node_id(1)}]
    assert Fixtures.scenario(:external_endpoint).edges == [%{from: node_id(1), to: "external:fixture-node"}]
    assert Fixtures.scenario(:missing_endpoint).edges == [%{from: node_id(1), to: "missing:fixture-node"}]
    assert Fixtures.scenario(:invalid).diagnostics == [%{code: :invalid_fixture, message: "synthetic invalid fixture"}]
    assert Fixtures.scenario(:degraded).diagnostics == [%{code: :degraded_fixture, message: "synthetic degraded fixture"}]
  end

  test "provides a deterministic live-update sequence through caller adapters" do
    updates = Fixtures.live_updates()

    assert updates == Fixtures.live_updates()
    assert Fixtures.counts(updates.initial) == %{nodes: 20, edges: 19, roots: 1}
    assert Fixtures.counts(updates.next) == %{nodes: 50, edges: 48, roots: 2}
    assert Fixtures.adapt(updates.next, &Fixtures.counts/1) == %{nodes: 50, edges: 48, roots: 2}
  end

  defp node_id(ordinal), do: "fixture-node-" <> String.pad_leading(Integer.to_string(ordinal), 3, "0")
  defp expected_ids(0), do: []
  defp expected_ids(size), do: Enum.map(1..size, &node_id/1)
end
