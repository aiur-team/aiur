defmodule Aiur.Usage.PriceTable.Window do
  @moduledoc """
  Peak/off-peak billing window resolution for the price table.

  Peak windows are **not API-discoverable** — no provider exposes a tier
  indicator, so the boundaries can only be a hand-maintained schedule compared
  against the clock (see `Aiur.Config.Schema.PricingPolicy`). The schedule is
  **data** in `Aiur.Usage.PriceTable.Data`; this module stays generic so an
  arbitrary schedule can be unit-tested. It turns a UTC occurrence time plus a
  schedule map into the window in force, resolves the window a call prices
  under, and finds the next boundary where the window flips.

  When the schedule is missing, malformed, or unparseable, `classify/2` returns
  `:unknown` and `resolve/2` maps it to `:peak` — the conservative rate, so a
  call is never priced cheaper than it was. Routing treats `:unknown` the same
  way (see the `avoid_peak_pricing` policy in `Aiur.CodingAgent`): it fails
  toward **not** rerouting.
  """

  alias Aiur.Usage.PriceTable.Data

  @type window :: :peak | :off_peak
  @type schedule :: map()

  # `Date.day_of_week/1` numbers: Monday = 1 ... Saturday = 6, Sunday = 7.
  @weekend_weekdays [6, 7]
  @default_horizon_days 8

  @doc """
  The window a schedule maps a UTC occurrence time to, or `:unknown` when the
  schedule is missing, malformed, or unparseable.

  The schedule is applied in Beijing time (the offset lives in the schedule
  data, so this module stays timezone-agnostic): all of Saturday and Sunday
  Beijing time on/after the weekend rule's effective date is off-peak; on any
  other day the weekday peak windows (expressed in UTC) decide.
  """
  @spec classify(DateTime.t(), schedule()) :: window() | :unknown
  def classify(%DateTime{} = occurred_at, schedule) when is_map(schedule) do
    with {:ok, offset_hours} <- offset_hours(schedule),
         {:ok, weekday_windows} <- weekday_peak_windows(schedule),
         {:ok, weekend_effective} <- weekend_off_peak_effective(schedule) do
      window_at(occurred_at, shift(occurred_at, offset_hours), weekday_windows, weekend_effective)
    else
      _ -> :unknown
    end
  end

  def classify(_occurred_at, _schedule), do: :unknown

  defp window_at(occurred_at, beijing, weekday_windows, weekend_effective) do
    cond do
      weekend_off_peak?(beijing, weekend_effective) -> :off_peak
      in_peak_window?(DateTime.to_time(occurred_at), weekday_windows) -> :peak
      true -> :off_peak
    end
  end

  @doc """
  The next UTC instant after `now` at which the in-force window changes, and
  the window that begins there. A full week plus margin is scanned, which is
  always enough because the daily peak windows repeat weekly.

  Returns `{:error, :unknown_window}` when the schedule is unparseable and
  `{:error, :no_boundary_in_horizon}` when no boundary falls inside the scan
  horizon (impossible for a schedule with valid daily peak windows).
  """
  @spec next_boundary(DateTime.t(), schedule()) ::
          {:ok, DateTime.t(), window()} | {:error, atom()}
  def next_boundary(%DateTime{} = now, schedule) when is_map(schedule) do
    case classify(now, schedule) do
      :unknown ->
        {:error, :unknown_window}

      _current ->
        case first_change(now, schedule) do
          nil -> {:error, :no_boundary_in_horizon}
          boundary -> {:ok, boundary, classify(boundary, schedule)}
        end
    end
  end

  def next_boundary(_now, _schedule), do: {:error, :unknown_window}

  @doc """
  The `pricing_window` a call from `provider` at `occurred_at` prices under.

  `nil` when the provider has no windowed schedule. Unknown windows — a
  missing occurrence time or an unparseable schedule — resolve to `:peak`, the
  conservative rate that can never hide overspend.
  """
  @spec resolve(atom(), DateTime.t() | nil) :: window() | nil
  def resolve(provider, occurred_at) do
    case Data.window_schedule(provider) do
      nil ->
        nil

      schedule ->
        case occurred_at do
          %DateTime{} = time -> unknown_as_peak(classify(time, schedule))
          _occurred_at_missing -> :peak
        end
    end
  end

  defp unknown_as_peak(:unknown), do: :peak
  defp unknown_as_peak(window), do: window

  # Beijing time, applied as a fixed shift of the UTC instant. The offset is a
  # named constant in `Data` carrying the no-DST justification; shifting the
  # instant and reading its calendar date/weekday is exactly the Beijing
  # calendar day the call landed on.
  defp shift(%DateTime{} = utc, offset_hours) do
    DateTime.add(utc, offset_hours * 3600, :second)
  end

  defp weekend_off_peak?(beijing, weekend_effective) do
    Date.compare(DateTime.to_date(beijing), weekend_effective) != :lt and
      Date.day_of_week(DateTime.to_date(beijing)) in @weekend_weekdays
  end

  defp in_peak_window?(utc_time, windows) do
    Enum.any?(windows, fn {start, finish} ->
      Time.compare(start, utc_time) in [:lt, :eq] and Time.compare(utc_time, finish) == :lt
    end)
  end

  defp first_change(now, schedule) do
    start_date = DateTime.to_date(now)

    now
    |> future_candidates(start_date, schedule)
    # `Enum.min/1` compares DateTime structs by term order, not chronology;
    # compare by unix seconds so the earliest future boundary wins.
    |> Enum.min_by(&DateTime.to_unix/1, fn -> nil end)
  end

  defp future_candidates(now, start_date, schedule) do
    for day_offset <- 0..@default_horizon_days,
        date = Date.add(start_date, day_offset),
        time <- candidate_times(),
        boundary = DateTime.new!(date, time, "Etc/UTC"),
        DateTime.compare(boundary, now) == :gt,
        classify(boundary, schedule) != classify(DateTime.add(boundary, -1, :second), schedule) do
      boundary
    end
  end

  defp candidate_times do
    # The daily peak-window boundaries, plus 16:00 UTC = 00:00 Beijing (the
    # weekday/weekend calendar boundary). Under the current schedule the
    # 16:00 UTC instants never flip the *rate* (both sides are off-peak), but
    # they are retained so a future weekend-rule change cannot silently extend
    # the scan past a real boundary.
    [~T[01:00:00], ~T[04:00:00], ~T[06:00:00], ~T[10:00:00], ~T[16:00:00]]
  end

  defp offset_hours(schedule) do
    case Map.get(schedule, :utc_offset_hours) do
      offset when is_integer(offset) -> {:ok, offset}
      _ -> :error
    end
  end

  defp weekday_peak_windows(schedule) do
    case Map.get(schedule, :weekday_peak_windows_utc) do
      windows when is_list(windows) and windows != [] ->
        if Enum.all?(windows, &valid_window?/1), do: {:ok, windows}, else: :error

      _ ->
        :error
    end
  end

  defp valid_window?({%Time{} = start, %Time{} = finish}), do: Time.compare(start, finish) == :lt
  defp valid_window?(_), do: false

  defp weekend_off_peak_effective(schedule) do
    case Map.get(schedule, :weekend_off_peak_effective) do
      %Date{} = date -> {:ok, date}
      _ -> :error
    end
  end
end
