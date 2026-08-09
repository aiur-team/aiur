defmodule AiurWeb.StreamdeckLogsTest do
  use ExUnit.Case, async: true

  alias AiurWeb.StreamdeckLogs

  test "projects a LIVE key plus coloured event keys and positions the flattened transcript" do
    logs =
      StreamdeckLogs.project([
        entry("latest assistant event", "turn-2", "AGENT"),
        entry("latest tool event", "turn-2", "EMIT"),
        entry("older operator event", "turn-1", "CONSUME")
      ])

    assert [%{kind: :live, index: 0, label: "LIVE"} | events] = logs.event_keys
    assert Enum.map(events, & &1.index) == [1, 2]
    assert Enum.map(events, &{&1.badge, &1.color}) == [{"AGENT", "#9fd0ff"}, {"CONSUME", "#88e0a6"}]
    assert logs.event_starts == %{1 => 0, 2 => 3}

    selected = StreamdeckLogs.select_event(logs, 2)
    assert selected.selected_event_index == 2
    assert selected.transcript_offset == 3
    assert hd(selected.transcript_visible).kind == :event_header
    assert hd(selected.transcript_visible).body == "older operator event"
  end

  test "maps every Stream Deck direction to its specified colour" do
    logs =
      StreamdeckLogs.project([
        entry("emit", "turn-5", "EMIT"),
        entry("consume", "turn-4", "CONSUME"),
        entry("info", "turn-3", "INFO"),
        entry("agent", "turn-2", "AGENT"),
        entry("system", "turn-1", "SYSTEM")
      ])

    assert Enum.map(Enum.drop(logs.event_keys, 1), &{&1.badge, &1.color}) == [
             {"EMIT", "#9fd0ff"},
             {"CONSUME", "#88e0a6"},
             {"INFO", "#c2c6cf"},
             {"AGENT", "#9fd0ff"},
             {"SYSTEM", "#ffcf87"}
           ]
  end

  test "transcript selection keeps the selected event in the eight-key window" do
    logs = StreamdeckLogs.project(Enum.map(1..10, &entry("event-#{&1}", "turn-#{&1}", "INFO")))

    selected = StreamdeckLogs.select_event(logs, 10)
    assert selected.selected_event_index == 10
    assert selected.events_offset == 3
    assert Enum.any?(selected.event_keys_visible, &(&1.index == 10))

    scrolled = StreamdeckLogs.scroll(selected, :transcript, -99)
    assert scrolled.transcript_offset == 0
    assert scrolled.selected_event_index == 1
    assert scrolled.selected_event_id == {:turn, "turn-1"}
    assert Enum.any?(scrolled.event_keys_visible, &(&1.index == 1))
  end

  test "refresh retains the selected event by turn identifier" do
    entries = [entry("latest", "turn-2", "AGENT"), entry("older", "turn-1", "INFO")]
    selected = entries |> StreamdeckLogs.project() |> StreamdeckLogs.select_event(2)

    refreshed = StreamdeckLogs.refresh(selected, [entry("new", "turn-3", "EMIT") | entries])

    assert refreshed.selected_event_id == {:turn, "turn-1"}
    assert refreshed.selected_event_index == 3
    assert refreshed.transcript_offset == 4
  end

  test "refreshes key-relative times as the view remains open" do
    now = DateTime.utc_now()
    timestamp = now |> DateTime.add(-1, :second) |> DateTime.to_iso8601()
    logs = StreamdeckLogs.project([entry("recent", "turn-1", "INFO", timestamp)])

    assert [%{kind: :live} | [%{time: "now"}]] = logs.event_keys

    refreshed = StreamdeckLogs.refresh_relative_times(logs, DateTime.add(now, 60, :second))

    assert [%{kind: :live} | [%{time: "1m"}]] = refreshed.event_keys
  end

  defp entry(body, turn_id, badge, timestamp \\ "2026-08-02T00:00:00Z") do
    %{
      type: "message",
      badge: badge,
      role: "assistant",
      body: body,
      timestamp: timestamp,
      turn_id: turn_id
    }
  end
end
