defmodule Aiur.AgentList.SelectionTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentList.Selection

  test "empty list parks focus on max agents at index zero" do
    state = %{summaries: [], selection_index: 2, selection_focus: :agents}

    assert Selection.move_selection(state, 1) == %{state | selection_index: 0, selection_focus: :max_agents}
  end

  test "leaving the chip enters the first or last row" do
    state = %{summaries: [:a, :b, :c], selection_index: 0, selection_focus: :max_agents}

    assert %{selection_index: 0, selection_focus: :agents} = Selection.move_selection(state, 1)
    assert %{selection_index: 2, selection_focus: :agents} = Selection.move_selection(state, -1)
  end

  test "edges move focus back to the chip" do
    first = %{summaries: [:a, :b], selection_index: 0, selection_focus: :agents}
    last = %{summaries: [:a, :b], selection_index: 1, selection_focus: :agents}

    assert %{selection_focus: :max_agents, selection_index: 0} = Selection.move_selection(first, -1)
    assert %{selection_focus: :max_agents, selection_index: 1} = Selection.move_selection(last, 1)
  end

  test "interior moves wrap with rem" do
    state = %{summaries: [:a, :b, :c], selection_index: 1, selection_focus: :agents}

    assert %{selection_index: 2, selection_focus: :agents} = Selection.move_selection(state, 1)
    assert %{selection_index: 0, selection_focus: :agents} = Selection.move_selection(state, -1)
  end

  test "clamp_selection clamps to count minus one and zero for empty lists" do
    assert %{selection_index: 1} =
             Selection.clamp_selection(%{summaries: [:a, :b], selection_index: 5, selection_focus: :agents})

    assert %{selection_index: 0} =
             Selection.clamp_selection(%{summaries: [], selection_index: 5, selection_focus: :agents})
  end
end
