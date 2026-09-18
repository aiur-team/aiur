defmodule Aiur.Claude.ResetTime do
  @moduledoc "Parses the local clock and IANA zone in Claude's session-limit banner."

  @clock ~r/\A(?<hour>\d{1,2}):(?<minute>\d{2})(?<period>am|pm)\s+\((?<zone>[^()]+)\)\z/i

  @spec parse(term(), DateTime.t()) :: String.t() | nil
  def parse(hint, now \\ DateTime.utc_now())

  def parse(hint, now) when is_binary(hint) do
    case DateTime.from_iso8601(hint) do
      {:ok, time, _offset} -> if DateTime.compare(time, now) == :lt, do: nil, else: DateTime.to_iso8601(time)
      _ -> parse_clock(hint, now)
    end
  end

  def parse(_hint, _now), do: nil

  defp parse_clock(hint, now) do
    with %{"hour" => hour, "minute" => minute, "period" => period, "zone" => zone} <- Regex.named_captures(@clock, hint),
         hour when hour in 1..12 <- String.to_integer(hour),
         minute when minute in 0..59 <- String.to_integer(minute),
         {:ok, local_now} <- DateTime.shift_zone(now, zone, Tz.TimeZoneDatabase),
         {:ok, clock} <- Time.new(rem(hour, 12) + if(String.downcase(period) == "pm", do: 12, else: 0), minute, 0) do
      # Find the next occurrence in local calendar time, not "now + 24h":
      # midnight and DST can both change the UTC date/offset.
      0..1
      |> Enum.flat_map(fn days ->
        local_now |> DateTime.to_date() |> Date.add(days) |> candidates(clock, zone)
      end)
      |> Enum.find(&(DateTime.compare(&1, now) != :lt))
      |> to_iso8601()
    else
      _ -> nil
    end
  end

  defp candidates(date, clock, zone) do
    case DateTime.new(date, clock, zone, Tz.TimeZoneDatabase) do
      {:ok, time} -> [time]
      {:ambiguous, first, second} -> [first, second]
      {:gap, _before, after_gap} -> [after_gap]
      {:error, _reason} -> []
    end
  end

  defp to_iso8601(nil), do: nil
  defp to_iso8601(time), do: time |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()
end
