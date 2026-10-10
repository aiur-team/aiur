defmodule AiurWeb.Build.FeatureStatsPayloadTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildOrder.FeatureStats
  alias AiurWeb.Build.Payload
  @dir Path.expand("../../fixtures/build_home", __DIR__)

  defp fixture, do: @dir |> Path.join("live.json") |> File.read!() |> Jason.decode!()

  test "feature statistics are required, nullable, and reject unknown fields" do
    data = fixture()
    stats = data["features"]["pag"]["stats"]
    assert stats["pct"] == 61
    assert Payload.validate(data) == :ok
    assert Payload.validate(put_in(data, ["features", "pag", "stats"], nil)) == :ok
    missing = update_in(data, ["features", "pag"], &Map.delete(&1, "stats"))
    assert {:error, [{"features.pag.stats", :missing}]} = Payload.validate(missing)
    assert {:error, [{"features.pag.stats.extra", :unknown}]} = Payload.validate(put_in(data, ["features", "pag", "stats", "extra"], 1))
  end

  test "server unknown statistics preserve nil figures and registry counts on the wire" do
    registry = %{features: %{"pag" => %{baseline: :none}}, owners: %{1 => %{feature: "pag", joined_at: DateTime.from_unix!(0)}}, also: %{}}
    stats = FeatureStats.compute_all(registry, %{}, now: 0)["pag"] |> FeatureStats.to_json()
    snapshot = fixture() |> put_in(["features", "pag", "stats"], stats) |> Payload.snapshot("E", 0)
    assert Payload.validate(snapshot) == :ok

    assert snapshot["features"]["pag"]["stats"] == %{
             "total" => 1,
             "done" => nil,
             "done_min" => 0,
             "pct" => nil,
             "pct_min" => nil,
             "orig" => 1,
             "added" => 0,
             "baseline" => false,
             "spark" => [1],
             "also" => 0,
             "reasons" => ["complexity", "status"]
           }
  end

  test "all statistics fields enforce their declared types" do
    for {key, value, reason} <- [
          {"total", -1, :type},
          {"done", -1, :type},
          {"done_min", nil, :type},
          {"pct", 101, :type},
          {"pct", 1.5, :type},
          {"pct_min", -1, :type},
          {"orig", "10", :type},
          {"added", nil, :type},
          {"baseline", nil, :type},
          {"spark", [-1], :type},
          {"also", nil, :type},
          {"reasons", ["upstream"], :enum}
        ] do
      assert {:error, errors} = fixture() |> put_in(["features", "pag", "stats", key], value) |> Payload.validate()
      assert Enum.any?(errors, fn {path, actual} -> String.starts_with?(path, "features.pag.stats.#{key}") and actual == reason end)
    end
  end

  test "feature figures are also accepted in whole-block diffs" do
    data = fixture()
    message = Payload.diff(%{now: data["now"], upsert: [], remove: [], set: %{features: data["features"]}}, "E", 1, nil)
    assert Payload.validate(message) == :ok
    assert message["set"]["features"]["pag"]["stats"]["pct"] == 61
    missing = update_in(message, ["set", "features", "pag"], &Map.delete(&1, "stats"))
    assert {:error, [{"set.features.pag.stats", :missing}]} = Payload.validate(missing)
  end
end
