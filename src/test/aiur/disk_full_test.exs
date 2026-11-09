defmodule Aiur.DiskFullTest do
  # Global latch and application env: never async.
  use ExUnit.Case, async: false

  alias Aiur.{DiskFull, ExecutorWakeInbox, Journal, JsonStore}

  @topic "system.disk.pressure"

  defmodule FullDisk do
    def write(_fd, _data), do: {:error, :enospc}
    def sync(fd), do: :file.sync(fd)
  end

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur-disk-full")
    parent = self()
    DiskFull.reset()
    Application.put_env(:aiur, :disk_full_alert_fun, fn topic, opts -> send(parent, {:alert, topic, opts}) end)

    on_exit(fn ->
      Application.delete_env(:aiur, :disk_full_alert_fun)
      Application.delete_env(:aiur, :atomic_write_fault_fun)
      DiskFull.reset()
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{root: root}
  end

  defp fill_disk(path), do: Application.put_env(:aiur, :atomic_write_fault_fun, fn target -> if target == path, do: {:error, :enospc}, else: :ok end)
  defp free_disk, do: Application.delete_env(:aiur, :atomic_write_fault_fun)

  test "state file: a full disk drops the write, alerts once naming the path, and leaves the old file whole", %{root: root} do
    path = Path.join(root, "state.json")
    :ok = JsonStore.write!(path, %{"v" => 1})

    fill_disk(path)
    assert :ok = JsonStore.write_or_drop(path, %{"v" => 2})
    assert :ok = JsonStore.write_or_drop(path, %{"v" => 3})
    assert {:error, :enospc} = JsonStore.write(path, %{"v" => 4})

    assert_receive {:alert, @topic, opts}, 1_000
    assert opts[:message] =~ path
    assert opts[:needs_attention] == true
    refute_receive {:alert, _, _}, 100

    assert JsonStore.read(path) == {:ok, %{"v" => 1}}
    assert File.ls!(root) == ["state.json"]

    free_disk()
    assert :ok = JsonStore.write_or_drop(path, %{"v" => 5})
    assert JsonStore.read(path) == {:ok, %{"v" => 5}}
  end

  test "run-log journal: a full disk fails the append, alerts once and keeps the earlier records", %{root: root} do
    path = Path.join(root, "event-publications.ndjson")
    :ok = Journal.prepare(root, path, fn -> :ok end)
    :ok = Journal.append(path, %{"n" => 1})

    assert {:failed, :enospc} = Journal.append(path, %{"n" => 2}, file_ops: FullDisk)
    assert {:failed, :enospc} = Journal.append(path, %{"n" => 3}, file_ops: FullDisk)

    assert_receive {:alert, @topic, opts}, 1_000
    assert opts[:message] =~ path
    refute_receive {:alert, _, _}, 100

    assert {:ok, [%{"n" => 1}], nil} = Journal.replay(path, &{:ok, &1})
    assert :ok = Journal.append(path, %{"n" => 4})
    assert {:ok, [%{"n" => 1}, %{"n" => 4}], nil} = Journal.replay(path, &{:ok, &1})
  end

  test "wake stream: the inbox server stays up when its pending and cursor writes hit a full disk", %{root: root} do
    pending_path = Path.join(root, "pending.json")
    cursor_path = Path.join(root, "cursor.json")
    name = Module.concat(__MODULE__, Inbox)

    pid =
      start_supervised!({ExecutorWakeInbox, name: name, debounce_ms: 60_000, path: Path.join(root, "wakes.ndjson"), cursor_path: cursor_path, pending_path: pending_path})

    Application.put_env(:aiur, :atomic_write_fault_fun, fn _target -> {:error, :enospc} end)
    assert :ok = ExecutorWakeInbox.enqueue(wake(1, "42"), name)
    assert :ok = ExecutorWakeInbox.enqueue(wake(2, "43"), name)

    assert_receive {:alert, @topic, opts}, 1_000
    assert opts[:message] =~ pending_path
    refute_receive {:alert, _, _}, 100
    assert Process.whereis(name) == pid
    assert map_size(:sys.get_state(name).pending) == 2
    refute File.exists?(pending_path)
  end

  test "a write that succeeds closes the episode; a new one alerts again after the quiet period", %{root: root} do
    path = Path.join(root, "state.json")
    fill_disk(path)
    :ok = JsonStore.write_or_drop(path, %{})
    assert_receive {:alert, @topic, _}, 1_000

    free_disk()
    :ok = JsonStore.write_or_drop(path, %{})
    fill_disk(path)
    :ok = JsonStore.write_or_drop(path, %{})
    refute_receive {:alert, _, _}, 100

    DiskFull.reset()
    :ok = JsonStore.write_or_drop(path, %{})
    assert_receive {:alert, @topic, _}, 1_000
  end

  defp wake(id, ticket) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      "wake_id" => id,
      "topic" => "ticket.#{ticket}.branch.push",
      "topic_class" => "ticket.branch.push",
      "event_id" => id,
      "ticket" => ticket,
      "count" => 1,
      "first_seen_at" => now,
      "last_seen_at" => now
    }
  end
end
