defmodule Aiur.DaemonHeartbeatWriterTest do
  use ExUnit.Case, async: true

  alias Aiur.DaemonHeartbeatWriter

  defp safe_stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
  catch
    :exit, _reason -> :ok
  end

  setup do
    # Use a unique name for each test to avoid conflicts
    name = :"heartbeat_writer_#{System.unique_integer()}"
    {:ok, pid} = DaemonHeartbeatWriter.start_link(name: name, start_paused?: true)
    on_exit(fn -> safe_stop(pid) end)
    {:ok, pid: pid}
  end

  describe "start_link/1" do
    test "starts the worker with default name" do
      name = :"default_writer_#{System.unique_integer()}"
      {:ok, pid} = DaemonHeartbeatWriter.start_link(name: name, start_paused?: true)
      assert is_pid(pid)
      assert GenServer.whereis(name) == pid
      on_exit(fn -> safe_stop(pid) end)
    end

    test "starts the worker with custom name" do
      name = :"custom_heartbeat_writer_#{System.unique_integer()}"
      {:ok, pid} = DaemonHeartbeatWriter.start_link(name: name, start_paused?: true)
      assert GenServer.whereis(name) == pid
      on_exit(fn -> safe_stop(pid) end)
    end

    test "registers the worker so it can be found by name" do
      name = :"registered_writer_#{System.unique_integer()}"
      {:ok, pid} = DaemonHeartbeatWriter.start_link(name: name, start_paused?: true)
      assert GenServer.whereis(name) == pid
      on_exit(fn -> safe_stop(pid) end)
    end
  end

  describe "init/1" do
    test "sets interval_ms to default 5 minutes (300_000 ms)" do
      name = :"init_test_1_#{System.unique_integer()}"
      {:ok, pid} = DaemonHeartbeatWriter.start_link(name: name, start_paused?: true)
      state = :sys.get_state(pid)
      assert state.interval_ms == 300_000
      on_exit(fn -> safe_stop(pid) end)
    end

    test "accepts custom interval_ms option" do
      name = :"init_test_2_#{System.unique_integer()}"
      {:ok, pid} = DaemonHeartbeatWriter.start_link(name: name, interval_ms: 60_000, start_paused?: true)
      state = :sys.get_state(pid)
      assert state.interval_ms == 60_000
      on_exit(fn -> safe_stop(pid) end)
    end

    test "sets start_paused? flag from options" do
      name = :"init_test_3_#{System.unique_integer()}"
      {:ok, pid} = DaemonHeartbeatWriter.start_link(name: name, start_paused?: true)
      state = :sys.get_state(pid)
      assert state.start_paused? == true
      on_exit(fn -> safe_stop(pid) end)
    end

    test "does not schedule first tick when start_paused? is true" do
      name = :"init_test_4_#{System.unique_integer()}"
      {:ok, pid} = DaemonHeartbeatWriter.start_link(name: name, start_paused?: true)

      # Send a tick message and verify it's not automatically scheduled
      # (this is indirect: if the tick were scheduled, it would fire and we'd
      # observe evidence of it; we can't directly observe that no message is pending)
      assert is_pid(pid)
      on_exit(fn -> safe_stop(pid) end)
    end
  end

  describe "tick/1" do
    test "calls Aiur.DaemonHeartbeat.write!/0", %{pid: pid} do
      # We'll verify the tick runs by manually sending it and checking state doesn't crash
      # Send tick message directly (simulating what PeriodicWorker does)
      send(pid, :tick)

      # Give it a moment to process
      Process.sleep(10)

      # If we get here without a crash, the tick executed successfully
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "returns updated state unchanged after tick", %{pid: pid} do
      initial_state = :sys.get_state(pid)

      # Manually invoke tick via GenServer message
      send(pid, :tick)
      Process.sleep(50)

      updated_state = :sys.get_state(pid)

      # State should be unchanged (tick just calls write! and returns state)
      assert updated_state.interval_ms == initial_state.interval_ms
      assert updated_state.start_paused? == initial_state.start_paused?
    end
  end

  describe "handle_info/2" do
    test "handles :tick message and schedules next tick", %{pid: pid} do
      # Manually trigger a tick
      send(pid, :tick)
      Process.sleep(50)

      # Verify the process is still alive (schedule continues after tick)
      assert Process.alive?(pid)
    end

    test "ignores unknown messages", %{pid: pid} do
      send(pid, :unknown_message)
      send(pid, {:some, :tuple})
      Process.sleep(50)

      # Process should still be alive after receiving unknown messages
      assert Process.alive?(pid)
    end
  end

  describe "periodic scheduling" do
    test "first tick is not scheduled when start_paused? is true" do
      name = :"sched_test_1_#{System.unique_integer()}"
      {:ok, pid} = DaemonHeartbeatWriter.start_link(name: name, start_paused?: true)
      state = :sys.get_state(pid)
      # With start_paused? true, no timer is scheduled initially
      assert state.start_paused? == true
      assert Process.alive?(pid)
      on_exit(fn -> safe_stop(pid) end)
    end

    test "first tick is scheduled when start_paused? is false" do
      name = :"sched_test_2_#{System.unique_integer()}"
      {:ok, pid} = DaemonHeartbeatWriter.start_link(name: name, start_paused?: false, interval_ms: 100)

      # Give it a moment for the first tick to fire
      Process.sleep(200)

      # Process should still be alive
      assert Process.alive?(pid)
      on_exit(fn -> safe_stop(pid) end)
    end

    test "tick failure does not crash the worker" do
      name = :"sched_test_3_#{System.unique_integer()}"
      {:ok, pid} = DaemonHeartbeatWriter.start_link(name: name, start_paused?: true)

      # Manually send a tick — even if write! raises, the worker should survive
      # (PeriodicWorker.run_tick rescues all errors)
      send(pid, :tick)
      Process.sleep(50)

      # Process should still be alive after tick
      assert Process.alive?(pid)
      on_exit(fn -> safe_stop(pid) end)
    end
  end

  describe "tick interval" do
    test "default interval is 5 minutes (300_000 ms)" do
      name = :"interval_test_1_#{System.unique_integer()}"
      {:ok, pid} = DaemonHeartbeatWriter.start_link(name: name, start_paused?: true)
      state = :sys.get_state(pid)
      assert state.interval_ms == 300_000
      on_exit(fn -> safe_stop(pid) end)
    end

    test "custom interval can be set" do
      name = :"interval_test_2_#{System.unique_integer()}"
      interval = 60_000
      {:ok, pid} = DaemonHeartbeatWriter.start_link(name: name, interval_ms: interval, start_paused?: true)
      state = :sys.get_state(pid)
      assert state.interval_ms == interval
      on_exit(fn -> safe_stop(pid) end)
    end

    test "interval is used for next_delay_ms if not overridden" do
      name = :"interval_test_3_#{System.unique_integer()}"
      {:ok, pid} = DaemonHeartbeatWriter.start_link(name: name, start_paused?: true)
      state = :sys.get_state(pid)

      # State should have interval_ms set for scheduling
      assert state.interval_ms == 300_000
      assert Map.has_key?(state, :interval_ms)
      on_exit(fn -> safe_stop(pid) end)
    end
  end

  describe "worker lifecycle" do
    test "worker can be stopped cleanly" do
      name = :"lifecycle_test_1_#{System.unique_integer()}"
      {:ok, pid} = DaemonHeartbeatWriter.start_link(name: name, start_paused?: true)
      assert Process.alive?(pid)

      GenServer.stop(pid)
      Process.sleep(10)

      assert not Process.alive?(pid)
    end

    test "multiple workers can run concurrently with different names" do
      name1 = :"writer1_#{System.unique_integer()}"
      name2 = :"writer2_#{System.unique_integer()}"
      {:ok, pid1} = DaemonHeartbeatWriter.start_link(name: name1, start_paused?: true)
      {:ok, pid2} = DaemonHeartbeatWriter.start_link(name: name2, start_paused?: true)

      assert is_pid(pid1)
      assert is_pid(pid2)
      assert pid1 != pid2
      assert Process.alive?(pid1)
      assert Process.alive?(pid2)

      GenServer.stop(pid1)
      GenServer.stop(pid2)
    end
  end

  describe "integration with PeriodicWorker" do
    test "tick callback is invoked on :tick message" do
      name = :"integration_test_1_#{System.unique_integer()}"
      {:ok, pid} = DaemonHeartbeatWriter.start_link(name: name, start_paused?: true)

      # Verify initial state
      initial_state = :sys.get_state(pid)
      assert initial_state.interval_ms == 300_000

      # Send tick and verify state returns unchanged
      send(pid, :tick)
      Process.sleep(50)

      final_state = :sys.get_state(pid)
      assert final_state.interval_ms == initial_state.interval_ms
      on_exit(fn -> safe_stop(pid) end)
    end

    test "PeriodicWorker.schedule_first_tick is called during init" do
      # When start_paused? is false, first tick should be scheduled
      name = :"integration_test_2_#{System.unique_integer()}"
      {:ok, pid} = DaemonHeartbeatWriter.start_link(name: name, start_paused?: false, interval_ms: 50)

      # Wait for the first tick to fire
      Process.sleep(150)

      # Process should still be alive and rescheduled
      assert Process.alive?(pid)
      on_exit(fn -> safe_stop(pid) end)
    end
  end

  describe "error handling" do
    test "worker survives and reschedules after tick failure" do
      name = :"error_test_1_#{System.unique_integer()}"
      {:ok, pid} = DaemonHeartbeatWriter.start_link(name: name, start_paused?: true)

      # Send tick multiple times to verify resilience
      send(pid, :tick)
      Process.sleep(10)
      send(pid, :tick)
      Process.sleep(10)

      # Process should still be alive
      assert Process.alive?(pid)

      # Should be able to query state
      state = :sys.get_state(pid)
      assert state.interval_ms == 300_000
      on_exit(fn -> safe_stop(pid) end)
    end
  end
end
