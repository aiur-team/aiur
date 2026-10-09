defmodule Aiur.ExperimentsCLITest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Aiur.{Experiments, ExperimentsCLI}

  setup do
    root = Path.join(System.tmp_dir!(), "experiments-cli-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:aiur, :experiments_dir)
    Application.put_env(:aiur, :experiments_dir, root)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :experiments_dir, previous), else: Application.delete_env(:aiur, :experiments_dir)
      File.rm_rf!(root)
    end)

    if !Process.whereis(Aiur.PubSub), do: start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    start_supervised!(Aiur.Experiments.Store)
    :ok
  end

  test "quick create persists its metric, returns facade JSON and appears in list and show" do
    output =
      capture_io(fn ->
        assert ExperimentsCLI.run(verb: :create, argv: ["--title", "smoke", "--line", "manual:smoke@2026-10-09T00:00:00Z", "--metric", "delivery/start:decrease", "--draft", "--no-freeze", "--json"]) ==
                 0
      end)

    spec = Jason.decode!(output)
    assert spec["metrics"] == [%{"ref" => "delivery/start", "direction" => "decrease", "primary" => true}]
    assert spec["status"] == "draft"
    assert spec["design"]["change"]["ref"] == "smoke"
    assert {:ok, detail} = Experiments.fetch(spec["id"])
    assert Aiur.JSONSafe.normalize(detail)["spec"]["metrics"] == spec["metrics"]
    output = capture_io(fn -> assert ExperimentsCLI.run(verb: :list, argv: ["--status", "draft", "--kind", "before_after", "--json"]) == 0 end)
    assert [%{"id" => id}] = Jason.decode!(output)
    assert id == spec["id"]
    output = capture_io(fn -> assert ExperimentsCLI.run(verb: :show, argv: [id, "--json"]) == 0 end)
    assert Jason.decode!(output) == Aiur.JSONSafe.normalize(detail)
  end

  test "invalid imported specs print every validation error and missing IDs are refused" do
    errors = capture_io(:stderr, fn -> assert ExperimentsCLI.run(verb: :create, argv: ["--spec-json", ~s({"title":""})]) == 1 end)
    assert errors =~ "title:"
    assert errors =~ "design"
    assert errors =~ "metrics"
    assert capture_io(:stderr, fn -> assert ExperimentsCLI.run(verb: :show, argv: ["missing"]) == 1 end) == "no experiment missing\n"
  end

  test "usage errors reject mixed forms, unknown options and incomplete quick forms" do
    for argv <- [["--line", "release"], ["--bogus"], ["--spec-json", "{}", "--title", "mixed"]] do
      assert capture_io(:stderr, fn -> assert ExperimentsCLI.run(verb: :create, argv: argv) == 64 end) =~ "expects list"
    end
  end

  test "missing manual time and invalid list filters are rejected" do
    assert capture_io(:stderr, fn ->
             assert ExperimentsCLI.run(verb: :create, argv: ["--title", "missing time", "--line", "manual:smoke", "--metric", "delivery/start"]) == 1
           end) =~ "design.change.time:"

    for argv <- [["--kind", "unexpected"], ["--status", "unexpected"]] do
      assert capture_io(:stderr, fn -> assert ExperimentsCLI.run(verb: :list, argv: argv) == 64 end) =~ "expects list"
    end
  end

  test "a tag line leaves timestamp resolution to the spec" do
    stop_supervised(Aiur.Experiments.Store)
    start_supervised!({Aiur.Experiments.Store, defaults: [resolve_time: fn "v1" -> {:ok, "2026-10-09T00:00:00Z"} end]})

    output =
      capture_io(fn ->
        assert ExperimentsCLI.run(verb: :create, argv: ["--title", "tag", "--line", "tag:v1", "--metric", "delivery/start", "--no-freeze", "--json"]) == 0
      end)

    assert get_in(Jason.decode!(output), ["design", "change", "time"]) == "2026-10-09T00:00:00Z"
  end

  test "create warns honestly that a baseline was not frozen" do
    warning =
      capture_io(:stderr, fn ->
        capture_io(fn ->
          assert ExperimentsCLI.run(verb: :create, argv: ["--title", "warning", "--line", "manual:warning@2026-10-09T00:00:00Z", "--metric", "delivery/start"]) == 0
        end)
      end)

    assert warning == "baseline not frozen: freeze is not available in this build\n"
  end
end
