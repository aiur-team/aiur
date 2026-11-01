Code.require_file("../../aiur/conversation/journal_support.exs", __DIR__)

defmodule AiurWeb.ExecutorTranscriptPrivacyTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase
  import Aiur.TestSupport.BuildHome.ProtocolCase, except: [source: 1]
  import Aiur.Conversation.TestSupport, only: [flush: 1]
  alias Aiur.Conversation.{History, Ref, TestSupport}
  alias Aiur.Executor.{Session, TranscriptIngest}

  setup context do
    context = TestSupport.setup(context)
    previous = Application.fetch_env(:aiur, :executor_state_dir)
    Application.put_env(:aiur, :executor_state_dir, Path.join(context.root, "executor"))

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :executor_state_dir, value)
        :error -> Application.delete_env(:aiur, :executor_state_dir)
      end
    end)

    start_supervised!({Session, instance_key: "executor-view-test"})
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    Map.put(context, :tail_supervisor, supervisor)
  end

  test "Executor capture excludes reasoning and credentials through history and display", context do
    token = "ghp_" <> String.duplicate("a", 36)
    thought = "private reasoning fixture"
    path = Path.join([context.root, ".claude/projects/project", "session.jsonl"])

    records = [
      %{"type" => "assistant", "uuid" => "answer", "message" => %{"content" => [%{"type" => "thinking", "thinking" => thought}, %{"type" => "text", "text" => "answer #{token}"}]}},
      %{"type" => "user", "uuid" => "prompt", "message" => %{"content" => "prompt #{token}"}},
      %{"type" => "user", "uuid" => "result", "message" => %{"content" => [%{"type" => "tool_result", "tool_use_id" => "call", "content" => "output #{token}"}]}}
    ]

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(records, "", &(Jason.encode!(&1) <> "\n")))
    assert {:ok, binding} = Session.attach(%{harness: "claude"})
    assert {:ok, _} = Session.bind_provider_session(binding.binding_id, %{session_id: "session", transcript_path: path})
    start_supervised!({TranscriptIngest, home: context.root, pubsub: context.pubsub, supervisor: context.tail_supervisor, interval_ms: nil})
    assert :ok = TranscriptIngest.poll()
    assert :ok = flush(context.ref)

    [segment] = Path.wildcard(Path.join(context.dir, "entries.*.jsonl"))
    bytes = File.read!(segment)
    refute bytes =~ token
    refute bytes =~ thought
    assert {:ok, internal} = History.list_entries(Ref.executor(), from_start: true, principal: :internal)
    assert Enum.map(internal.entries, & &1.kind) == ["message", "operator_message", "tool_result"]
    assert hd(internal.entries).body == "answer [REDACTED:ghp]"

    # Device reads must also preserve the capture privacy policy.
    assert {:ok, device} = History.list_entries(Ref.executor(), from_start: true, principal: {:device, "paired"})
    assert Enum.map(device.entries, & &1.body) == ["answer [REDACTED:ghp]", "prompt [REDACTED:ghp]", "tool result"]
    assert List.last(device.entries).output == "output [REDACTED:ghp]"
    refute Jason.encode!(device.entries) =~ token

    conn = %{build_conn() | remote_ip: {192, 0, 2, 1}}
    conn = Plug.Conn.put_private(conn, :live_view_connect_info, %{peer_data: %{address: {192, 0, 2, 1}}})
    assert {:ok, view, html} = live(conn, "/conversations/#{Ref.conversation_id(context.ref)}")
    assert has_element?(view, "#entry-1", "answer [REDACTED:ghp]")
    assert has_element?(view, ".conversation-divider", "Session 1")
    refute has_element?(view, ".conversation-reasoning")
    refute html =~ thought
    refute html =~ token
    refute html =~ "Show raw"
    refute render_click(view, "reveal_entry", %{"pos" => "1"}) =~ token
    assert File.read!(segment) == bytes
  end
end
