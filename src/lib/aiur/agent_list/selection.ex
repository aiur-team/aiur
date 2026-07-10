defmodule Aiur.AgentList.Selection do
  @moduledoc """
  Pure selection-ring updates for AgentList state.
  """

  @spec move_selection(map(), integer()) :: map()
  def move_selection(state, delta) do
    # Navigation forms one continuous ring across the agent rows and the
    # max-agents chip:
    #
    #   max_agents → first agent → ... → last agent → max_agents → first ...
    #
    # ↑ from the first row and ↓ from the last row both land on the chip,
    # and the chip's own ↑/↓ continues into the opposite end of the list.
    count = length(state.summaries)

    cond do
      count == 0 ->
        %{state | selection_index: 0, selection_focus: :max_agents}

      state.selection_focus == :max_agents ->
        %{state | selection_index: chip_entry_index(count, delta), selection_focus: :agents}

      at_edge?(state, count, delta) ->
        %{state | selection_focus: :max_agents}

      true ->
        new_index = rem(state.selection_index + delta + count, count)
        %{state | selection_index: new_index, selection_focus: :agents}
    end
  end

  @spec clamp_selection(map()) :: map()
  def clamp_selection(state) do
    count = length(state.summaries)

    cond do
      count == 0 -> %{state | selection_index: 0}
      state.selection_index >= count -> %{state | selection_index: count - 1}
      true -> state
    end
  end

  # When leaving the chip, ↓ lands on the first row and ↑ on the last.
  defp chip_entry_index(_count, delta) when delta > 0, do: 0
  defp chip_entry_index(count, _delta), do: count - 1

  # The two ring edges that hand selection back to the chip: row 0 going
  # up, or the last row going down.
  defp at_edge?(%{selection_index: 0}, _count, delta) when delta < 0, do: true
  defp at_edge?(%{selection_index: idx}, count, delta) when delta > 0 and idx == count - 1, do: true
  defp at_edge?(_state, _count, _delta), do: false
end
