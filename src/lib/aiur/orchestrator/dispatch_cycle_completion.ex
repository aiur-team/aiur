defmodule Aiur.Orchestrator.DispatchCycleCompletion do
  @moduledoc false

  alias Aiur.Orchestrator.DispatchCycleLiveness
  alias Aiur.Orchestrator.{Lifecycle, State, StatusReport, TrackerHealth}

  @spec finish(State.t()) :: State.t()
  def finish(state) do
    schedule = TrackerHealth.poll_schedule(state)

    state =
      state
      |> Lifecycle.schedule_tick(schedule.delay_ms)
      |> Map.put(:effective_poll_interval_ms, schedule.delay_ms)
      |> Map.put(:idle_poll_backoff, %{active?: schedule.idle_backoff?, factor: schedule.idle_widen_factor})
      # Keep the first poll at the base interval; idle widening starts after an observed cycle (#2138).
      |> Map.update!(:poll_cycles_completed, &(&1 + 1))
      # A pulled-forward tick must still respect GitHub's poll floor.
      |> Map.put(:last_dispatch_poll_at_ms, System.monotonic_time(:millisecond))
      # Hints whose budget this cycle exhausted are pruned after they are counted.
      |> TrackerHealth.prune_queued_demand_hints()

    # Publish the effective cadence after composing idle widening and GitHub floors.
    :ok = TrackerHealth.publish_poll_cadence(state, schedule)

    state =
      state
      |> DispatchCycleLiveness.complete()
      |> Map.put(:poll_check_in_progress, false)

    StatusReport.sync_waiting_for_human_episodes(state, DateTime.utc_now())
    |> StatusReport.notify_dashboard()

    state
  end
end
