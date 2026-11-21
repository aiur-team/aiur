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
    %{state | dispatch_watchdog: %{ref: ref, timer: timer, deadline: deadline(state)}}
  end

  defp ensure_dispatch_watchdog(state), do: state

  # A hold is "progressing" while its worker is alive. The build's separate
  # total deadline is owned by that build and survives idle-watchdog re-arms.
  @doc false
  @spec clear_released_watchdog(map()) :: map()
  def clear_released_watchdog(%{phase: phase} = state) when phase in [:cloning, :fetching, :building, :checking],
    do: state

  def clear_released_watchdog(state), do: clear_dispatch_watchdog(state)

  # Restart only the idle clock when its worker is alive. The independent
  # build.timer stays in the build record and is unaffected by this re-arm.
  @doc false
  @spec rearm_dispatch_watchdog(map()) :: map()
  def rearm_dispatch_watchdog(%{dispatch_watchdog: %{timer: timer}} = state) do
    if is_reference(timer), do: Process.cancel_timer(timer)
    ref = make_ref()
    new_timer = Process.send_after(self(), {:dispatch_hold_timeout, ref}, state.dispatch_hold_timeout_ms)
    %{state | dispatch_watchdog: %{state.dispatch_watchdog | ref: ref, timer: new_timer, deadline: deadline(state)}}
  end

  def rearm_dispatch_watchdog(state), do: state

  # Dispatch calls this every tick so an overdue hold expires even when its
  # timer message was lost (#8100). A duplicate expiry no longer matches the ref.
  @doc false
  @spec expire_overdue_watchdog(map()) :: map()
  def expire_overdue_watchdog(%{dispatch_watchdog: %{ref: ref, deadline: deadline}} = state) do
    if System.monotonic_time(:millisecond) >= deadline, do: send(self(), {:dispatch_hold_timeout, ref})
    state
  end

  def expire_overdue_watchdog(state), do: state

  # Records when the current phase was first observed, so status can report its age.
  @doc false
  @spec stamp_phase(map()) :: map()
  def stamp_phase(%{phase: phase, phase_seen: phase} = state), do: state

  # A few direct callers/tests provide the older minimal state shape. GenServer
  # state includes these fields, but keep this helper robust for partial maps.
  def stamp_phase(%{phase: phase} = state) do
    Map.merge(state, %{phase_seen: phase, phase_since_ms: System.monotonic_time(:millisecond)})
  end

  @doc false
  @spec phase_age(map()) :: non_neg_integer()
  def phase_age(%{phase_since_ms: since}), do: System.monotonic_time(:millisecond) - since

  defp deadline(state), do: System.monotonic_time(:millisecond) + state.dispatch_hold_timeout_ms

  @doc false
  @spec hold_phase?(term()) :: boolean()
  def hold_phase?(phase), do: phase in [:cloning, :fetching, :building, :checking]

  # Only a live build worker counts. A `:checking` hold never does: each probe is
  # bounded at 30 seconds and a dead one is respawned every tick, so a live probe
  # at expiry proves nothing and would re-arm the hold forever (#8100).
  @doc false
  @spec hold_progress?(map()) :: boolean()
  def hold_progress?(%{phase: phase, build: %{pid: pid}})
      when phase in [:building, :cloning, :fetching] and is_pid(pid),
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
