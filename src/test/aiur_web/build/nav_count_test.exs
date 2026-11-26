defmodule AiurWeb.Build.NavCountTest do
  use ExUnit.Case, async: true
  alias Aiur.TestSupport.BuildHome.FixtureSource
  alias AiurWeb.Build.{NavCount, Payload}

  test "counts active now rows, folds transitions/removals and preserves unknown truth" do
    {:ok, fixture} = FixtureSource.full(dataset: "live")
    rows = fixture["sections"]["now"]
    assert Enum.all?(rows, &match?({:ok, _}, Payload.row(&1)))
    state = NavCount.from_snapshot(fixture)
    assert NavCount.count(state) == 3
    assert NavCount.count(NavCount.from_snapshot(put_in(fixture, ["sections", "now"], []))) == 0
    unknown = put_in(fixture, ["sources", "agents", "state"], "unavailable")
    assert NavCount.count(NavCount.from_snapshot(unknown)) == nil
    row = hd(rows)
    paused = put_in(row, ["agent", "state"], "paused")
    state = NavCount.apply(state, %{upsert: [paused]})
    assert NavCount.count(state) == 2
    state = NavCount.apply(state, %{upsert: [row, row]})
    assert NavCount.count(state) == 3
    moved = Map.put(row, "sec", "hist")
    assert NavCount.count(NavCount.apply(state, %{upsert: [moved]})) == 2
    assert NavCount.count(NavCount.apply(state, %{remove: [row["id"]]})) == 2
    assert NavCount.count(NavCount.apply(state, %{set: %{sources: unknown["sources"]}})) == nil
    stale = put_in(fixture, ["sources", "agents", "state"], "stale")
    assert NavCount.count(NavCount.from_snapshot(stale)) == 3
    invalid = NavCount.apply(state, %{resync: true})
    assert NavCount.count(invalid) == nil
    assert NavCount.count(NavCount.apply(invalid, %{set: %{sources: fixture["sources"]}, upsert: [row]})) == nil
  end
end
