defmodule Aiur.Orchestrator.DispatchCycleLiveness do
  @moduledoc false

  alias Aiur.Alerts
  alias Aiur.Orchestrator.{State, StatusReport}

  @retry_ms 1_000

  @spec handle_check(State.t(), reference()) :: {:noreply, State.t()}
  def handle_check(state, token) do
    state = check(state, token)
    StatusReport.notify_dashboard(state)
    {:noreply, state}
  end

  @spec start(State.t()) :: State.t()
  def start(%State{dispatch_cycle_started_monotonic_ms: started} = state) when is_integer(started), do: state

  def start(%State{} = state) do
    state = state |> cancel_watchdog() |> resolve_stall("Dispatch cycle started.")
    now_mono = System.monotonic_time(:millisecond)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:dispatch_cycle_liveness_check, token}, overdue_ms(state))

    %{
      state
      | dispatch_cycle_started_at_ms: System.system_time(:millisecond),
        dispatch_cycle_started_monotonic_ms: now_mono,
        dispatch_cycle_watchdog_token: token,
        dispatch_cycle_watchdog_timer_ref: timer_ref
    }
  end

  @spec check(State.t(), reference()) :: State.t()
  def check(%State{dispatch_cycle_watchdog_token: token} = state, token) when is_reference(token) do
    cond do
      startup_cleanup_running?(state) ->
        reschedule(state, token, 100)

      is_integer(state.dispatch_cycle_started_monotonic_ms) ->
        elapsed_ms = System.monotonic_time(:millisecond) - state.dispatch_cycle_started_monotonic_ms
        check_elapsed(state, elapsed_ms, token)

      is_integer(state.last_dispatch_cycle_completed_at_ms) ->
        elapsed_ms = System.system_time(:millisecond) - state.last_dispatch_cycle_completed_at_ms
        check_elapsed(state, elapsed_ms, token)

      true ->
        state
    end
  end

  def check(%State{} = state, _token), do: state

  @spec complete(State.t()) :: State.t()
  def complete(%State{} = state) do
    state = state |> cancel_watchdog() |> resolve_stall("Dispatch cycle completed.")

    state = %{
      state
      | dispatch_cycle_started_at_ms: nil,
        dispatch_cycle_started_monotonic_ms: nil,
        dispatch_cycle_stalled?: false,
        dispatch_cycle_stage: nil,
        last_dispatch_cycle_completed_at_ms: System.system_time(:millisecond),
        dispatch_cycle_watchdog_token: nil,
        dispatch_cycle_watchdog_timer_ref: nil
    }

    arm(state, overdue_ms(state))
  end

  defp emit_stalled(%State{dispatch_cycle_stalled?: true} = state, _elapsed_ms, _token), do: state

  defp emit_stalled(state, elapsed_ms, token) do
    stage = stage(state)
    seconds = div(elapsed_ms, 1_000)
    reason = "Dispatch cycle has not completed for #{seconds}s (stage: #{stage})."
    started_at_ms = state.dispatch_cycle_started_at_ms || idle_stall_started_at(state)

    case Alerts.emit_system("system.dispatch.cycle_stalled", message: reason, reason: reason, needs_attention: true, severity: "warning") do
      :ok ->
        %{state | dispatch_cycle_stalled?: true, dispatch_cycle_stage: stage, dispatch_cycle_started_at_ms: started_at_ms, dispatch_cycle_watchdog_timer_ref: nil}

      {:error, _} ->
        reschedule(state, token, @retry_ms)
    end
  end

  defp check_elapsed(state, elapsed_ms, token) do
    if elapsed_ms >= overdue_ms(state), do: emit_stalled(state, elapsed_ms, token), else: reschedule(state, token, overdue_ms(state) - elapsed_ms)
  end

  defp idle_stall_started_at(state), do: state.last_dispatch_cycle_completed_at_ms + overdue_ms(state)

  defp startup_cleanup_running?(state),
    do: Enum.any?(state.tracker_tasks, fn {_ref, task} -> task.key == :startup_workspace_cleanup end)

  defp resolve_stall(%State{dispatch_cycle_stalled?: true} = state, message) do
    _ = Alerts.emit_system("system.dispatch.cycle_stalled.resolved", message: message, reason: message, needs_attention: false, severity: "info")
    %{state | dispatch_cycle_stalled?: false, dispatch_cycle_stage: nil, dispatch_cycle_started_at_ms: nil}
  end

  defp resolve_stall(state, _message), do: state

  defp cancel_watchdog(state) do
    if is_reference(state.dispatch_cycle_watchdog_timer_ref), do: Process.cancel_timer(state.dispatch_cycle_watchdog_timer_ref)
    %{state | dispatch_cycle_watchdog_token: nil, dispatch_cycle_watchdog_timer_ref: nil}
  end

  defp arm(state, delay_ms) do
    token = make_ref()
    timer_ref = Process.send_after(self(), {:dispatch_cycle_liveness_check, token}, delay_ms)
    %{state | dispatch_cycle_watchdog_token: token, dispatch_cycle_watchdog_timer_ref: timer_ref}
  end

  defp reschedule(state, token, delay_ms) do
    timer_ref = Process.send_after(self(), {:dispatch_cycle_liveness_check, token}, max(delay_ms, 1))
    %{state | dispatch_cycle_watchdog_timer_ref: timer_ref}
  end

  defp interval(state),
    do: state.effective_poll_interval_ms || state.poll_interval_ms || Aiur.PollCadence.base_interval_ms(class: :dispatch)

  defp overdue_ms(state), do: interval(state) * 2

  defp stage(state) do
    case state.tracker_tasks |> Map.values() |> Enum.map(& &1.key) do
      [] -> if(state.poll_check_in_progress, do: "polling", else: "waiting for dispatch cycle")
      keys -> Enum.map_join(keys, ", ", &inspect/1)
    end
  end
end
