defmodule AiurWeb.BuildOrder.PlanningPackResultsTest do
  use AiurWeb.BuildOrder.PlanningSourceCase
  alias AiurWeb.Build.UnfiledRows

  test "public loader reports failed configured paths while keeping matching packs" do
    path = Application.fetch_env!(:aiur, :build_order_planning_pack)
    broken = path <> ".broken"
    foreign = path <> ".foreign"
    File.write!(path, @pack |> Jason.decode!() |> Map.put("repository", Config.repo()) |> Jason.encode!())
    File.write!(foreign, @pack |> Jason.decode!() |> Map.put("repository", "other/repository") |> Jason.encode!())
    File.write!(broken, "{")
    Application.delete_env(:aiur, :build_order_planning_pack)
    Application.put_env(:aiur, :build_order_planning_packs, [path, broken, foreign])

    on_exit(fn ->
      Application.delete_env(:aiur, :build_order_planning_packs)
      Aiur.TestCleanup.rm_rf!(broken)
      Aiur.TestCleanup.rm_rf!(foreign)
    end)

    assert %{configured: 3, packs: [pack], failed: [%{source: :configured, path: ^broken}]} = PlanningSource.load_pack_results()
    assert pack.path == path
    assert pack.repository == Config.repo() |> String.split("/") |> List.to_tuple()
  end

  test "invalid configured path is reported instead of raising" do
    Application.delete_env(:aiur, :build_order_planning_pack)
    Application.put_env(:aiur, :build_order_planning_packs, [123])
    on_exit(fn -> Application.delete_env(:aiur, :build_order_planning_packs) end)
    assert %{configured: 1, packs: [], failed: [%{source: :configured, path: 123}]} = PlanningSource.load_pack_results()
  end

  test "state discovery renders a relative build path without host directories" do
    root = Aiur.TestSupport.tmp_root!("unfiled-state-discovery")
    previous_root = Application.get_env(:aiur, :repo_base_root)
    previous_dirs = System.get_env("AIUR_BUILD_ORDER_DIRS")
    Application.put_env(:aiur, :repo_base_root, root)
    Application.delete_env(:aiur, :build_order_planning_pack)
    Application.delete_env(:aiur, :build_order_planning_packs)
    System.delete_env("AIUR_BUILD_ORDER_DIRS")
    directory = Path.join(RepoBase.builds_path("https://github.com/#{Config.repo()}.git"), "demo")
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "build-order.json"), @pack |> Jason.decode!() |> Map.put("repository", Config.repo()) |> Jason.encode!())

    on_exit(fn ->
      if previous_root, do: Application.put_env(:aiur, :repo_base_root, previous_root), else: Application.delete_env(:aiur, :repo_base_root)
      if previous_dirs, do: System.put_env("AIUR_BUILD_ORDER_DIRS", previous_dirs), else: System.delete_env("AIUR_BUILD_ORDER_DIRS")
      Aiur.TestCleanup.rm_rf!(root)
    end)

    result = UnfiledRows.build(%{filed_numbers: MapSet.new(), done_numbers: MapSet.new(), max_wave: 0, max_ord: -1, epics: MapSet.new(), now: 1})
    assert length(result.rows) == 2
    assert Enum.all?(result.rows, &(&1.src.path == "builds/demo/build-order.json"))
    refute Jason.encode!(result) =~ root
  end
end
