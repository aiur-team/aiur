defmodule AiurPushRelay.Config do
  @moduledoc "Validates the topic allowlist and uniform fallback pins before starting children."

  def load(env \\ &System.get_env/1) do
    topics = String.split(env.("AIUR_RELAY_APP_TOPICS") || "", ",", trim: true)

    Enum.reduce_while(topics, {:ok, %{}}, fn topic, {:ok, pins} ->
      case fallback(env.(fallback_key(topic))) do
        {:ok, pin} -> {:cont, {:ok, Map.put(pins, topic, pin)}}
        :error -> {:halt, {:error, {:missing_fallback, topic}}}
      end
    end)
    |> nonempty()
  end

  def abuse_limits(env \\ &System.get_env/1) do
    with {:ok, send_per_hour} <- positive_integer(env, "AIUR_RELAY_SEND_PER_HOUR", 60),
         {:ok, send_burst} <- positive_integer(env, "AIUR_RELAY_SEND_BURST", 10),
         {:ok, handles_per_ip_hour} <- positive_integer(env, "AIUR_RELAY_HANDLES_PER_IP_HOUR", 20),
         {:ok, log_retention_days} <- retention_days(env) do
      {:ok,
       %{
         send: %{per_hour: send_per_hour, burst: send_burst},
         handles_per_ip_hour: handles_per_ip_hour,
         log_retention_days: log_retention_days
       }}
    end
  end

  defp positive_integer(env, key, default) do
    case env.(key) do
      nil -> {:ok, default}
      value -> parse_positive(value)
    end
  end

  defp parse_positive(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> {:error, :invalid_rate_limit}
    end
  end

  defp retention_days(env) do
    case env.("AIUR_RELAY_LOG_RETENTION_DAYS") do
      nil ->
        {:ok, 7}

      value ->
        case Integer.parse(value) do
          {days, ""} when days in 1..7 -> {:ok, days}
          {days, ""} when days > 7 -> {:error, :retention_too_long}
          _ -> {:error, :invalid_retention_days}
        end
    end
  end

  def fallback_key(topic) do
    "AIUR_RELAY_FALLBACK_" <> String.replace(String.upcase(topic), ~r/[^A-Z0-9]/, "_")
  end

  defp fallback(value) when is_binary(value) do
    with {:ok, %{"title" => title, "body" => body}} <- Jason.decode(value),
         true <- is_binary(title) and is_binary(body),
         true <- byte_size(title) + byte_size(body) <= 200 do
      {:ok, %{"title" => title, "body" => body}}
    else
      _ -> :error
    end
  end

  defp fallback(_), do: :error
  defp nonempty({:ok, pins}) when map_size(pins) == 0, do: {:error, :missing_app_topics}
  defp nonempty(result), do: result
end
