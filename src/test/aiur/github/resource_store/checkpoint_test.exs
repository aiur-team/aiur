defmodule Aiur.GitHub.ResourceStore.CheckpointTest do
  # These tests share the real store lifecycle because each guards the relation
  # between ETS mutations, cached checkpoint rows, periodic writes, and restart.
  use Aiur.TestSupport

  alias Aiur.GitHub.ResourceStore
  alias Aiur.GitHub.ResourceStore.Checkpoint
  alias Aiur.GitHub.ResourceStore.Memory

  test "an unchanged periodic checkpoint skips rendering", %{path: path} do
    restart_store!(path)
    key = ResourceStore.key(:issue, "owner", "repo", 9901)
    ResourceStore.put_resource(key, %{"number" => 9901})
    assert :ok = ResourceStore.flush()

    test_pid = self()
    handler_id = "resource-store-checkpoint-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:aiur, :github, :resource_store, :checkpoint],
        fn _event, measurements, metadata, pid ->
          send(pid, {:checkpoint, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    send(Process.whereis(ResourceStore), :checkpoint)

    assert_receive {:checkpoint, %{entries: 1}, %{result: :unchanged}}, 1_000
    assert ResourceStore.data(key) == %{"number" => 9901}
  end

  test "a mutation after flush makes the next periodic checkpoint write", %{path: path} do
    restart_store!(path)
    first_key = ResourceStore.key(:issue, "owner", "repo", 9901)
    second_key = ResourceStore.key(:issue, "owner", "repo", 9902)
    ResourceStore.put_resource(first_key, %{"number" => 9901})
    assert :ok = ResourceStore.flush()

    test_pid = self()
    handler_id = "resource-store-checkpoint-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:aiur, :github, :resource_store, :checkpoint],
        fn _event, measurements, metadata, pid ->
          send(pid, {:checkpoint, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ResourceStore.put_resource(second_key, %{"number" => 9902})
    send(Process.whereis(ResourceStore), :checkpoint)

    assert_receive {:checkpoint, %{entries: 2}, %{result: :written}}, 1_000
    assert {:ok, contents} = File.read(path)
    assert %{"entries" => entries} = Jason.decode!(contents)
    assert Map.has_key?(entries, "issue|owner|repo|9902")
  end

  test "forgetting an entry removes it from the next periodic checkpoint", %{path: path} do
    restart_store!(path)
    key = ResourceStore.key(:issue, "owner", "repo", 9903)
    ResourceStore.put_resource(key, %{"number" => 9903})
    assert :ok = ResourceStore.flush()
    ResourceStore.forget(key)

    test_pid = self()
    handler_id = "resource-store-checkpoint-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:aiur, :github, :resource_store, :checkpoint],
        fn _event, measurements, metadata, pid -> send(pid, {:checkpoint, measurements, metadata}) end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    send(Process.whereis(ResourceStore), :checkpoint)

    assert_receive {:checkpoint, %{entries: 0}, %{result: :written}}, 1_000
    assert {:ok, contents} = File.read(path)
    assert %{"entries" => %{}} = Jason.decode!(contents)
  end

  test "checkpoint encoding reuses unchanged entries and refreshes only a dirty key", %{path: path} do
    restart_store!(path)
    first_key = ResourceStore.key(:issue, "owner", "repo", 9904)
    second_key = ResourceStore.key(:issue, "owner", "repo", 9905)
    first_entry = %{recorded_at_ms: 1}
    second_entry = %{recorded_at_ms: 1}
    table = :ets.new(:checkpoint_cache_test, [:set])
    true = :ets.insert(table, [{first_key, first_entry}, {second_key, second_entry}])
    parent = self()

    encode = fn entry ->
      send(parent, {:encoded, entry})
      Jason.encode!(entry)
    end

    Checkpoint.cached_entry(table, first_key, first_entry, encode)
    Checkpoint.cached_entry(table, second_key, second_entry, encode)
    Checkpoint.cached_entry(table, first_key, first_entry, encode)
    assert_received {:encoded, ^first_entry}
    assert_received {:encoded, ^second_entry}
    refute_received {:encoded, _entry}

    Checkpoint.mark_entry_dirty(first_key)
    Checkpoint.cached_entry(table, first_key, first_entry, encode)
    assert_received {:encoded, ^first_entry}
    Checkpoint.cached_entry(table, second_key, second_entry, encode)
    refute_received {:encoded, _entry}
  end

  test "a stale fold row cannot be cached under a newer key revision", %{path: path} do
    restart_store!(path)
    key = ResourceStore.key(:issue, "owner", "repo", 9906)
    ResourceStore.put_resource(key, %{"generation" => 1})
    assert :ok = ResourceStore.flush()
    table = Aiur.GitHub.ResourceStore.Table
    [{^key, stale_entry}] = :ets.lookup(table, key)

    ResourceStore.put_resource(key, %{"generation" => 2})

    encoded =
      Checkpoint.cached_entry(table, key, stale_entry, fn current ->
        [Jason.encode!("issue|owner|repo|9906"), ?:, Jason.encode!(%{"data" => current.data})]
      end)

    assert %{"issue|owner|repo|9906" => %{"data" => %{"generation" => 2}}} =
             Jason.decode!("{#{IO.iodata_to_binary(encoded)}}")

    assert :ok = ResourceStore.flush()
    assert {:ok, contents} = File.read(path)
    assert %{"entries" => entries} = Jason.decode!(contents)
    assert %{"data" => %{"generation" => 2}} = entries["issue|owner|repo|9906"]
  end

  test "delete and recreate cannot reuse a cached key revision", %{path: path} do
    restart_store!(path)
    key = ResourceStore.key(:issue, "owner", "repo", 9913)
    ResourceStore.put_resource(key, %{"generation" => 1})
    [{^key, stale_entry}] = :ets.lookup(Aiur.GitHub.ResourceStore.Table, key)

    encoded =
      Checkpoint.cached_entry(Aiur.GitHub.ResourceStore.Table, key, stale_entry, fn current ->
        assert :ok = ResourceStore.forget(key)
        assert :ok = ResourceStore.put_resource(key, %{"generation" => 2})

        [Jason.encode!("issue|owner|repo|9913"), ?:, Jason.encode!(%{"data" => current.data})]
      end)

    assert %{"issue|owner|repo|9913" => %{"data" => %{"generation" => 1}}} =
             Jason.decode!("{#{IO.iodata_to_binary(encoded)}}")

    assert :ok = ResourceStore.flush()
    assert %{"entries" => entries} = read_checkpoint(path)
    assert %{"data" => %{"generation" => 2}} = entries["issue|owner|repo|9913"]
  end

  test "clear persists removed entries on a periodic checkpoint", %{path: path} do
    restart_store!(path)
    key = ResourceStore.key(:issue, "owner", "repo", 9907)
    ResourceStore.put_resource(key, %{"number" => 9907})
    assert :ok = ResourceStore.flush()

    assert :ok = ResourceStore.clear(:issue, "owner", "repo")
    checkpoint_result!(:written)
    assert %{"entries" => %{}} = read_checkpoint(path)
    restart_store!(path)
    assert ResourceStore.data(key) == nil
  end

  test "reset persists all removed entries on a periodic checkpoint", %{path: path} do
    restart_store!(path)
    key = ResourceStore.key(:issue, "owner", "repo", 9908)
    ResourceStore.put_resource(key, %{"number" => 9908})
    assert :ok = ResourceStore.flush()

    assert :ok = ResourceStore.reset()
    checkpoint_result!(:written)
    assert %{"entries" => %{}} = read_checkpoint(path)
    restart_store!(path)
    assert ResourceStore.data(key) == nil
  end

  test "membership replacement persists removed keys on a periodic checkpoint", %{path: path} do
    restart_store!(path)
    assert :ok = ResourceStore.replace_membership("owner", "repo", [], [{"old", %{"id" => "old"}}])
    assert :ok = ResourceStore.flush()
    old_key = ResourceStore.key(:sub_issue, "owner", "repo", "old")
    expected = ResourceStore.list(:sub_issue, "owner", "repo") |> Enum.sort()

    assert :ok = ResourceStore.replace_membership("owner", "repo", expected, [{"new", %{"id" => "new"}}])
    checkpoint_result!(:written)
    entries = read_checkpoint(path)["entries"]
    refute Map.has_key?(entries, "sub_issue|owner|repo|old")
    assert Map.has_key?(entries, "sub_issue|owner|repo|new")
    restart_store!(path)
    assert ResourceStore.data(old_key) == nil
    assert [{{:sub_issue, "owner", "repo", "new"}, _entry}] = ResourceStore.list(:sub_issue, "owner", "repo")
  end

  test "membership replacement refreshes retained keys and evicts removed cache rows", %{path: path} do
    restart_store!(path)

    assert :ok =
             ResourceStore.replace_membership("owner", "repo", [], [
               {"retained", %{"generation" => 1}},
               {"removed", %{"generation" => 1}}
             ])

    assert :ok = ResourceStore.flush()
    retained_key = ResourceStore.key(:sub_issue, "owner", "repo", "retained")
    removed_key = ResourceStore.key(:sub_issue, "owner", "repo", "removed")
    expected = ResourceStore.list(:sub_issue, "owner", "repo") |> Enum.sort()

    assert :ok =
             ResourceStore.replace_membership("owner", "repo", expected, [
               {"retained", %{"generation" => 2}}
             ])

    checkpoint_result!(:written)
    entries = read_checkpoint(path)["entries"]
    assert %{"data" => %{"generation" => 2}} = entries["sub_issue|owner|repo|retained"]
    refute Map.has_key?(entries, "sub_issue|owner|repo|removed")
    assert :ets.lookup(Checkpoint.EncodedEntries, removed_key) == []
    restart_store!(path)
    assert ResourceStore.data(retained_key) == %{"generation" => 2}
    assert ResourceStore.data(removed_key) == nil
  end

  test "sweep deletions persist on a periodic checkpoint", %{path: path} do
    restart_store!(path)
    key = ResourceStore.key(:issue, "owner", "repo", 9909)
    ResourceStore.put_resource(key, %{"number" => 9909})
    assert :ok = ResourceStore.flush()
    [{^key, entry}] = :ets.lookup(Aiur.GitHub.ResourceStore.Table, key)
    expired_at = System.system_time(:millisecond) - ResourceStore.retention_ms() - 1
    true = :ets.insert(Aiur.GitHub.ResourceStore.Table, {key, %{entry | recorded_at_ms: expired_at}})

    send(Process.whereis(ResourceStore), :sweep)
    :sys.get_state(ResourceStore)
    checkpoint_result!(:written)
    assert %{"entries" => %{}} = read_checkpoint(path)
    restart_store!(path)
    assert ResourceStore.data(key) == nil
  end

  test "sweep body drops persist on a periodic checkpoint", %{path: path} do
    restart_store!(path)
    key = ResourceStore.key(:issue, "owner", "repo", 9912)
    ResourceStore.put_resource(key, %{"number" => 9912})
    assert :ok = ResourceStore.flush()
    [{^key, entry}] = :ets.lookup(Aiur.GitHub.ResourceStore.Table, key)
    expired_at = System.system_time(:millisecond) - ResourceStore.retention_ms() - 1

    true =
      :ets.insert(Aiur.GitHub.ResourceStore.Table, {key, %{entry | fetched_at_ms: expired_at, recorded_at_ms: System.system_time(:millisecond)}})

    send(Process.whereis(ResourceStore), :sweep)
    :sys.get_state(ResourceStore)
    checkpoint_result!(:written)
    assert %{"issue|owner|repo|9912" => %{"data" => nil}} = read_checkpoint(path)["entries"]
    restart_store!(path)
    assert ResourceStore.data(key) == nil
    assert [{{:issue, "owner", "repo", "9912"}, entry}] = ResourceStore.list(:issue, "owner", "repo")
    assert is_nil(entry.data)
  end

  test "memory shedding persists dropped bodies on a periodic checkpoint", %{path: path} do
    restart_store!(path)
    first_key = ResourceStore.key(:issue, "owner", "repo", 9910)
    second_key = ResourceStore.key(:issue, "owner", "repo", 9911)
    body = %{"body" => String.duplicate("x", 100)}
    ResourceStore.put_resource(first_key, body)
    ResourceStore.put_resource(second_key, body)
    assert :ok = ResourceStore.flush()
    body_size = :erlang.external_size(body)
    Application.put_env(:aiur, :github_resource_store_max_body_bytes, body_size)

    try do
      stats = Memory.enforce(Aiur.GitHub.ResourceStore.Table)
      assert stats.shed == 1
      checkpoint_result!(:written)
      entries = read_checkpoint(path)["entries"]
      assert Enum.count(entries, fn {_key, value} -> is_nil(value["data"]) end) == 1
      restart_store!(path)
      assert Enum.count([ResourceStore.data(first_key), ResourceStore.data(second_key)], &is_nil/1) == 1
    after
      Application.delete_env(:aiur, :github_resource_store_max_body_bytes)
    end
  end

  setup do
    dir = Aiur.TestSupport.tmp_root!("aiur-resource-store-checkpoint")
    File.mkdir_p!(dir)
    path = Path.join(dir, "github_resources.json")

    on_exit(fn ->
      Application.delete_env(:aiur, :github_resource_store_path)
      ResourceStore.reset()
      Aiur.TestCleanup.rm_rf!(dir)
    end)

    {:ok, path: path}
  end

  defp stop_store! do
    case Process.whereis(ResourceStore) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Supervisor.terminate_child(Aiur.Supervisor, ResourceStore)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          5_000 -> flunk("ResourceStore did not stop")
        end
    end
  end

  defp restart_store!(path) do
    stop_store!()
    Application.put_env(:aiur, :github_resource_store_path, path)
    {:ok, _pid} = Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
    :ok
  end

  defp checkpoint_result!(expected) do
    handler_id = "resource-store-checkpoint-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:aiur, :github, :resource_store, :checkpoint],
        fn _event, _measurements, metadata, pid -> send(pid, {:checkpoint_result, metadata.result}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    send(Process.whereis(ResourceStore), :checkpoint)
    assert_receive {:checkpoint_result, ^expected}, 1_000
  end

  defp read_checkpoint(path) do
    assert {:ok, contents} = File.read(path)
    Jason.decode!(contents)
  end
end
