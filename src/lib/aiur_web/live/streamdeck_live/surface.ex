defmodule AiurWeb.StreamdeckLive.Surface do
  @moduledoc """
  Dial math and HTML knob readouts for the Stream Deck emulator.
  """

  alias AiurWeb.StreamdeckStrip

  @spec clamp_page(term(), integer()) :: integer()
  def clamp_page(page, windows) when is_integer(page), do: clamp(page, 0, max(windows - 1, 0))
  def clamp_page(_page, windows), do: clamp_page(0, windows)

  @spec max_column_offset(non_neg_integer()) :: non_neg_integer()
  def max_column_offset(agent_count), do: max(0, ceil(agent_count / 2) - 4)
  @spec clamp_column_offset(number(), non_neg_integer()) :: number()
  def clamp_column_offset(offset, agent_count),
    do: clamp(offset, 0, max_column_offset(agent_count))

  @spec column_offset_from_dial(number(), non_neg_integer()) :: integer()
  def column_offset_from_dial(value, agent_count),
    do: round(clamp(value, 0, 100) / 100 * max_column_offset(agent_count))

  @spec dial_value_from_offset(number(), non_neg_integer()) :: integer()
  def dial_value_from_offset(offset, agent_count) do
    max_offset = max_column_offset(agent_count)
    if max_offset == 0, do: 0, else: clamp(round(offset / max_offset * 100), 0, 100)
  end

  @spec current_window(integer(), non_neg_integer()) :: integer()
  def current_window(column_offset, agent_count) do
    max_offset = max_column_offset(agent_count)
    windows = max(1, ceil(agent_count / 8))

    if column_offset >= max_offset,
      do: windows - 1,
      else: min(div(max(column_offset, 0), 4), windows - 1)
  end

  @spec clamp(number(), number(), number()) :: number()
  def clamp(value, min, max), do: value |> max(min) |> min(max)

  @spec knob_descriptors(number(), integer(), atom(), map()) :: [map()]
  def knob_descriptors(dial_value \\ 0, windows \\ 0, mode \\ :grid, logs \\ %{}) do
    back_hint =
      case mode do
        :cmd ->
          StreamdeckStrip.hint(0, 0, "BACK")

        :settings ->
          StreamdeckStrip.hint(0, 0, "BACK")

        :commands ->
          StreamdeckStrip.hint(0, 0, "BACK")

        :logs ->
          StreamdeckStrip.hint(
            Map.get(logs, :transcript_offset, 0),
            Map.get(logs, :transcript_max_offset, 0),
            "BACK"
          )

        _ ->
          nil
      end

    events_hint =
      if mode == :logs,
        do:
          StreamdeckStrip.hint(
            Map.get(logs, :events_offset, 0),
            Map.get(logs, :events_max_offset, 0),
            "EVENTS"
          ),
        else: nil

    [
      %{label: "Focus", value: "62", angle: 138, hint: back_hint},
      %{label: "Volume", value: "74", angle: 174, hint: nil},
      %{label: "Speed", value: "48", angle: 78, hint: nil},
      %{
        label: "Page",
        value: String.pad_leading(to_string(dial_value), 2, "0"),
        angle: if(windows > 0, do: dial_value / 100 * 270 - 135, else: -135),
        hint: events_hint
      }
    ]
  end
end
