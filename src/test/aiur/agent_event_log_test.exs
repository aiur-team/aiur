defmodule Aiur.AgentEventLogTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentEventLog

  defp tmp_workspace do
    path = Aiur.TestSupport.tmp_root!("aiur-eventlog")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  describe "write/3" do
    test "writes both agent.ndjson and agent.md when worker_host is nil and workspace is local" do
      # `agent.ndjson` is the full structured event stream: every event lands
      # there, not just `alert` events. It must stay unfiltered — AlertFeed
      # reads its `alert` lines, and #708 requires non-alert crash reasons
      # (e.g. {:port_exit, N}) to persist too. This plain `notification` event
      # stands in for "anything not an alert" and must still reach the file, so
      # an event-type filter can't sneak back in.
      workspace = tmp_workspace()
      message = %{event: "notification", timestamp: ~U[2026-01-01 00:00:00Z], last_message: "hello"}

      assert :ok = AgentEventLog.write(workspace, nil, message)

      ndjson = File.read!(Path.join(workspace, "logs/agent.ndjson"))
      markdown = File.read!(Path.join(workspace, "logs/agent.md"))

      assert ndjson =~ ~s("event":"notification")
      assert ndjson =~ ~s("last_message":"hello")
      assert markdown =~ "## 2026-01-01T00:00:00Z notification"
      assert markdown =~ "hello"
    end

    test "renders the raw payload in a code block when no last_message is present" do
      workspace = tmp_workspace()
      message = %{event: "warning", raw: "{\"foo\":\"bar\"}"}

      assert :ok = AgentEventLog.write(workspace, nil, message)

      markdown = File.read!(Path.join(workspace, "logs/agent.md"))
      assert markdown =~ "```text"
      assert markdown =~ "{\"foo\":\"bar\"}"
    end

    test "projects the structured record when neither last_message nor raw is present" do
      workspace = tmp_workspace()
      message = %{event: "custom", payload: %{score: 1}}

      assert :ok = AgentEventLog.write(workspace, nil, message)

      markdown = File.read!(Path.join(workspace, "logs/agent.md"))
      assert markdown =~ "```text"
      assert markdown =~ ~s("event":"custom")
      assert markdown =~ ~s("payload":{"score":1})
    end

    test "no-ops when worker_host is a remote string (writes go to that host instead)" do
      workspace = tmp_workspace()

      assert :ok = AgentEventLog.write(workspace, "remote.example.com", %{event: "notification"})

      refute File.exists?(Path.join(workspace, "logs/agent.ndjson"))
    end

    test "no-ops when neither workspace nor worker_host fit the local-write contract" do
      assert :ok = AgentEventLog.write(nil, nil, %{event: "notification"})
      assert :ok = AgentEventLog.write("anywhere", nil, :not_a_map)
    end

    test "returns :ok and logs at debug when the filesystem write would crash" do
      # An unwritable workspace path triggers the rescue branch. Writing
      # inside a regular file (not a directory) makes `File.mkdir_p`
      # fail with ENOTDIR, and `File.write` then raises if the rescue
      # path isn't taken.
      blocker = Aiur.TestSupport.tmp_root!("aiur-eventlog-blocker")
      File.touch!(blocker)
      on_exit(fn -> File.rm!(blocker) end)

      # `<blocker>/sub` is invalid because `blocker` is a regular file.
      workspace = Path.join(blocker, "sub")

      assert :ok = AgentEventLog.write(workspace, nil, %{event: "notification"})
    end

    test "rescues exceptions raised during encoding" do
      # Jason can't encode a function reference. The function does
      # everything inside the `with` chain, so when `Jason.encode!`
      # raises we land in the rescue clause and still return :ok.
      workspace = tmp_workspace()

      assert :ok =
               AgentEventLog.write(workspace, nil, %{
                 event: "notification",
                 weird: fn -> :nope end
               })
    end

    test "stringifies non-atom keys (e.g. binary keys from JSON-decoded payloads)" do
      workspace = tmp_workspace()

      assert :ok =
               AgentEventLog.write(workspace, nil, %{
                 "event" => "notification",
                 "last_message" => "hi"
               })

      ndjson = File.read!(Path.join(workspace, "logs/agent.ndjson"))
      assert ndjson =~ ~s("event":"notification")
      assert ndjson =~ ~s("last_message":"hi")
    end

    test "serialises atom and DateTime values via the JSON-safe path" do
      workspace = tmp_workspace()

      assert :ok =
               AgentEventLog.write(workspace, nil, %{
                 event: :notification,
                 timestamp: ~U[2026-05-17 12:00:00Z],
                 nested: [1, :two, nil]
               })

      ndjson = File.read!(Path.join(workspace, "logs/agent.ndjson"))
      assert ndjson =~ ~s("event":"notification")
      assert ndjson =~ ~s("nested":[1,"two",null])
    end

    test "persists a tuple crash reason (e.g. {:port_exit, N}) as a JSON list" do
      # Regression for #708/#699: a `{:port_exit, 1}` reason is not
      # JSON-encodable, so `Jason.encode!` used to raise and the rescue
      # swallowed the whole record — the crash detail never reached
      # agent.ndjson. The tuple must now round-trip as a list.
      workspace = tmp_workspace()

      assert :ok =
               AgentEventLog.write(workspace, nil, %{
                 event: "turn_ended_with_error",
                 reason: {:port_exit, 1}
               })

      ndjson = File.read!(Path.join(workspace, "logs/agent.ndjson"))
      markdown = File.read!(Path.join(workspace, "logs/agent.md"))
      assert ndjson =~ ~s("event":"turn_ended_with_error")
      assert ndjson =~ ~s("reason":["port_exit",1])
      assert markdown =~ ~s("reason":["port_exit",1])
    end

    test "accepts a binary timestamp string in the message and renders it unchanged" do
      workspace = tmp_workspace()

      assert :ok =
               AgentEventLog.write(workspace, nil, %{
                 event: "notification",
                 timestamp: "2026-05-17T12:00:00Z",
                 last_message: "ok"
               })

      markdown = File.read!(Path.join(workspace, "logs/agent.md"))
      assert markdown =~ "## 2026-05-17T12:00:00Z notification"
    end

    test "supplies the current time when the timestamp is missing or not a known type" do
      workspace = tmp_workspace()

      assert :ok =
               AgentEventLog.write(workspace, nil, %{
                 event: "notification",
                 timestamp: 12_345,
                 last_message: "ok"
               })

      markdown = File.read!(Path.join(workspace, "logs/agent.md"))
      assert markdown =~ ~r/## \d{4}-\d{2}-\d{2}T/
    end
  end
end
