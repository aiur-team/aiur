defmodule Aiur.Claude.NotificationPolicy do
  @moduledoc false

  @limit_markers [
    "rate limit",
    "rate_limit",
    "ratelimit",
    "usage limit",
    "usage_limit",
    "quota",
    "too many requests",
    "credit balance",
    "insufficient credits"
  ]

  @spec usage_limit_exhausted?(term()) :: boolean()
  def usage_limit_exhausted?(payload) when is_map(payload) do
    status = get_value(payload, ["status", :status, "status_code", :status_code, "code", :code])

    status in [429, "429", "rate_limit_error", "rate_limit"] or
      payload_text(payload) |> String.downcase() |> String.contains?(@limit_markers)
  end

  def usage_limit_exhausted?(_payload), do: false

  @spec usage_limit_pause(term()) :: map()
  def usage_limit_pause(payload) do
    %{
      kind: :usage_limit_exhausted,
      reason: error_reason(payload),
      reset_hint: get_value(payload, ["reset_at", :reset_at, "resetAt", :resetAt])
    }
  end

  @spec error_reason(term()) :: String.t()
  def error_reason(payload) do
    case payload_text(payload) do
      "" -> "Claude usage limit exhausted"
      text -> text
    end
  end

  defp payload_text(payload) do
    payload
    |> flatten_values()
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
  end

  defp flatten_values(value) when is_map(value), do: Enum.flat_map(value, fn {key, item} -> [key | flatten_values(item)] end)
  defp flatten_values(value) when is_list(value), do: Enum.flat_map(value, &flatten_values/1)
  defp flatten_values(value), do: [value]

  defp get_value(payload, keys) when is_map(payload) do
    Enum.find_value(keys, fn key -> Map.get(payload, key) end)
  end

  defp get_value(_payload, _keys), do: nil
end
