defmodule Aiur.RepoBase.ServerTest do
  use Aiur.RepoBaseCase

  alias Aiur.Orchestrator.DispatchPolicy

  describe "server state machine" do
    setup do
      # Pin a prewarm-disabled config and force the shared WorkflowStore cache to
      # reload it, so `resolve/0` is deterministically `:disabled` and the instance
      # never schedules a poll. Otherwise a sibling test that left a prewarm-enabled
      # config cached makes the auto-poll start a real build mid-test (flaky).
      tmp = Aiur.TestSupport.tmp_root!("rb_cfg")
      File.mkdir_p!(tmp)
      cfg = Path.join(tmp, "config")
      File.write!(cfg, "tracker:\n  kind: memory\n")
      prev_path = Application.get_env(:aiur, :workflow_file_path)
      Aiur.Workflow.set_workflow_file_path(cfg)

      # An unnamed instance so we can drive its handlers without colliding with
      # the supervised singleton (which always registers __MODULE__).
      {:ok, pid} = GenServer.start_link(RepoBase, [])

      on_exit(fn ->
        Aiur.TestSupport.safe_stop(pid)

        case prev_path do
          nil -> Aiur.Workflow.clear_workflow_file_path()
          p -> Aiur.Workflow.set_workflow_file_path(p)
        end

        Aiur.TestCleanup.rm_rf!(tmp)
      end)

      {:ok, server: pid, cfg: cfg}
    end

    test "starts idle", %{server: pid} do
      assert %{phase: :idle, build: nil, probe: nil} = :sys.get_state(pid)
    end

    test "refresh_async is a no-op when pre-warm is disabled", %{server: pid} do
      GenServer.cast(pid, :refresh_async)
      assert %{phase: :idle} = :sys.get_state(pid)
    end

    test "build_done success marks ready and records the head", %{server: pid} do
      :sys.replace_state(pid, fn s ->
        %{s | build: %{pid: pid, ref: make_ref(), head: "abc"}, phase: :building}
      end)

      send(pid, {:build_done, pid, "abc", {:ok, "/base"}})

      assert %{phase: :ready, base_path: "/base", ready_head: "abc", freshness: :unknown, build: nil} =
               :sys.get_state(pid)
    end

    test "build_done error sets the error phase", %{server: pid} do
      :sys.replace_state(pid, fn s ->
        %{s | build: %{pid: pid, ref: make_ref(), head: nil}, phase: :building}
      end)

      send(pid, {:build_done, pid, nil, {:error, :boom}})

      assert %{phase: {:error, :boom}, build: nil} = :sys.get_state(pid)
    end

    test "build_head records the locked head on the in-flight build", %{server: pid} do
      :sys.replace_state(pid, fn s -> %{s | build: %{pid: pid, ref: make_ref(), head: nil}} end)

      send(pid, {:build_head, pid, "deadbeef"})

      assert %{build: %{head: "deadbeef"}} = :sys.get_state(pid)
    end

    test "a crashed build process surfaces an error phase", %{server: pid} do
      ref = make_ref()
      :sys.replace_state(pid, fn s -> %{s | build: %{pid: self(), ref: ref, head: nil}, phase: :building} end)

      send(pid, {:DOWN, ref, :process, self(), :killed})

      assert %{phase: {:error, {:build_crashed, :killed}}, build: nil} = :sys.get_state(pid)
    end

    test "a remote-head advance past a ready base triggers a rebuild", %{server: pid} do
      :sys.replace_state(pid, fn s ->
        %{s | build: nil, phase: :ready, ready_head: "old", probe: probe(pid)}
      end)

      send(pid, {:remote_head, pid, {:ok, "new"}})

      # resolve is disabled in test, so the triggered rebuild resolves to idle.
      assert %{phase: :idle, probe: nil} = :sys.get_state(pid)
    end

    test "a remote-head with no advance leaves a ready base untouched", %{server: pid} do
      :sys.replace_state(pid, fn s ->
        %{s | build: nil, phase: :ready, ready_head: "same", probe: probe(pid)}
      end)

      send(pid, {:remote_head, pid, {:ok, "same"}})

      assert %{phase: :ready} = :sys.get_state(pid)
    end

    test "a matching dispatch freshness check marks the ready base fresh", %{server: pid} do
      :sys.replace_state(pid, fn s ->
        %{s | build: nil, phase: :checking, ready_head: "same", freshness: :unknown, probe: probe(pid)}
      end)

      send(pid, {:remote_head, pid, {:ok, "same"}})

      assert %{phase: :ready, freshness: :fresh} = :sys.get_state(pid)
    end

    test "a failed freshness check never certifies the warm base", %{server: pid} do
      :sys.replace_state(pid, fn s ->
        %{s | build: nil, phase: :checking, ready_head: "same", freshness: :unknown, probe: probe(pid)}
      end)

      send(pid, {:remote_head, pid, {:error, :timeout}})

      assert %{phase: {:error, {:repo_base_remote_probe_failed, :timeout}}, freshness: :unknown} =
               :sys.get_state(pid)
    end

    test "a lost checking probe is released by the dispatch watchdog", %{server: pid, cfg: cfg} do
      pid = restart_enabled_server(pid, cfg, dispatch_hold_timeout_ms: 50)
      Phoenix.PubSub.subscribe(Aiur.PubSub, "prewarm:phase")

      # Enter :checking with a live probe so the dispatch watchdog arms.
      :sys.replace_state(pid, fn state -> %{state | phase: :ready, freshness: :unknown} end)
      assert :checking = GenServer.call(pid, :refresh_for_dispatch)
      assert %{probe: %{pid: live_probe}, dispatch_watchdog: %{}} = :sys.get_state(pid)
      assert Process.alive?(live_probe)

      # Lose the probe exactly as #2237 did: swap in an already-dead pid whose
      # ref matches no monitor, then kill the original so its :DOWN is swallowed
      # against the replaced record. No completion signal can ever arrive.
      {dead_probe, dead_ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^dead_ref, :process, ^dead_probe, :normal}, 1000
      refute Process.alive?(dead_probe)

      :sys.replace_state(pid, fn state ->
        %{state | probe: %{pid: dead_probe, ref: make_ref(), timer: nil}}
      end)

      Process.exit(live_probe, :kill)

      # The idle watchdog observes a dead worker and releases the dispatch gate.
      assert_receive {:prewarm_phase, {:error, {:repo_base_dispatch_hold_stalled, :checking}}}, 2_000

      # The stall release must tear down the orphaned worker record, not leave
      # residue that a later refresh would mistake for an in-flight probe.
      assert %{phase: {:error, {:repo_base_dispatch_hold_stalled, :checking}}, probe: nil} =
               :sys.get_state(pid)

      phase = GenServer.call(pid, :refresh_for_dispatch)
      assert phase == {:error, {:repo_base_dispatch_hold_stalled, :checking}}
      assert DispatchPolicy.prewarm_gate(true, phase) == :dispatch
    end

    test "a dead checking probe is restarted and the fresh probe keeps the hold", %{server: pid, cfg: cfg} do
      pid = restart_enabled_server(pid, cfg, dispatch_hold_timeout_ms: 50)
      Phoenix.PubSub.subscribe(Aiur.PubSub, "prewarm:phase")
      {dead_probe, dead_ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^dead_ref, :process, ^dead_probe, :normal}, 1000
      refute Process.alive?(dead_probe)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | phase: :checking,
            probe: %{pid: dead_probe, ref: make_ref(), timer: nil},
            ready_head: "same",
            freshness: :unknown
        }
      end)

      assert :checking = GenServer.call(pid, :refresh_for_dispatch)
      assert %{probe: %{pid: fresh_probe}, dispatch_watchdog: %{}} = :sys.get_state(pid)
      assert fresh_probe != dead_probe
      assert Process.alive?(fresh_probe)

      # A live probe self-resolves via its own 30-second timeout, so the idle
      # watchdog must not release the hold while it is alive.
      Process.sleep(150)
      assert %{phase: :checking, probe: %{pid: ^fresh_probe}} = :sys.get_state(pid)
      assert Process.alive?(fresh_probe)
      refute_receive {:prewarm_phase, {:error, {:repo_base_dispatch_hold_stalled, _}}}, 100
    end

    test "a lost build is released by the dispatch watchdog", %{server: pid, cfg: cfg} do
      pid = restart_enabled_server(pid, cfg, dispatch_hold_timeout_ms: 50)
      Phoenix.PubSub.subscribe(Aiur.PubSub, "prewarm:phase")
      {dead_build, dead_ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^dead_ref, :process, ^dead_build, :normal}, 1000
      refute Process.alive?(dead_build)

      :sys.replace_state(pid, fn state ->
        %{state | phase: :building, build: %{pid: dead_build, ref: make_ref(), head: nil}}
      end)

      assert :building = GenServer.call(pid, :refresh_for_dispatch)
      assert %{dispatch_watchdog: %{}} = :sys.get_state(pid)

      assert_receive {:prewarm_phase, {:error, {:repo_base_dispatch_hold_stalled, :building}}}, 2_000

      # The stall release must abort the orphaned build worker and clear its
      # record, so no residue survives into the released gate.
      assert %{phase: {:error, {:repo_base_dispatch_hold_stalled, :building}}, build: nil} =
               :sys.get_state(pid)

      phase = GenServer.call(pid, :refresh_for_dispatch)
      assert phase == {:error, {:repo_base_dispatch_hold_stalled, :building}}
      assert DispatchPolicy.prewarm_gate(true, phase) == :dispatch
    end

    test "a live build is never killed by the dispatch watchdog", %{server: pid, cfg: cfg} do
      pid = restart_enabled_server(pid, cfg, dispatch_hold_timeout_ms: 50)
      Phoenix.PubSub.subscribe(Aiur.PubSub, "prewarm:phase")
      build_pid = install_live_build(pid, "same")

      assert :building = GenServer.call(pid, :refresh_for_dispatch)
      assert %{dispatch_watchdog: %{}} = :sys.get_state(pid)

      # A cold build (deps + compile + dialyzer PLT) can run for many minutes;
      # the idle watchdog must re-arm rather than kill a progressing build.
      Process.sleep(150)
      assert %{phase: :building, build: %{pid: ^build_pid}} = :sys.get_state(pid)
      assert Process.alive?(build_pid)
      refute_receive {:prewarm_phase, {:error, {:repo_base_dispatch_hold_stalled, _}}}, 100
    end

    test "a completed build clears the dispatch watchdog", %{server: pid, cfg: cfg} do
      pid = restart_enabled_server(pid, cfg, dispatch_hold_timeout_ms: 50)
      Phoenix.PubSub.subscribe(Aiur.PubSub, "prewarm:phase")
      build_pid = install_live_build(pid, "same")

      assert :building = GenServer.call(pid, :refresh_for_dispatch)
      assert %{dispatch_watchdog: %{}} = :sys.get_state(pid)

      send(pid, {:build_done, build_pid, "same", {:ok, "/base"}})
      Process.exit(build_pid, :kill)

      assert %{phase: :ready, freshness: :unknown, dispatch_watchdog: nil} = :sys.get_state(pid)

      # The stale timer must clear itself without raising a false stall error.
      Process.sleep(100)
      assert %{phase: :ready, freshness: :unknown, dispatch_watchdog: nil} = :sys.get_state(pid)
      refute_receive {:prewarm_phase, {:error, {:repo_base_dispatch_hold_stalled, _}}}, 100
    end

    test "a hold that outlives one watchdog fire is released once its worker dies", %{server: pid, cfg: cfg} do
      pid = restart_enabled_server(pid, cfg, dispatch_hold_timeout_ms: 50)
      Phoenix.PubSub.subscribe(Aiur.PubSub, "prewarm:phase")
      build_pid = install_live_build(pid, "same")

      assert :building = GenServer.call(pid, :refresh_for_dispatch)
      assert %{dispatch_watchdog: %{}} = :sys.get_state(pid)

      # A cold build (deps + compile + dialyzer PLT) runs past one watchdog
      # interval; the watchdog must re-arm while the worker is alive. The release
      # below must depend on the *later* fire, not on the first one — a watchdog
      # that never re-arms would look identical on this first sleep.
      Process.sleep(120)
      assert %{phase: :building, build: %{pid: ^build_pid}} = :sys.get_state(pid)
      assert Process.alive?(build_pid)
      refute_receive {:prewarm_phase, {:error, {:repo_base_dispatch_hold_stalled, _}}}, 100

      # The build dies without a completion signal (OOM kill): swap in an
      # already-dead record so the :DOWN is swallowed and release depends purely
      # on the watchdog observing the dead worker.
      {dead_build, dead_ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^dead_ref, :process, ^dead_build, :normal}, 1000
      refute Process.alive?(dead_build)

      :sys.replace_state(pid, fn state ->
        %{state | build: %{pid: dead_build, ref: make_ref(), head: nil}}
      end)

      Process.exit(build_pid, :kill)

      # The next watchdog fire observes the dead worker and releases the gate.
      assert_receive {:prewarm_phase, {:error, {:repo_base_dispatch_hold_stalled, :building}}}, 2_000

      phase = GenServer.call(pid, :refresh_for_dispatch)
      assert phase == {:error, {:repo_base_dispatch_hold_stalled, :building}}
      assert DispatchPolicy.prewarm_gate(true, phase) == :dispatch
    end

    test "the periodic poll restarts a dead checking probe (absorbing-state fix)", %{server: pid, cfg: cfg} do
      pid = restart_enabled_server(pid, cfg, dispatch_hold_timeout_ms: 50)
      {dead_probe, dead_ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^dead_ref, :process, ^dead_probe, :normal}, 1000
      refute Process.alive?(dead_probe)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | phase: :checking,
            probe: %{pid: dead_probe, ref: make_ref(), timer: nil},
            ready_head: "same",
            freshness: :unknown
        }
      end)

      # The periodic poll (`:refresh_async` / `:poll` share do_refresh_async/1)
      # must restart a dead probe instead of treating :checking as absorbing —
      # the same defect #2237 exposed, on the path that poll_seconds: 30 keeps
      # alive as an independent recovery route.
      GenServer.cast(pid, :refresh_async)
      assert %{phase: :checking, probe: %{pid: fresh_probe}} = :sys.get_state(pid)
      assert fresh_probe != dead_probe
      assert Process.alive?(fresh_probe)
    end

    test "disabling prewarm while a hold is in flight aborts the worker and clears the watchdog", %{
      server: pid,
      cfg: cfg
    } do
      pid = restart_enabled_server(pid, cfg, dispatch_hold_timeout_ms: 50)
      build_pid = install_live_build(pid, "same")

      assert :building = GenServer.call(pid, :refresh_for_dispatch)
      assert %{dispatch_watchdog: %{}} = :sys.get_state(pid)
      assert Process.alive?(build_pid)

      # The operator disables prewarm while the build hold is in flight.
      File.write!(cfg, """
      tracker:
        kind: github
        base_branch: main
        github:
          repo: owner/project
      prewarm:
        enabled: false
        base_build: "true"
        poll_seconds: 30
      """)

      :ok = Aiur.WorkflowStore.force_reload()

      assert :idle = GenServer.call(pid, :refresh_for_dispatch)
      assert %{phase: :idle, build: nil, probe: nil, dispatch_watchdog: nil} = :sys.get_state(pid)
      refute Process.alive?(build_pid)
    end

    test "a hold with no worker record is released by the watchdog fallback", %{server: pid, cfg: cfg} do
      pid = restart_enabled_server(pid, cfg, dispatch_hold_timeout_ms: 50)
      Phoenix.PubSub.subscribe(Aiur.PubSub, "prewarm:phase")

      # A hold phase whose worker record is gone (defensive path): the fallback
      # must decide "release", never "hold forever". Arm a real watchdog timer
      # against the injected state so the release flows through handle_info/2.
      watchdog_ref = make_ref()
      watchdog_timer = Process.send_after(pid, {:dispatch_hold_timeout, watchdog_ref}, 50)

      :sys.replace_state(pid, fn state ->
        %{state | phase: :building, build: nil, dispatch_watchdog: %{ref: watchdog_ref, timer: watchdog_timer}}
      end)

      assert_receive {:prewarm_phase, {:error, {:repo_base_dispatch_hold_stalled, :building}}}, 2_000

      assert %{phase: {:error, {:repo_base_dispatch_hold_stalled, :building}}, dispatch_watchdog: nil} =
               :sys.get_state(pid)
    end
  end

  defp restart_enabled_server(pid, cfg, opts) do
    Aiur.TestSupport.safe_stop(pid)

    File.write!(cfg, """
    tracker:
      kind: github
      base_branch: main
      github:
        repo: owner/project
    prewarm:
      enabled: true
      base_build: "true"
      poll_seconds: 0
    """)

    :ok = Aiur.WorkflowStore.force_reload()

    opts = Keyword.put_new(opts, :remote_head_fun, fn _repo_url -> Process.sleep(:infinity) end)
    {:ok, pid} = GenServer.start_link(RepoBase, opts)
    on_exit(fn -> Aiur.TestSupport.safe_stop(pid) end)
    pid
  end

  defp install_live_build(pid, head) do
    test_pid = self()

    :sys.replace_state(pid, fn state ->
      {build_pid, ref} = spawn_monitor(fn -> Process.sleep(:infinity) end)
      send(test_pid, {:build_pid, build_pid})
      %{state | phase: :building, build: %{pid: build_pid, ref: ref, head: head}}
    end)

    assert_receive {:build_pid, build_pid}, 1000
    build_pid
  end

  defp probe(pid), do: %{pid: pid, ref: make_ref(), timer: nil}
end
