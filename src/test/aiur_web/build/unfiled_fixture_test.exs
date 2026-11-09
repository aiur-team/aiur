defmodule AiurWeb.Build.UnfiledFixtureTest do
  use ExUnit.Case, async: true
  alias Aiur.TestSupport.BuildHome.{FixtureSource, UnfiledFixture}

  test "unfiled dataset converts exactly the last two design waves and rewrites graph references" do
    {:ok, live} = FixtureSource.full(dataset: "live")
    {:ok, data} = FixtureSource.full(dataset: "unfiled")
    rows = Enum.filter(data["sections"]["plan"], &is_map(&1["src"]))
    assert length(rows) == 16
    first = hd(rows)
    assert first["id"] == "pack:build-plan/BP-645"
    assert Map.take(first, ~w(num qpos was)) == %{"num" => nil, "qpos" => nil, "was" => nil}
    assert first["est"] == 1.25
    assert first["src"] == %{"kind" => "pack", "path" => "docs/build-plan.md", "wave" => 5}
    assert data["sources"]["packs"]["state"] == "ok"
    assert Enum.any?(live["sections"]["plan"], &("645" in &1["deps"]))
    rewritten = Enum.find(data["sections"]["plan"], &(first["id"] in &1["deps"]))
    assert rewritten["dep_states"][first["id"]] == "blocking"
    assert rewritten["id"] in first["children"]
    assert data["sections"]["hist"] == live["sections"]["hist"]
  end

  test "unavailable packs retain filed rows and report partial failure at the frozen time" do
    {:ok, data} = FixtureSource.full(dataset: "unfiled_unavailable")
    assert length(data["sections"]["plan"]) == 38
    assert Enum.all?(data["sections"]["plan"], &is_nil(&1["src"]))

    assert data["sources"]["packs"] == %{
             "state" => "unavailable",
             "observed_at" => data["now"],
             "reason" => "1 of 2 planning packs could not be read: broken.json"
           }
  end

  test "conversion rewrites dependency state keys and children outside the planned section" do
    {:ok, live} = FixtureSource.full(dataset: "live")
    live = put_in(live, ["sections", "now", Access.at(0), "children"], ["645"])
    live = put_in(live, ["sections", "now", Access.at(0), "deps"], ["645"])
    live = put_in(live, ["sections", "now", Access.at(0), "dep_states"], %{"645" => "blocking"})
    row = UnfiledFixture.convert(live)["sections"]["now"] |> hd()
    assert row["children"] == ["pack:build-plan/BP-645"]
    assert row["deps"] == ["pack:build-plan/BP-645"]
    assert row["dep_states"] == %{"pack:build-plan/BP-645" => "blocking"}
  end
end
