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
