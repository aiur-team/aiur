defmodule Aiur.Codex.EventNormalizer do
  @moduledoc """
  Normalizes Codex event payloads into canonical usage and rate-limit keys.
  """

  alias Aiur.Codex.RateLimits
  alias Aiur.Protocol.MapAccess
  alias Aiur.TokenUsage

  @spec normalize_event(map()) :: map()
  def normalize_event(event) when is_map(event) do
    event
    |> normalize_usage()
    |> normalize_rate_limits()
  end

  defp normalize_usage(event) do
    payloads = [
      event[:usage],
      Map.get(event, "usage"),
      event[:payload],
      Map.get(event, "payload"),
      event
    ]

    usage =
      Enum.find_value(payloads, &absolute_token_usage/1) ||
        Enum.find_value(payloads, &turn_completed_usage/1) ||
        Enum.find_value(payloads, &direct_token_map/1)

    Map.put(event, :usage, TokenUsage.canonicalize(usage))
  end

  defp normalize_rate_limits(event) do
    raw =
      find_rate_limits(event[:rate_limits]) ||
        find_rate_limits(Map.get(event, "rate_limits")) ||
        find_rate_limits(event[:payload]) ||
        find_rate_limits(Map.get(event, "payload")) ||
        find_rate_limits(event)

    Map.put(event, :rate_limits, raw)
  end

  defp absolute_token_usage(payload) when is_map(payload) do
    paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    Enum.find_value(paths, fn path ->
      value = MapAccess.dig(payload, path)
      if is_map(value) and TokenUsage.token_field?(value), do: value
    end)
  end

  defp absolute_token_usage(_), do: nil

  defp turn_completed_usage(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") || Map.get(payload, :usage) ||
          MapAccess.dig(payload, ["params", "usage"]) || MapAccess.dig(payload, [:params, :usage])

      if is_map(direct) and TokenUsage.token_field?(direct), do: direct
    end
  end

  defp turn_completed_usage(_), do: nil

  defp direct_token_map(payload) when is_map(payload) do
    if TokenUsage.token_field?(payload), do: payload
  end

  defp direct_token_map(_), do: nil

  defp find_rate_limits(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) -> direct
      rate_limits_map?(payload) -> payload
      true -> search_rate_limits(payload)
    end
  end

  defp find_rate_limits(_), do: nil

  defp search_rate_limits(payload) when is_map(payload) do
    Enum.find_value(Map.values(payload), fn
      value when is_map(value) -> find_rate_limits(value)
      _ -> nil
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    has_id =
      !is_nil(
        Map.get(payload, "limit_id") || Map.get(payload, :limit_id) ||
          Map.get(payload, "limit_name") || Map.get(payload, :limit_name)
      )

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    (has_id and has_buckets) or RateLimits.safe?(payload)
  end

  defp rate_limits_map?(_), do: false
end
