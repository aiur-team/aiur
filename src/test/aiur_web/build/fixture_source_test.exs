defmodule AiurWeb.Build.FixtureSourceTest do
  use Aiur.TestSupport
  alias Aiur.TestSupport.BuildHome.FixtureSource

  test "every dataset loads its unchanged file with the frozen now" do
    for dataset <- ~w(live dense newrepo noqueue offline) do
      assert {:ok, json} = FixtureSource.snapshot(dataset: dataset)
      assert json["meta"]["dataset"] == dataset
      assert json["meta"]["now"] == 1_791_408_000_000
      path = Path.expand("../../fixtures/build_home/#{dataset}.json", __DIR__)
      assert json == path |> File.read!() |> Jason.decode!()
    end

    previous = Application.get_env(:aiur, :build_fixture_dataset)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :build_fixture_dataset, previous), else: Application.delete_env(:aiur, :build_fixture_dataset)
    end)

    Application.put_env(:aiur, :build_fixture_dataset, "dense")
    assert {:ok, %{"meta" => %{"dataset" => "dense"}}} = FixtureSource.snapshot([])
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
