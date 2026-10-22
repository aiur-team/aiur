defmodule Aiur.Webhooks.DeliveryLogCeiling do
  @moduledoc false

  @default_low_watermark 0.9

  @spec low_watermark(keyword()) :: float()
  def low_watermark(opts) do
    case Keyword.get(opts, :eviction_low_watermark, @default_low_watermark) do
      value when is_float(value) and value > 0 and value < 1 -> value
      _other -> @default_low_watermark
    end
  end

  @spec target(pos_integer(), float()) :: pos_integer()
  def target(max_entries, low_watermark), do: max(1, trunc(max_entries * low_watermark))

  @spec sort_entries(map()) :: list()
  def sort_entries(entries), do: Enum.sort_by(entries, fn {_key, %{recorded_at: recorded_at}} -> recorded_at end)

  @spec enforce(map(), integer()) :: map()
  def enforce(state, now) do
    if map_size(state.entries) > state.max_entries do
      overflow = map_size(state.entries) - target(state.max_entries, state.eviction_low_watermark)
      entries = drop_oldest(state.entries, overflow, state.eviction_sort_fun)
      alert_overflow(%{state | entries: entries}, now)
    else
      state
    end
  end

  defp drop_oldest(entries, count, sort_fun) do
    dropped =
      sort_fun.(entries)
      |> Enum.take(count)
      |> Enum.map(fn {key, _entry} -> key end)

    Map.drop(entries, dropped)
  end

  defp alert_overflow(%{overflowed?: true} = state, _now), do: state

  defp alert_overflow(state, _now) do
    message = "Webhook delivery dedupe log exceeded #{state.max_entries} live entries; the oldest entries were evicted before their retention window expired and duplicate protection is degraded."
    metadata = [needs_attention: true, severity: "warning", reason: message]
    state.alert_fun.("webhook_delivery_log.ceiling_exceeded", message, metadata)
    %{state | overflowed?: true}
  rescue
    _error -> %{state | overflowed?: true}
  catch
    _kind, _reason -> %{state | overflowed?: true}
  end
end
