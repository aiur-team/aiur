defmodule Aiur.PaneManager.StateTest do
  use ExUnit.Case, async: true

  alias Aiur.PaneManager.State

  test "record_slot_pane populates all pane maps" do
    state = %State{slot_panes: State.empty_slot_panes(5)}

    assert %State{
             identifier_to_pane: %{"issue-1" => "%10"},
             pane_to_identifier: %{"%10" => "issue-1"},
             pane_to_slot: %{"%10" => 2},
             slot_panes: %{2 => "%10"}
           } = State.record_slot_pane(state, 2, "%10", "issue-1")
  end

  test "forget_pane_by_identifier clears both directions, title, and slot" do
    state =
      %State{slot_panes: State.empty_slot_panes(5)}
      |> State.record_slot_pane(3, "%10", "issue-1")
      |> State.remember_title("issue-1", title: "Title")

    new_state = State.forget_pane_by_identifier(state, "%10")

    refute Map.has_key?(new_state.identifier_to_pane, "issue-1")
    refute Map.has_key?(new_state.pane_to_identifier, "%10")
    refute Map.has_key?(new_state.pane_to_slot, "%10")
    refute Map.has_key?(new_state.title_by_identifier, "issue-1")
    assert new_state.slot_panes[3] == nil
  end

  test "forget_identifier_for_pane only clears identifier lookup and title" do
    state =
      %State{slot_panes: State.empty_slot_panes(5)}
      |> State.record_slot_pane(3, "%10", "issue-1")
      |> State.remember_title("issue-1", title: "Title")

    new_state = State.forget_identifier_for_pane(state, "%10")

    refute Map.has_key?(new_state.identifier_to_pane, "issue-1")
    refute Map.has_key?(new_state.title_by_identifier, "issue-1")
    assert new_state.pane_to_identifier["%10"] == "issue-1"
    assert new_state.pane_to_slot["%10"] == 3
    assert new_state.slot_panes[3] == "%10"
  end

  test "forget_dead_slot no-ops on an empty slot" do
    state = %State{slot_panes: State.empty_slot_panes(5)}

    assert State.forget_dead_slot(state, 2) == state
  end

  test "remember_title stores only non-blank binaries" do
    state =
      %State{}
      |> State.remember_title("issue-1", title: "Title")
      |> State.remember_title("issue-2", title: "")
      |> State.remember_title("issue-3", title: nil)

    assert state.title_by_identifier == %{"issue-1" => "Title"}
  end

  test "pane_title_text combines id and scrubbed title" do
    state = State.remember_title(%State{}, "issue-1", title: "Line\r\nTabbed\tDone")

    assert State.pane_title_text(state, "issue-1") == "issue-1 Line  Tabbed Done"
    assert State.pane_title_text(state, "issue-2") == "issue-2"
  end

  test "placeholder record and drops round-trip" do
    state =
      %State{}
      |> State.record_placeholder("issue-1", "%20", 4)

    assert state.placeholder_panes == %{"issue-1" => %{pane_id: "%20", slot: 4}}
    assert State.drop_placeholder(state, "issue-1").placeholder_panes == %{}
    assert State.drop_placeholder_by_pane(state, "%20").placeholder_panes == %{}
    assert State.drop_placeholder_by_pane(state, "%missing") == state
  end

  test "advance_cycle wraps at slot_count" do
    assert State.advance_cycle(%State{cycle_index: 0, slot_count: 5}).cycle_index == 1
    assert State.advance_cycle(%State{cycle_index: 4, slot_count: 5}).cycle_index == 0
  end

  test "slot_panes_list overlays placeholders on slot indexes" do
    state =
      %State{slot_count: 5, slot_panes: State.empty_slot_panes(5)}
      |> State.record_slot_pane(2, "%10", "issue-1")
      |> State.record_placeholder("issue-2", "%20", 2)
      |> State.record_placeholder("issue-3", "%21", 4)

    assert State.slot_panes_list(state) == [nil, "%20", nil, "%21", nil]
  end

  test "visible_panes_packed packs left-to-right and pads nils" do
    state =
      %State{slot_count: 5, slot_panes: State.empty_slot_panes(5)}
      |> State.record_slot_pane(4, "%40", "issue-4")
      |> State.record_slot_pane(2, "%20", "issue-2")

    assert State.visible_panes_packed(state) == ["%20", "%40", nil, nil, nil]
  end

  test "first_available_visual_slot returns first nil index plus one and nil when full" do
    state =
      %State{slot_count: 3, slot_panes: State.empty_slot_panes(3)}
      |> State.record_slot_pane(1, "%10", "issue-1")
      |> State.record_slot_pane(3, "%30", "issue-3")

    assert State.first_available_visual_slot(state) == 2

    full =
      state
      |> State.record_slot_pane(2, "%20", "issue-2")

    assert State.first_available_visual_slot(full) == nil
  end

  test "slot count and empty slot map use grid formula" do
    assert State.slot_count(3) == 5
    assert State.empty_slot_panes(5) == %{1 => nil, 2 => nil, 3 => nil, 4 => nil, 5 => nil}
  end
end
