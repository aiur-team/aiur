defmodule Aiur.Orchestrator.Dispatcher.OverrideOrderTest do
  use Aiur.DispatcherTestSupport

  alias Aiur.Commands
  alias Aiur.Orchestrator.OverrideResume

  test "owner poll starts ordinary dispatch before stranded reconciliation while override lookup waits" do
    parent = self()
    candidate = %{issue("override-order") | selected_backend: "codex", blocked_by: []}
    state = %State{snapshot_key: self(), max_concurrent_agents: 4, effective_concurrent_agents: 4}
    assert TrackerTasks.owner?(state)

    pending =
      TrackerTasks.run(
        state,
        :override_resumes,
        fn ->
          send(parent, {:override_lookup_waiting, self()})
          receive do: (:release -> [])
        end,
        &OverrideResume.apply_loaded/2
      )

    receive_barrier({:override_lookup_waiting, worker})
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)

    next =
      Dispatcher.dispatch_candidate_poll(pending,
        fetch_candidate_issues_fun: fn current -> {:ok, [candidate], current} end,
        startup_claim_opts: [read_boot_marker_fun: fn -> {:ok, Aiur.Boot.run_id()} end],
        scan_commands_fun: &Function.identity/1,
        stop_closed_pr_agents_fun: &Function.identity/1,
        stranded_reconciliation_fun: fn current, [^candidate] ->
          assert TrackerTasks.running?(current, :override_resumes)
          assert TrackerTasks.running?(current, {:dispatch, candidate.id})
          send(parent, :reconciled_after_dispatch)
          current
        end
      )

    assert_received :reconciled_after_dispatch
    assert TrackerTasks.running?(next, :override_resumes)
    # The lookup completion must not dispatch again or repeat the stranded pass.
    send(worker, :release)
    {ref, _job} = Enum.find(next.tracker_tasks, fn {_ref, job} -> job.key == :override_resumes end)
    receive_barrier({^ref, result})
    assert {:handled, completed} = TrackerTasks.result(next, ref, result)
    refute TrackerTasks.running?(completed, :override_resumes)
    assert TrackerTasks.running?(completed, {:dispatch, candidate.id})
    refute_received :reconciled_after_dispatch
    TrackerTasks.stop(completed)
  end

  test "an owner with no waiting overrides does not start tracker work" do
    assert OverrideResume.waiting(Commands.list_decisions(Commands.default_store())) == []
    state = %State{snapshot_key: self()}
    assert TrackerTasks.owner?(state)
    assert OverrideResume.schedule(state, []) == state
  end
end
