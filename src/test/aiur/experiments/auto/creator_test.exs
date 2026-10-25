defmodule Aiur.Experiments.Auto.CreatorTest do
  use Aiur.TestSupport
  alias Aiur.Config.Schema.Experiments.Auto, as: AutoConfig
  alias Aiur.Experiments
  alias Aiur.Experiments.Auto.{Creator, Line}
  alias Aiur.Experiments.{Paths, Store}
  alias Aiur.RunTelemetry.Dataset

  setup do
    root = Path.join(System.tmp_dir!(), "auto-creator-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    capture = Path.join(root, "capture")
    File.mkdir_p!(Path.join(repo, ".aiur/experiments/packs"))
    File.mkdir_p!(capture)
    previous = Application.get_env(:aiur, :experiments_dir)
    Application.put_env(:aiur, :experiments_dir, Path.join(root, "state"))
    source = %{kind: "event_interval", start: "job.started", end: "job.finished", unit_key: "/id", attrs: %{complexity: "/complexity"}}
    metric = %{id: "latency", label: "Latency", unit: "ms", unit_of_analysis: "job", kind: "duration", better: "lower", default_direction: "decrease", group: "flow", requires: [], source: source}
    File.write!(Path.join(repo, ".aiur/experiments/packs/app.json"), Jason.encode!(%{schema_version: 1, id: "app", version: "1", metrics: [metric]}))
    File.write!(Path.join(capture, "coverage.json"), Jason.encode!(%{"app/latency" => "2026-09-01T00:00:00Z"}))

    rows =
      for {topic, at} <- [{"job.started", "2026-10-09T01:00:00Z"}, {"job.finished", "2026-10-09T02:00:00Z"}],
          do: %{metric_ref: "app/latency", unit: "one", topic: topic, at: at, attrs: %{complexity: 3}}

    File.write!(Path.join(capture, "events-2026-10.ndjson"), Enum.map_join(rows, "\n", &Jason.encode!/1) <> "\n")
    ctx = %{repo_path: repo, capture_root: capture, clock: ~U[2026-10-10 00:00:00Z]}
    start_supervised!({Store, catalog_context: ctx})
    opts = [catalog_context: ctx, config: %AutoConfig{metric_packs: ["app"]}, telemetry: fn -> true end, path: Path.join(root, "creator.json")]
    creator = start_supervised!({Creator, opts})

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :experiments_dir, previous), else: Application.delete_env(:aiur, :experiments_dir)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{root: root, creator: creator, opts: opts, ctx: ctx, capture: capture}
  end

  defp line, do: %Line{source: :aiur_version, key: "auto:version:0.0.10", at: ~U[2026-10-10 00:00:00Z], evidence: %{version: "0.0.10"}}

  test "repeated line across a creator restart keeps one experiment and one real frozen baseline", %{creator: creator, opts: opts} do
    assert {:ok, spec} = Creator.create(line(), creator)
    assert {:ok, :exists} = Creator.create(line(), creator)
    stop_supervised!(Creator)
    restarted = start_supervised!({Creator, opts})
    assert {:ok, :exists} = Creator.create(line(), restarted)
    assert {:ok, [%{id: id}]} = Experiments.list()
    assert id == spec.id
    assert {:ok, detail} = Experiments.fetch(id)
    assert [snapshot] = detail.snapshots
    assert snapshot["window_name"] == "before"
    assert [%{"unit_id" => "one", "value" => 3_600_000}] = snapshot["metrics"]["app/latency"]["observations"]
    assert Enum.count(detail.journal, &(&1["kind"] == "frozen")) == 1
  end

  test "default delivery alias creates and freezes the registered built-in metrics", %{opts: opts, ctx: ctx} do
    fixtures = Path.expand("../../../fixtures/experiments/telemetry", __DIR__)
    assert {:ok, prior} = Dataset.build(Path.join(fixtures, "boot-a.ndjson"))
    ctx = Map.merge(ctx, %{telemetry_enabled: true, boot_id: "boot-b", telemetry_path: Path.join(fixtures, "boot-b.ndjson"), prior_loader: fn "boot-b" -> {[prior], false} end})
    stop_supervised!(Creator)
    stop_supervised!(Store)
    start_supervised!({Store, catalog_context: ctx})
    creator = start_supervised!({Creator, opts |> Keyword.delete(:path) |> Keyword.put(:config, %AutoConfig{}) |> Keyword.put(:catalog_context, ctx)})
    assert {:ok, spec} = Creator.create(line(), creator)
    assert length(spec.metrics) == 26
    assert Enum.all?(spec.metrics, &String.starts_with?(&1["ref"], "delivery-speed/"))
    assert {:ok, :exists} = Creator.create(line(), creator)
    assert File.exists?(Path.join(Paths.root(), "auto-creator.json"))
    assert {:ok, [%{id: id}]} = Experiments.list()
    assert id == spec.id
    assert {:ok, %{snapshots: [snapshot]}} = Experiments.fetch(spec.id)
    observation = Enum.find(snapshot["metrics"]["delivery-speed/start_to_merge"]["observations"], &(&1["unit_id"] == "ticket:101"))
    assert observation["value"] == 9_000_000
  end

  test "disabled telemetry creates nothing and logs once per key even after restart", %{opts: opts} do
    stop_supervised!(Creator)
    write_workflow_file!(Workflow.workflow_file_path())
    path = Workflow.workflow_file_path()
    write_workflow_file_atomic!(path, String.replace(File.read!(path), "observability:\n", "observability:\n  telemetry_enabled: false\n"))
    :ok = WorkflowStore.force_reload()
    refute Config.telemetry_enabled?()
    opts = Keyword.delete(opts, :telemetry)
    creator = start_supervised!({Creator, opts})

    log =
      capture_log(fn ->
        assert {:ok, :skipped} = Creator.create(line(), creator)
        assert {:ok, :skipped} = Creator.create(line(), creator)
        stop_supervised!(Creator)
        restarted = start_supervised!({Creator, opts})
        assert {:ok, :skipped} = Creator.create(line(), restarted)
      end)

    assert length(Regex.scan(~r/automatic experiment skipped: telemetry disabled key=auto:version:0.0.10/, log)) == 1
    assert {:ok, []} = Experiments.list()
  end

  test "previous line clips the actual frozen before window", %{creator: creator} do
    line = %{line() | before_floor: ~U[2026-10-05 00:00:00Z]}
    assert {:ok, spec} = Creator.create(line, creator)
    assert spec.windows["before"] == %{"start" => "2026-10-05T00:00:00Z", "end" => "2026-10-10T00:00:00Z"}
    assert spec.windows["after"]["end"] == "2026-10-24T00:00:00Z"
    assert {:ok, %{snapshots: [snapshot]}} = Experiments.fetch(spec.id)
    assert snapshot["window"] == spec.windows["before"]
  end

  test "feature baseline stops before rollout and carries the excluded gap", %{creator: creator} do
    line = %Line{source: :feature, key: "auto:feature:42", at: ~U[2026-10-10 00:00:00Z], before_window: {~U[2026-09-24 00:00:00Z], ~U[2026-10-08 00:00:00Z]}}
    assert {:ok, spec} = Creator.create(line, creator)
    assert spec.windows["before"]["end"] == "2026-10-08T00:00:00Z"
    assert spec.design["change"]["evidence"]["excluded"] == %{"start" => "2026-10-08T00:00:00Z", "end" => "2026-10-10T00:00:00Z"}
    assert {:ok, %{snapshots: [snapshot]}} = Experiments.fetch(spec.id)
    assert snapshot["observation_count"] == 0
  end

  defp other(id, status, until) do
    %{
      id: id,
      title: id,
      status: status,
      metrics: [%{ref: "app/latency"}],
      design: %{kind: "before_after", change: %{type: "manual", ref: id, time: "2026-10-08T00:00:00Z"}},
      windows: %{before: %{start: "2026-10-01T00:00:00Z", end: "2026-10-08T00:00:00Z"}, after: %{start: "2026-10-08T00:00:00Z", end: until}}
    }
  end

  test "concurrent line annotates an open window once but skips closed and exclusive end bounds", %{creator: creator} do
    for {id, status, until} <- [{"open-window", "active", "2026-10-20T00:00:00Z"}, {"closed-window", "concluded", "2026-10-20T00:00:00Z"}, {"ended-window", "active", "2026-10-10T00:00:00Z"}] do
      assert {:ok, _spec} = Experiments.create(other(id, status, until))
    end

    assert {:ok, _spec} = Creator.create(line(), creator)
    assert {:ok, :exists} = Creator.create(line(), creator)
    assert {:ok, %{annotations: [annotation]}} = Experiments.fetch("open-window")
    assert annotation["auto_line_key"] == line().key
    assert annotation["reason"] == "concurrent change: aiur_version 0.0.10"
    for id <- ["closed-window", "ended-window"], do: assert({:ok, %{annotations: []}} = Experiments.fetch(id))
  end

  test "unavailable pack returns an error without creating or freezing", %{opts: opts} do
    stop_supervised!(Creator)
    creator = start_supervised!({Creator, Keyword.put(opts, :config, %AutoConfig{metric_packs: ["missing"]})})
    assert Creator.create(line(), creator) == {:error, {:metric_packs_unavailable, ["missing"]}}
    assert {:ok, []} = Experiments.list()
  end

  test "retry after annotation failure neither duplicates annotations nor re-freezes baseline", %{creator: creator} do
    for id <- ["a-open-window", "b-open-window"], do: assert({:ok, _spec} = Experiments.create(other(id, "active", "2026-10-20T00:00:00Z")))
    path = Paths.file("b-open-window", "annotations.ndjson")
    original = File.read!(path)
    File.write!(path, "garbage\n")
    assert {:error, _reason} = Creator.create(line(), creator)
    assert {:ok, %{annotations: [_annotation]}} = Experiments.fetch("a-open-window")
    File.write!(path, original)
    assert {:ok, spec} = Creator.create(line(), creator)
    assert {:ok, :exists} = Creator.create(line(), creator)
    for id <- ["a-open-window", "b-open-window"], do: assert({:ok, %{annotations: [_annotation]}} = Experiments.fetch(id))
    assert {:ok, %{snapshots: [_snapshot]}} = Experiments.fetch(spec.id)
  end

  test "store failure propagates without a frozen snapshot or completion receipt", %{creator: creator, ctx: ctx, root: root} do
    stop_supervised!(Store)
    start_supervised!({Store, catalog_context: ctx, journal_writer: fn _path, _entry -> {:error, :enospc} end})
    assert {:error, :enospc} = Creator.create(line(), creator)
    assert Path.wildcard(Path.join(root, "state/*/snapshots/before*.json")) == []
    refute File.exists?(Path.join(root, "creator.json"))
    stop_supervised!(Store)
    start_supervised!({Store, catalog_context: ctx})
    assert {:ok, spec} = Creator.create(line(), creator)
    assert {:ok, %{snapshots: [_snapshot]}} = Experiments.fetch(spec.id)
  end

  test "an existing auto key without a baseline freezes once before completion", %{creator: creator} do
    attrs = other("existing-auto", "active", "2026-10-24T00:00:00Z")
    attrs = attrs |> Map.put(:key, line().key) |> put_in([:windows, :before, :end], "2026-10-10T00:00:00Z")
    assert {:ok, existing} = Experiments.create(attrs, freeze: false)
    assert {:ok, %{snapshots: []}} = Experiments.fetch(existing.id)
    assert {:ok, spec} = Creator.create(line(), creator)
    assert spec.id == existing.id
    assert {:ok, :exists} = Creator.create(line(), creator)
    assert {:ok, %{snapshots: [snapshot]}} = Experiments.fetch(existing.id)
    assert snapshot["observation_count"] == 1
  end

  test "invalid line inputs cannot create an experiment or persist a receipt", %{creator: creator, root: root} do
    for invalid <- [%{line() | key: nil}, %{line() | source: :deploy}, %{line() | evidence: nil}, %{line() | before_window: {~U[2026-10-10 00:00:00Z], ~U[2026-10-11 00:00:00Z]}}] do
      assert Creator.create(invalid, creator) == {:error, :invalid_line}
    end

    assert {:ok, []} = Experiments.list()
    refute File.exists?(Path.join(root, "creator.json"))
  end

  test "malformed durable receipts are refused instead of discarding deduplication", %{opts: opts} do
    stop_supervised!(Creator)
    File.write!(opts[:path], Jason.encode!(%{completed: [42], skipped: []}))
    assert {:error, {:invalid_auto_receipts, _child_spec}} = start_supervised({Creator, Keyword.put(opts, :name, nil)})
  end

  test "read-only future experiments are unchanged and warn once while new lines complete", %{creator: creator, root: root} do
    assert {:ok, _spec} = Experiments.create(other("future-window", "active", "2026-10-20T00:00:00Z"))
    path = Paths.file("future-window", "spec.json")
    raw = path |> File.read!() |> Jason.decode!() |> Map.put("schema_version", 2) |> Map.put("windows", %{"future" => %{"bounds" => ["2026-10-01T00:00:00Z", "2026-10-20T00:00:00Z"]}})
    original = Jason.encode!(raw)
    File.write!(path, original)
    next_line = %{line() | key: "auto:version:0.0.11"}

    log =
      capture_log(fn ->
        for next <- [line(), next_line] do
          assert {:ok, spec} = Creator.create(next, creator)
          assert {:ok, %{snapshots: [snapshot]}} = Experiments.fetch(spec.id)
          assert snapshot["window_name"] == "before"
          assert {:ok, :exists} = Creator.create(next, creator)
        end
      end)

    receipts = root |> Path.join("creator.json") |> File.read!() |> Jason.decode!()
    assert Enum.sort(receipts["completed"]) == [line().key, next_line.key]
    assert length(Regex.scan(~r/concurrent annotation skipped: read-only experiment id=future-window/, log)) == 1
    assert File.read!(path) == original
    assert {:ok, %{annotations: [], read_only?: true}} = Experiments.fetch("future-window")
  end
end
