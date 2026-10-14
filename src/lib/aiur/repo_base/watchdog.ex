defmodule Aiur.RepoBase.Watchdog do
  @moduledoc """
  Idle dispatch-hold watchdog transitions for the `Aiur.RepoBase` server
  state. Timers target the calling process, so call these from the server.
  """

  @doc false
  @spec sync_dispatch_watchdog(map()) :: map()
  def sync_dispatch_watchdog(%{phase: phase} = state) when phase in [:cloning, :fetching, :building, :checking],
    do: ensure_dispatch_watchdog(state)

  def sync_dispatch_watchdog(state), do: clear_dispatch_watchdog(state)

  defp ensure_dispatch_watchdog(%{dispatch_watchdog: nil} = state) do
    ref = make_ref()
    timer = Process.send_after(self(), {:dispatch_hold_timeout, ref}, state.dispatch_hold_timeout_ms)
    %{state | dispatch_watchdog: %{ref: ref, timer: timer}}
  end

  defp ensure_dispatch_watchdog(state), do: state

  # A hold is "progressing" while its worker is alive. There is no continuous
  # deadline across phases: any successful transition is itself progress, so
  # leaving a hold clears the watchdog and a fresh hold arms a fresh one.
  @doc false
  @spec clear_released_watchdog(map()) :: map()
  def clear_released_watchdog(%{phase: phase} = state) when phase in [:cloning, :fetching, :building, :checking],
    do: state

  def clear_released_watchdog(state), do: clear_dispatch_watchdog(state)

  # Restart the idle clock for a hold whose worker is still alive: cancel the
  # fired timer and arm a fresh interval. A fresh ref keeps a stale in-flight
  # message from matching the new record.
  @doc false
  @spec rearm_dispatch_watchdog(map()) :: map()
  def rearm_dispatch_watchdog(%{dispatch_watchdog: %{timer: timer}} = state) do
    if is_reference(timer), do: Process.cancel_timer(timer)
    ensure_dispatch_watchdog(%{state | dispatch_watchdog: nil})
  end

  def rearm_dispatch_watchdog(state), do: state

  @doc false
  @spec hold_phase?(term()) :: boolean()
  def hold_phase?(phase), do: phase in [:cloning, :fetching, :building, :checking]

  @doc false
  @spec hold_progress?(map()) :: boolean()
  def hold_progress?(%{phase: phase, build: %{pid: pid}})
      when phase in [:building, :cloning, :fetching] and is_pid(pid),
      do: Process.alive?(pid)

  def hold_progress?(%{phase: :checking, probe: %{pid: pid}}) when is_pid(pid),
    do: Process.alive?(pid)

  def hold_progress?(_state), do: false

  @doc false
  @spec clear_dispatch_watchdog(map()) :: map()
  def clear_dispatch_watchdog(%{dispatch_watchdog: %{timer: timer}} = state) do
    if is_reference(timer), do: Process.cancel_timer(timer)
    %{state | dispatch_watchdog: nil}
  end

  def clear_dispatch_watchdog(state), do: state
end
