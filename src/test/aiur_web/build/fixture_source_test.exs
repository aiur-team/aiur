defmodule AiurWeb.Build.FixtureSourceTest do
  use Aiur.TestSupport
  alias Aiur.TestSupport.BuildHome.FixtureSource
  alias AiurWeb.Build.DataSource

  test "every dataset serves its initial window with the frozen now" do
    for dataset <- ~w(live dense newrepo noqueue offline) do
      assert {:ok, json} = FixtureSource.snapshot(dataset: dataset)
      assert json["now"] == 1_791_408_000_000
      path = Path.expand("../../fixtures/build_home/#{dataset}.json", __DIR__)
      full = path |> File.read!() |> Jason.decode!()
      assert json["sections"]["now"] == full["sections"]["now"]
      assert json["history"]["total"] == length(full["sections"]["hist"])
      assert json["history"]["tz"] == "America/Los_Angeles"
    end
  end

  test "source call merges socket options with injection without adding an arity" do
    source = {FixtureSource, [dataset: "dense", time_zone: "America/Los_Angeles"]}
    assert {:ok, data} = DataSource.call(source, :snapshot, [[time_zone: "Etc/UTC", financial: :locked]])
    assert data["history"]["tz"] == "Etc/UTC"
    assert data["history"]["total"] == 1300
    assert data["usage"]["state"] == "locked"
    assert {:ok, page} = DataSource.call(source, :earlier, [data["history"]["from"], "Etc/UTC", [days: 2]])
    assert page["history"]["from"] < data["history"]["from"]
    assert page["history"]["tz"] == "Etc/UTC"
  end

  test "unknown, non-dataset, missing and invalid fixtures are errors" do
    assert FixtureSource.datasets() == ~w(live dense newrepo noqueue offline unavailable hold)
    for dataset <- ~w(nope manifest usage-sets ../live), do: assert(FixtureSource.snapshot(dataset: dataset) == {:error, :unknown_dataset})
    assert FixtureSource.snapshot(dataset: "unavailable") == {:error, :fixture_unavailable}
    dir = Aiur.TestSupport.tmp_root!("build-home-missing")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "live.json")
    assert FixtureSource.snapshot(dataset: "live", dir: dir) == {:error, {:fixture_missing, path}}
    File.write!(path, "bad json")
    assert FixtureSource.snapshot(dataset: "live", dir: dir) == {:error, {:fixture_missing, path}}
  end
end
