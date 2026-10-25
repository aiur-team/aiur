defmodule AiurWeb.Build.UsageFacts do
  @moduledoc false
  alias Aiur.ModelAvailability
  @durable_windows ~w(hourly weekly monthly)

  @spec durable(atom(), Path.t()) :: map() | nil
  def durable(provider, path \\ ModelAvailability.path()) do
    with %{"backends" => backends} <- ModelAvailability.load(path),
         %{} = entry when map_size(entry) > 0 <- Map.get(backends, Atom.to_string(provider)),
         %{percent: percent} <- durable_percent_entry(entry) do
      %{
        percent: percent,
        observed_at: parse_observed_at(Map.get(entry, "observed_at"))
      }
    else
      _ -> nil
    end
  end

  defp parse_observed_at(%DateTime{} = value), do: value

  defp parse_observed_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_observed_at(_value), do: nil

  defp durable_percent_entry(entry) do
    entry
    |> Map.take(@durable_windows)
    |> Enum.map(fn {_window, %{"used" => used, "limit" => limit}} when is_number(used) and is_number(limit) and limit > 0 ->
      %{percent: min(round(used / limit * 100), 100)}
    end)
    |> Enum.max_by(& &1.percent, fn -> nil end)
  end

  @spec elevenlabs_failure(term()) :: String.t()
  def elevenlabs_failure(:authentication), do: "the API key was rejected"
  def elevenlabs_failure(:rate_limited), do: "rate limited by ElevenLabs"
  def elevenlabs_failure(:provider_error), do: "ElevenLabs returned an error"
  def elevenlabs_failure(:transport), do: "ElevenLabs could not be reached"
  def elevenlabs_failure(:malformed), do: "the response could not be read"
  def elevenlabs_failure(_failure), do: "the quota could not be read"
  @spec compact_number(integer()) :: String.t()
  def compact_number(number) when is_integer(number) and number >= 1_000_000, do: "#{Float.round(number / 1_000_000, 2)}M"
  def compact_number(number) when is_integer(number) and number >= 1_000, do: "#{Float.round(number / 1_000, 1)}K"
  def compact_number(number) when is_integer(number), do: Integer.to_string(number)
end
