defmodule Aiur.Codex.ResetTime do
  @moduledoc """
  Parses the reset time in a Codex usage-limit refusal into a UTC timestamp.

  Codex CLI 0.154.0 ends a refused turn with "try again at Sep 21st, 2026
  6:26 PM", or only "6:26 PM" when the reset is later the same day. The CLI
  formats this time in the local zone of the host that runs the app-server and
  does not name the zone. By default Aiur reads it in its own local zone
  (`:local`, from the Erlang runtime's local time rules).
  `agent.codex.reset_time_zone` sets an IANA zone instead, for example the
  zone of a remote worker host.

  The text has minute precision and Codex truncates the seconds, so the real
  reset can be up to a minute later. The parsed time is rounded up to the end
  of its minute: resuming early only meets the same refusal again. Prefer the
  numeric `resetsAt` from `account/rateLimits` when Aiur has one.

  A time with no date is its next occurrence. A date with no year is its next
  occurrence too. A time that passed only recently (two hours for a clock
  time, a day for a yearless date) keeps its past value, so the worker resumes
  now instead of waiting a day or a year. Other past times and text that is
  not a reset time return `nil`, so recovery needs a fresh provider
  observation.
  """

  # How long a parsed time can be in the past and still name the reset that
  # just passed, rather than one a day or a year later. A clock time alone
  # rolls to tomorrow after two hours. A yearless date never rolls a year for a
  # date that passed within the last day. A full date never rolls.
  @recent_past_clock_seconds 2 * 60 * 60
  @recent_past_date_seconds 24 * 60 * 60

  @clock ~r/\A(?:(?<month>[A-Za-z]{3,9})\.?\s+(?<day>\d{1,2})(?:st|nd|rd|th)?,?\s+(?:(?<year>\d{4}),?\s+)?)?(?<hour>\d{1,2}):(?<minute>\d{2})\s*(?<period>[AP]M)\z/i

  @months %{
    "jan" => 1,
    "feb" => 2,
    "mar" => 3,
    "apr" => 4,
    "may" => 5,
    "jun" => 6,
    "jul" => 7,
    "aug" => 8,
    "sep" => 9,
    "oct" => 10,
    "nov" => 11,
    "dec" => 12
  }

  @type zone :: :local | String.t()

  @spec parse(term(), DateTime.t(), zone()) :: String.t() | nil
  def parse(hint, now \\ DateTime.utc_now(), zone \\ :local)

  def parse(hint, now, zone) when is_binary(hint) do
    hint = String.trim(hint)

    case DateTime.from_iso8601(hint) do
      {:ok, time, _offset} -> future_iso8601(time, now)
      _ -> parse_clock(hint, now, zone)
    end
  end

  def parse(_hint, _now, _zone), do: nil

  defp parse_clock(hint, now, zone) do
    with %{} = captures <- Regex.named_captures(@clock, hint),
         {:ok, clock} <- clock(captures),
         {:ok, local_today} <- local_date(now, zone),
         {:ok, dates} <- candidate_dates(captures, local_today) do
      earliest = DateTime.add(now, -recent_past_seconds(captures))

      dates
      |> Enum.map(&(&1 |> to_utc(clock, zone) |> end_of_minute()))
      |> Enum.find(&(is_struct(&1, DateTime) and DateTime.compare(&1, earliest) != :lt))
      |> to_iso8601()
    else
      _ -> nil
    end
  end

  defp recent_past_seconds(%{"month" => ""}), do: @recent_past_clock_seconds
  defp recent_past_seconds(%{"year" => ""}), do: @recent_past_date_seconds
  defp recent_past_seconds(_captures), do: 0

  defp clock(%{"hour" => hour, "minute" => minute, "period" => period}) do
    with hour when hour in 1..12 <- String.to_integer(hour),
         minute when minute in 0..59 <- String.to_integer(minute) do
      offset = if String.upcase(period) == "PM", do: 12, else: 0
      Time.new(rem(hour, 12) + offset, minute, 0)
    else
      _ -> :error
    end
  end

  # A clock time alone is yesterday, today or tomorrow; a month and day without
  # a year is last year, this year or next year; a full date is exactly that
  # date. The first
  # candidate that is not before the recent-past bound wins, so a yearless date
  # that passed a moment ago stays in this year.
  defp candidate_dates(%{"month" => ""}, today), do: {:ok, [Date.add(today, -1), today, Date.add(today, 1)]}

  defp candidate_dates(%{"month" => month, "day" => day, "year" => year}, today) do
    case month(month) do
      {:ok, month} ->
        day = String.to_integer(day)
        years = if year == "", do: [today.year - 1, today.year, today.year + 1], else: [String.to_integer(year)]
        dates = Enum.flat_map(years, &valid_date(&1, month, day))
        if dates == [], do: :error, else: {:ok, dates}

      :error ->
        :error
    end
  end

  defp valid_date(year, month, day) do
    case Date.new(year, month, day) do
      {:ok, date} -> [date]
      _ -> []
    end
  end

  defp month(name) do
    case Map.fetch(@months, name |> String.downcase() |> String.slice(0, 3)) do
      {:ok, month} -> {:ok, month}
      :error -> :error
    end
  end

  defp local_date(now, :local) do
    {date, _time} = now |> DateTime.to_naive() |> NaiveDateTime.to_erl() |> :calendar.universal_time_to_local_time()
    Date.from_erl(date)
  end

  defp local_date(now, zone) when is_binary(zone) do
    case DateTime.shift_zone(now, zone, Tz.TimeZoneDatabase) do
      {:ok, local_now} -> {:ok, DateTime.to_date(local_now)}
      _ -> :error
    end
  end

  defp local_date(_now, _zone), do: :error

  # Near a DST change, prefer the later instant: resuming early only meets the
  # same refusal again.
  defp to_utc(date, clock, :local) do
    {:ok, naive} = NaiveDateTime.new(date, clock)

    case :calendar.local_time_to_universal_time_dst(NaiveDateTime.to_erl(naive)) do
      [] -> naive |> NaiveDateTime.add(3600) |> local_naive_to_utc()
      instants -> instants |> List.last() |> erl_to_utc()
    end
  end

  defp to_utc(date, clock, zone) do
    case DateTime.new(date, clock, zone, Tz.TimeZoneDatabase) do
      {:ok, time} -> time
      {:ambiguous, _first, second} -> second
      {:gap, _before, after_gap} -> after_gap
      {:error, _reason} -> nil
    end
  end

  defp local_naive_to_utc(naive) do
    case :calendar.local_time_to_universal_time_dst(NaiveDateTime.to_erl(naive)) do
      [] -> nil
      instants -> instants |> List.last() |> erl_to_utc()
    end
  end

  # The text drops the seconds of the real reset; resume at the end of the
  # printed minute, never inside it.
  defp end_of_minute(%DateTime{} = time), do: DateTime.add(time, 60, :second)
  defp end_of_minute(nil), do: nil

  defp erl_to_utc(erl), do: erl |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC")

  defp future_iso8601(time, now) do
    if DateTime.compare(time, now) == :lt, do: nil, else: to_iso8601(time)
  end

  defp to_iso8601(nil), do: nil
  defp to_iso8601(time), do: time |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()
end
