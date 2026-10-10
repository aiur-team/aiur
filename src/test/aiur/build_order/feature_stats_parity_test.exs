defmodule Aiur.BuildOrder.FeatureStatsParityTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildOrder.FeatureStats, as: Stats
  alias Aiur.BuildOrder.History.Row

  test "all four design datasets match the oracle except empty percentages" do
    oracle = File.read!(Path.expand("../../fixtures/build_home/feature-stats.json", __DIR__)) |> Jason.decode!()
    assert Enum.sort(Map.keys(oracle)) == ~w(dense live newrepo noqueue)

    results =
      for {_dataset, %{"now" => now, "features" => features}} <- oracle, {slug, input} <- features do
        members = input["members"]

        registry = %{
          features: %{slug => %{baseline: %{at: DateTime.from_unix!(now, :millisecond), members: members |> Enum.reject(& &1["added"]) |> Enum.map(& &1["num"]) |> MapSet.new()}}},
          owners: Map.new(members, &{&1["num"], %{feature: slug, joined_at: DateTime.from_unix!(&1["created"], :millisecond)}}),
          also: Map.new(input["also"], &{&1, [slug]})
        }

        facts =
          Map.new(members, fn member ->
            assert Stats.points(member["cx"]) == member["pts"]

            status =
              case member["sec"] do
                "hist" -> String.to_existing_atom(member["status"])
                "now" -> :running
                "plan" -> :queued
                "nq" -> :open
              end

            {member["num"], Stats.fact(%Row{labels: ["complexity:#{member["cx"]}"]}, status, {:known, member["pct"]})}
          end)

        result = Stats.compute_all(registry, facts, now: now)[slug] |> Stats.to_json()
        expected = input["expected"]
        assert Map.take(result, ~w(total done orig added spark also)) == Map.take(expected, ~w(total done orig added spark also))
        assert result["done_min"] == expected["done"]
        assert result["baseline"] == true

        if expected["total"] == 0 do
          assert expected["pct"] == 0
          assert result["pct"] == nil
          assert result["pct_min"] == nil
          assert result["reasons"] == ["no_weight"]
        else
          assert result["pct"] == expected["pct"]
          assert result["pct_min"] == expected["pct"]
          assert result["reasons"] == []
        end

        expected["total"]
      end

    assert length(results) == 18
    assert Enum.count(results, &(&1 == 0)) == 7
  end
end
