defmodule AiurWeb.StreamdeckLogsTest do
  use ExUnit.Case, async: true

  alias AiurWeb.{StreamdeckKeyFaceContract, StreamdeckLogs}

  test "projects a LIVE key plus badged event keys and positions the flattened transcript" do
    logs =
      StreamdeckLogs.project([
        entry("latest assistant event", "turn-2", "AGENT"),
        entry("latest tool event", "turn-2", "EMIT"),
        entry("older operator event", "turn-1", "CONSUME")
      ])

    assert [%{kind: :live, index: 0, label: "LIVE"} | events] = logs.event_keys
    assert Enum.map(events, & &1.index) == [1, 2]
    assert Enum.map(events, & &1.badge) == ["AGENT", "CONSUME"]
    assert logs.event_starts == %{1 => 0, 2 => 3}

    selected = StreamdeckLogs.select_event(logs, 2)
    assert selected.selected_event_index == 2
    assert selected.transcript_offset == 3
    assert hd(selected.transcript_visible).kind == :event_header
    assert hd(selected.transcript_visible).body == "older operator event"
  end

  test "projects every Stream Deck direction as its own badge" do
    logs =
      StreamdeckLogs.project([
        entry("emit", "turn-5", "EMIT"),
        entry("consume", "turn-4", "CONSUME"),
        entry("info", "turn-3", "INFO"),
        entry("agent", "turn-2", "AGENT"),
        entry("system", "turn-1", "SYSTEM"),
        entry("unknown", "turn-0", "WAT")
      ])

    assert Enum.map(Enum.drop(logs.event_keys, 1), & &1.badge) ==
             ["EMIT", "CONSUME", "INFO", "AGENT", "SYSTEM", "INFO"]
  end

  # The shared key-face contract (#1726) owns the ink, so the packaged deck and
  # the emulator paint one palette. Assert here that every direction the
  # projection can emit has a colour there, and that no two of the visually
  # distinct directions collapse onto one value.
  test "every projected direction has a colour in the shared key-face contract" do
    colors =
      Map.new(~w(EMIT CONSUME INFO AGENT SYSTEM), fn direction ->
        {direction, StreamdeckKeyFaceContract.direction_badge!(direction)["color"]}
      end)

    assert Enum.all?(colors, fn {_direction, color} -> is_binary(color) and color != "" end),
           "directions without a contract colour: " <>
             inspect(for {direction, color} <- colors, color in [nil, ""], do: direction)

    assert colors["EMIT"] == colors["AGENT"], "#1576 specifies one blue for EMIT and AGENT"

    distinct = colors |> Map.take(~w(EMIT CONSUME INFO SYSTEM)) |> Map.values()
    assert distinct == Enum.uniq(distinct), "two directions share one colour: #{inspect(colors)}"
  end

  # The projection's direction set is the contract's, not a private copy.
  test "the projection normalises exactly the contract's directions" do
    contract_badges = StreamdeckKeyFaceContract.direction_badges() |> Map.keys() |> Enum.sort()

    projected =
      contract_badges
      |> Enum.with_index(1)
      |> Enum.map(fn {badge, index} -> entry("body #{index}", "turn-#{index}", badge) end)
      |> StreamdeckLogs.project()
      |> Map.fetch!(:event_keys)
      |> Enum.filter(&(&1.kind == :event))
      |> Enum.map(& &1.badge)
      |> Enum.sort()

    assert projected == contract_badges
  end

  test "projects an empty feed as a LIVE-only window with no transcript" do
    logs = StreamdeckLogs.project([])

    assert logs.transcript == []
    assert logs.event_starts == %{}
    assert logs.transcript_max_offset == 0
    assert logs.transcript_visible == []
    assert [%{kind: :live, index: 0}] = logs.event_keys
    assert length(logs.event_keys_visible) == 8
    assert Enum.map(logs.event_keys_visible, & &1.kind) == [:live | List.duplicate(:empty, 7)]
    # Selecting past the end of a one-key list must not escape the window.
    assert StreamdeckLogs.select_event(logs, 4).selected_event_index == 0
  end

  test "pads a short feed to eight keys" do
    logs = StreamdeckLogs.project(Enum.map(1..3, &entry("event-#{&1}", "turn-#{&1}", "INFO")))

    assert length(logs.event_keys_visible) == 8

    assert Enum.map(logs.event_keys_visible, & &1.kind) ==
             [:live, :event, :event, :event] ++ List.duplicate(:empty, 4)

    assert logs.events_max_offset == 0
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

  test "refresh keeps how far into the selected event the transcript is scrolled" do
    entries = Enum.map(1..4, &entry("event-#{&1}", "turn-#{&1}", "INFO"))

    scrolled =
      entries
      |> StreamdeckLogs.project()
      |> StreamdeckLogs.select_event(3)
      |> StreamdeckLogs.scroll(:transcript, 1)

    # Event 3 starts at offset 4; the operator is one line into it.
    assert scrolled.transcript_offset == 5
    assert scrolled.selected_event_id == {:turn, "turn-3"}

    refreshed = StreamdeckLogs.refresh(scrolled, [entry("new", "turn-0", "EMIT") | entries])

    # The event moved down one slot, so its start moved from 4 to 6 — and the
    # operator is still one line into it rather than back at its header.
    assert refreshed.event_starts[refreshed.selected_event_index] == 6
    assert refreshed.transcript_offset == 7
    assert refreshed.selected_event_id == {:turn, "turn-3"}
  end

  test "refresh keeps the key window the operator scrolled to" do
    entries = Enum.map(1..12, &entry("event-#{&1}", "turn-#{&1}", "INFO"))
    logs = entries |> StreamdeckLogs.project() |> StreamdeckLogs.scroll(:events, 3)

    assert logs.events_offset == 3
    assert logs.selected_event_id == :live

    refreshed = StreamdeckLogs.refresh(logs, entries)

    assert refreshed.events_offset == 3
    assert Enum.map(refreshed.event_keys_visible, & &1.index) == Enum.to_list(3..10)
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
