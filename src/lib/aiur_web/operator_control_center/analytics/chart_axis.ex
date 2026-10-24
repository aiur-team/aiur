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
end
