defmodule Aiur.Experiments.SnapshotTest do
  use ExUnit.Case, async: false
  alias Aiur.Experiments
  alias Aiur.Experiments.{Evidence, Paths, Reader, Snapshot, Spec, Store, WindowData}

  setup do
    root = Path.join(System.tmp_dir!(), "snapshots-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    capture = Path.join(root, "capture")
    File.mkdir_p!(Path.join(repo, ".aiur/experiments/packs"))
    File.mkdir_p!(capture)
    previous = Application.get_env(:aiur, :experiments_dir)
    Application.put_env(:aiur, :experiments_dir, Path.join(root, "state"))
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)
    unless Process.whereis(Aiur.PubSub), do: start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    source = %{"kind" => "event_interval", "start" => "job.started", "end" => "job.finished", "unit_key" => "/id", "attrs" => %{"complexity" => "/complexity"}}
    metric = %{id: "latency", label: "Latency", unit: "ms", unit_of_analysis: "job", kind: "duration", better: "lower", default_direction: "decrease", group: "flow", requires: [], source: source}
    pack = %{schema_version: 1, id: "app", version: "1", metrics: [metric]}
    File.write!(Path.join(repo, ".aiur/experiments/packs/app.json"), Jason.encode!(pack))
    File.write!(Path.join(capture, "coverage.json"), Jason.encode!(%{"app/latency" => "2026-10-01T00:00:00Z"}))
    events = [event("one", "job.started", "2026-10-01T01:00:00Z"), event("one", "job.finished", "2026-10-01T02:00:00Z"), event("open", "job.started", "2026-10-01T03:00:00Z")]
    File.write!(Path.join(capture, "events-2026-10.ndjson"), Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n")
    ctx = %{repo_path: repo, capture_root: capture, clock: ~U[2026-10-02 00:00:00Z]}
    start_supervised!({Store, catalog_context: ctx})

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :experiments_dir, previous), else: Application.delete_env(:aiur, :experiments_dir)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{ctx: ctx, root: root, capture: capture, repo: repo}
  end

  defp event(unit, topic, at), do: %{metric_ref: "app/latency", unit: unit, topic: topic, at: at, attrs: %{complexity: 3}}

  defp attrs do
    %{
      id: "freeze-fixture",
      title: "Frozen baseline",
      design: %{kind: "before_after", change: %{type: "manual", ref: "deploy", time: "2026-10-02T00:00:00Z"}},
      windows: %{before: %{start: "2026-10-01T00:00:00Z", end: "2026-10-02T00:00:00Z"}, after: %{start: "2026-10-02T00:00:00Z", end: "2026-10-03T00:00:00Z"}},
      metrics: [%{ref: "app/latency"}]
    }
  end

  test "create freezes raw durations and censored rows; deleting telemetry preserves show and arms", %{ctx: ctx, capture: capture} do
    assert {:ok, spec} = Experiments.create(attrs())
    assert {:ok, detail} = Experiments.fetch(spec.id)
    assert [snapshot] = detail.snapshots
    assert snapshot["observation_count"] == 2
    rows = snapshot["metrics"]["app/latency"]["observations"]
    assert Enum.find(rows, &(&1["unit_id"] == "one"))["value"] == 3_600_000
    assert %{"censored" => true, "value" => 75_600_000, "finished_at" => nil} = Enum.find(rows, &(&1["unit_id"] == "open"))
    assert [%{"kind" => "created"}, %{"kind" => "frozen", "sha256" => sha}] = Experiments.journal(spec.id)
    assert sha == snapshot["sha256"]
    assert {:ok, stat} = File.stat(Paths.file(spec.id, "snapshots/before.r1.json"))
    assert Bitwise.band(stat.mode, 0o777) == 0o444
    assert {:ok, arms} = Experiments.arms(spec.id, context: ctx)
    File.rm!(Path.join(capture, "events-2026-10.ndjson"))
    assert {:ok, after_detail} = Experiments.fetch(spec.id)
    assert Evidence.encode(after_detail) == Evidence.encode(detail)
    assert {:ok, after_arms} = Experiments.arms(spec.id, context: ctx)
    assert Evidence.encode(after_arms) == Evidence.encode(arms)
  end

  test "tampered bytes and recomputed hashes cannot replace journaled evidence", %{ctx: ctx} do
    {:ok, spec} = Experiments.create(attrs())
    path = Paths.file(spec.id, "snapshots/before.r1.json")
    File.chmod!(path, 0o600)
    bytes = File.read!(path)
    # Mutate an existing numeric value, preserving valid JSON.
    modified = Jason.decode!(bytes) |> put_in(["metrics", "app/latency", "observations", Access.at(0), "value"], 7)
    File.write!(path, Jason.encode!(modified))
    assert Snapshot.read(path) == {:error, :tampered}
    assert Experiments.arms(spec.id, context: ctx) == {:error, :tampered}
    modified = Map.put(modified, "sha256", Evidence.hash(Map.delete(modified, "sha256")))
    File.write!(path, Jason.encode!(modified))
    assert Experiments.fetch(spec.id) == {:error, :tampered}
  end

  test "revisions need a reason and keep old bytes", %{ctx: ctx} do
    {:ok, spec} = Experiments.create(attrs())
    path = Paths.file(spec.id, "snapshots/before.r1.json")
    bytes = File.read!(path)
    assert Experiments.freeze(spec.id, "before") == {:error, {:reason_required, 1}}
    assert {:ok, revision} = Experiments.freeze(spec.id, "before", reason: "more complete", context: ctx)
    assert revision["revision"] == 2
    assert File.read!(path) == bytes
    assert {:ok, latest} = Snapshot.latest(spec.id, "before")
    assert latest == revision
    assert List.last(Experiments.journal(spec.id))["reason"] == "more complete"
  end

  test "50001 observations refuse without any snapshot or pending write", %{ctx: ctx} do
    {:ok, spec} = Experiments.create(attrs(), freeze: false)
    rows = for n <- 1..50_001, do: %{unit_id: to_string(n), value: n, at: ~U[2026-10-01 01:00:00Z], attrs: %{}}
    evaluate = fn _refs, _window, _ctx -> %{"app/latency" => %{coverage: %{state: :captured}, observations: rows}} end
    assert {:error, {:too_many_observations, %{"app/latency" => 50_001}}} = Experiments.freeze(spec.id, "before", context: Map.put(ctx, :evaluate, evaluate))
    refute File.exists?(Paths.file(spec.id, "snapshots"))
    refute File.exists?(Paths.file(spec.id, "snapshot-pending.json"))
    assert [%{"kind" => "created"}] = Experiments.journal(spec.id)
  end

  test "canonical hashing ignores map order and snapshot sample input order", %{ctx: ctx} do
    {:ok, spec} = Experiments.create(attrs(), freeze: false)
    make_ctx = fn rows -> Map.put(ctx, :evaluate, fn _, _, _ -> %{"app/latency" => %{coverage: %{state: :captured}, observations: rows}} end) end
    rows = for n <- [2, 1], do: %{unit_id: to_string(n), value: n, at: ~U[2026-10-01 01:00:00Z], attrs: %{}}
    assert {:ok, first} = WindowData.evaluate(Spec.to_map(spec), "before", make_ctx.(rows))
    assert {:ok, second} = WindowData.evaluate(Spec.to_map(spec), "before", make_ctx.(Enum.reverse(rows)))
    assert Evidence.hash(first) == Evidence.hash(second)
    assert Evidence.hash(%{a: 1, b: 2}) == Evidence.hash(%{"b" => 2, "a" => 1})
  end

  test "real interval evaluation excludes straddlers and supports finish assignment", %{ctx: ctx, capture: capture} do
    events = [event("cross", "job.started", "2026-10-01T23:00:00Z"), event("cross", "job.finished", "2026-10-02T01:00:00Z")]
    File.write!(Path.join(capture, "events-2026-10.ndjson"), Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n")
    ctx = Map.put(ctx, :clock, ~U[2026-10-03 00:00:00Z])
    {:ok, spec} = Experiments.create(attrs(), freeze: false)
    assert {:ok, start_arms} = Experiments.arms(spec.id, context: ctx)
    assert start_arms["excluded"]["straddle"] == 1
    assert start_arms["arms"]["before"]["metrics"]["app/latency"]["n"] == 0
    assert start_arms["arms"]["after"]["metrics"]["app/latency"]["n"] == 0
    assert {:ok, _updated} = Experiments.amend(spec.id, %{design: Map.put(spec.design, "assign_by", "finish")}, "operator")
    assert {:ok, finish_arms} = Experiments.arms(spec.id, context: ctx)
    assert finish_arms["excluded"]["straddle"] == 0
    assert finish_arms["arms"]["after"]["metrics"]["app/latency"]["n"] == 1
    assert [row] = finish_arms["arms"]["after"]["metrics"]["app/latency"]["observations"]
    assert row["value"] == 7_200_000
  end

  test "unfinished row becomes finished on a later revision", %{ctx: ctx, capture: capture} do
    {:ok, spec} = Experiments.create(attrs())
    finish = event("open", "job.finished", "2026-10-01T04:00:00Z")
    File.write!(Path.join(capture, "events-2026-10.ndjson"), Jason.encode!(finish) <> "\n", [:append])
    assert {:ok, snapshot} = Experiments.freeze(spec.id, "before", context: ctx, reason: "completion arrived")
    assert %{"censored" => false, "value" => 3_600_000, "finished_at" => "2026-10-01T04:00:00Z"} = Enum.find(snapshot["metrics"]["app/latency"]["observations"], &(&1["unit_id"] == "open"))
  end

  test "future checkpoint schemas are refused without live fallback", %{ctx: ctx} do
    {:ok, spec} = Experiments.create(attrs(), freeze: false)
    File.mkdir_p!(Paths.file(spec.id, "snapshots"))
    File.write!(Paths.file(spec.id, "snapshots/before.partial.ndjson"), Jason.encode!(%{schema_version: 2}) <> "\n")
    assert Experiments.arms(spec.id, context: ctx) == {:error, {:newer_version, 2}}
    assert Experiments.freeze(spec.id, "before", context: ctx) == {:error, {:newer_version, 2}}
    refute File.exists?(Paths.file(spec.id, "snapshots/before.r1.json"))
  end

  test "show detects a pack definition changed since the frozen revision", %{ctx: ctx, repo: repo} do
    {:ok, spec} = Experiments.create(attrs())
    assert {:ok, original} = Reader.fetch(spec.id, ctx)
    refute original.pack_changed_since_freeze
    path = Path.join(repo, ".aiur/experiments/packs/app.json")
    pack = Jason.decode!(File.read!(path)) |> put_in(["metrics", Access.at(0), "label"], "Changed definition")
    File.write!(path, Jason.encode!(pack))
    assert {:ok, changed} = Reader.fetch(spec.id, ctx)
    assert changed.pack_changed_since_freeze
    assert changed.snapshots == original.snapshots
  end

  test "re-freezing after retention preserves completed evidence", %{ctx: ctx, capture: capture} do
    {:ok, spec} = Experiments.create(attrs())
    File.rm!(Path.join(capture, "events-2026-10.ndjson"))
    assert {:ok, revised} = Experiments.freeze(spec.id, "before", context: ctx, reason: "retention elapsed")
    assert revised["observation_count"] == 2
    assert %{"value" => 3_600_000, "censored" => false} = Enum.find(revised["metrics"]["app/latency"]["observations"], &(&1["unit_id"] == "one"))
  end

  test "deleting a journaled revision refuses evidence instead of choosing older or live rows" do
    {:ok, spec} = Experiments.create(attrs())
    assert {:ok, _second} = Experiments.freeze(spec.id, "before", reason: "second revision")
    File.rm!(Paths.file(spec.id, "snapshots/before.r2.json"))
    assert Experiments.fetch(spec.id) == {:error, :tampered}
    assert Experiments.arms(spec.id) == {:error, :tampered}
    assert Experiments.freeze(spec.id, "before", reason: "replace deleted") == {:error, :tampered}
  end

  test "invalid experiment ids are refused without terminating the writer" do
    assert Experiments.freeze("../escape") == {:error, :not_found}
    assert Experiments.export_analysis_input("../escape") == {:error, :not_found}
    assert {:ok, spec} = Experiments.create(attrs())
    assert {:ok, %{snapshots: [snapshot]}} = Experiments.fetch(spec.id)
    assert snapshot["observation_count"] == 2
  end
end
