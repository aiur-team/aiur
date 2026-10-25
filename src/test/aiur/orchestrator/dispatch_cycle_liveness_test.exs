defmodule Aiur.Orchestrator.DispatchCycleLivenessTest do
  use Aiur.DispatcherTestSupport

  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.DispatchCycleLiveness

  test "watchdog alerts when the dispatch tick stops after a completed cycle" do
    :ok = Exchange.subscribe("system.dispatch.cycle_stalled")

    completed =
      DispatchCycleLiveness.complete(%State{
        poll_interval_ms: 10,
        effective_poll_interval_ms: 10
      })

    assert is_integer(completed.last_dispatch_cycle_completed_at_ms)
    assert_receive {:dispatch_cycle_liveness_check, token}, 1_000
    assert {:noreply, stalled} = Orchestrator.handle_info({:dispatch_cycle_liveness_check, token}, completed)
    assert stalled.dispatch_cycle_stalled?
    assert stalled.dispatch_cycle_stage == "waiting for dispatch cycle"
    assert stalled.dispatch_cycle_started_at_ms > completed.last_dispatch_cycle_completed_at_ms
    assert_received {:event, %{"topic" => "system.dispatch.cycle_stalled", "reason" => reason}}
    assert reason =~ "stage: waiting for dispatch cycle"

    if is_reference(stalled.tick_timer_ref), do: Process.cancel_timer(stalled.tick_timer_ref)
  end

  test "startup-cleanup and active-cycle early returns do not create false stalls" do
    :ok = Exchange.subscribe("system.dispatch.cycle_stalled")

    idle = DispatchCycleLiveness.complete(%State{poll_interval_ms: 10, effective_poll_interval_ms: 10})
    cleanup_ref = make_ref()
    cleanup = %{idle | tracker_tasks: %{cleanup_ref => %{key: :startup_workspace_cleanup}}}
    assert {:noreply, skipped} = Dispatcher.run_poll_cycle(cleanup)
    assert_receive {:dispatch_cycle_liveness_check, token}, 1_000
    assert {:noreply, checked} = Orchestrator.handle_info({:dispatch_cycle_liveness_check, token}, skipped)
    refute checked.dispatch_cycle_stalled?
    assert checked.tracker_tasks == cleanup.tracker_tasks
    refute_received {:event, %{"topic" => "system.dispatch.cycle_stalled"}}

    active = DispatchCycleLiveness.start(%State{poll_interval_ms: 10, effective_poll_interval_ms: 10})
    poll_ref = make_ref()
    active = %{active | tracker_tasks: %{poll_ref => %{key: :dispatch_poll}}}
    assert {:noreply, waiting} = Dispatcher.run_poll_cycle(active)
    refute waiting.dispatch_cycle_stalled?
    assert is_integer(waiting.dispatch_cycle_started_monotonic_ms)

    for ref <- [checked.dispatch_cycle_watchdog_timer_ref, waiting.dispatch_cycle_watchdog_timer_ref, waiting.tick_timer_ref] do
      if is_reference(ref), do: Process.cancel_timer(ref)
    end
  end
end
