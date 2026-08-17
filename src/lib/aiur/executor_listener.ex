defmodule Aiur.ExecutorListener do
  @moduledoc """
  Daemon-resident, supervised consumer for the reviewed Executor wake bindings.

  Command events retain their durable Executor journal and alert path. Other
  allowlisted events are reduced to identifier-only wake records and persisted
  by `Aiur.ExecutorWakeInbox` for bounded Executor waits.
  """

  use GenServer

  require Logger

  alias Aiur.Alerts
  alias Aiur.Executor.StatePaths
  alias Aiur.Events.{Exchange, Topic}
  alias Aiur.{ExecutorBindings, ExecutorEvents, ExecutorWakeInbox, ExecutorWakeProjection, JsonStore}

  @command_topics ~w(executor.decision.requested executor.decision.deferred)
  @resubscribe_interval_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec alive?(GenServer.server()) :: boolean()
  def alive?(server \\ __MODULE__), do: bindings(server) != [] and missing_defaults(server) == []

  @spec bindings(GenServer.server()) :: [String.t()]
  def bindings(server \\ __MODULE__) do
    case Process.whereis(server) do
      pid when is_pid(pid) -> safe_bindings(pid)
      _ -> []
    end
  end

  @spec missing_defaults(GenServer.server()) :: [String.t()]
  def missing_defaults(server \\ __MODULE__) do
    bound = MapSet.new(bindings(server))
    Enum.reject(ExecutorBindings.patterns(), &MapSet.member?(bound, &1))
  end

  @impl true
  def init(opts) do
    if Keyword.get(opts, :reconcile?, true), do: ExecutorBindings.reconcile()

    patterns = Keyword.get(opts, :patterns, ExecutorBindings.patterns())
    interval = Keyword.get(opts, :resubscribe_interval_ms, @resubscribe_interval_ms)
    watermark = read_watermark()
    subscribe_missing(patterns)

    current_health = health(patterns)

    state = %{
      patterns: patterns,
      watermark: watermark,
      resubscribe_interval_ms: interval,
      health: current_health
    }

    state =
      if "executor.#" in patterns and bound?("executor.#") do
        replay_and_deliver("executor.#", state)
      else
        state
      end

    maybe_report_health(nil, current_health, patterns)
    schedule_resubscribe(interval)

    {:ok, state}
  end

  @impl true
  def handle_info({:event, event}, state), do: {:noreply, process_event(event, state)}

  def handle_info(:resubscribe, state) do
    observed_health = health(state.patterns)
    maybe_report_health(state.health, observed_health, state.patterns)
    executor_missing? = "executor.#" in state.patterns and not bound?("executor.#")
    subscribe_missing(state.patterns)

    state =
      if executor_missing? and bound?("executor.#") do
        replay_and_deliver("executor.#", %{state | watermark: read_watermark()})
      else
        state
      end

    current_health = health(state.patterns)
    maybe_report_health(observed_health, current_health, state.patterns)
    schedule_resubscribe(state.resubscribe_interval_ms)
    {:noreply, %{state | health: current_health}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.patterns, &Exchange.unsubscribe/1)
    :ok
  rescue
    _ -> :ok
  end

  defp subscribe_missing(patterns) do
    Enum.each(patterns, fn pattern ->
      if not bound?(pattern), do: subscribe_or_arm(pattern)
    end)
  end

  defp subscribe_or_arm(pattern) do
    :ok = Exchange.subscribe(pattern)
    true
  rescue
    error ->
      Logger.error("aiur_executor_listener phase=subscribe_error topic=#{pattern} error=#{Exception.message(error)}")
      false
  catch
    :exit, reason ->
      Logger.error("aiur_executor_listener phase=subscribe_exit topic=#{pattern} reason=#{inspect(reason)}")
      false
  end

  defp bound?(pattern), do: pattern in safe_bindings(self())

  # Replay threads the caller's state through every event and returns it, so a
  # watermark advanced during replay survives (#2039). Folding over a throwaway
  # state instead would re-deliver the whole replayed range on the next restart.
  defp replay_and_deliver(pattern, state) do
    case ExecutorEvents.replay([pattern], state.watermark) do
      {:ok, events} ->
        Enum.reduce(events, state, &process_event/2)

      {:error, reason} ->
        Logger.error("aiur_executor_listener phase=replay_failed reason=#{inspect(reason)}")
        state
    end
  end

  defp process_event(event, state) do
    if matching_fresh_event?(event, state) do
      try do
        :ok = deliver(event)

        if executor_topic?(event) do
          :ok = advance_watermark(event_id(event))
          %{state | watermark: event_id(event)}
        else
          state
        end
      rescue
        error ->
          log_delivery_failure(event, error)
          state
      catch
        kind, reason ->
          log_delivery_failure(event, {kind, reason})
          state
      end
    else
      state
    end
  end

  defp matching_fresh_event?(event, state) do
    case {event_topic(event), event_id(event)} do
      {topic, id} when is_binary(topic) and is_integer(id) ->
        Enum.any?(state.patterns, &Topic.matches?(&1, topic)) and
          (not String.starts_with?(topic, "executor.") or id > (state.watermark || 0))

      _ ->
        false
    end
  end

  defp deliver(event) do
    if executor_topic?(event) do
      scrubbed = ExecutorEvents.scrub_untrusted_output(event)
      if command_topic?(scrubbed) and command_alerting_enabled?(), do: emit_command_alert(scrubbed)
      :ok
    else
      case ExecutorWakeProjection.project(event) do
        {:ok, record} -> ExecutorWakeInbox.enqueue(record)
        :ignore -> :ok
      end
    end
  end

  defp emit_command_alert(event) do
    decision_id = value(event, :decision_id)
    issue = value(event, :issue_identifier)
    kind = if event_topic(event) == "executor.decision.deferred", do: "deferred", else: "requested"
    title = value(event, :title)

    message =
      "Executor Command #{decision_id} awaits you (ticket ##{issue})" <>
        if(is_binary(title) and title != "", do: ": #{truncate(title, 80)}", else: "")

    Alerts.emit_custom(
      "executor.command.#{kind}",
      message,
      issue: issue,
      reason: "executor.decision.#{kind} for decision #{decision_id} (ticket ##{issue})",
      needs_attention: true,
      severity: "warning"
    )
  rescue
    error ->
      Logger.error("aiur_executor_listener phase=alert_failed topic=#{event_topic(event)} error=#{Exception.message(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.error("aiur_executor_listener phase=alert_exit topic=#{event_topic(event)} reason=#{inspect(reason)}")
      :ok
  end

  defp health(patterns) do
    count = Enum.count(patterns, &bound?/1)

    cond do
      count == 0 -> :absent
      count == length(patterns) -> :present
      true -> :degraded
    end
  end

  defp maybe_report_health(previous, current, _patterns) when previous == current, do: :ok
  defp maybe_report_health(nil, :present, _patterns), do: :ok

  defp maybe_report_health(_previous, :present, _patterns) do
    safe_health_alert("executor.bindings.incomplete.resolved", "Executor wake bindings recovered.", false)
  end

  defp maybe_report_health(_previous, health, patterns) when health in [:degraded, :absent] do
    bound = MapSet.new(safe_bindings(self()))
    missing = Enum.reject(patterns, &MapSet.member?(bound, &1))

    safe_health_alert(
      "executor.bindings.incomplete",
      "Executor wake bindings incomplete; missing: #{Enum.join(missing, ", ")}",
      true
    )
  end

  defp safe_health_alert(name, message, needs_attention?) do
    if alerting_enabled?() do
      alert_fun = Application.get_env(:aiur, :executor_listener_health_alert_fun, &Alerts.emit_custom/3)

      alert_fun.(name, message,
        reason: "executor wake binding health changed",
        needs_attention: needs_attention?,
        severity: if(needs_attention?, do: "warning", else: "info")
      )
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp safe_bindings(pid) do
    Exchange.bindings_for(pid)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp event_topic(event), do: value(event, :topic)
  defp event_id(event), do: value(event, :id)
  defp executor_topic?(event), do: is_binary(event_topic(event)) and String.starts_with?(event_topic(event), "executor.")
  defp command_topic?(event), do: event_topic(event) in @command_topics
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp alerting_enabled?, do: Application.get_env(:aiur, :executor_listener_alerting?, true)

  # Recording is unconditional; raising a needs-attention Command alert is not.
  # A Command alert asks a *human* to answer something, and a stale one cannot
  # yet be retired (#2099) — nine already sit open on this daemon. Firing one on
  # every unattended run would industrialise that false signal, so the alert
  # stays bound to an Executor-owned run while the underlying record is written
  # either way and remains replayable by a late arrival.
  defp command_alerting_enabled? do
    alerting_enabled?() and
      Application.get_env(:aiur, :executor_command_alerts?, Application.get_env(:aiur, :executor_mode, false))
  end

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  # Tests pin the interval to :infinity to keep the resubscribe timer from
  # firing mid-assertion (#2039).
  defp schedule_resubscribe(:infinity), do: :ok

  defp schedule_resubscribe(interval) when is_integer(interval) and interval > 0 do
    Process.send_after(self(), :resubscribe, interval)
    :ok
  end

  defp read_watermark do
    case JsonStore.read(watermark_path()) do
      {:ok, %{"last_seen_event_id" => id}} when is_integer(id) and id > 0 -> id
      {:ok, %{last_seen_event_id: id}} when is_integer(id) and id > 0 -> id
      _ -> 0
    end
  end

  defp advance_watermark(id) do
    JsonStore.write!(watermark_path(), %{"last_seen_event_id" => id})
  end

  defp watermark_path, do: StatePaths.watermark_path()

  defp log_delivery_failure(event, error) do
    Logger.error("aiur_executor_listener phase=delivery_failed topic=#{inspect(event_topic(event))} id=#{inspect(event_id(event))} error=#{inspect(error)}")
  end
end
