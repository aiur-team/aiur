defmodule Aiur.AgentList.PerfIntakeTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentList.PerfIntake

  defp state do
    %{perf_summary: %{agent_list_ready_ms: nil, chat_pane_visible_ms: nil, opencode_render_ms: nil}, warmth_events: []}
  end

  test "updates only footer milestones and signals render only on summary change" do
    {state, true} = PerfIntake.fold(state(), %{phase: :agent_list_ready, meta: %{wall_ms: 42}})
    assert state.perf_summary.agent_list_ready_ms == 42
    {state, true} = PerfIntake.fold(state, %{phase: :placeholder_spawn_done, meta: %{wall_ms: 8}})
    {state, true} = PerfIntake.fold(state, %{phase: :convo_first_paint, meta: %{wall_ms: 12}})
    assert state.perf_summary.chat_pane_visible_ms == 8
    assert state.perf_summary.opencode_render_ms == 12
    assert {^state, false} = PerfIntake.fold(state, %{phase: :other, meta: %{}})
  end

  test "records every warmth phase with newest values first" do
    state =
      Enum.reduce([:slot_attach_added, :slot_attach_removed, :slot_visible_changed], state(), fn phase, acc ->
        {next, false} = PerfIntake.fold(acc, %{phase: phase, at_ms: 1, meta: %{slot: 2, identifier: "A"}})
        next
      end)

    assert Enum.map(state.warmth_events, & &1.phase) == [:slot_visible_changed, :slot_attach_removed, :slot_attach_added]
  end

  test "captures warmth events newest first and caps the ring" do
    state =
      Enum.reduce(1..501, state(), fn slot, acc ->
        {next, _} = PerfIntake.fold(acc, %{phase: :slot_attach_added, at_ms: slot, meta: %{slot: slot, identifier: "A"}})
        next
      end)

    assert length(state.warmth_events) == 500
    assert hd(state.warmth_events).slot == 501
    assert List.last(state.warmth_events).slot == 2
  end
end
