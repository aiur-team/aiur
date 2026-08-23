defmodule Mix.Tasks.Aiur.PricingWindow do
  use Mix.Task

  @shortdoc "Show the current peak/off-peak pricing window and next boundary"

  @moduledoc """
  # Peak/off-peak pricing window

  Prints which pricing window is currently in force (peak or off-peak), the
  next UTC boundary where the window flips, and how `avoid_peak_pricing`
  routing would treat the windowed provider right now.

      mix aiur.pricing_window

  Peak windows are not API-discoverable, so the schedule is the hand-maintained
  table in `Aiur.Usage.PriceTable.Data` compared against the clock by
  `Aiur.Usage.PriceTable.Window`. Prices report at the peak rate whenever the
  window cannot be determined, and `avoid_peak_pricing` routing never reroutes
  on an unknown window.
  """

  @requirements []

  alias Aiur.Usage.PriceTable.{Data, Window}

  @impl Mix.Task
  def run(_argv) do
    now = DateTime.utc_now()

    Data.window_schedule(:deepseek)
    |> render(now)
    |> Mix.shell().info()
  end

  @doc "Renders the current window, next boundary, and routing note from a pinned clock."
  @spec render(map() | nil, DateTime.t()) :: String.t()
  def render(nil, _now), do: "No provider currently declares a peak/off-peak window."

  def render(schedule, now) do
    case Window.next_boundary(now, schedule) do
      {:ok, boundary, next_window} ->
        [
          "DeepSeek peak/off-peak window (#{offset_label(schedule)}):",
          "  Current window: #{Window.classify(now, schedule)}",
          "  Next boundary: #{format(boundary)} -> #{next_window}",
          routing_line(schedule, now)
        ]
        |> Enum.join("\n")

      {:error, reason} ->
        "DeepSeek pricing window: unknown (#{reason}); prices report at peak and routing is unchanged"
    end
  end

  defp routing_line(schedule, now) do
    case avoid_peak_pricing_preference() do
      nil ->
        "  avoid_peak_pricing: unknown (config unreadable); routing is unchanged"

      false ->
        "  avoid_peak_pricing: off; agent.priority is used exactly as written"

      true ->
        window = Window.classify(now, schedule)

        if window == :peak do
          "  avoid_peak_pricing: on; peak-priced DeepSeek routes are dropped when a non-peak alternative remains"
        else
          "  avoid_peak_pricing: on; DeepSeek routes are kept (off-peak is in force)"
        end
    end
  end

  defp avoid_peak_pricing_preference do
    case Aiur.Config.settings() do
      {:ok, settings} -> Aiur.Config.avoid_peak_pricing_value(settings)
      _ -> nil
    end
  end

  defp offset_label(schedule) do
    case Map.get(schedule, :utc_offset_hours) do
      offset when is_integer(offset) -> "UTC+#{offset}, no DST"
      _ -> "timezone unknown"
    end
  end

  defp format(%DateTime{} = boundary), do: DateTime.to_iso8601(boundary)
end
