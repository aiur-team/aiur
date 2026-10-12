defmodule AiurWeb.OperatorControlCenter.RunSummaryStrip.Meters do
  @moduledoc false

  @seconds_per_day 86_400
  @seconds_per_hour 3_600

  @spec currency_amount(String.t(), String.t()) :: String.t()
  def currency_amount("USD", amount), do: "$#{amount}"
  def currency_amount(currency, amount), do: "#{amount} #{currency}"

  @spec format_used_percent(number()) :: String.t()
  def format_used_percent(percent) when is_number(percent) do
    percent = percent |> max(0) |> min(100)
    rounded = Float.round(percent, 1)

    if rounded == trunc(rounded) do
      Integer.to_string(trunc(rounded))
    else
      :erlang.float_to_binary(rounded, decimals: 1)
    end
  end

  @spec reset_text(DateTime.t() | nil, DateTime.t()) :: String.t()
  def reset_text(%DateTime{} = reset, %DateTime{} = now) do
    seconds = DateTime.diff(reset, now, :second)
    if seconds > 0, do: "resets in #{duration(seconds)}", else: "reset time passed"
  end

  def reset_text(_reset, _now), do: "reset unavailable"
  # Days once there are any: a weekly window reading "167h 59m" makes the reader
  # divide to learn it is a week away.
  defp duration(seconds) when seconds < @seconds_per_hour, do: "#{max(div(seconds, 60), 1)}m"

  defp duration(seconds) when seconds < @seconds_per_day do
    "#{div(seconds, @seconds_per_hour)}h #{div(rem(seconds, @seconds_per_hour), 60)}m"
  end

  defp duration(seconds) do
    "#{div(seconds, @seconds_per_day)}d #{div(rem(seconds, @seconds_per_day), @seconds_per_hour)}h #{div(rem(seconds, @seconds_per_hour), 60)}m"
  end
end
