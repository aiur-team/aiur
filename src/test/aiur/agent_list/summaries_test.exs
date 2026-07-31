defmodule Aiur.AgentList.SummariesTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentList.Summaries

  test "visible_summaries rejects inactive agent tags" do
    summaries = [
      %{identifier: "1", status: :running, tag: "agent:done"},
      %{identifier: "2", status: :running, tag: "agent:canceled"},
      %{identifier: "3", status: :running, tag: "agent:cancelled"},
      %{identifier: "4", status: :running, work_state: :working}
    ]

    assert [%{identifier: "4"}] = Summaries.visible_summaries(summaries)
  end

  test "visible_summaries sorts by work bucket and natural identifier order" do
    summaries = [
      %{identifier: "queued", status: :queued},
      %{identifier: "other", status: :running, work_state: :other},
      %{identifier: "10", status: :running, work_state: :working},
      %{identifier: "5", status: :running, work_state: :working},
      %{identifier: "abc", status: :running, work_state: :working},
      %{identifier: "paused", status: :running, work_state: :paused},
      %{identifier: "sleep", status: :running, work_state: :sleeping},
      %{identifier: "completed", status: :running, work_state: :completed},
      %{identifier: "error", status: :running, work_state: :error},
      %{identifier: "done", status: :running, work_state: :deactivated}
    ]

    assert Enum.map(Summaries.visible_summaries(summaries), & &1.identifier) == [
             "5",
             "10",
             "abc",
             "paused",
             "sleep",
             "completed",
             "done",
             "error",
             "other",
             "queued"
           ]
  end

  test "summary predicates accept atom and string work states" do
    assert Summaries.paused?(%{work_state: :paused})
    assert Summaries.paused?(%{work_state: "paused"})
    refute Summaries.paused?(%{work_state: :working})

    assert Summaries.deactivated?(%{work_state: :deactivated})
    assert Summaries.deactivated?(%{work_state: "deactivated"})
    refute Summaries.deactivated?(%{work_state: :working})

    assert Summaries.completed?(%{work_state: :completed})
    assert Summaries.completed?(%{work_state: "completed"})
    refute Summaries.completed?(%{work_state: :working})
  end

  test "remote_control_on? is true only for launching and on" do
    assert Summaries.remote_control_on?(%{remote_control: %{status: :launching}})
    assert Summaries.remote_control_on?(%{remote_control: %{status: :on}})
    refute Summaries.remote_control_on?(%{remote_control: %{status: :off}})
    refute Summaries.remote_control_on?(%{})
  end

  test "active_agent_count counts running non-paused summaries" do
    summaries = [
      %{status: :running, work_state: :working},
      %{status: :running, work_state: :paused},
      %{status: :running, work_state: :completed},
      %{status: :queued, work_state: :working}
    ]

    assert Summaries.active_agent_count(summaries) == 1
  end

  test "id_sets preserves visible slot and retain semantics" do
    summaries = [
      %{identifier: "work", status: :running, work_state: :working},
      %{identifier: "paused", status: :running, work_state: :paused},
      %{identifier: "done", status: :running, work_state: :deactivated},
      %{identifier: "completed", status: :running, work_state: :completed},
      %{identifier: nil, status: :running, work_state: :working},
      %{identifier: "queued", status: :queued, work_state: :working}
    ]

    assert Summaries.id_sets(summaries) == %{
             visible_ids: ["work", "paused", "done", "completed"],
             slot_ids: ["work"],
             retain_ids: ["paused", "done"]
           }
  end

  test "id_sets retains deactivated (human-review) pane alongside paused" do
    summaries = [
      %{identifier: "active", status: :running, work_state: :working},
      %{identifier: "paused", status: :running, work_state: :paused},
      %{identifier: "done", status: :running, work_state: :deactivated}
    ]

    %{slot_ids: slot_ids, retain_ids: retain_ids} = Summaries.id_sets(summaries)
    assert slot_ids == ["active"]
    assert retain_ids == ["paused", "done"]
  end
end
