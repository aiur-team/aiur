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

    payload = %{tool: "edit", input: %{changes: [%{path: "a.ex", diff: "+new"}]}, output: "+new"}
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

  test "largest page includes fifty bounded records", %{identifier: identifier} do
    write_events(identifier, Enum.map(1..50, &event("assistant", String.duplicate("x", 2_000) <> " #{&1}")))

    assert {:ok, %{events: events, pagination: %{limit: 50, next_cursor: nil}}} = AgentEventFeed.list(identifier, %{"limit" => 50})
    assert length(events) == 50
    assert String.ends_with?(hd(events).body, " 50")
    assert String.ends_with?(List.last(events).body, " 1")
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
    assert AgentEventFeed.badge("unknown") == "SYSTEM"
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
    assert %{type: "diff", path: "edit lib/fallback.ex", additions: 1, deletions: 1, line: "new"} = fallback
    assert %{type: "diff", path: "lib/header.ex", additions: 0, deletions: 1, line: "old"} = header
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
