defmodule Aiur.BuildGateHoldMonitor do
  @moduledoc """
  Daemon-side needs-attention alerting for build-gate slots held beyond the
  configured maximum hold duration (#2349; the #2311 acceptance criterion).

  The detached lease holder (`build_gate_holder.py`) enforces the absolute cap
  itself: at `agent.build_gate_max_hold_seconds` it releases the slot, logs,
  and leaves a durable `slot-N.hold-timeout` marker. This worker turns that
  condition into a needs-attention alert naming the command, covering both
  causes together:

    * a slot currently held at or beyond the threshold — a serialised `--trace`
      run that monopolises a slot (#2311) or a leaked holder that is still
      alive (#2349), and
    * a `slot-N.hold-timeout` marker — the holder already self-released, so the
      marker makes the alert reliable even when the release races this poll.

  Alerts use per-slot topics (`system.build_gate.hold_timeout.slot-N`) so the
  ledger can track each slot's firing/cleared cycle; a `.resolved` event is
  emitted when the condition clears. Fails open: any status or config read
  error degrades to no alert rather than taking the supervision tree down.
  """

  use GenServer

  require Logger

  alias Aiur.{Alerts, BuildGate, Config}

  @default_interval_ms 30_000
  @topic_prefix "system.build_gate.hold_timeout"
  @default_threshold_seconds 3_600

  defmodule State do
    @moduledoc false
    defstruct [
      :interval_ms,
      :threshold_seconds,
      :status_fun,
      :emit_fun,
      alerted: MapSet.new()
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Per-slot alert topic naming the offending slot."
  @spec topic_for(pos_integer()) :: String.t()
  def topic_for(slot) when is_integer(slot) and slot > 0, do: "#{@topic_prefix}.slot-#{slot}"

  @doc false
  # Pure per-tick transition: alert on newly-offending slots, resolve cleared
  # ones, and return the next alerted set. `emit_fun` is injectable so tests
  # drive the decision without the full alert pipeline.
  @spec evaluate(map(), map()) :: map()
  def evaluate(%State{} = state, status) do
    offending = offending_slots(status, state.threshold_seconds)
    alerted = state.alerted

    for {slot, _} <- offending, not MapSet.member?(alerted, slot) do
      emit_alert(state.emit_fun, state.threshold_seconds, slot, Map.fetch!(offending, slot))
    end

    for slot <- alerted, not Map.has_key?(offending, slot) do
      emit_resolution(state.emit_fun, slot)
    end

    %{state | alerted: MapSet.new(Map.keys(offending))}
  end

  # --------------------------------------------------------- callbacks

  @impl true
  def init(opts) do
    if enabled?() do
      state = %State{
        interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
        threshold_seconds: Keyword.get(opts, :threshold_seconds, threshold(opts)),
        status_fun: Keyword.get(opts, :status_fun, &BuildGate.status/0),
        emit_fun: Keyword.get(opts, :emit_fun, &Alerts.emit_system/2),
        alerted: MapSet.new()
      }

      schedule_tick(state.interval_ms)
      {:ok, state}
    else
      Logger.info("build_gate_hold_monitor disabled (build gate not enabled)")
      {:ignore, %State{}}
    end
  end

  @impl true
  def handle_info(:tick, state) do
    state = tick(state)
    schedule_tick(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ----------------------------------------------------------- internals

  defp tick(state) do
    status = safe_status(state.status_fun)
    state = evaluate(state, status)
    remove_markers(status, state.alerted)
    state
  end

  # A slot is offending when its `slot-N.hold-timeout` marker exists (the
  # holder already released at the cap) or it is a live slot holder held at or
  # beyond the threshold. Marker records win when both describe the same slot.
  defp offending_slots(%{enabled?: false}, _threshold), do: %{}

  defp offending_slots(_status, threshold) when threshold <= 0, do: %{}

  defp offending_slots(status, threshold) do
    held =
      for %{kind: :slot, slot: slot, command: command, held_for_seconds: held} <-
            Map.get(status, :holders, []),
          is_integer(slot),
          is_integer(held),
          held >= threshold,
          into: %{},
          do: {slot, %{command: command, held: held, source: :held}}

    markers =
      for %{slot: slot, command: command, held_for_seconds: held} <- Map.get(status, :timeouts, []),
          is_integer(slot),
          into: %{},
          do: {slot, %{command: command, held: held, source: :marker}}

    Map.merge(held, markers)
  end

  defp emit_alert(emit_fun, threshold, slot, %{command: command, held: held, source: source}) do
    message =
      "Build-gate slot #{slot} held #{format_hold(held)} without completing " <>
        "(max hold #{threshold}s exceeded); command=#{inspect(command)}"

    emit_fun.(topic_for(slot),
      message: message,
      reason: "build-gate slot #{slot} exceeded the max hold duration (observed via #{source})",
      needs_attention: true,
      severity: "warning"
    )
  end

  defp emit_resolution(emit_fun, slot) do
    emit_fun.("#{topic_for(slot)}.resolved",
      message: "Build-gate slot #{slot} is no longer held beyond the max hold duration",
      reason: "build-gate slot #{slot} released",
      needs_attention: false,
      severity: "info"
    )
  end

  # A marker has been converted into an alert (or was already latched);
  # remove it so the next tick does not re-alert. Removal is best-effort — a
  # leftover marker merely re-alerts and `collapse_repeated_attention` dedups.
  defp remove_markers(%{enabled?: false}, _alerted), do: :ok

  defp remove_markers(status, alerted) do
    for %{slot: slot, path: path} <- Map.get(status, :timeouts, []),
        MapSet.member?(alerted, slot) do
      File.rm(path)
    end

    :ok
  end

  defp safe_status(status_fun) do
    status_fun.()
  rescue
    error ->
      Logger.warning("build_gate_hold_monitor status_failed error=#{inspect(error)}")
      %{enabled?: false}
  catch
    _kind, reason ->
      Logger.warning("build_gate_hold_monitor status_failed caught=#{inspect(reason)}")
      %{enabled?: false}
  end

  defp threshold(opts) do
    case Keyword.get(opts, :threshold_seconds) do
      value when is_integer(value) and value >= 0 -> value
      _ -> safe_config(&Config.build_gate_max_hold_seconds/0, @default_threshold_seconds)
    end
  end

  # Fail-open: an unreadable config at boot must not crash the monitor's init
  # (a crash would restart-loop it). If the gate cannot be evaluated, start the
  # monitor — its tick degrades to no alerts when status is unavailable.
  defp enabled? do
    safe_config(&BuildGate.enabled?/0, true)
  end

  defp safe_config(fun, fallback) do
    fun.()
  rescue
    _error -> fallback
  catch
    _kind, _reason -> fallback
  end

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp format_hold(seconds) when is_integer(seconds) and seconds >= 3_600 do
    "#{div(seconds, 3_600)}h#{div(rem(seconds, 3_600), 60)}m"
  end

  defp format_hold(seconds) when is_integer(seconds) and seconds >= 60,
    do: "#{div(seconds, 60)}m#{rem(seconds, 60)}s"

  defp format_hold(seconds) when is_integer(seconds) and seconds >= 0, do: "#{seconds}s"
  defp format_hold(_seconds), do: "unknown"
end
