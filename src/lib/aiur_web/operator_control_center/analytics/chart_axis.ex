defmodule AiurWeb.OperatorControlCenter.Analytics.ChartAxis do
  @moduledoc false

  @spec nice_axis(number(), pos_integer()) :: {number(), [number()]}
  def nice_axis(maximum, tick_count), do: nice_axis(maximum, tick_count, 0)

  @spec nice_axis(number(), pos_integer(), number()) :: {number(), [number()]}
  def nice_axis(maximum, tick_count, minimum_step) do
    raw_step = maximum / tick_count
    magnitude = :math.pow(10, :math.floor(:math.log10(raw_step)))
    step = Enum.find([1, 2, 5, 10], &(raw_step <= &1 * magnitude)) * magnitude
    step = max(step, minimum_step)
    axis_max = :math.ceil(maximum / step) * step
    intervals = round(axis_max / step)

    {axis_max, Enum.map(0..intervals, &(&1 * step))}
  end

  @spec elapsed(number(), :seconds | :minutes) :: String.t()
  def elapsed(ms, :seconds) do
    seconds = max(div(round(ms), 1000), 0)
    if seconds < 60, do: "#{seconds}s", else: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end

  def elapsed(ms, :minutes) do
    total_min = div(round(ms / 1000), 60)
    h = div(total_min, 60)
    m = rem(total_min, 60)

    cond do
      h > 0 and m > 0 -> "#{h}h #{m}m"
      h > 0 -> "#{h}h"
      true -> "#{total_min}m"
    end
  end

  @minimum_domain_ms 1_000

  @spec normalize_time_domain(map(), term()) :: {integer(), integer()} | nil
  def normalize_time_domain(%{window: %{start_ms: start_ms, end_ms: end_ms}}, {left, right}) do
    with t0 when is_integer(t0) <- integer(left),
         t1 when is_integer(t1) <- integer(right),
         lo = max(min(t0, t1), start_ms),
         hi = min(max(t0, t1), end_ms),
         true <- hi - lo >= minimum_domain_ms(start_ms, end_ms) do
      if lo == start_ms and hi == end_ms, do: nil, else: {lo, hi}
    else
      _invalid -> nil
    end
  end

  def normalize_time_domain(_model, _domain), do: nil

  @spec time_domain_label(map(), {integer(), integer()}) :: String.t()
  def time_domain_label(%{window: window}, {t0, t1}) do
    origin = Map.get(window, :axis_origin_ms, window.start_ms)
    "#{elapsed(t0 - origin)}–#{elapsed(t1 - origin)}"
  end

  defp minimum_domain_ms(start_ms, end_ms), do: max(@minimum_domain_ms, div(end_ms - start_ms, 100))

  defp integer(value) when is_integer(value), do: value
  defp integer(value) when is_float(value), do: round(value)

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _invalid -> nil
    end
  end

  defp integer(_value), do: nil

  defp elapsed(ms) do
    minutes = ms |> max(0) |> div(60_000)
    hours = div(minutes, 60)
    remainder = rem(minutes, 60)

    cond do
      hours > 0 and remainder > 0 -> "#{hours}h #{remainder}m"
      hours > 0 -> "#{hours}h"
      true -> "#{remainder}m"
    end
  end
end
