defmodule Aiur.Claude.NotificationPolicy do
  @moduledoc false

  @limit_statuses [429, "429"]
  @limit_types ["rate_limit_error", "rate_limit"]

  @spec usage_limit_exhausted?(term()) :: boolean()
  def usage_limit_exhausted?(payload) when is_map(payload) do
    Enum.any?(find_values(payload, ["status", :status, "status_code", :status_code, "api_error_status", :api_error_status]), &(&1 in @limit_statuses)) or
      Enum.any?(find_values(payload, ["type", :type, "code", :code]), &(&1 in @limit_types))
  end

  def usage_limit_exhausted?(_payload), do: false

  @spec usage_limit_pause(term()) :: map()
  def usage_limit_pause(payload) do
    %{
      kind: :usage_limit_exhausted,
      reason: error_reason(payload),
      reset_hint: find_value(payload, ["reset_at", :reset_at, "resetAt", :resetAt])
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

  defp find_value(payload, keys), do: payload |> find_values(keys) |> List.first()

  defp find_values(payload, keys) when is_map(payload) do
    values = Enum.flat_map(keys, &(Map.get(payload, &1) |> List.wrap()))
    nested = payload |> Map.values() |> Enum.flat_map(&find_values(&1, keys))
    values ++ nested
  end

  defp find_values(payload, keys) when is_list(payload), do: Enum.flat_map(payload, &find_values(&1, keys))
  defp find_values(_payload, _keys), do: []
end
