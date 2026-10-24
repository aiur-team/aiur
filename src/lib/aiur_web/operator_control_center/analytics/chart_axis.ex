defmodule AiurWeb.OperatorControlCenter.Analytics.ChartAxis do
  @moduledoc false

  @spec nice_axis_max(number(), pos_integer()) :: number()
  def nice_axis_max(maximum, tick_count) do
    magnitude = :math.pow(10, :math.floor(:math.log10(maximum / tick_count)))
    step = Enum.find([1, 2, 5, 10], &(maximum / tick_count / magnitude <= &1)) * magnitude
    :math.ceil(maximum / step) * step
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
