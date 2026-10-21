defmodule Aiur.BuildOrder.IndexEstimatesTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport.BuildHome.IndexParts
  alias Aiur.BuildOrder.Index
  alias AiurWeb.Build.Payload

  test "assembled planned and running estimates preserve ambiguous complexity and overrides" do
    p = parts() |> put_in([:open, Access.key(:tickets)], [open(5, ["complexity:2", "complexity:4"]), open(6, ["complexity:3"])])
    p = p |> put_in([:planned, :rows], [plan_row(5)]) |> put_in([:now, :rows], %{"6" => now_row(6)})
    override = %{hours: 6, reason: "known effort", by: "cli:test", at: DateTime.utc_now()}
    p = Map.put(p, :estimates, {:ok, %{overrides: %{5 => override}, health: health()}})
    assert {:ok, index} = assemble(p)
    assert index.all["5"].cx == nil
    assert index.all["5"].est == nil
    assert index.all["5"].override.hours == 6
    assert is_integer(index.all["5"].override.at)
    assert index.all["6"].est == 4
    assert index.sources.estimates.state == "ok"
    assert {:ok, unavailable} = assemble(Map.put(p, :estimates, {:error, %{health() | state: :unavailable, failure: :estimates_corrupt}}))
    assert unavailable.all["6"].est == nil
    assert unavailable.all["5"].override == nil
    assert unavailable.sources.estimates.reason == "estimates_corrupt"
    diff = Index.diff(index, unavailable)
    assert Enum.sort(Enum.map(diff.upsert, & &1.id)) == ["5", "6"]
    assert diff.set.sources.estimates.state == "unavailable"
  end

  test "capacity snapshot and diffs retain the observed runtime cap without config fallback" do
    p = parts() |> Map.put(:capacity, {:current, %{capacity: %{max: 8}}, %{observed_at: now()}})
    assert {:ok, index} = assemble(p)
    expected = %{max: 8, observed_at: now(), stale: false}
    assert index.capacity == expected
    assert Index.window(Index.base(index), "Etc/UTC", now()).capacity == expected
    assert {:ok, unknown} = assemble(Map.put(p, :capacity, :snapshot_unpublished))
    assert unknown.capacity == %{max: nil, observed_at: nil, stale: false}
    assert Index.diff(index, unknown).set.capacity == unknown.capacity
    assert {:ok, stale} = assemble(Map.put(p, :capacity, {:stale, %{capacity: %{max: 2}}, %{observed_at: now() - 1000}}))
    assert stale.capacity == %{max: 2, observed_at: now() - 1000, stale: true}
  end

  test "strict schema requires estimate health and rejects invented or invalid capacities" do
    path = Path.expand("../../fixtures/build_home/live.json", __DIR__)
    data = path |> File.read!() |> Jason.decode!()
    assert Payload.validate(data) == :ok

    for max <- [0, -1, "4", 1.5] do
      assert {:error, errors} = Payload.validate(put_in(data, ["capacity", "max"], max))
      assert {"capacity.max", :type} in errors
    end

    assert Payload.validate(put_in(data, ["capacity", "max"], nil)) == :ok
    assert {:error, errors} = Payload.validate(update_in(data, ["sources"], &Map.delete(&1, "estimates")))
    assert {"sources.estimates", :missing} in errors
  end
end
