defmodule Aiur.DaemonHotPathsTest do
  # Keep the synchronous call-tracing regressions together so trace patterns share one lifecycle.
  use Aiur.TestSupport

  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.CurrentRunMembership.{Reconciler, Store}
  alias Aiur.CurrentRunProjections.CheckpointPersistence
  alias Aiur.{IssueSyncTestSupport, SystemCgroup, TestCleanup, TestSupport, TicketActivity, TicketObservation, TrackerIdentity}
  alias Aiur.Orchestrator.{DispatchPolicy, State, WaitingReason}
  alias Aiur.Orchestrator.IssueSync.CapacityConstraints
  alias Aiur.Workspace.Ownership.Retention

  test "activity scans reuse ingested keys while membership changes remain visible" do
    now = DateTime.utc_now()
    first = identity("one")
    second = identity("two")
    members = start_supervised!({Agent, fn -> [first] end})

    owner =
      start_supervised!(
        {TicketActivity,
         name: nil,
         now_fun: fn -> now end,
         membership_snapshot_fun: fn -> %{members: Agent.get(members, & &1)} end,
         exchange_subscribe_fun: fn -> :ok end,
         membership_subscribe_fun: fn -> :ok end,
         retention_all_fun: fn -> %{} end,
         retention_retain_fun: fn _, _ -> :ok end}
      )

    observation = %TicketObservation{
      status: :joinable,
      reason: nil,
      tracker_identity: first,
      source: %{kind: :agent_event, name: "progress"},
      event_id: 1,
      provenance: %{run_id: "run"},
      occurred_at: now,
      observed_at: now,
      attributes: %{percent: 40}
    }

    send(owner, {:event, %{ticket_observation: observation}})
    assert [%{identity: ^first, progress: %{percent: 40}, retention: :current}] = TicketActivity.snapshots(server: owner, now: now).entries

    trace_calls(owner, [{TrackerIdentity, :github_key, 1}, {TrackerIdentity, :joinable?, 1}])

    for _ <- 1..5 do
      send(owner, {:current_run_membership_health_changed, %{}})
      assert [%{identity: ^first, retention: :current}] = TicketActivity.snapshots(server: owner, now: now).entries
    end

    assert calls(owner) == []

    Agent.update(members, fn _ -> [second] end)
    send(owner, {:current_run_membership_health_changed, %{}})
    assert [%{identity: ^first, retention: :recent}] = TicketActivity.snapshots(server: owner, now: now).entries
    assert Enum.any?(calls(owner), &match?({TrackerIdentity, :github_key, [^second]}, &1))
  end

  test "checkpoint hash avoids inspection and remains stable across generation and map order" do
    parent = self()

    owner =
      spawn_link(fn ->
        receive_barrier(:hash)
        one = %{run_id: "run", checkpoint_generation: 1, weight_facts: Map.new([{{:github, "o", "r", "two"}, 2}, {{:github, "o", "r", "one"}, 1}])}
        two = %{one | checkpoint_generation: 2, weight_facts: Map.new(Enum.reverse(Enum.to_list(one.weight_facts)))}

        send(
          parent,
          {:hashes, CheckpointPersistence.content_hash(one), CheckpointPersistence.content_hash(two), CheckpointPersistence.content_hash(put_in(one, [:weight_facts, {:github, "o", "r", "one"}], 3))}
        )

        receive_barrier(:stop)
      end)

    trace_calls(owner, [{Kernel, :inspect, 1}, {Kernel, :inspect, 2}])
    send(owner, :hash)
    {:hashes, one, two, changed} = receive_barrier({:hashes, _, _, _})
    assert one == two
    assert one != changed
    assert calls(owner) == []
    send(owner, :stop)
  end

  test "reconciliation persists multiple membership changes with one open and sync, and recovers them" do
    dir = TestSupport.tmp_root!("membership-batch")
    on_exit(fn -> TestCleanup.rm_rf!(dir) end)
    owner = start_supervised!({Store, name: nil, state_dir: dir, run_id: "batch-run", checkpoint_interval: 32})
    trace_calls(owner, [{:file, :open, 2}, {:file, :sync, 1}])
    one = identity("one")
    two = identity("two")
    snapshot = %{running: [%{tracker_identity: one}, %{tracker_identity: two}]}
    {results, _} = Reconciler.Snapshot.reconcile_changes(snapshot, %{}, fn rows -> Store.observe_many(rows, server: owner) end, MapSet.new())
    assert [{:ok, %{generation: 2}}] = results
    operations = calls(owner)
    assert Enum.count(operations, &match?({:file, :open, _}, &1)) == 1
    assert Enum.count(operations, &match?({:file, :sync, _}, &1)) == 1
    assert {:ok, %{status: :unchanged}} = Store.observe_many([{one, :running}, {two, :running}], server: owner)
    assert {:ok, %{status: :unchanged}} = Store.observe_many([], server: owner)
    assert calls(owner) == []
    assert Store.generation(owner) == 2
    assert {:ok, %{lifecycle: :running}} = Store.lookup(one, owner)
    assert {:ok, %{lifecycle: :running}} = Store.lookup(two, owner)
    stop_supervised!(Store)
    recovered = start_supervised!({Store, name: nil, state_dir: dir, run_id: "batch-run"})
    assert Store.generation(recovered) == 2
    assert {:ok, %{lifecycle: :running}} = Store.lookup(one, recovered)
    assert {:ok, %{lifecycle: :running}} = Store.lookup(two, recovered)
  end

  test "batch append failure exposes no unpersisted projection or lifecycle events" do
    dir = TestSupport.tmp_root!("membership-batch-failure")
    on_exit(fn -> TestCleanup.rm_rf!(dir) end)
    parent = self()

    owner =
      start_supervised!(
        {Store,
         name: nil,
         state_dir: dir,
         run_id: "batch-run",
         append_many_fun: fn _, records ->
           send(parent, {:attempted, length(records)})
           {:error, :disk_full}
         end,
         event_publish_fun: fn _, _ -> send(parent, :published) end}
      )

    assert {:error, {:membership_persistence_failed, {:append_failed, :disk_full}}} =
             Store.observe_many([{identity("one"), :running}, {identity("two"), :queued}], server: owner)

    assert_received {:attempted, 2}
    assert Store.generation(owner) == 0
    refute_received :published
    assert {:error, {:membership_unavailable, _}} = Store.observe_many([{identity("one"), :running}], server: owner)
  end

  test "a batch crossing the checkpoint cadence compacts and recovers all members" do
    dir = TestSupport.tmp_root!("membership-batch-checkpoint")
    on_exit(fn -> TestCleanup.rm_rf!(dir) end)
    owner = start_supervised!({Store, name: nil, state_dir: dir, run_id: "batch-run", checkpoint_interval: 2})
    one = identity("one")
    two = identity("two")
    assert {:ok, %{generation: 2}} = Store.observe_many([{one, :running}, {two, :queued}], server: owner)
    [journal] = Path.wildcard(Path.join([dir, "runs", "*", "membership.ndjson"]))
    assert File.read!(journal) == ""
    assert File.regular?(Path.join(Path.dirname(journal), "membership.checkpoint.json"))
    stop_supervised!(Store)
    recovered = start_supervised!({Store, name: nil, state_dir: dir, run_id: "batch-run"})
    assert Store.generation(recovered) == 2
    assert {:ok, %{lifecycle: :running}} = Store.lookup(one, recovered)
    assert {:ok, %{lifecycle: :queued}} = Store.lookup(two, recovered)
  end

  test "invalid batch validates every row before persisting any row" do
    dir = TestSupport.tmp_root!("membership-invalid-batch")
    on_exit(fn -> TestCleanup.rm_rf!(dir) end)
    parent = self()

    owner =
      start_supervised!(
        {Store,
         name: nil,
         state_dir: dir,
         run_id: "batch-run",
         append_many_fun: fn _, _ ->
           send(parent, :appended)
           :ok
         end}
      )

    assert {:error, _reason} = Store.observe_many([{identity("one"), :running}, {identity("two"), :invalid}], server: owner)
    assert Store.generation(owner) == 0
    refute_received :appended
  end

  test "capacity scan normalizes terminal states once for the whole issue list" do
    issues = for id <- 1..4, do: IssueSyncTestSupport.issue(to_string(id), "todo")

    {ready, calls} =
      run_traced([{DispatchPolicy, :terminal_state_set, 0}], fn ->
        CapacityConstraints.routable_todo_issues(issues)
      end)

    assert length(ready) == 4
    assert length(calls) == 1
  end

  test "active waiting facts avoid workspace retention lookups" do
    row = %{issue_id: "1", identifier: "1", waiting_reason: :active}

    {rendered, calls} =
      run_traced([{Retention, :for_ticket, 1}], fn ->
        WaitingReason.attach(row, %State{})
      end)

    assert rendered.waiting.reason == :active
    assert rendered.waiting.owner == "AgentRunner"
    assert calls == []
  end

  test "cgroup values stay fresh without file-server reads" do
    dir = TestSupport.tmp_root!("raw-cgroup")
    File.mkdir_p!(dir)
    previous = Application.get_env(:aiur, :cgroup_root_override)
    Application.put_env(:aiur, :cgroup_root_override, dir)

    on_exit(fn ->
      Application.put_env(:aiur, :cgroup_root_override, previous)
      TestCleanup.rm_rf!(dir)
    end)

    File.write!(Path.join(dir, "cpu.max"), "200000 100000")
    {quota, calls} = run_traced([{:file, :read_file, 1}], fn -> SystemCgroup.cpu_quota() end)
    assert quota == 2.0
    assert calls == []
    File.write!(Path.join(dir, "cpu.max"), "300000 100000")
    assert SystemCgroup.cpu_quota() == 3.0
  end

  defp run_traced(patterns, fun) do
    parent = self()

    owner =
      spawn_link(fn ->
        receive_barrier(:go)
        send(parent, {:result, self(), fun.()})
        receive_barrier(:stop)
      end)

    trace_calls(owner, patterns)
    send(owner, :go)
    {:result, ^owner, result} = receive_barrier({:result, ^owner, _})
    calls = calls(owner)
    send(owner, :stop)
    {result, calls}
  end

  defp identity(id), do: %TrackerIdentity{status: :joinable, kind: :github, owner: "Owner", repository: "Repo", provider_id: id, identifier: "42", reason: nil}

  defp trace_calls(owner, patterns) do
    for pattern <- patterns do
      :erlang.trace_pattern(pattern, true, [])
      on_exit(fn -> :erlang.trace_pattern(pattern, false, []) end)
    end

    :erlang.trace(owner, true, [:call])
  end

  defp calls(owner) do
    ref = :erlang.trace_delivered(owner)
    receive_barrier({:trace_delivered, ^owner, ^ref})
    drain_calls(owner, [])
  end

  defp drain_calls(owner, acc) do
    receive do
      {:trace, ^owner, :call, call} -> drain_calls(owner, [call | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
