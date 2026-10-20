defmodule Aiur.Orchestrator.GlobalPauseGuardTest do
  use Aiur.TestSupport

  import Aiur.Orchestrator.GlobalPauseTestSupport

  alias Aiur.Orchestrator.{GlobalPause, PauseResume}

  describe "global-hold-wins guard" do
    test "an individual resume is blocked while globally paused" do
      id = unique_id("gp-guard")
      state = base_state(globally_paused: true, running: %{id => paused_entry(id, :global_pause)})

      assert {:reply, {:error, :globally_paused}, ^state} =
               PauseResume.tracker_control_call(state, :resume, id)

      assert {:reply, {:error, :globally_paused}, ^state} =
               PauseResume.request_control_call(state, id, :resume, 7)

      refute_receive {:resume_agent, _rid, _gen}, 50
    end

    test "does not acknowledge a pause when persistence fails" do
      previous = Application.get_env(:aiur, :global_pause_store_path)
      Application.put_env(:aiur, :global_pause_store_path, "/dev/null/global-pause.json")

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:aiur, :global_pause_store_path),
          else: Application.put_env(:aiur, :global_pause_store_path, previous)
      end)

      id = unique_id("gp-persistence")
      state = base_state(running: %{id => running_entry(id)})

      assert {:reply, {:error, {:global_pause_persistence_failed, {:write_failed, _, _}}}, ^state} =
               GlobalPause.set_global_pause_call(state, true, "dashboard")

      refute_receive {:pause_agent, _rid, _gen}, 50
    end
  end

  describe "idempotency and projection" do
    test "re-pausing or re-unpausing is a no-op" do
      already_paused = base_state(globally_paused: true, running: %{})

      assert {:reply, {:ok, %{globally_paused: true} = _projection}, ^already_paused} =
               GlobalPause.set_global_pause_call(already_paused, true)

      already_running = base_state(globally_paused: false, running: %{})

      assert {:reply, {:ok, %{globally_paused: false} = _projection}, ^already_running} =
               GlobalPause.set_global_pause_call(already_running, false)
    end

    test "globally_paused_call and global_pause_status mirror the flag" do
      state = base_state(globally_paused: true, running: %{})

      assert {:reply, true, ^state} = GlobalPause.globally_paused_call(state)
      assert GlobalPause.global_pause_status(state) == %{globally_paused: true, paused_at: nil, source: nil}

      assert GlobalPause.global_pause_status(%{state | globally_paused: false}) ==
               %{globally_paused: false, paused_at: nil, source: nil}
    end

    test "persists the global pause and provenance across orchestrator restart" do
      path = Aiur.TestSupport.tmp_root!("global-pause") <> ".json"
      previous = Application.get_env(:aiur, :global_pause_store_path)
      Application.put_env(:aiur, :global_pause_store_path, path)

      on_exit(fn ->
        File.rm(path)

        if is_nil(previous),
          do: Application.delete_env(:aiur, :global_pause_store_path),
          else: Application.put_env(:aiur, :global_pause_store_path, previous)
      end)

      name = Module.concat(__MODULE__, :RestoredOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: name, initial_poll?: false)
      assert {:ok, %{globally_paused: false}} = GlobalPause.global_pause_status(name)

      assert {:ok, %{globally_paused: true, paused_at: paused_at, source: "dashboard"}} =
               GlobalPause.set_global_pause(name, true, "dashboard")

      ref = Process.monitor(pid)
      Process.unlink(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1000

      {:ok, restarted_pid} = Orchestrator.start_link(name: name, initial_poll?: false)

      on_exit(fn ->
        if Process.alive?(restarted_pid) do
          Process.unlink(restarted_pid)
          Process.exit(restarted_pid, :kill)
        end
      end)

      assert {:ok, %{globally_paused: true, paused_at: ^paused_at, source: "dashboard"}} =
               GlobalPause.global_pause_status(name)
    end

    test "holds the fleet when persisted pause recovery is corrupt" do
      path = Aiur.TestSupport.tmp_root!("global-pause-corrupt") <> ".json"
      File.write!(path, "corrupt")
      previous = Application.get_env(:aiur, :global_pause_store_path)
      Application.put_env(:aiur, :global_pause_store_path, path)

      name = Module.concat(__MODULE__, :CorruptStoreOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: name, initial_poll?: false)
      Process.unlink(pid)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
        File.rm(path)

        if is_nil(previous),
          do: Application.delete_env(:aiur, :global_pause_store_path),
          else: Application.put_env(:aiur, :global_pause_store_path, previous)
      end)

      assert {:ok, %{globally_paused: true, source: "persistence recovery failed"}} =
               GlobalPause.global_pause_status(name)
    end

    test "does not report an unavailable orchestrator as unpaused" do
      name = Module.concat(__MODULE__, :MissingOrchestrator)

      assert {:error, :orchestrator_unavailable} = GlobalPause.globally_paused?(name)
      assert {:error, :orchestrator_unavailable} = GlobalPause.global_pause_status(name)
    end

    test "distinguishes a timed-out status query from an unavailable orchestrator" do
      name = Module.concat(__MODULE__, :SuspendedOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: name, initial_poll?: false)
      :sys.suspend(pid)

      try do
        assert {:error, :timeout} = GlobalPause.global_pause_status(name, 1)
      after
        :sys.resume(pid)
      end
    end
  end
end
