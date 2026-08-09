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

  test "preserve_row follows trusted row identity through live resorting" do
    one = summary("42", "node-1")
    two = summary("42", "node-2")
    previous = %{summaries: [one, two], selection_index: 1, selection_focus: :agents}
    next = %{previous | summaries: [two, one]}

    assert Selection.preserve_row(previous, next).selection_index == 0
  end

  test "preserve_row falls back to identifier and clamps when a row disappears" do
    previous = %{
      summaries: [%{identifier: "1"}, %{identifier: "2"}],
      selection_index: 1,
      selection_focus: :agents
    }

    reordered = %{previous | summaries: [%{identifier: "2"}, %{identifier: "1"}]}
    removed = %{previous | summaries: [%{identifier: "1"}]}

    assert Selection.preserve_row(previous, reordered).selection_index == 0
    assert Selection.preserve_row(previous, removed).selection_index == 0
  end

  defp summary(identifier, provider_id) do
    %{
      identifier: identifier,
      tracker_identity: %Aiur.TrackerIdentity{
        version: 1,
        status: :joinable,
        kind: :github,
        owner: "owner",
        repository: "repo",
        provider_id: provider_id,
        identifier: identifier,
        reason: nil
      }
    }
  end
end
