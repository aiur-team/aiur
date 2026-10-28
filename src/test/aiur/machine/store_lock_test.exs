defmodule Aiur.Machine.StoreLockTest do
  use ExUnit.Case, async: false
  alias Aiur.Machine.Store
  import Aiur.TestSupport, only: [receive_barrier: 1]

  setup do
    dir = Path.join(System.tmp_dir!(), "lock-#{System.unique_integer([:positive])}")
    old = Application.get_env(:aiur, :machine_state_dir)
    Application.put_env(:aiur, :machine_state_dir, dir)
    assert :ok = Store.check_dir(dir)

    on_exit(fn ->
      if old, do: Application.put_env(:aiur, :machine_state_dir, old), else: Application.delete_env(:aiur, :machine_state_dir)
      Aiur.TestCleanup.rm_rf!(dir)
    end)

    %{lock: Path.join(dir, "store.lock")}
  end

  test "second contender waits then succeeds after release" do
    parent = self()

    first =
      Task.async(fn ->
        Store.with_lock(fn ->
          send(parent, :holding)

          receive do
            :release -> :first
          after
            2_000 -> flunk("release was not sent")
          end
        end)
      end)

    receive_barrier(:holding)

    second =
      Task.async(fn ->
        Store.with_lock(
          fn ->
            send(parent, {:contender_state, :entered})
            :second
          end,
          on_wait: fn -> send(parent, {:contender_state, :waiting}) end
        )
      end)

    try do
      receive_barrier({:contender_state, state})
      assert state == :waiting
    after
      send(first.pid, :release)
      assert Task.await(first) == :first
      assert Task.await(second) == :second
    end
  end

  test "a separate OS holder excludes writers and is reclaimed after exiting", %{lock: lock} do
    script = ~s(mkdir "$1" && printf '%s gateway' "$$" > "$1/owner" && printf ready && read reply)
    port = Port.open({:spawn_executable, System.find_executable("sh")}, [:binary, :exit_status, args: ["-c", script, "holder", lock]])
    receive_barrier({^port, {:data, "ready"}})
    assert Store.with_lock(fn -> flunk("entered external holder") end, timeout: 0) == {:error, :store_locked, "gateway"}
    Port.command(port, "done\n")
    receive_barrier({^port, {:exit_status, 0}})
    assert Store.with_lock(fn -> :reclaimed end) == :reclaimed
  end

  test "dead holder is reclaimed", %{lock: lock} do
    File.mkdir!(lock)
    File.write!(Path.join(lock, "owner"), "999999 cli")
    assert Store.with_lock(fn -> :reclaimed end, alive?: fn "999999" -> false end) == :reclaimed
    refute File.exists?(lock)
  end

  test "live holder times out with its role", %{lock: lock} do
    File.mkdir!(lock)
    File.write!(Path.join(lock, "owner"), "123 gateway")
    assert Store.with_lock(fn -> flunk("entered live lock") end, timeout: 20, alive?: fn "123" -> true end) == {:error, :store_locked, "gateway"}
    assert File.read!(Path.join(lock, "owner")) == "123 gateway"
  end

  test "fresh ownerless lock is retained and old ownerless lock is reclaimed", %{lock: lock} do
    File.mkdir!(lock)
    now = File.stat!(lock, time: :posix).mtime
    assert Store.with_lock(fn -> flunk("entered fresh lock") end, timeout: 0, now: now) == {:error, :store_locked, "unknown"}
    assert Store.with_lock(fn -> :reclaimed end, now: now + 120) == :reclaimed
  end

  test "gateway lifetime handle permits writes until released", %{lock: lock} do
    assert {:ok, handle} = Store.hold_lock(timeout: 50)
    assert File.read!(Path.join(lock, "owner")) == System.pid() <> " gateway"
    assert Store.with_lock(fn -> :gateway_write end, lock: handle) == :gateway_write
    assert Store.with_lock(fn -> :cli_write end, timeout: 0) == {:error, :store_locked, "gateway"}
    assert Store.hold_lock(timeout: 0) == {:error, :store_locked, "gateway"}
    assert :ok = Store.release_lock(handle)
    assert Store.with_lock(fn -> :after_shutdown end) == :after_shutdown
    assert Store.with_lock(fn -> :invalid end, lock: handle) == {:error, :lock_lost}
  end

  test "release never removes a replaced owner", %{lock: lock} do
    assert {:ok, handle} = Store.hold_lock()
    File.write!(Path.join(lock, "owner"), "123 cli")
    assert Store.release_lock(handle) == {:error, :lock_lost}
    assert File.read!(Path.join(lock, "owner")) == "123 cli"
  end

  test "a killed local writer is reclaimed even while its OS process lives" do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Store.with_lock(fn ->
          send(parent, :holding)
          receive_barrier(:never)
        end)
      end)

    receive_barrier(:holding)
    Process.exit(pid, :kill)
    receive_barrier({:DOWN, ^ref, :process, ^pid, :killed})
    assert Store.with_lock(fn -> :reclaimed end) == :reclaimed
  end

  test "exceptions release the lock", %{lock: lock} do
    assert_raise RuntimeError, "failed", fn -> Store.with_lock(fn -> raise "failed" end) end
    refute File.exists?(lock)
    assert Store.with_lock(fn -> :released end) == :released
  end
end
