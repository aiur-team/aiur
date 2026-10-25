defmodule Aiur.Experiments.StoreEvaluationTest do
  use ExUnit.Case, async: false
  alias Aiur.Experiments
  alias Aiur.Experiments.{Paths, Snapshot, Store}

  setup do
    root = Path.join(System.tmp_dir!(), "snapshots-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    capture = Path.join(root, "capture")
    File.mkdir_p!(Path.join(repo, ".aiur/experiments/packs"))
    File.mkdir_p!(capture)
    previous = Application.get_env(:aiur, :experiments_dir)
    Application.put_env(:aiur, :experiments_dir, Path.join(root, "state"))
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)
    :ok = Aiur.TestSupport.ensure_pubsub_running()
    source = %{"kind" => "event_interval", "start" => "job.started", "end" => "job.finished", "unit_key" => "/id", "attrs" => %{"complexity" => "/complexity"}}
    metric = %{id: "latency", label: "Latency", unit: "ms", unit_of_analysis: "job", kind: "duration", better: "lower", default_direction: "decrease", group: "flow", requires: [], source: source}
    pack = %{schema_version: 1, id: "app", version: "1", metrics: [metric]}
    File.write!(Path.join(repo, ".aiur/experiments/packs/app.json"), Jason.encode!(pack))
    File.write!(Path.join(capture, "coverage.json"), Jason.encode!(%{"app/latency" => "2026-10-01T00:00:00Z"}))
    events = [event("one", "job.started", "2026-10-01T01:00:00Z"), event("one", "job.finished", "2026-10-01T02:00:00Z"), event("open", "job.started", "2026-10-01T03:00:00Z")]
    File.write!(Path.join(capture, "events-2026-10.ndjson"), Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n")
    ctx = %{repo_path: repo, capture_root: capture, clock: ~U[2026-10-02 00:00:00Z]}
    owner = self()
    controller = start_supervised!({Agent, fn -> :empty end})

    evaluate = fn _, _, _ ->
      case Agent.get(controller, & &1) do
        :raise ->
          raise "broken evaluator"

        :hold ->
          send(owner, {:evaluating, self()})

          receive do
            :release -> %{"app/latency" => %{observations: []}}
          end

        :oversized ->
          %{"app/latency" => %{observations: for(n <- 1..50_001, do: %{unit_id: to_string(n), value: n, at: "2026-10-01T01:00:00Z", attrs: %{}})}}

        :empty ->
          %{"app/latency" => %{observations: []}}
      end
    end

    ctx = Map.put(ctx, :evaluate, evaluate)
    writer = start_supervised!({Store, catalog_context: ctx})

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :experiments_dir, previous), else: Application.delete_env(:aiur, :experiments_dir)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{ctx: ctx, controller: controller, writer: writer}
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

  test "oversized create persists nothing and can retry the same id", %{controller: controller} do
    Agent.update(controller, fn _ -> :oversized end)
    assert {:error, {:too_many_observations, %{"app/latency" => 50_001}}} = Experiments.create(attrs())
    refute File.exists?(Paths.experiment("freeze-fixture"))
    assert {:ok, []} = Paths.ids()
    Agent.update(controller, fn _ -> :empty end)
    assert {:ok, %{id: "freeze-fixture", existing: false}} = Experiments.create(attrs())
  end

  test "raising create and freeze evaluators leave writer alive", %{controller: controller, writer: writer} do
    Agent.update(controller, fn _ -> :raise end)
    assert {:error, {:evaluation_failed, "broken evaluator"}} = Experiments.create(attrs())
    refute File.exists?(Paths.experiment("freeze-fixture"))
    assert Process.alive?(writer)
    assert {:ok, spec} = Experiments.create(attrs(), freeze: false)
    assert {:error, {:evaluation_failed, "broken evaluator"}} = Experiments.freeze(spec.id)
    assert Process.alive?(writer)
    assert {:ok, nil} = Snapshot.latest(spec.id, "before")
    Agent.update(controller, fn _ -> :empty end)
    assert {:ok, snapshot} = Experiments.freeze(spec.id)
    assert snapshot["revision"] == 1
  end

  test "evaluation is outside writer, concurrent work is bounded and amendments remain responsive", %{controller: controller, writer: writer} do
    assert {:ok, spec} = Experiments.create(attrs(), freeze: false)
    Agent.update(controller, fn _ -> :hold end)
    freeze = Task.async(fn -> Experiments.freeze(spec.id) end)
    assert_receive {:evaluating, evaluator}, 1_000
    refute evaluator == writer
    assert Experiments.export_analysis_input(spec.id) == {:error, :evaluation_busy}
    assert {:ok, changed} = Experiments.amend(spec.id, %{title: "Amended while evaluating"}, "operator")
    assert changed.title == "Amended while evaluating"
    send(evaluator, :release)
    assert Task.await(freeze) == {:error, :stale_preparation}
    assert {:ok, nil} = Snapshot.latest(spec.id, "before")
  end

  test "create runs under task supervision and timeout leaves no experiment", %{controller: controller, writer: writer} do
    Agent.update(controller, fn _ -> :hold end)
    create = Task.async(fn -> Experiments.create(attrs()) end)
    assert_receive {:evaluating, evaluator}, 1_000
    assert evaluator in Task.Supervisor.children(Aiur.TaskSupervisor)
    refute evaluator == writer
    refute File.exists?(Paths.experiment("freeze-fixture"))
    state = :sys.get_state(writer)
    send(writer, {:evaluation_timeout, state.evaluation.token})
    assert Task.await(create) == {:error, :evaluation_timeout}
    refute File.exists?(Paths.experiment("freeze-fixture"))
    assert {:ok, []} = Paths.ids()
    assert Process.alive?(writer)
  end

  test "deadline kills the evaluator and refuses late persistence", %{controller: controller, writer: writer} do
    assert {:ok, spec} = Experiments.create(attrs(), freeze: false)
    Agent.update(controller, fn _ -> :hold end)
    freeze = Task.async(fn -> Experiments.freeze(spec.id) end)
    assert_receive {:evaluating, evaluator}, 1_000
    monitor = Process.monitor(evaluator)
    state = :sys.get_state(writer)
    send(writer, {:evaluation_timeout, state.evaluation.token})
    assert Task.await(freeze) == {:error, :evaluation_timeout}
    assert_receive {:DOWN, ^monitor, :process, ^evaluator, :killed}, 1_000
    assert Process.alive?(writer)
    assert {:ok, nil} = Snapshot.latest(spec.id, "before")
    Agent.update(controller, fn _ -> :empty end)
    assert {:ok, snapshot} = Experiments.freeze(spec.id)
    assert snapshot["revision"] == 1
  end
end
