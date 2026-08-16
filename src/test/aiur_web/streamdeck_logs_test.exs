defmodule AiurWeb.StreamdeckLogsTest do
  use ExUnit.Case, async: true

  alias AiurWeb.{StreamdeckKeyFaceContract, StreamdeckLogs}

  test "projects one key per bus event, an origin anchor first and LIVE last" do
    logs =
      StreamdeckLogs.project(%{
        events: [
          bus(1, "emit", "ticket.401.agent.progress", "34%", "2026-08-02T00:10:00Z"),
          bus(2, "consumed", "ticket.401.pr.merged", "", "2026-08-02T00:20:00Z")
        ],
        transcript: [
          message("after the merge", "2026-08-02T00:21:00Z"),
          message("mid-run note", "2026-08-02T00:11:00Z"),
          message("before anything published", "2026-08-02T00:01:00Z")
        ]
      })

    assert Enum.map(logs.event_keys, & &1.kind) == [:event, :event, :event, :live]
    assert Enum.map(logs.event_keys, & &1.text) == ["Ticket opened", "Progress", "PR merged", "LIVE"]
    assert Enum.map(logs.event_keys, & &1.badge) == ["INFO", "EMIT", "CONSUME", "AGENT"]
    assert Enum.map(logs.event_keys, & &1.index) == [0, 1, 2, 3]
  end

  # The whole bug: a turn is one grouping of dozens of messages, so grouping the
  # transcript by `turn_id` collapsed a page of activity into a single key whose
  # label was simply the newest thing the agent had typed.
  test "a transcript with no bus events does not masquerade as events" do
    logs =
      StreamdeckLogs.project(%{
        events: [],
        transcript: Enum.map(1..20, &message("line #{&1}", "2026-08-02T00:00:0#{rem(&1, 10)}Z"))
      })

    assert Enum.map(logs.event_keys, & &1.kind) == [:event, :live]
    # Every one of those rows is still readable; they belong to the origin.
    assert length(logs.transcript) == 21
  end

  test "orders the whole projection oldest first and opens at the live end" do
    logs =
      StreamdeckLogs.project(%{
        events: [
          bus(1, "self", "ticket.401.agent.phase.review.start", "review", "2026-08-02T00:10:00Z"),
          bus(2, "emit", "ticket.401.pr.opened", "PR #1904", "2026-08-02T00:30:00Z")
        ],
        transcript: [message("newest", "2026-08-02T00:31:00Z"), message("oldest", "2026-08-02T00:01:00Z")]
      })

    bodies = Enum.map(logs.transcript, fn row -> Map.get(row, :body) end)
    assert bodies == ["Ticket opened", "oldest", "review", "PR #1904", "newest"]

    # Requirement 7: LIVE is the newest end, and the surface opens there.
    assert logs.transcript_offset == logs.transcript_max_offset
    assert logs.selected_event_id == :live
    assert logs.selected_event_index == length(logs.event_keys) - 1
  end

  # Each key carries its own jump target, so the client never has to reproduce
  # the server's anchoring rules to address a key.
  test "every key's start points at its own header, and LIVE's at the newest row" do
    logs =
      StreamdeckLogs.project(%{
        events: [
          bus(1, "emit", "ticket.401.agent.progress", "34%", "2026-08-02T00:10:00Z"),
          bus(2, "emit", "ticket.401.ci.failed", "credo", "2026-08-02T00:20:00Z")
        ],
        transcript: [message("b", "2026-08-02T00:21:00Z"), message("a", "2026-08-02T00:11:00Z")]
      })

    for key <- logs.event_keys, key.kind == :event do
      assert Enum.at(logs.transcript, key.start).kind == :event_header
      assert Enum.at(logs.transcript, key.start).label == key.text
    end

    live = List.last(logs.event_keys)
    assert live.start == length(logs.transcript) - 1
  end

  test "wire projection is JSON-safe for real event identifiers and offsets" do
    wire =
      %{events: [bus(7, "emit", "ticket.401.pr.opened", "PR #1904")], transcript: [message("chat")]}
      |> StreamdeckLogs.project()
      |> StreamdeckLogs.wire()

    assert wire["event_keys"] |> List.last() |> Map.get("id") == "live"
    assert wire["event_keys"] |> hd() |> Map.get("id") == "origin"
    assert wire["event_keys"] |> Enum.at(1) |> Map.get("id") == "bus:7"
    assert Enum.all?(wire["transcript"], &is_map/1)
    assert {:ok, encoded} = Jason.encode(wire)
    assert is_binary(encoded)
  end

  # Direction comes from the marker kind, which is what records who moved the
  # event. Deriving it from the topic would make the same `pr.merged` read EMIT
  # when published and CONSUME when received.
  test "maps each marker kind onto its own direction badge" do
    logs =
      StreamdeckLogs.project(%{
        events: [
          bus(1, "emit", "ticket.401.pr.opened", "", "2026-08-02T00:01:00Z"),
          bus(2, "consumed", "ticket.401.issue.commented", "", "2026-08-02T00:02:00Z"),
          bus(3, "self", "ticket.401.agent.progress", "", "2026-08-02T00:03:00Z"),
          bus(4, "emit_alert", "ticket.401.agent.attention.raised", "", "2026-08-02T00:04:00Z")
        ],
        transcript: []
      })

    assert logs.event_keys |> Enum.drop(1) |> Enum.map(& &1.badge) ==
             ["EMIT", "CONSUME", "AGENT", "SYSTEM", "AGENT"]
  end

  test "falls back to the neutral badge for a direction the contract does not know" do
    logs = StreamdeckLogs.project(%{events: [%{badge: "WAT", label: "Odd", body: "", id: 1, timestamp: "2026-08-02T00:00:00Z"}], transcript: []})

    assert Enum.at(logs.event_keys, 1).badge == "INFO"
  end

  # The shared key-face contract owns the ink, so the packaged deck and the
  # emulator paint one palette.
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

  # Requirement 4: the anchor exists even for a ticket that has published
  # nothing, so the surface always has a defined left edge.
  test "projects an empty feed as an origin plus LIVE" do
    logs = StreamdeckLogs.project(%{events: [], transcript: []})

    assert Enum.map(logs.event_keys, & &1.kind) == [:event, :live]
    assert Enum.map(logs.transcript, & &1.kind) == [:event_header]
    assert logs.transcript_max_offset == 0
    assert length(logs.event_keys_visible) == 8
    assert Enum.map(logs.event_keys_visible, & &1.kind) == [:event, :live] ++ List.duplicate(:empty, 6)
    # Selecting past the end of a two-key list must not escape the window.
    assert StreamdeckLogs.select_event(logs, 9).selected_event_index == 1
  end

  test "a bare transcript list still projects, with an empty bus" do
    logs = StreamdeckLogs.project([message("legacy caller")])

    assert Enum.map(logs.event_keys, & &1.kind) == [:event, :live]
    assert Enum.map(logs.transcript, & &1.kind) == [:event_header, :message]
  end

  test "pads a short feed to eight keys" do
    logs = StreamdeckLogs.project(%{events: Enum.map(1..3, &bus(&1, "emit", "ticket.401.pr.opened", "e#{&1}", "2026-08-02T00:0#{&1}:00Z")), transcript: []})

    assert length(logs.event_keys_visible) == 8
    assert Enum.map(logs.event_keys_visible, & &1.kind) == [:event, :event, :event, :event, :live] ++ List.duplicate(:empty, 3)
    assert logs.events_max_offset == 0
  end

  test "selection keeps the selected event in the eight-key window" do
    logs = StreamdeckLogs.project(%{events: Enum.map(1..12, &bus(&1, "emit", "ticket.401.pr.opened", "e#{&1}", stamp(&1))), transcript: []})

    selected = StreamdeckLogs.select_event(logs, 1)
    assert selected.selected_event_index == 1
    assert selected.events_offset == 1
    assert Enum.any?(selected.event_keys_visible, &(&1.index == 1))

    scrolled = StreamdeckLogs.scroll(selected, :transcript, -99)
    assert scrolled.transcript_offset == 0
    assert scrolled.selected_event_index == 0
    assert scrolled.selected_event_id == :origin
  end

  # Requirement 10, server-side: scrolling to the newest row is what selects
  # LIVE, and scrolling off it is what deselects it.
  test "scrolling to the end selects LIVE and scrolling back selects an event" do
    logs = StreamdeckLogs.project(%{events: Enum.map(1..3, &bus(&1, "emit", "ticket.401.pr.opened", "e#{&1}", stamp(&1))), transcript: []})

    assert logs.selected_event_id == :live

    back = StreamdeckLogs.scroll(logs, :transcript, -1)
    assert back.selected_event_id == {:bus, 2}

    forward = StreamdeckLogs.scroll(back, :transcript, 1)
    assert forward.selected_event_id == :live
  end

  test "refresh retains the selected event by its bus identifier" do
    events = [bus(1, "emit", "ticket.401.pr.opened", "older", stamp(1)), bus(2, "emit", "ticket.401.ci.passed", "latest", stamp(2))]
    selected = %{events: events, transcript: []} |> StreamdeckLogs.project() |> StreamdeckLogs.select_event(1)

    refreshed = StreamdeckLogs.refresh(selected, %{events: events ++ [bus(3, "emit", "ticket.401.pr.merged", "new", stamp(3))], transcript: []})

    assert refreshed.selected_event_id == {:bus, 1}
    assert refreshed.selected_event_index == 1
    assert refreshed.transcript_offset == 1
  end

  # Requirement 7's other half: while LIVE is the selection, a refresh follows
  # the feed rather than freezing where the last flush happened to land.
  test "refresh follows the feed while LIVE is selected" do
    events = [bus(1, "emit", "ticket.401.pr.opened", "one", stamp(1))]
    logs = StreamdeckLogs.project(%{events: events, transcript: []})
    assert logs.selected_event_id == :live

    refreshed = StreamdeckLogs.refresh(logs, %{events: events ++ [bus(2, "emit", "ticket.401.ci.passed", "two", stamp(2))], transcript: []})

    assert refreshed.selected_event_id == :live
    assert refreshed.transcript_offset == refreshed.transcript_max_offset
  end

  test "refreshes key-relative times as the view remains open" do
    now = DateTime.utc_now()
    timestamp = now |> DateTime.add(-1, :second) |> DateTime.to_iso8601()
    logs = StreamdeckLogs.project(%{events: [bus(1, "emit", "ticket.401.pr.opened", "recent", timestamp)], transcript: []})

    assert Enum.at(logs.event_keys, 1).time == "now"

    refreshed = StreamdeckLogs.refresh_relative_times(logs, DateTime.add(now, 60, :second))

    assert Enum.at(refreshed.event_keys, 1).time == "1m"
    assert List.last(refreshed.event_keys).time == ""
  end

  test "refresh keeps how far into the selected event the transcript is scrolled" do
    events = Enum.map(1..4, &bus(&1, "emit", "ticket.401.pr.opened", "e#{&1}", stamp(&1)))
    transcript = Enum.map(1..4, &message("m#{&1}", stamp_after(&1)))

    scrolled =
      %{events: events, transcript: Enum.reverse(transcript)}
      |> StreamdeckLogs.project()
      |> StreamdeckLogs.select_event(2)
      |> StreamdeckLogs.scroll(:transcript, 1)

    assert scrolled.selected_event_id == {:bus, 2}
    assert scrolled.transcript_offset == start_of(scrolled) + 1

    refreshed =
      StreamdeckLogs.refresh(scrolled, %{
        events: [bus(0, "emit", "ticket.401.agent.progress", "new oldest", "2026-08-01T00:00:00Z") | events],
        transcript: Enum.reverse(transcript)
      })

    # The event moved one slot later, so its absolute start moved too — and the
    # operator is still exactly one line into it rather than back at its header.
    assert refreshed.selected_event_id == {:bus, 2}
    assert start_of(refreshed) > start_of(scrolled)
    assert refreshed.transcript_offset == start_of(refreshed) + 1
  end

  defp start_of(logs), do: logs.event_keys |> Enum.at(logs.selected_event_index) |> Map.fetch!(:start)

  test "refresh keeps the key window the operator scrolled to" do
    events = Enum.map(1..12, &bus(&1, "emit", "ticket.401.pr.opened", "e#{&1}", stamp(&1)))
    logs = %{events: events, transcript: []} |> StreamdeckLogs.project() |> StreamdeckLogs.scroll(:events, -3)

    assert logs.events_offset == 3

    refreshed = StreamdeckLogs.refresh(logs, %{events: events, transcript: []})

    assert refreshed.events_offset == 3
    assert Enum.map(refreshed.event_keys_visible, & &1.index) == Enum.to_list(3..10)
  end

  test "renders each flattened row as a line" do
    assert StreamdeckLogs.line(%{kind: :event_header, badge: "EMIT", body: "opened"}) == "[EMIT] opened"
    assert StreamdeckLogs.line(%{kind: :message, role: "assistant", body: "hi"}) == "[assistant] hi"
    # A hunk line keeps its sign: it is the only thing saying added or removed.
    assert StreamdeckLogs.line(%{kind: :diff_line, sign: "+", text: "  ok"}) == "+  ok"
    assert StreamdeckLogs.line(%{kind: :diff_line, sign: " ", text: "  same"}) == "   same"
    assert StreamdeckLogs.line(%{kind: :diff, path: nil, additions: 1, deletions: 2, line: "+x"}) == "[diff] changed file +1 -2 +x"
    assert StreamdeckLogs.line(%{kind: :mystery}) == "[INFO]"
  end

  # The hunk is unrolled into one row per line, not packed into the diff row.
  # The client addresses transcript rows by index to scroll and to jump, so a
  # row that painted three lines would move the readout three rows per detent.
  test "unrolls a diff into a header row plus one row per hunk line" do
    logs =
      StreamdeckLogs.project(%{
        events: [],
        transcript: [%{type: "diff", path: "lib/a.ex", additions: 1, deletions: 1, line: "+ok", lines: [%{sign: "+", text: "ok"}, %{sign: "-", text: "gone"}], timestamp: stamp(1)}]
      })

    assert Enum.map(logs.transcript, & &1.kind) == [:event_header, :diff, :diff_line, :diff_line]
    assert Enum.filter(logs.transcript, &(&1.kind == :diff_line)) == [%{kind: :diff_line, sign: "+", text: "ok"}, %{kind: :diff_line, sign: "-", text: "gone"}]

    # The header no longer carries the lines it was unrolled into.
    diff = Enum.find(logs.transcript, &(&1.kind == :diff))
    refute Map.has_key?(diff, :lines)
    assert diff.line == "+ok"
  end

  test "a diff with no lines still projects as a single header row" do
    logs = StreamdeckLogs.project(%{events: [], transcript: [%{type: "diff", path: "lib/a.ex", timestamp: stamp(1)}]})

    assert Enum.map(logs.transcript, & &1.kind) == [:event_header, :diff]
    diff = Enum.find(logs.transcript, &(&1.kind == :diff))
    refute Map.has_key?(diff, :lines)
    assert diff.additions == 0
  end

  # `nil` is an atom, and the generic atom clause used to send it as the string
  # "nil" — the same defect as the persisted turn id, one layer out. A client
  # reading an absent tool name would have rendered every tool row as "Nil".
  test "wires an absent value as JSON null, never the string \"nil\"" do
    wire =
      %{events: [], transcript: [%{type: "message", role: "tool", body: "src/a.ex", tool: nil, timestamp: stamp(1)}]}
      |> StreamdeckLogs.project()
      |> StreamdeckLogs.wire()

    row = wire["transcript"] |> Enum.find(&(&1["kind"] == "message"))
    assert row["tool"] == nil
    assert wire["event_keys"] |> List.last() |> Map.get("timestamp") == nil
  end

  # An event with no usable timestamp must claim nothing rather than everything:
  # the walk runs newest-first, so a match-everything boundary handed one
  # malformed event the whole transcript and emptied every older key.
  test "an event with no timestamp does not swallow the transcript" do
    logs =
      StreamdeckLogs.project(%{
        events: [
          bus(1, "emit", "ticket.401.pr.opened", "real", stamp(1)),
          %{type: "event", id: 2, kind: "emit", badge: "EMIT", label: "Broken", body: "", timestamp: nil}
        ],
        transcript: [message("said after the first event", stamp(2))]
      })

    starts = Enum.map(logs.event_keys, & &1.start)
    assert starts == Enum.sort(starts)
    # The entry belongs to the real event it followed, not to the undated one.
    assert Enum.at(logs.transcript, 2).body == "said after the first event"
  end

  # ISO 8601 is only lexically ordered at equal precision in one offset.
  test "orders entries by instant, not by string, across mixed precisions" do
    logs =
      StreamdeckLogs.project(%{
        events: [bus(1, "emit", "ticket.401.pr.opened", "boundary", "2026-08-02T00:10:00Z")],
        transcript: [
          message("after, with sub-second precision", "2026-08-02T00:10:00.500000Z"),
          message("before", "2026-08-02T00:09:59Z")
        ]
      })

    bodies = Enum.map(logs.transcript, fn row -> Map.get(row, :body) end)
    assert bodies == ["Ticket opened", "before", "boundary", "after, with sub-second precision"]
  end

  # The window stops at the end of the transcript even though the reading
  # position does not, so scrolling fully right paints a full readout.
  test "clamps the visible window to the end while keeping every row addressable" do
    # `list/2` hands back newest-first, which the projection reverses.
    logs = StreamdeckLogs.project(%{events: [], transcript: Enum.map(6..1//-1, &message("m#{&1}", stamp(&1)))})

    assert logs.transcript_max_offset == length(logs.transcript) - 1
    assert length(logs.transcript_visible) == 2
    assert List.last(logs.transcript_visible).body == "m6"
  end

  # An unattributable row is still something the agent said, so it falls to the
  # origin rather than being dropped.
  test "keeps a transcript entry with no timestamp under the origin" do
    logs =
      StreamdeckLogs.project(%{
        events: [bus(1, "emit", "ticket.401.pr.opened", "later", stamp(5))],
        transcript: [%{type: "message", role: "system", body: "undated"}]
      })

    assert Enum.map(logs.transcript, & &1.kind) == [:event_header, :message, :event_header]
    assert Enum.at(logs.transcript, 1).body == "undated"
  end

  test "shows the publisher's summary when it says more than the topic name" do
    logs =
      StreamdeckLogs.project(%{
        events: [
          bus(1, "emit", "ticket.401.pr.merged", "PR merged", stamp(1)),
          bus(2, "emit", "ticket.401.ci.failed", "credo --strict", stamp(2))
        ],
        transcript: []
      })

    headers = Enum.filter(logs.transcript, &(&1.kind == :event_header))
    assert Enum.map(headers, & &1.body) == ["Ticket opened", "PR merged", "credo --strict"]
  end

  test "renders a non-ISO timestamp as a truncated literal and a missing one as blank" do
    logs =
      StreamdeckLogs.project(%{
        events: [%{id: 1, kind: "emit", badge: "EMIT", label: "Odd", body: "", timestamp: "not-a-time"}],
        transcript: []
      })

    assert Enum.at(logs.event_keys, 1).time == "not-a-t" |> String.slice(0, 6)
  end

  defp bus(id, kind, topic, body, timestamp \\ "2026-08-02T00:00:00Z") do
    %{
      type: "event",
      id: id,
      kind: kind,
      topic: topic,
      badge: Aiur.AgentEventFeed.badge_for_kind(kind),
      label: Aiur.AgentEventFeed.topic_label(topic),
      body: body,
      timestamp: timestamp
    }
  end

  defp message(body, timestamp \\ "2026-08-02T00:00:00Z") do
    %{type: "message", role: "assistant", body: body, timestamp: timestamp}
  end

  defp stamp(index), do: "2026-08-02T00:#{String.pad_leading(to_string(index), 2, "0")}:00Z"
  defp stamp_after(index), do: "2026-08-02T00:#{String.pad_leading(to_string(index), 2, "0")}:30Z"
end
