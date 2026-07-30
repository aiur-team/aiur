defmodule Aiur.AgentEventFeedTest do
  use Aiur.TestSupport

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

  test "renders only real unified-diff payloads as diffs", %{identifier: identifier} do
    diff = "--- a/lib/example.ex\n+++ b/lib/example.ex\n@@ -1 +1 @@\n-old\n+new"

    write_events(identifier, [
      event("tool", "edit lib/example.ex", %{"tool" => "edit", "output" => diff}),
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

    payload = %{tool: "edit", output: "--- a/a.ex\n+++ b/a.ex\n@@ -1 +1 @@\n-old\n+new"}
    event = Aiur.AgentEvents.transcript_event(:tool, "edit a.ex", payload: payload)
    send(pid, {:transcript_event, event})
    send(pid, {:alert, Aiur.AgentEvents.alert_event("phase.review.start", "reviewing")})
    _ = :sys.get_state(pid)

    assert {:ok, %{events: [alert, %{type: "diff", path: "a.ex"}]}} = AgentEventFeed.list(identifier)
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

  test "large logs have bounded response size and tail-query time", %{identifier: identifier} do
    write_events(identifier, Enum.map(1..5_000, &event("assistant", String.duplicate("x", 80) <> " #{&1}")))
    started = System.monotonic_time(:microsecond)
    assert {:ok, payload} = AgentEventFeed.list(identifier)
    elapsed_us = System.monotonic_time(:microsecond) - started

    assert length(payload.events) == 7
    assert byte_size(Jason.encode!(payload)) < 2_000
    assert elapsed_us < 250_000
  end

  test "rejects invalid page controls", %{identifier: identifier} do
    assert {:error, :invalid_limit} = AgentEventFeed.list(identifier, %{"limit" => "0"})
    assert {:error, :invalid_cursor} = AgentEventFeed.list(identifier, %{"cursor" => "bad"})
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
