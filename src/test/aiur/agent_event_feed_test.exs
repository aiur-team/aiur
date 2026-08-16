defmodule Aiur.AgentEventFeedTest do
  use Aiur.TestSupport

  import ExUnit.CaptureLog

  alias Aiur.{AgentEventFeed, IssueLog}

  setup do
    original_log_file = Application.get_env(:aiur, :log_file)
    identifier = "event-feed-#{System.unique_integer([:positive])}"
    tmp = Path.join(System.tmp_dir!(), "aiur-event-feed-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "log"))
    Application.put_env(:aiur, :log_file, Path.join(tmp, "log/aiur.log"))

    on_exit(fn ->
      if original_log_file, do: Application.put_env(:aiur, :log_file, original_log_file), else: Application.delete_env(:aiur, :log_file)
      File.rm_rf!(tmp)
    end)

    %{identifier: identifier}
  end

  test "returns durable events newest first with every documented badge", %{identifier: identifier} do
    write_events(identifier, [
      event("user", "executor input"),
      event("assistant", "agent response"),
      event("system", "provider context"),
      event("command", "mix test"),
      event("alert", "review needed"),
      event("reasoning", "checking state"),
      event("tool", "read lib/aiur.ex")
    ])

    assert {:ok, %{events: events, pagination: %{limit: 7, next_cursor: nil}}} = AgentEventFeed.list(identifier)
    assert Enum.map(events, & &1.badge) == ["EMIT", "INFO", "INFO", "EMIT", "SYSTEM", "AGENT", "CONSUME"]
    assert Enum.all?(events, &(&1.type == "message"))
  end

  test "paginates a durable transcript without scanning its history", %{identifier: identifier} do
    write_events(identifier, Enum.map(1..8, &event("assistant", "message #{&1}")))

    assert {:ok, %{events: first, pagination: %{next_cursor: cursor}}} = AgentEventFeed.list(identifier, %{"limit" => "3"})
    assert Enum.map(first, & &1.body) == ["message 8", "message 7", "message 6"]
    assert is_binary(cursor)

    assert {:ok, %{events: second}} = AgentEventFeed.list(identifier, %{"limit" => 3, "cursor" => cursor})
    assert Enum.map(second, & &1.body) == ["message 5", "message 4", "message 3"]
  end

  test "renders only provider file-change records as diffs", %{identifier: identifier} do
    diff = "--- a/lib/example.ex\n+++ b/lib/example.ex\n@@ -1 +1 @@\n-old\n+new"

    write_events(identifier, [
      event("tool", "edit lib/example.ex", %{"tool" => "edit", "changes" => [%{"path" => "lib/example.ex", "diff" => diff}], "output" => diff}),
      event("tool", "edit lib/replaced.ex", %{"tool" => "edit", "output" => "whole file content"})
    ])

    assert {:ok, %{events: [message, diff]}} = AgentEventFeed.list(identifier)
    assert %{type: "message", body: "edit lib/replaced.ex"} = message
    assert %{type: "diff", path: "lib/example.ex", additions: 1, deletions: 1, line: "new"} = diff
  end

  test "an agent with no events returns an empty page", %{identifier: identifier} do
    assert {:ok, %{events: [], pagination: %{next_cursor: nil}}} = AgentEventFeed.list(identifier)
  end

  test "writer preserves a transcript payload for the restart-safe feed", %{identifier: identifier} do
    tmp = Path.dirname(IssueLog.transcript_path(identifier))
    path = Path.join(tmp, "#{identifier}.log")
    event_path = Path.join(tmp, "#{identifier}.events.log")
    transcript_path = IssueLog.transcript_path(identifier)

    {:ok, pid} =
      IssueLog.start_link(
        identifier: identifier,
        path: path,
        event_path: event_path,
        transcript_path: transcript_path
      )

    on_exit(fn -> Aiur.TestSupport.safe_stop(pid) end)

    diff = "--- a/a.ex\n+++ b/a.ex\n+new"
    payload = %{tool: "edit", input: %{changes: [%{diff: diff}]}, output: diff}
    event = Aiur.AgentEvents.transcript_event(:tool, "edit a.ex", payload: payload)
    send(pid, {:transcript_event, event})
    send(pid, {:alert, Aiur.AgentEvents.alert_event("phase.review.start", "reviewing")})
    _ = :sys.get_state(pid)
    :ok = GenServer.stop(pid)

    assert {:ok, %{events: [alert, %{type: "diff", path: "a.ex", additions: 1, line: "new"}]}} = AgentEventFeed.list(identifier)
    assert %{type: "message", role: "alert", badge: "INFO", body: "reviewing"} = alert
  end

  test "writer caps oversized records so a bounded tail can still return them", %{identifier: identifier} do
    tmp = Path.dirname(IssueLog.transcript_path(identifier))
    transcript_path = IssueLog.transcript_path(identifier)

    {:ok, pid} =
      IssueLog.start_link(
        identifier: identifier,
        path: Path.join(tmp, "#{identifier}.log"),
        event_path: Path.join(tmp, "#{identifier}.events.log"),
        transcript_path: transcript_path
      )

    on_exit(fn -> Aiur.TestSupport.safe_stop(pid) end)

    event = Aiur.AgentEvents.transcript_event(:assistant, String.duplicate("x", 70_000))
    send(pid, {:transcript_event, event})
    _ = :sys.get_state(pid)

    assert {:ok, %{events: [%{type: "message", body: body}]}} = AgentEventFeed.list(identifier)
    assert String.ends_with?(body, "…")
    assert File.stat!(transcript_path).size < 16_384
  end

  test "writer recovers durable transcript writes after an I/O failure", %{identifier: identifier} do
    tmp = Path.dirname(IssueLog.transcript_path(identifier))

    {:ok, pid} =
      IssueLog.start_link(
        identifier: identifier,
        path: Path.join(tmp, "#{identifier}.log"),
        event_path: Path.join(tmp, "#{identifier}.events.log"),
        transcript_path: IssueLog.transcript_path(identifier)
      )

    on_exit(fn -> Aiur.TestSupport.safe_stop(pid) end)

    :ok = File.close(:sys.get_state(pid).transcript_file)

    log =
      capture_log(fn ->
        send(pid, {:transcript_event, Aiur.AgentEvents.transcript_event(:assistant, "will not persist")})
        _ = :sys.get_state(pid)
      end)

    assert log =~ "IssueLog transcript write failed identifier=#{identifier}"
    assert Process.alive?(pid)
    assert {:ok, %{events: [%{body: "will not persist"}]}} = AgentEventFeed.list(identifier)
  end

  test "large logs have bounded response size and tail-query time", %{identifier: identifier} do
    write_events(identifier, Enum.map(1..5_000, &event("assistant", String.duplicate("x", 80) <> " #{&1}")))
    started = System.monotonic_time(:microsecond)
    assert {:ok, payload} = AgentEventFeed.list(identifier)
    elapsed_us = System.monotonic_time(:microsecond) - started

    assert length(payload.events) == 7
    assert byte_size(Jason.encode!(payload)) < 2_000
    assert elapsed_us < 250_000
  end

  test "largest page includes fifty maximum-size records", %{identifier: identifier} do
    empty_record = event("assistant", "")
    body = String.duplicate("x", 16_384 - byte_size(Jason.encode!(empty_record)))
    record = event("assistant", body)
    assert byte_size(Jason.encode!(record)) == 16_384

    write_events(identifier, List.duplicate(record, 50))

    assert {:ok, %{events: events, pagination: %{limit: 50, next_cursor: nil}}} = AgentEventFeed.list(identifier, %{"limit" => 50})
    assert length(events) == 50
    assert hd(events).body == body
    assert List.last(events).body == body
  end

  test "rejects invalid page controls", %{identifier: identifier} do
    assert {:error, :invalid_limit} = AgentEventFeed.list(identifier, %{"limit" => "0"})
    assert {:error, :invalid_limit} = AgentEventFeed.list(identifier, %{"limit" => 51})
    assert {:error, :invalid_cursor} = AgentEventFeed.list(identifier, %{"cursor" => "bad"})
    assert {:error, :invalid_cursor} = AgentEventFeed.list(identifier, %{"cursor" => -1})
    assert {:error, :invalid_limit} = AgentEventFeed.list(identifier, [])
  end

  test "badge maps atoms, persisted strings, and unknown roles safely" do
    assert AgentEventFeed.badge(:command) == "EMIT"
    assert AgentEventFeed.badge("user") == "CONSUME"
    assert AgentEventFeed.badge("unknown") == "INFO"
  end

  test "retains unknown persisted roles with the INFO badge", %{identifier: identifier} do
    write_events(identifier, [event("provider_extension", "new provider event")])

    assert {:ok, %{events: [%{body: "new provider event", badge: "INFO"}]}} = AgentEventFeed.list(identifier)
  end

  test "keeps malformed payloads as messages and renders provider deleted lines", %{identifier: identifier} do
    diff = "@@ -1 +0,0 @@\n-old"

    write_events(identifier, [
      event("tool", "edit lib/removed.ex", %{"tool" => "edit", "changes" => [%{"path" => "lib/removed.ex", "diff" => diff}], "output" => diff}),
      event("assistant", "plain message", "not a payload map")
    ])

    assert {:ok, %{events: [message, diff]}} = AgentEventFeed.list(identifier)
    assert %{type: "message", body: "plain message", badge: "AGENT"} = message
    assert %{type: "diff", path: "lib/removed.ex", additions: 0, deletions: 1, line: "old"} = diff
  end

  test "does not expose Claude's pane-generated edit text as a diff", %{identifier: identifier} do
    pane_diff = "@@ lib/aiur.ex @@\n-old\n+new"

    write_events(identifier, [event("tool", "edit lib/aiur.ex", %{"tool" => "edit", "output" => pane_diff})])

    assert {:ok, %{events: [%{type: "message", body: "edit lib/aiur.ex"}]}} = AgentEventFeed.list(identifier)
  end

  test "renders a provider-marked Codex file change without a unified hunk", %{identifier: identifier} do
    write_events(identifier, [
      event("tool", "edit lib/x.ex", %{
        "tool" => "edit",
        "output" => "+ defmodule X do\n",
        "changes" => [%{"path" => "lib/x.ex", "diff" => "+ defmodule X do\n"}]
      })
    ])

    assert {:ok, %{events: [%{type: "diff", path: "lib/x.ex", additions: 1, deletions: 0, line: " defmodule X do"}]}} =
             AgentEventFeed.list(identifier)
  end

  test "keeps malformed records and incomplete provider changes as messages", %{identifier: identifier} do
    write_events(identifier, [
      %{"payload" => %{}},
      event("tool", "edit lib/incomplete.ex", %{"tool" => "edit", "changes" => [%{"path" => "lib/incomplete.ex"}]}),
      event("tool", "edit lib/empty.ex", %{"tool" => "edit", "changes" => [%{"path" => "lib/empty.ex", "diff" => ""}]})
    ])

    assert {:ok, %{events: events}} = AgentEventFeed.list(identifier)

    assert Enum.map(events, &Map.take(&1, [:type, :body, :badge])) == [
             %{type: "message", body: "edit lib/empty.ex", badge: "EMIT"},
             %{type: "message", body: "edit lib/incomplete.ex", badge: "EMIT"},
             %{type: "message", body: "", badge: "INFO"}
           ]
  end

  test "derives a diff path and accepts a zero cursor", %{identifier: identifier} do
    diff = "+++ lib/derived.ex\n-old\n+new"

    write_events(identifier, [
      event("assistant", "first"),
      event("tool", "edit lib/derived.ex", %{"tool" => "edit", "changes" => [%{"diff" => diff}]})
    ])

    assert {:ok, %{events: [%{type: "diff", path: "lib/derived.ex", additions: 1, deletions: 1, line: "new"}]}} =
             AgentEventFeed.list(identifier, %{"limit" => 1})

    assert {:ok, %{events: []}} = AgentEventFeed.list(identifier, %{"limit" => 1, "cursor" => "0"})
  end

  test "derives diff metadata from real headers and retains event context", %{identifier: identifier} do
    write_events(identifier, [
      event("tool", "edit lib/header.ex", %{
        "tool" => "edit",
        "changes" => [%{"diff" => "--- a/lib/header.ex\n+++ b/lib/header.ex\n-old"}]
      }),
      event("tool", "edit lib/fallback.ex", %{
        "tool" => "edit",
        "changes" => [%{"diff" => "-old\n+new"}]
      })
    ])

    assert {:ok, %{events: [fallback, header]}} = AgentEventFeed.list(identifier)
    assert %{type: "diff", path: nil, additions: 1, deletions: 1, line: "new"} = fallback
    assert %{type: "diff", path: "lib/header.ex", additions: 0, deletions: 1, line: "old"} = header
  end

  # ---------------------------------------------------------------------------
  # Shared event bus
  # ---------------------------------------------------------------------------

  describe "bus_events/2" do
    test "reads the ticket's published events oldest first", %{identifier: identifier} do
      write_bus_log(identifier, [
        "2026-07-30T00:01:00Z [event:emit] id=11 ticket.#{identifier}.pr.opened: PR #1904",
        "2026-07-30T00:02:00Z [event:consumed] id=12 ticket.#{identifier}.issue.commented: please rotate refresh too",
        "2026-07-30T00:03:00Z [event:self] id=13 ticket.#{identifier}.agent.progress: 72%"
      ])

      assert [first, second, third] = AgentEventFeed.bus_events(identifier)
      assert Enum.map([first, second, third], & &1.id) == [11, 12, 13]
      assert Enum.map([first, second, third], & &1.label) == ["PR opened", "Comment", "Progress"]
      assert Enum.map([first, second, third], & &1.badge) == ["EMIT", "CONSUME", "AGENT"]
      assert first.body == "PR #1904"
      assert first.timestamp == "2026-07-30T00:01:00Z"
    end

    test "a ticket that has published nothing is an empty list, not an error", %{identifier: identifier} do
      assert AgentEventFeed.bus_events(identifier) == []
    end

    # A log written by an older build can hold a byte-sliced summary that is not
    # valid UTF-8. `Jason` raises on such a byte, and Phoenix serialises from the
    # socket transport process, so the raise would tear down the whole Stream
    # Deck socket — then the sidecar reconnects, re-reads the same durable line
    # and dies again. Scrubbing on read is what stops one bad byte from being a
    # permanent outage.
    test "survives a summary that is not valid UTF-8, and stays JSON-encodable", %{identifier: identifier} do
      corrupt = binary_part("progress: 🚀 shipping", 0, 13)
      refute String.valid?(corrupt)

      write_bus_log(identifier, [
        "2026-07-30T00:01:00Z [event:emit] id=1 ticket.#{identifier}.agent.progress: #{corrupt}"
      ])

      assert [event] = AgentEventFeed.bus_events(identifier)
      assert String.valid?(event.body)
      assert event.body == "progress:"
      assert {:ok, _encoded} = Jason.encode(%{"body" => event.body})
    end

    test "honours the limit so a long-lived ticket cannot flood the wire", %{identifier: identifier} do
      write_bus_log(
        identifier,
        Enum.map(1..30, &"2026-07-30T00:00:00Z [event:emit] id=#{&1} ticket.#{identifier}.pr.opened: e#{&1}")
      )

      assert length(AgentEventFeed.bus_events(identifier, limit: 5)) == 5
    end
  end

  describe "topic_label/1" do
    test "writes out the topics a ticket actually publishes" do
      assert AgentEventFeed.topic_label("ticket.401.pr.merged") == "PR merged"
      assert AgentEventFeed.topic_label("ticket.401.ci.failed") == "CI failed"
      assert AgentEventFeed.topic_label("ticket.401.agent.progress.checkin") == "Progress check-in"
      assert AgentEventFeed.topic_label("ticket.401.decision.requested") == "Decision requested"
    end

    # A routing key is precise and unreadable at key-face size, but degrading to
    # its own segments still beats a blank key.
    test "degrades an unknown topic to its own segments rather than to nothing" do
      assert AgentEventFeed.topic_label("ticket.401.agent.some_new_thing") == "Agent some new thing"
      assert AgentEventFeed.topic_label("system.main.branch.push") == "Branch push"
      assert AgentEventFeed.topic_label(nil) == "Event"
      assert AgentEventFeed.topic_label("") == "Event"
    end
  end

  describe "badge_for_kind/1" do
    # Direction is what the marker kind records. Deriving it from the topic
    # would make the same `pr.merged` read EMIT when published and CONSUME when
    # received.
    test "maps each marker kind onto its direction" do
      assert AgentEventFeed.badge_for_kind("consumed") == "CONSUME"
      assert AgentEventFeed.badge_for_kind("emit_alert") == "SYSTEM"
      assert AgentEventFeed.badge_for_kind("self") == "AGENT"
      assert AgentEventFeed.badge_for_kind("emit") == "EMIT"
      assert AgentEventFeed.badge_for_kind(:self) == "AGENT"
      assert AgentEventFeed.badge_for_kind("something else") == "EMIT"
    end
  end

  # The Stream Deck's bottom panel renders a real diff, so the feed has to carry
  # the lines rather than only the first changed one.
  test "carries a bounded window of real hunk lines for a provider diff", %{identifier: identifier} do
    hunk =
      Enum.join(
        ["diff --git a/lib/a.ex b/lib/a.ex", "--- a/lib/a.ex", "+++ b/lib/a.ex", "@@ -1,3 +1,3 @@", " context", "-gone", "+added"],
        "\n"
      )

    write_events(identifier, [
      event("tool", "edit lib/a.ex", %{"tool" => "edit", "changes" => [%{"path" => "lib/a.ex", "diff" => hunk}]})
    ])

    assert {:ok, %{events: [diff]}} = AgentEventFeed.list(identifier)

    assert diff.lines == [
             %{sign: " ", text: "context"},
             %{sign: "-", text: "gone"},
             %{sign: "+", text: "added"}
           ]
  end

  defp write_bus_log(identifier, lines) do
    path = IssueLog.event_log_path(identifier)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.join(lines, "\n") <> "\n")
  end

  defp write_events(identifier, events) do
    path = IssueLog.transcript_path(identifier)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n")
  end

  defp event(role, body, payload \\ nil) do
    %{
      "role" => role,
      "body" => body,
      "timestamp" => "2026-07-30T00:00:00Z",
      "msg_id" => nil,
      "sequence" => 1,
      "turn_id" => nil,
      "payload" => payload
    }
  end
end
