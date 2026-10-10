defmodule Aiur.Conversation.HistoryTest do
  use Aiur.TestSupport

  alias Aiur.Conversation.History

  # Future-regression guard: unknown generations already preserve uncertainty.
  test "live reads preserve restart_unknown and invalid handle results" do
    handle = "conversation:" <> String.duplicate("A", 43)

    assert {:ok,
            %{
              state: :restart_unknown,
              health: :unknown,
              freshness: :unknown,
              generation_handle: ^handle,
              messages: []
            }} = History.live_resolve(handle)

    assert History.live_resolve("invalid") == {:error, :invalid_handle}
    assert History.live_subscribe(handle) == :ok
    assert History.live_unsubscribe(handle) == :ok
  end

  test "transcript and bus reads use the existing durable logs" do
    identifier = "history-#{System.unique_integer([:positive])}"
    path = Aiur.IssueLog.transcript_path(identifier)
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        role: "assistant",
        body: "facade transcript",
        timestamp: "2026-10-09T12:00:00Z"
      }) <> "\n"
    )

    assert {:ok, %{events: [%{body: "facade transcript"}], pagination: %{limit: 1}}} =
             History.transcript(identifier, %{"limit" => 1})

    assert History.transcript(identifier, %{"limit" => "invalid"}) == {:error, :invalid_limit}
    bus_path = Aiur.IssueLog.event_log_path(identifier)

    File.write!(
      bus_path,
      "2026-10-09T12:00:00Z [event:emit] id=1 ticket.#{identifier}.pr.opened: first\n2026-10-09T12:00:01Z [event:emit] id=2 ticket.#{identifier}.pr.merged: second\n"
    )

    assert [%{id: 1, body: "first"}, %{id: 2, body: "second"}] = History.bus_events(identifier)
    assert [%{id: 2, body: "second"}] = History.bus_events(identifier, limit: 1)
  end

  test "workspace and anchor reads preserve content and observed placement" do
    workspace = Aiur.TestSupport.tmp_root!("history")
    on_exit(fn -> File.rm_rf!(workspace) end)
    path = History.workspace_log_path(workspace)
    File.mkdir_p!(Path.dirname(path))

    content =
      Jason.encode!(%{
        event: "notification",
        timestamp: "2026-10-09T12:00:00Z",
        raw: Jason.encode!(%{method: "item/agentMessage/delta", params: %{delta: "workspace reply"}})
      }) <> "\n"

    File.write!(path, content)

    assert History.read_log(path) == content
    assert [%{role: "assistant", body: "workspace reply"}] = History.parse_log(content)

    assert %{path: ^path, messages: [%{role: "assistant", body: "workspace reply"}]} =
             History.workspace_log(workspace)

    entries = [%{timestamp: "2026-10-09T12:00:01Z", body: "reply"}]
    events = [%{id: :event, timestamp: "2026-10-09T12:00:00Z"}]

    assert [%{id: :origin, timestamp: "2026-10-09T12:00:00Z"}, %{id: :event}] =
             anchors = History.load_anchors(events, entries)

    assert [%{id: :origin, entries: []}, %{id: :event, entries: ^entries}] =
             History.anchor(anchors, entries)
  end
end
