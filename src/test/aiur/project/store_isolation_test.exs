defmodule Aiur.Project.StoreIsolationTest do
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.Features
  alias Aiur.BuildQueue
  alias Aiur.BuildQueue.{Hints, Model, Server, Store}
  alias Aiur.Config.Paths
  alias Aiur.Orchestrator.{SnapshotCache, SnapshotPublisher, SnapshotStore, TrackedSet}
  alias Aiur.Project
  alias Aiur.Project.{Context, Table}
  alias Aiur.TestSupport.WorkflowFiles
  alias Aiur.WorkflowStore

  defmodule Boundary do
    def open_issue_labels(_age), do: {:ok, %{}, 1_000}
    def status(_ids), do: :unavailable
    def ensure_labels(_labels), do: :ok
    def add_label(_id, _label), do: :ok
    def remove_label(_id, _label), do: :ok
    def add_labels(_id, _labels), do: :ok
    def remove_labels(_id, _labels), do: :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "project-isolation-#{System.unique_integer([:positive])}")
    start_supervised!({Registry, keys: :unique, name: Aiur.ProjectRegistry})
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    a = project("o/a", root)
    b = project("o/b", root)
    on_exit(fn -> Table.drop("o/a") && Table.drop("o/b") end)
    {:ok, a: a, b: b}
  end

  defp project(repo, root) do
    state_root = Path.join(root, String.replace(repo, "/", "-"))
    Project.from_machine_entry(%{repo: repo, config: Path.join(state_root, "config")}, state_root)
  end

  defp as(project, fun) do
    Context.put(project)
    fun.()
  after
    Context.delete()
  end

  # Linked to the test process, which carries the project context start_link reads.
  defp start(module, opts), do: {:ok, _pid} = module.start_link(opts)

  defp queue_opts do
    [
      settings: {:ok, %Aiur.Config.Schema{build_queue: %Aiur.Config.Schema.BuildQueue{enabled: true}, tracker: %Aiur.Config.Schema.Tracker{}, polling: %Aiur.Config.Schema.Polling{}}},
      tracker: Boundary,
      claim_probe: Boundary,
      clock: fn -> 1_000 end,
      exchange: :absent_isolation_exchange,
      schedule: fn
        pid, {:reconcile, _} = message, _delay ->
          send(pid, message)
          make_ref()

        _pid, _message, _delay ->
          make_ref()
      end
    ]
  end

  defp document do
    created = ~U[2026-10-08 00:00:00Z]
    queue = %Model.Queue{id: "q-ab12", name: "Q", kind: :list, root: nil, held: false, generation: 0, created_at: created}
    item = fn id -> %Model.Item{issue_id: id, queue_id: "q-ab12", position: 0, hold: nil, override: nil, promoted_at: nil, added_at: created} end
    %{queues: [queue], items: [item.("1")], edges: [], intents: [], latches: []}
  end

  test "adding #5 to A's queue leaves B's queue.json unchanged", %{a: a, b: b} do
    for p <- [a, b], do: as(p, fn -> Store.save(document()) end)
    path = fn p -> as(p, fn -> Path.join(elem(Paths.build_queue_dir(), 1), "queue.json") end) end
    assert path.(a) != path.(b)
    b_before = File.read!(path.(b))

    for p <- [a, b], do: as(p, fn -> start(Server, queue_opts()) end)
    assert {:ok, _} = as(a, fn -> BuildQueue.add(["5"], "q-ab12") end)

    assert File.read!(path.(b)) == b_before
    assert File.read!(path.(a)) =~ "5"
    assert as(a, fn -> GenServer.whereis(Project.via(Server)) end) != as(b, fn -> GenServer.whereis(Project.via(Server)) end)
    assert as(a, fn -> Hints.table_ref() end) != as(b, fn -> Hints.table_ref() end)
  end

  test "tracked sets are per project", %{a: a, b: b} do
    for p <- [a, b], do: as(p, fn -> start(TrackedSet, []) end)
    as(a, fn -> TrackedSet.reset(["1"]) end)
    as(b, fn -> TrackedSet.reset(["2"]) end)
    assert as(a, fn -> {TrackedSet.member?("1"), TrackedSet.member?("2")} end) == {true, false}
    assert as(b, fn -> {TrackedSet.member?("1"), TrackedSet.member?("2")} end) == {false, true}
  end

  test "snapshot cache and features are per project", %{a: a, b: b} do
    for p <- [a, b] do
      as(p, fn ->
        start(SnapshotCache, [])
        start(Features, general_epics: fn -> {:ok, [%{key: "bugs", hue: 38}]} end, alert_fun: fn _, _, _ -> :ok end)
      end)
    end

    as(a, fn -> SnapshotCache.put(:orch, %{n: 1}) end)
    assert as(a, fn -> SnapshotCache.get(:orch) end) == %{n: 1}
    assert as(b, fn -> SnapshotCache.get(:orch) end) == nil

    assert {:ok, _} = as(a, fn -> Features.create("f1", %{label: "F1"}, source: "cli:executor", actor: "executor") end)
    assert File.exists?(as(a, fn -> elem(Paths.build_features_state_dir(), 1) end))
    assert {:ok, %{features: %{"f1" => _}}} = as(a, fn -> Features.snapshot() end)
    assert {:ok, %{features: features}} = as(b, fn -> Features.snapshot() end)
    refute Map.has_key?(features, "f1")
  end

  test "Table.new reuses a live table and drop forgets only one project", %{a: a, b: b} do
    tid = as(a, fn -> Table.new(:t, [:set, :public]) end)
    assert as(a, fn -> Table.new(:t, [:set, :public]) end) == tid
    as(b, fn -> Table.new(:t, [:set, :public]) end)
    Table.drop("o/a")
    assert as(a, fn -> Table.ref(:t) end) == nil
    assert as(b, fn -> Table.ref(:t) end) != nil
  end

  test "per-project paths follow the context; machine-level paths do not", %{a: a} do
    machine = Paths.decision_state_dir()
    assert as(a, fn -> Paths.build_queue_dir() end) == {:ok, Path.join(a.state_root, "build-queue")}
    assert as(a, fn -> Paths.decision_state_dir() end) == machine
  end

  test "the snapshot store works for the project that started it", %{a: a, b: b} do
    for p <- [a, b] do
      as(p, fn ->
        start(SnapshotCache, [])
        start(SnapshotStore, [])
      end)
    end

    as(a, fn ->
      generation = SnapshotStore.begin_generation(:orch)
      SnapshotStore.publish_state(:orch, generation, %Aiur.Orchestrator.State{})
    end)

    assert eventually(fn -> as(a, fn -> SnapshotCache.get(:orch) end) end)
    assert as(b, fn -> SnapshotCache.get(:orch) end) == nil
  end

  test "snapshot publisher tables are per project", %{a: a, b: b} do
    for p <- [a, b], do: as(p, fn -> start(SnapshotPublisher, []) end)
    as(a, fn -> SnapshotPublisher.write(:orch, make_ref(), %{n: 1}) end)
    assert as(a, fn -> :ets.tab2list(Table.ref(SnapshotPublisher)) end) != []
    assert as(b, fn -> :ets.tab2list(Table.ref(SnapshotPublisher)) end) == []
  end

  test "each project's workflow store reads its own config", %{a: a, b: b} do
    for {p, seconds} <- [{a, 91}, {b, 47}] do
      File.mkdir_p!(Path.dirname(p.config_path))
      :ok = WorkflowFiles.write_workflow_file!(p.config_path, poll_interval_seconds: seconds)
    end

    for p <- [a, b], do: as(p, fn -> start(WorkflowStore, []) end)
    interval = fn p -> as(p, fn -> Aiur.Config.settings!().polling.interval_seconds end) end
    assert {interval.(a), interval.(b)} == {91, 47}

    WorkflowFiles.write_workflow_file!(a.config_path, poll_interval_seconds: 33)
    assert :ok = as(a, fn -> WorkflowStore.force_reload() end)
    assert {interval.(a), interval.(b)} == {33, 47}
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end
end
