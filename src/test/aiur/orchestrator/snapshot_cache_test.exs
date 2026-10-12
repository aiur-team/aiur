defmodule Aiur.Orchestrator.SnapshotCacheTest do
  use ExUnit.Case, async: false
  alias Aiur.Orchestrator.{SnapshotCache, SnapshotStore}

  test "replaced snapshots use ETS and retain generation, age and last good data across projection worker restarts" do
    key = self()
    on_exit(fn -> SnapshotStore.discard(key) end)
    generation = SnapshotStore.begin_generation(key)
    old = %{running: [], retrying: [], idle: [], padding: List.duplicate(1, 150_000)}
    current = %{old | padding: List.duplicate(2, 150_000)}
    SnapshotStore.publish(key, old)
    SnapshotStore.publish(key, current)
    assert {:current, ^current, metadata} = SnapshotStore.read(key, 50)
    assert metadata.age_ms >= 0
    assert :persistent_term.get({SnapshotStore, key}, :absent) == :absent
    cached = SnapshotCache.get(key)
    assert cached.snapshot == current
    assert cached.generation == generation

    owner = :ets.info(SnapshotCache, :owner)
    assert owner == Process.whereis(SnapshotCache)
    assert owner != Process.whereis(SnapshotStore)
    :ok = Supervisor.terminate_child(Aiur.Supervisor, SnapshotStore)

    try do
      assert {:current, ^current, _} = SnapshotStore.read(key, 50)
      assert SnapshotCache.get(key) == cached
    after
      assert {:ok, _pid} = Supervisor.restart_child(Aiur.Supervisor, SnapshotStore)
    end

    SnapshotStore.forget(key)
    assert SnapshotCache.get(key) == nil
    assert :snapshot_unpublished = SnapshotStore.read(key, 50)
  end
end
