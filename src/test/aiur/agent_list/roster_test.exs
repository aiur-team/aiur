defmodule Aiur.AgentList.RosterTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentList.{Roster, State}

  defp state do
    State.new(command_template: "cmd")
  end

  test "fold returns slot and retain ids with deactivated excluded from slot_ids but included in retain_ids" do
    summaries = [
      %{identifier: "work", status: :running, work_state: :working},
      %{identifier: "paused", status: :running, work_state: :paused},
      %{identifier: "done", status: :running, work_state: :deactivated},
      %{identifier: nil, status: :running, work_state: :working}
    ]

    {new_state, slot_ids, retain_ids} = Roster.fold(state(), summaries)

    assert Enum.map(new_state.summaries, & &1.identifier) == [nil, "work", "paused", "done"]
    assert slot_ids == ["work"]
    assert retain_ids == ["paused", "done"]
  end

  test "fold flips focus when summaries first arrive and clamps when list shrinks" do
    empty = %{state() | summaries: [], selection_focus: :max_agents, selection_index: 3}
    {with_rows, _slot_ids, _retain_ids} = Roster.fold(empty, [%{identifier: "1", status: :running}])

    assert with_rows.selection_focus == :agents
    assert with_rows.selection_index == 0

    existing = %{state() | summaries: [%{}, %{}, %{}], selection_focus: :agents, selection_index: 2}
    {shrunk, _slot_ids, _retain_ids} = Roster.fold(existing, [%{identifier: "1", status: :running}])

    assert shrunk.selection_index == 0
  end

  test "fold preserves the selected row while work-state sorting changes" do
    working = %{identifier: "1", status: :running, work_state: :working}
    paused = %{identifier: "2", status: :running, work_state: :paused}

    previous = %{
      state()
      | summaries: [working, paused],
        selection_focus: :agents,
        selection_index: 1
    }

    {resorted, _slot_ids, _retain_ids} =
      Roster.fold(previous, [
        %{working | work_state: :paused},
        %{paused | work_state: :working}
      ])

    assert Enum.at(resorted.summaries, resorted.selection_index).identifier == "2"
  end

  test "fold drops identifier activity caches and keeps visible local row state" do
    existing = %{
      state()
      | latest_event_by_id: %{"work" => :latest, "done" => :done_latest, "gone" => :gone},
        phase_by_identifier: %{"work" => :work, "done" => :review, "gone" => :plan},
        progress_by_id: %{"work" => [{10, 1}], "done" => [{100, 2}], "gone" => [{50, 3}]},
        agents_with_content: MapSet.new(["work", "done", "gone"])
    }

    summaries = [
      %{identifier: "work", status: :running, work_state: :working},
      %{identifier: "done", status: :running, work_state: :deactivated}
    ]

    {new_state, _slot_ids, _retain_ids} = Roster.fold(existing, summaries)

    assert new_state.latest_event_by_id == %{}
    assert new_state.phase_by_identifier == %{}
    assert new_state.progress_by_id == %{}
    assert new_state.agents_with_content == MapSet.new(["work", "done"])
  end

  test "fold never invents completion progress for deactivated rows" do
    existing = %{
      state()
      | progress_by_id: %{
          "missing" => [{50, 1}],
          "already" => [{100, 2}, {50, 1}]
        }
    }

    summaries = [
      %{identifier: "missing", status: :running, work_state: :deactivated},
      %{identifier: "already", status: :running, work_state: :deactivated}
    ]

    {new_state, _slot_ids, _retain_ids} = Roster.fold(existing, summaries)

    assert new_state.progress_by_id == %{}
  end

  test "fold rebuilds open attention counts to zero when store has no data" do
    summaries = [%{identifier: "work", status: :running, work_state: :working}]

    {new_state, _slot_ids, _retain_ids} = Roster.fold(state(), summaries)

    assert new_state.open_attentions_by_id == %{"work" => 0}
  end
end
