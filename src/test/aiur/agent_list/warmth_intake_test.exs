defmodule Aiur.AgentList.WarmthIntakeTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentList.WarmthIntake

  defp state do
    %{agents_with_content: MapSet.new(), opened_panes: MapSet.new(), visible_sessions: %{}, started_slots: MapSet.new(), attach_state: %{}, fully_warmed_slots: MapSet.new()}
  end

  test "folds marker state and leaves irrelevant events untouched" do
    {state, true} = WarmthIntake.fold(state(), {:agent_chat_active, "A"})
    assert MapSet.member?(state.agents_with_content, "A")
    assert {^state, false} = WarmthIntake.fold(state, {:agent_chat_active, "A"})
    {state, true} = WarmthIntake.fold(state, {:slot_session_changed, 2, "A"})
    assert state.visible_sessions == %{2 => "A"}
    {state, true} = WarmthIntake.fold(state, {:slot_visible_changed, 2, nil})
    assert state.visible_sessions == %{}
    assert {^state, false} = WarmthIntake.fold(state, :ignored)
  end

  test "folds attach state and warming transitions" do
    {state, true} = WarmthIntake.fold(state(), {:attach_state_changed, "A", 2, 1})
    assert state.attach_state["A"] == %{attach_count: 2, visible_in: 1}
    {state, true} = WarmthIntake.fold(state, {:slot_ready, 3})
    {state, true} = WarmthIntake.fold(state, {:slot_fully_warmed, 3})
    assert MapSet.member?(state.started_slots, 3)
    assert MapSet.member?(state.fully_warmed_slots, 3)
    {state, true} = WarmthIntake.fold(state, {:slot_warmth_dropped, 3})
    refute MapSet.member?(state.fully_warmed_slots, 3)
  end

  test "folds pane visibility and ignores malformed started-slot events" do
    {state, true} = WarmthIntake.fold(state(), {:status_changed, %{identifier: "A", status: :pane_opened}})
    assert MapSet.member?(state.opened_panes, "A")
    {state, true} = WarmthIntake.fold(state, {:status_changed, %{identifier: "A", status: :pane_closed}})
    refute MapSet.member?(state.opened_panes, "A")
    {state, true} = WarmthIntake.fold(state, {:slot_starting, 4})
    assert MapSet.member?(state.started_slots, 4)
    assert {^state, false} = WarmthIntake.fold(state, {:slot_ready, :bad})
    assert {^state, false} = WarmthIntake.fold(state, {:slot_starting, :bad})
  end
end
