defmodule AiurWeb.RemainingMeter do
  @moduledoc "Shared conversion from known used percentages to remaining meter values."

  @spec percent(term()) :: 0..100 | nil
  def percent(used_percent) when is_number(used_percent) do
    100 - clamp(used_percent)
  end

  def percent(_unknown), do: nil

  @spec clamp(number()) :: 0..100
  def clamp(percent) when is_number(percent), do: percent |> max(0) |> min(100)
end
