defmodule Aiur.Regression.OrchestratorLifecycle.RecoveryDrainDurationTest do
  use Aiur.TestSupport

  import Aiur.OrchestratorLifecycleSupport

  describe "poll recovery" do
    test "a booted in-progress orphan retains tracker truth during recovery grace" do
      previous_loadavg = Application.get_env(:aiur, :loadavg_source_override)
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1\n"} end)
      on_exit(fn -> restore_app_env(:loadavg_source_override, previous_loadavg) end)

      issue = %Issue{
        id: "L11-ORPHAN",
        identifier: "L11-ORPHAN",
        state: "in-progress",
        title: "Recover orphan"
      }

      memory_tracker!([issue])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["todo", "in-progress", "human-review", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"],
        pre_warmed_sessions: 0
      )

      WorkflowStore.force_reload()

      name = Module.concat(__MODULE__, :RecoverOrphanedInProgress)
      pid = start_orchestrator(name)

      send(pid, :run_poll_cycle)
      state = await_orchestrator_state(pid, &Map.has_key?(&1.orphaned_claim_since, issue.identifier))

      # Periodic recovery waits for the grace period; the poll must not dispatch
      # the original claim before its PR state has been checked.
      refute Map.has_key?(state.running, issue.id)
      assert state.last_polled_issues[issue.id].state == "in-progress"
      refute_received {:memory_tracker_state_update, "L11-ORPHAN", _target}
      assert %{idle: idle} = Orchestrator.snapshot(name, 15_000)
      assert Enum.any?(idle, &(&1.identifier == "L11-ORPHAN" and &1.waiting_reason == :orphaned_claim))
    end
  end

  describe "drain semantics" do
    test "lowering the cap below active count reports draining and holds new dispatch" do
      name = Module.concat(__MODULE__, :Drain)
      pid = start_orchestrator(name)
      running = %{"a" => running_entry("a", "L12A", :working), "b" => running_entry("b", "L12B", :working)}
      :sys.replace_state(pid, &%{&1 | session_max_concurrent_agents: 3, running: running})

      assert {:ok, %{max: 1, draining?: true}} = Orchestrator.set_max_concurrent_agents(name, 1)
      state = :sys.get_state(pid)
      assert map_size(state.running) == 2
      refute Orchestrator.should_dispatch_issue_for_test(todo_issue("fresh-l12"), state)
    end
  end

  describe "max-duration bound" do
    test "an overrun active entry gets a cooperative pause, never a kill" do
      started_at = DateTime.add(DateTime.utc_now(), -120, :second)
      entry = Map.put(running_entry("l13", "L13", :working), :started_at, started_at)
      next = Orchestrator.apply_overrun_check_for_test(base_state(running: %{"l13" => entry}), 60)

      assert_receive {:pause_agent, _}, 2000
      assert get_in(next.running["l13"], [:control, :status]) == :paused
      assert next.running["l13"].paused_reason == :max_agent_duration
      assert next.running["l13"].pid == self()
    end

    test "a stale containment pause is logged and resumed" do
      name = Module.concat(__MODULE__, :ContainmentPause)
      pid = start_orchestrator(name)
      entry = running_entry("l16", "L16", :working)
      :sys.replace_state(pid, &%{&1 | running: %{"l16" => entry}, claimed: MapSet.new(["l16"])})

      log =
        capture_log(fn ->
          send(pid, {:worker_control_state, "l16", :paused, %{request_id: :containment}})
          assert_receive {:resume_agent, _}, 2_000
          # A synchronous system call queues after the worker message, so the
          # capture includes the log emitted by its handler under coverage load.
          _ = :sys.get_state(pid)
        end)

      resumed = :sys.get_state(pid).running["l16"]
      assert resumed.control.status == :working
      refute Map.has_key?(resumed, :paused_reason)
      assert log =~ "orchestrator.pause"
      assert log =~ "issue_identifier=L16"
      assert log =~ "cause=pause_containment"
    end

    test "a usage-limit worker pause is logged but not resumed" do
      name = Module.concat(__MODULE__, :UsageLimitPause)
      pid = start_orchestrator(name)
      entry = running_entry("l17", "L17", :working)
      :sys.replace_state(pid, &%{&1 | running: %{"l17" => entry}, claimed: MapSet.new(["l17"])})

      log =
        capture_log(fn ->
          send(pid, {:worker_control_state, "l17", :paused, %{kind: :usage_limit_exhausted}})
          assert :paused = get_in(:sys.get_state(pid, 15_000).running["l17"], [:control, :status])
        end)

      refute_receive {:resume_agent, _}, 100
      paused = :sys.get_state(pid).running["l17"]
      assert paused.paused_reason == :usage_limit_exhausted
      assert log =~ "orchestrator.pause"
      assert log =~ "issue_identifier=L17"
      assert log =~ "cause=usage_limit_exhausted"
    end

    test "an operator-attributed containment confirmation remains paused" do
      name = Module.concat(__MODULE__, :OperatorContainmentPause)
      pid = start_orchestrator(name)

      entry =
        "l18"
        |> running_entry("L18", :paused)
        |> Map.put(:paused_reason, :operator_pause)

      :sys.replace_state(pid, &%{&1 | running: %{"l18" => entry}, claimed: MapSet.new(["l18"])})

      send(pid, {:worker_control_state, "l18", :paused, %{request_id: :containment}})

      refute_receive {:resume_agent, _}, 100
      paused = :sys.get_state(pid).running["l18"]
      assert paused.control.status == :paused
      assert paused.paused_reason == :operator_pause
    end

    test "paused and deactivated entries are excluded from the overrun check" do
      started_at = DateTime.add(DateTime.utc_now(), -120, :second)

      running = %{
        "paused" => Map.put(running_entry("paused", "L14P", :paused), :started_at, started_at),
        "deactivated" => Map.put(running_entry("deactivated", "L14D", :deactivated), :started_at, started_at)
      }

      assert base_state(running: running) == Orchestrator.apply_overrun_check_for_test(base_state(running: running), 60)
      refute_receive {:pause_agent, _}, 100
    end

    test "duration-cap resume: operator resets the budget, automated resume preserves the overrun" do
      old_started = DateTime.add(DateTime.utc_now(), -300, :second)
      entry = running_entry("l15", "L15", :paused) |> Map.merge(%{started_at: old_started, paused_reason: :max_agent_duration})
      state = base_state(running: %{"l15" => entry})

      {{:ok, :resumed}, operator_state} = Orchestrator.resume_paused_issue_for_test(state, entry, true)
      {{:ok, :resumed}, auto_state} = Orchestrator.resume_paused_issue_for_test(state, entry, false)

      assert DateTime.diff(DateTime.utc_now(), operator_state.running["l15"].started_at, :second) in 0..2
      assert auto_state.running["l15"].started_at == old_started
      assert %DateTime{} = operator_state.running["l15"].last_codex_timestamp
      assert %DateTime{} = auto_state.running["l15"].last_codex_timestamp
    end
  end
end
