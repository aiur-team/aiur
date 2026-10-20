defmodule Aiur.ExperimentsCLITest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Aiur.{Experiments, ExperimentsCLI}
  alias Aiur.Experiments.Paths
  alias AiurWeb.Experiments.Source

  defmodule FixturePack do
    @behaviour Aiur.Experiments.MetricPack
    def id, do: "delivery"
    def version, do: 1

    def metrics,
      do: [
        %Aiur.Experiments.Metric{
          id: "start",
          pack: id(),
          label: "Fixture",
          unit: "ms",
          unit_of_analysis: "ticket",
          kind: "duration",
          better: "lower",
          default_direction: "decrease",
          group: "Fixture",
          requires: []
        }
      ]

    def observations(_ids, window, _context), do: %{"start" => {%{state: :captured}, [%{unit_id: "fixture-1", value: 12, at: window.start}]}}
  end

  setup do
    previous_packs = Application.get_env(:aiur, :experiment_metric_packs)
    Application.put_env(:aiur, :experiment_metric_packs, [FixturePack])

    on_exit(fn ->
      if previous_packs, do: Application.put_env(:aiur, :experiment_metric_packs, previous_packs), else: Application.delete_env(:aiur, :experiment_metric_packs)
    end)

    root = Path.join(System.tmp_dir!(), "experiments-cli-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:aiur, :experiments_dir)
    previous_base = Application.get_env(:aiur, :repo_base_root)
    Application.put_env(:aiur, :repo_base_root, Path.join(root, "repo"))
    Application.put_env(:aiur, :experiments_dir, root)

    on_exit(fn ->
      if previous_base, do: Application.put_env(:aiur, :repo_base_root, previous_base), else: Application.delete_env(:aiur, :repo_base_root)
      if previous, do: Application.put_env(:aiur, :experiments_dir, previous), else: Application.delete_env(:aiur, :experiments_dir)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)
    :ok = Aiur.TestSupport.ensure_pubsub_running()
    start_supervised!(Aiur.Experiments.Store)
    :ok
  end

  test "metrics JSON lists registered definitions" do
    output = capture_io(fn -> assert ExperimentsCLI.run(verb: :metrics, argv: ["--json"]) == 0 end)
    assert Jason.decode!(output)["metrics"]["delivery/start"]["unit"] == "ms"
    assert Jason.decode!(output)["problems"] == []
  end

  test "malformed packs are reported by metrics and show without hiding registered metrics" do
    base = Aiur.RepoBase.base_path(Paths.repo())
    packs = Path.join(base, ".aiur/experiments/packs")
    File.mkdir_p!(packs)
    File.write!(Path.join(packs, "bad.json"), "{")
    output = capture_io(fn -> assert ExperimentsCLI.run(verb: :metrics, argv: ["--json"]) == 0 end)
    assert [%{"file" => file}] = Jason.decode!(output)["problems"]
    assert file == Path.join(packs, "bad.json")
    assert Jason.decode!(output)["metrics"]["delivery/start"]["unit"] == "ms"
    {:ok, spec} = Experiments.create(%{title: "pack issue", design: %{kind: "before_after", change: %{type: "manual", ref: "test", time: "2026-10-09T00:00:00Z"}}, metrics: [%{ref: "delivery/start"}]})
    output = capture_io(fn -> assert ExperimentsCLI.run(verb: :show, argv: [spec.id, "--json"]) == 0 end)
    assert [%{"file" => ^file}] = Jason.decode!(output)["pack_problems"]
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
    assert Jason.decode!(output) == Aiur.JSONSafe.normalize(Map.put(detail, :pack_problems, []))
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

  test "confirmed abandonment is audited and hidden from default and page lists" do
    output = capture_io(fn -> assert ExperimentsCLI.run(verb: :create, argv: quick_args("abandon smoke") ++ ["--no-freeze", "--json"]) == 0 end)
    spec = Jason.decode!(output)

    assert capture_io(:stderr, fn -> assert ExperimentsCLI.run(verb: :abandon, argv: [spec["id"], "--reason", "smoke complete"]) == 64 end) =~ "abandon <id>"
    assert capture_io(fn -> assert ExperimentsCLI.run(verb: :abandon, argv: [spec["id"], "--reason", "smoke complete", "--confirm"]) == 0 end) =~ "abandoned"

    assert {:ok, detail} = Experiments.fetch(spec["id"])
    assert detail.spec["status"] == "abandoned"
    assert Enum.any?(detail.journal, &(&1["kind"] == "abandoned" and &1["reason"] == "smoke complete" and &1["actor"] == "operator"))
    assert {:ok, []} = Experiments.list()
    assert {:ok, []} = Experiments.list(status: nil)
    assert {:ok, [%{id: id, status: "abandoned"}]} = Experiments.list(status: "abandoned")
    assert id == spec["id"]

    previous_facade = Application.get_env(:aiur, :experiments_facade)
    Application.put_env(:aiur, :experiments_facade, Experiments)

    try do
      assert {:ok, []} = Source.index()
    after
      if previous_facade, do: Application.put_env(:aiur, :experiments_facade, previous_facade), else: Application.delete_env(:aiur, :experiments_facade)
    end
  end

  test "abandon list filtering keeps incomplete summary rows" do
    output = capture_io(fn -> assert ExperimentsCLI.run(verb: :create, argv: quick_args("corrupt summary") ++ ["--no-freeze", "--json"]) == 0 end)
    spec = Jason.decode!(output)
    File.write!(Paths.file(spec["id"], "spec.json"), "{")
    File.rm!(Path.join(Paths.root(), "index.json"))

    assert {:ok, [%{id: id, error: :unreadable}]} = Experiments.list()
    assert id == spec["id"]
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

  test "create freezes the baseline and reports its window, count and coverage" do
    output = capture_io(fn -> assert ExperimentsCLI.run(verb: :create, argv: quick_args("frozen")) == 0 end)
    assert output =~ "froze before window 2026-09-25T00:00:00Z..2026-10-09T00:00:00Z: 1 observations"
    assert output =~ ~s|coverage delivery/start={"state":"captured"} (n=1)|
    {:ok, [row]} = Experiments.list()
    assert Enum.map(Experiments.journal(row.id), & &1["kind"]) == ["created", "frozen"]
    {:ok, detail} = Experiments.fetch(row.id)
    assert [%{"window_name" => "before", "observation_count" => 1, "revision" => 1}] = detail.snapshots
    shown = capture_io(fn -> assert ExperimentsCLI.run(verb: :show, argv: [row.id]) == 0 end)
    assert shown =~ "1 observations"
    assert shown =~ "(n=1)"
  end

  test "no-freeze opts out and explicit freeze requires a reason for revisions" do
    output = capture_io(fn -> assert ExperimentsCLI.run(verb: :create, argv: quick_args("optout") ++ ["--no-freeze", "--json"]) == 0 end)
    spec = Jason.decode!(output)
    refute Map.has_key?(spec, "frozen_snapshot")
    assert {:ok, %{snapshots: []}} = Experiments.fetch(spec["id"])
    output = capture_io(fn -> assert ExperimentsCLI.run(verb: :freeze, argv: [spec["id"], "--json"]) == 0 end)
    assert Jason.decode!(output)["observation_count"] == 1
    assert capture_io(:stderr, fn -> assert ExperimentsCLI.run(verb: :freeze, argv: [spec["id"]]) == 1 end) =~ "revision r1 already exists; --reason is required"
    output = capture_io(fn -> assert ExperimentsCLI.run(verb: :freeze, argv: [spec["id"], "--reason", "new evidence", "--json"]) == 0 end)
    assert Jason.decode!(output)["revision"] == 2
    assert {:ok, %{snapshots: snapshots}} = Experiments.fetch(spec["id"])
    assert Enum.map(snapshots, & &1["revision"]) == [1, 2]
  end

  test "freeze rejects a window absent from an A/B design as invalid usage" do
    attrs = %{
      title: "ab",
      design: %{kind: "ab", cohorts: [%{id: "a", label: "A", where: %{attr: "backend", op: "eq", value: "a"}}, %{id: "b", label: "B", where: %{attr: "backend", op: "eq", value: "b"}}], control: "a"},
      metrics: [%{ref: "delivery/start"}]
    }

    assert {:ok, spec} = Experiments.create(attrs, freeze: false)
    assert capture_io(:stderr, fn -> assert ExperimentsCLI.run(verb: :freeze, argv: [spec.id, "--window", "before"]) == 64 end) =~ "--window before|after|observation"
    assert {:ok, %{snapshots: []}} = Experiments.fetch(spec.id)
    output = capture_io(fn -> assert ExperimentsCLI.run(verb: :freeze, argv: [spec.id, "--json"]) == 0 end)
    assert Jason.decode!(output)["window_name"] == "observation"
  end

  defp quick_args(title), do: ["--title", title, "--line", "manual:#{title}@2026-10-09T00:00:00Z", "--metric", "delivery/start"]

  test "control RPC transports errors and creation notices using protocol markers" do
    missing = capture_io(fn -> assert Aiur.AgentControlCLI.experiments(verb: :show, argv: ["missing"]) == :ok end)
    assert missing =~ "__AIUR_CONTROL_ERROR__:no experiment missing"
    assert missing =~ "__AIUR_CONTROL_EXIT__:1"
    invalid = capture_io(fn -> Aiur.AgentControlCLI.experiments(verb: :create, argv: ["--spec-json", ~s({"title":""})]) end)
    for path <- ["title", "design", "metrics"], do: assert(invalid =~ "__AIUR_CONTROL_ERROR__:#{path}")
    usage = capture_io(fn -> Aiur.AgentControlCLI.experiments(verb: :create, argv: ["--bogus"]) end)
    assert usage =~ "__AIUR_CONTROL_ERROR__:aiur: experiments expects"
    assert usage =~ "__AIUR_CONTROL_EXIT__:64"
    created = capture_io(fn -> Aiur.AgentControlCLI.experiments(verb: :create, argv: ["--title", "rpc", "--line", "manual:rpc@2026-10-09T00:00:00Z", "--metric", "delivery/start", "--json"]) end)
    refute created =~ "__AIUR_CONTROL_ERROR__"
    assert created =~ "__AIUR_CONTROL_EXIT__:0"
    [json | _markers] = String.split(created, "\n", trim: true)
    assert Jason.decode!(json)["title"] == "rpc"
    assert Jason.decode!(json)["frozen_snapshot"]["observation_count"] == 1
    assert Jason.decode!(json)["frozen_snapshot"]["metrics"]["delivery/start"]["coverage"] == %{"state" => "captured"}
  end
end
