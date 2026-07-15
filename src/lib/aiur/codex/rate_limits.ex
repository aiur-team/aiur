defmodule Aiur.Codex.RateLimits do
  @moduledoc false

  @bucket_fields %{
    "limit" => :limit,
    "resetAt" => :resetAt,
    "reset_at" => :reset_at,
    "resetsAt" => :resetsAt,
    "used" => :used,
    "usedPercent" => :usedPercent,
    "windowDurationMins" => :windowDurationMins,
    "window_minutes" => :window_minutes
  }
  @top_level_fields %{
    "limited" => :limited,
    "resetAt" => :resetAt,
    "reset_at" => :reset_at,
    "resetsAt" => :resetsAt
  }
  @max_epoch_millis 4_102_444_800_000
  @max_iso_timestamp_bytes 64

  @spec from_notification(map()) :: map() | nil
  def from_notification(%{"params" => %{"rateLimits" => rate_limits}}) when is_map(rate_limits),
    do: redact(rate_limits)

  def from_notification(_payload), do: nil

  @doc "Whether a map is already the privacy-reduced rate-limit shape this module emits."
  @spec safe?(term()) :: boolean()
  def safe?(rate_limits) when is_map(rate_limits) do
    map_size(rate_limits) > 0 and redact(rate_limits) == rate_limits
  end

  def safe?(_rate_limits), do: false

  @spec redact(map()) :: map() | nil
  def redact(rate_limits) when is_map(rate_limits) do
    rate_limits
    |> safe_fields(@top_level_fields, &safe_top_level_value?/2)
    |> add_buckets(rate_limits)
    |> present_or_nil()
  end

  defp add_buckets(safe_limits, rate_limits) do
    Enum.reduce(["primary", "secondary", "hourly", "weekly", "monthly"], safe_limits, fn bucket, acc ->
      case get(rate_limits, bucket) do
        {:ok, value} when is_map(value) ->
          case value |> safe_fields(@bucket_fields, &safe_bucket_value?/2) |> present_or_nil() do
            nil -> acc
            safe_bucket -> Map.put(acc, bucket, safe_bucket)
          end

        _ ->
          acc
      end
    end)
  end

  defp safe_fields(values, fields, valid?) do
    Enum.reduce(fields, %{}, fn {name, atom_name}, acc ->
      case get(values, name, atom_name) do
        {:ok, value} ->
          case valid?.(name, value) do
            {:ok, safe_value} -> Map.put(acc, name, safe_value)
            :error -> acc
          end

        :error ->
          acc
      end
    end)
  end

  defp safe_top_level_value?("limited", value) when is_boolean(value), do: {:ok, value}
  defp safe_top_level_value?("limited", _value), do: :error
  defp safe_top_level_value?(_name, value), do: safe_reset_value(value)

  defp safe_bucket_value?(name, value) when name in ["usedPercent", "used", "limit", "windowDurationMins", "window_minutes"],
    do: safe_metric_value(value)

  defp safe_bucket_value?(_name, value), do: safe_reset_value(value)
  defp safe_metric_value(value) when is_number(value), do: {:ok, value}
  defp safe_metric_value(_value), do: :error

  defp safe_reset_value(value) when is_integer(value) and value >= 0 and value <= @max_epoch_millis, do: {:ok, value}

  defp safe_reset_value(value) when is_binary(value) and byte_size(value) <= @max_iso_timestamp_bytes do
    case DateTime.from_iso8601(value) do
      {:ok, reset_at, _offset} -> {:ok, DateTime.to_iso8601(reset_at)}
      _ -> :error
    end
  end

  defp safe_reset_value(_value), do: :error

  defp present_or_nil(map) when map_size(map) == 0, do: nil
  defp present_or_nil(map), do: map

  defp get(map, name, atom_name \\ nil) do
    case Map.fetch(map, name) do
      {:ok, _value} = result -> result
      :error when is_atom(atom_name) -> Map.fetch(map, atom_name)
      :error -> :error
    end
  end
end
