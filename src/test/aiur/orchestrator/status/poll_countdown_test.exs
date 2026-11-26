defmodule Aiur.Orchestrator.Status.PollCountdownTest do
  use Aiur.TestSupport

  import Aiur.OrchestratorStatusSupport

  test "orchestrator snapshot includes poll countdown and checking status" do
    orchestrator_name = Module.concat(__MODULE__, :PollingSnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    now_ms = System.monotonic_time(:millisecond)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | poll_interval_ms: 30_000,
          effective_poll_interval_ms: 150_000,
          idle_poll_backoff: %{active?: true, factor: 5.0},
          tick_timer_ref: nil,
          tick_token: make_ref(),
          next_poll_due_at_ms: now_ms + 4_000,
          poll_check_in_progress: false
      }
    end)

    snapshot = GenServer.call(pid, :snapshot)

    assert %{
             polling: %{
               checking?: false,
               poll_interval_ms: 30_000,
               effective_interval_ms: 150_000,
               idle_backoff: %{active?: true, factor: 5.0},
               next_poll_in_ms: due_in_ms
             }
           } = snapshot

    assert is_integer(due_in_ms)
    assert due_in_ms >= 0
    assert due_in_ms <= 4_000

    :sys.replace_state(pid, fn state ->
      %{state | poll_check_in_progress: true, next_poll_due_at_ms: nil}
    end)

    snapshot = GenServer.call(pid, :snapshot)
    assert %{polling: %{checking?: true, next_poll_in_ms: nil}} = snapshot
  end

  test "orchestrator triggers an immediate poll cycle shortly after startup" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_seconds: 5
    )

    orchestrator_name = Module.concat(__MODULE__, :ImmediateStartupOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    assert %{polling: %{checking?: true}} =
             wait_for_snapshot(
               pid,
               fn
                 %{polling: %{checking?: true}} ->
                   true

                 _ ->
                   false
               end,
               500
             )

    assert %{
             polling: %{
               checking?: false,
               next_poll_in_ms: next_poll_in_ms,
               poll_interval_ms: 5_000,
               effective_interval_ms: 5_000,
               idle_backoff: %{active?: false, factor: 5.0}
             }
           } =
             wait_for_snapshot(
               pid,
               fn
                 %{polling: %{checking?: false, next_poll_in_ms: due_in_ms}}
                 when is_integer(due_in_ms) and due_in_ms <= 5_000 ->
                   true

                 _ ->
                   false
               end,
               500
             )

    assert is_integer(next_poll_in_ms)
    assert next_poll_in_ms >= 0
  end

  # Criterion 3 of #2138: a freshly restarted daemon has observed no idleness,
  # so its first scheduled interval is the base — and only after that first
  # full cycle completes (finding nothing to do) does the idle backoff apply.
  test "the first poll cycle schedules the base interval and only later cycles back off" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_seconds: 5
    )

    orchestrator_name = Module.concat(__MODULE__, :PollCadenceProgressionOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    assert %{
             polling: %{
               checking?: false,
               effective_interval_ms: 5_000,
               idle_backoff: %{active?: false, factor: 5.0}
             }
           } =
             wait_for_snapshot(
               pid,
               fn
                 # A base-interval schedule with a real next-due countdown only
                 # appears once the first full poll cycle has completed — the
                 # freshly-started daemon has observed no idleness yet, so it
                 # schedules the base interval (#2138). Matching on the
                 # countdown (the init state reports the same interval with a
                 # ~0 countdown) makes the manual cycle below deterministically
                 # the second one.
                 %{
                   polling: %{
                     checking?: false,
                     effective_interval_ms: 5_000,
                     next_poll_in_ms: due_in_ms
                   }
                 }
                 when is_integer(due_in_ms) and due_in_ms > 0 and due_in_ms <= 5_000 ->
                   true

                 _ ->
                   false
               end,
               500
             )

    # A second full cycle: one idle cycle has been observed, so the widened
    # cadence is now eligible.
    send(pid, :run_poll_cycle)

    assert %{
             polling: %{
               checking?: false,
               effective_interval_ms: 25_000,
               idle_backoff: %{active?: true, factor: 5.0}
             }
           } =
             wait_for_snapshot(
               pid,
               fn
                 %{polling: %{checking?: false, effective_interval_ms: 25_000}} ->
                   true

                 _ ->
                   false
               end,
               500
             )
  end

  test "orchestrator poll cycle resets next refresh countdown after a check" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_seconds: 1
    )

    orchestrator_name = Module.concat(__MODULE__, :PollCycleOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | poll_interval_ms: 1_000,
          # Simulate a daemon that has already completed an idle poll cycle, so
          # the widened cadence is eligible (a fresh daemon schedules base
          # first, #2138).
          poll_cycles_completed: 1,
          poll_check_in_progress: true,
          next_poll_due_at_ms: nil
      }
    end)

    send(pid, :run_poll_cycle)

    snapshot =
      wait_for_snapshot(pid, fn
        %{
          polling: %{
            checking?: false,
            poll_interval_ms: 1_000,
            effective_interval_ms: 5_000,
            idle_backoff: %{active?: true, factor: 5.0},
            next_poll_in_ms: next_poll_in_ms
          }
        }
        when is_integer(next_poll_in_ms) and next_poll_in_ms <= 5_000 ->
          true

        _ ->
          false
      end)

    assert %{
             polling: %{
               checking?: false,
               poll_interval_ms: 1_000,
               effective_interval_ms: 5_000,
               idle_backoff: %{active?: true, factor: 5.0},
               next_poll_in_ms: next_poll_in_ms
             }
           } = snapshot

    assert is_integer(next_poll_in_ms)
    assert next_poll_in_ms >= 0
    assert next_poll_in_ms <= 5_000
  end
end
