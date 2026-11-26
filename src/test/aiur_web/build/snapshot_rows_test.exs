defmodule AiurWeb.Build.SnapshotRowsTest do
  use ExUnit.Case, async: true
  alias Aiur.TestSupport.BuildHome.FixtureSource
  alias AiurWeb.Build.{Payload, SnapshotRows}

  test "drops invalid rows, keeps valid rows, and removes every reference to dropped ids" do
    {:ok, data} = FixtureSource.full(dataset: "live")
    [invalid | valid] = data["sections"]["plan"]
    invalid = Map.put(invalid, "id", "991") |> Map.put("deps", [""]) |> Map.put("dep_states", %{"" => "unknown"})

    referenced =
      valid
      |> hd()
      |> Map.update!("deps", &["991" | &1])
      |> Map.update!("children", &["991" | &1])
      |> Map.update!("dep_states", &Map.put(&1, "991", "unknown"))

    data = put_in(data, ["sections", "plan"], [invalid, referenced | tl(valid)])
    {snapshot, dropped} = data |> Payload.snapshot("epoch", 1) |> SnapshotRows.retain_valid()
    rows = snapshot["sections"]["plan"]
    ids = MapSet.new(Enum.map(rows, & &1["id"]))

    assert length(dropped) == 1
    assert Enum.map(rows, & &1["id"]) == Enum.map(valid, & &1["id"])
    assert snapshot["unavailable_rows"] == 1

    refute Enum.any?(rows, fn row ->
             "991" in row["deps"] or "991" in row["children"] or Map.has_key?(row["dep_states"], "991")
           end)

    assert MapSet.member?(ids, hd(valid)["id"])
    assert Payload.validate(snapshot) == :ok
  end

  test "row recovery does not excuse invalid top-level snapshot structure" do
    {:ok, data} = FixtureSource.full(dataset: "live")
    snapshot = data |> Payload.snapshot("epoch", 1) |> Map.delete("sections")
    {recovered, []} = SnapshotRows.retain_valid(snapshot)

    assert {:error, errors} = Payload.validate(recovered)
    assert {"sections", :missing} in errors
  end

  test "live diffs drop references to unavailable ids until that row recovers" do
    {:ok, data} = FixtureSource.full(dataset: "live")
    row = data["sections"]["now"] |> hd() |> Map.update!("deps", &["991" | &1]) |> Map.update!("children", &["991" | &1]) |> Map.update!("dep_states", &Map.put(&1, "991", "unknown"))
    {changes, dropped} = SnapshotRows.scrub_changes(%{"upsert" => [row], "remove" => ["991"]}, MapSet.new(["991"]))
    [clean] = changes["upsert"]

    refute "991" in clean["deps"]
    refute "991" in clean["children"]
    refute Map.has_key?(clean["dep_states"], "991")
    assert changes["remove"] == []
    assert MapSet.member?(dropped, "991")

    recovered = row |> Map.put("id", "991") |> Map.put("num", 991)
    {changes, dropped} = SnapshotRows.scrub_changes(%{"upsert" => [recovered], "remove" => []}, dropped)

    assert changes["upsert"] == [recovered]
    assert MapSet.size(dropped) == 0
  end
end
