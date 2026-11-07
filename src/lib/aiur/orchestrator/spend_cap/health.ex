defmodule Aiur.Orchestrator.SpendCap.Health do
  @moduledoc false
  # An unhealthy spend-cap store skips every tracked ticket, which empties the ready set and
  # silences capacity-starvation alerts. So each cause raises its own alert and retries with
  # backoff until the store recovers without a restart (#7755).

  require Logger

  alias Aiur.Orchestrator.SpendCap.Persistence

  @topic "system.spend_cap.unavailable"
  # Reported cause when several faults overlap.
  @order [:load, :persistence, :subscription]

  @spec status(%{faults: map()}) :: :healthy | {:unavailable, atom()}
  def status(%{faults: faults}) do
    case Enum.find_value(@order, &Map.get(faults, &1)) do
      nil -> :healthy
      reason -> {:unavailable, reason}
    end
  end

  @spec fault(map(), :load | :persistence | :subscription, atom()) :: map()
  def fault(state, kind, reason), do: state |> put_fault(kind, reason) |> settle()

  @spec clear(map(), :load | :persistence | :subscription) :: map()
  def clear(state, kind) do
    if Map.has_key?(state.faults, kind), do: state |> drop_fault(kind) |> settle(), else: state
  end

  @doc "Retry every outstanding fault once; reschedules with backoff while any remains."
  @spec retry(map()) :: map()
  def retry(state) do
    state = %{state | health_retry_scheduled?: false}

    @order
    |> Enum.filter(&Map.has_key?(state.faults, &1))
    |> Enum.reduce(state, &repair(&2, &1))
    |> settle()
  end

  @spec sync_table(map()) :: :ok
  def sync_table(state) do
    :ets.delete_all_objects(state.table)
    :ets.insert(state.table, {:health, state.health})
    Enum.each(state.records, fn {key, record} -> :ets.insert(state.table, {key, record.state}) end)
    :ok
  end

  defp repair(state, :load) do
    case Persistence.load(state.load_opts, state.repository) do
      {:ok, path, records, writer} -> drop_fault(%{state | path: path, records: records, writer: writer}, :load)
      {:error, reason, _path, _writer} -> put_fault(state, :load, reason)
    end
  end

  defp repair(state, :persistence) do
    case Persistence.write(state.path, state.repository, state.records, state.writer, state.sync_fun) do
      :ok -> drop_fault(state, :persistence)
      {:error, reason} -> put_fault(state, :persistence, reason)
    end
  end

  # ponytail: re-runs both subscriptions, so a half-succeeded first attempt can double the
  # usage subscription; duplicate refresh messages are debounced, so it is harmless.
  defp repair(state, :subscription) do
    with :ok <- safe_call(state.subscribe_fun),
         :ok <- safe_call(state.running_subscribe_fun) do
      drop_fault(state, :subscription)
    else
      reason ->
        Logger.warning("spend-cap re-subscription failed reason=#{inspect(reason)}")
        state
    end
  end

  defp put_fault(state, kind, reason), do: Map.update!(state, :faults, &Map.put(&1, kind, reason))
  defp drop_fault(state, kind), do: Map.update!(state, :faults, &Map.delete(&1, kind))

  defp settle(state) do
    state = %{state | health: status(state)}
    sync_table(state)
    state |> schedule_retry() |> sync_alert()
  end

  defp schedule_retry(%{health: :healthy} = state), do: %{state | health_retry_attempt: 0}

  defp schedule_retry(%{health_retry_scheduled?: false} = state) do
    if configured?(state) do
      delay = min(state.retry_ms * Integer.pow(2, state.health_retry_attempt), state.retry_max_ms)
      Process.send_after(self(), :retry_spend_cap_health, delay)
      %{state | health_retry_scheduled?: true, health_retry_attempt: state.health_retry_attempt + 1}
    else
      state
    end
  end

  defp schedule_retry(state), do: state

  defp sync_alert(%{health: {:unavailable, reason}, health_alerted?: false} = state) do
    if configured?(state) do
      emit(state, @topic, true,
        message: "Spend-cap store is unavailable (cause: #{reason}); dispatch admits no tracked ticket.",
        reason:
          "The spend-cap store reports #{reason}. Every ticket with a tracker identity leaves the ready set, " <>
            "which also silences capacity-starvation alerts. Aiur retries with backoff and resolves this alert on recovery.",
        severity: "warning",
        needs_attention: true
      )
    else
      state
    end
  end

  defp sync_alert(%{health: :healthy, health_alerted?: true} = state) do
    emit(state, @topic <> ".resolved", false,
      message: "Spend-cap store recovered; dispatch admission resumed.",
      reason: "The spend-cap store is healthy again.",
      severity: "info",
      needs_attention: false
    )
  end

  defp sync_alert(state), do: state

  defp emit(state, topic, alerted?, opts) do
    case safe_call(fn -> state.alert_fun.(topic, opts) end) do
      :ok ->
        %{state | health_alerted?: alerted?}

      other ->
        Logger.warning("spend-cap health alert failed topic=#{topic} reason=#{inspect(other)}")
        state
    end
  end

  # Without a repository there is no store to recover; that is configuration, not an outage.
  defp configured?(state), do: is_binary(state.repository) and state.repository != ""

  defp safe_call(fun) do
    fun.()
  rescue
    error -> {:error, {:exception, error}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
