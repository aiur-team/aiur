defmodule AiurWeb.BuildOrder.PlanningSource.LivePackProgressTest do
  use AiurWeb.BuildOrder.PlanningSourceCase

  alias Aiur.Orchestrator.{SnapshotCache, SnapshotStore}
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.PlanningSource
  alias AiurWeb.BuildOrder.PlanningSource.LivePackProgress

  test "uses current poll labels without waiting on the mailbox and drops stale labels" do
    path = Application.fetch_env!(:aiur, :build_order_planning_pack)
    File.write!(path, @canonical_pack)
    Application.put_env(:aiur, :build_order_planning_pack, path)

    {:ok, identity} =
      TrackerIdentity.from_github(
        %{"number" => 4101, "node_id" => "I_live_4101"},
        {"acme", "widgets"},
        {"acme", "widgets"}
      )

    original = Process.whereis(Aiur.Orchestrator)
    if is_pid(original), do: Process.unregister(Aiur.Orchestrator)
    busy = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(busy, Aiur.Orchestrator)
    retained = SnapshotCache.get(Aiur.Orchestrator)

    :ok =
      SnapshotStore.publish(Aiur.Orchestrator, %{
        running: [%{tracker_identity: identity, labels: ["agent:rework"]}],
        retrying: [],
        idle: []
      })

    on_exit(fn ->
      stop_busy_process(busy)
      if retained, do: SnapshotCache.put(Aiur.Orchestrator, retained), else: SnapshotStore.forget(Aiur.Orchestrator)

      if is_pid(original) and Process.alive?(original) and is_nil(Process.whereis(Aiur.Orchestrator)),
        do: Process.register(original, Aiur.Orchestrator)
    end)

    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn ->
      %{
        generation: 9,
        health: :healthy,
        freshness: %{status: :fresh},
        members: [%{identity: identity, lifecycle: :queued}],
        labels_by_identity: %{TrackerIdentity.github_key(identity) => ["agent:rework"]}
      }
    end)

    key = TrackerIdentity.github_key(identity)

    task =
      Task.async(fn ->
        poll_labels = LivePackProgress.current_poll_labels()
        [root] = PlanningSource.catalog().data.entries
        {:ok, snapshot} = PlanningSource.demand(root.identity)
        {poll_labels, Enum.map(snapshot.data.members, & &1.labels)}
      end)

    assert {:ok, {%{^key => ["agent:rework"]}, [["agent:rework"], ["build-lane:dashboard-ui", "phase:3", "complexity:2"]]}} =
             Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill)

    previous_ceiling = Application.get_env(:aiur, :snapshot_stale_age_ceiling_ms)
    Application.put_env(:aiur, :snapshot_stale_age_ceiling_ms, 1)

    on_exit(fn ->
      if is_nil(previous_ceiling),
        do: Application.delete_env(:aiur, :snapshot_stale_age_ceiling_ms),
        else: Application.put_env(:aiur, :snapshot_stale_age_ceiling_ms, previous_ceiling)
    end)

    Process.sleep(2)

    assert {:stale, _, %{status: :stale}} = Aiur.Orchestrator.dashboard_snapshot()
    assert LivePackProgress.current_poll_labels() == %{}

    parent = self()

    cleanup =
      Task.async(fn ->
        stop_busy_process(busy, fn _busy ->
          send(parent, :stand_in_termination_requested)

          receive do
            :release_termination -> :ok
          after
            5_000 -> raise "test did not release the stand-in termination request"
          end
        end)
      end)

    assert_receive :stand_in_termination_requested, 1_000
    send(cleanup.pid, :release_termination)
    assert Task.yield(cleanup, 1_000) == nil

    Process.exit(busy, :kill)
    assert {:ok, :killed} = Task.yield(cleanup, 1_000)

    if is_pid(original) and Process.alive?(original) and is_nil(Process.whereis(Aiur.Orchestrator)),
      do: Process.register(original, Aiur.Orchestrator)

    assert Process.whereis(Aiur.Orchestrator) == original,
           "expected original Orchestrator #{inspect(original)} after stand-in #{inspect(busy)} exited :killed"
  end

  defp stop_busy_process(busy, request_exit \\ &Process.exit(&1, :kill)) do
    monitor = Process.monitor(busy)
    request_exit.(busy)

    receive do
      {:DOWN, ^monitor, :process, ^busy, reason} -> reason
    after
      5_000 -> raise "temporary orchestrator stand-in did not exit"
    end
  end
end
