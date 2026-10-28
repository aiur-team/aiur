Code.require_file("journal_support.exs", __DIR__)

defmodule Aiur.Conversation.WorkerTeeTest do
  use ExUnit.Case, async: false
  alias Aiur.AgentRunner.{MessageHandler, SessionLifecycle}
  alias Aiur.Conversation.{Ingest, Ref}
  alias Aiur.{Issue, TrackerIdentity}
  import Aiur.Conversation.TestSupport
  import Aiur.TestSupport, only: [receive_barrier: 1]

  setup context do
    context = Aiur.Conversation.TestSupport.setup(context)
    id = Integer.to_string(System.unique_integer([:positive]))
    {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => "I_#{id}", "number" => 6624}, {"test", "repo"}, {"test", "repo"})
    issue = %Issue{id: id, identifier: id, tracker_identity: identity}
    {:ok, ref} = Ref.worker(identity)
    opts = [session_id: "worker-session", attempt_id: "attempt-one", live_conversation: :disabled, resumed: true]
    Map.merge(context, %{issue: issue, ref: ref, dir: Path.join(context.root, Ref.conversation_id(ref)), opts: opts})
  end

  test "normalized Codex records retain order, item identity and tool anchors", c do
    handler = handler(c)
    handler.(item("agentMessage", "answer", %{text: "hello"}, c.now))
    handler.(item("commandExecution", "cmd-one", %{command: "pwd", aggregatedOutput: "/work", exitCode: 0}, c.now))
    handler.(item("commandExecution", "cmd-two", %{command: "pwd", aggregatedOutput: "/work", exitCode: 0}, c.now))
    handler.(item("dynamicToolCall", "tool-one", %{tool: "read", arguments: "{}", success: true}, c.now))
    assert :ok = flush(c.ref)
    entries = rows(c.dir)
    assert Enum.map(entries, &{&1["pos"], &1["kind"]}) == [{1, "message"}, {2, "command"}, {3, "command"}, {4, "tool_result"}]
    assert Enum.map(entries, & &1["refs"]["provider_item_id"]) == ["answer", "cmd-one", "cmd-two", "tool-one"]
    assert List.last(entries)["refs"]["tool_call_id"] == "tool-one"
    assert [start] = sessions(c.dir)

    assert {start["harness"], start["provider_session_id"], start["aiur_attempt_id"], start["start_reason"]} ==
             {"codex", "worker-session", "attempt-one", "resume"}
  end

  test "delta is skipped while its completed message is journaled", c do
    handler = handler(c)
    handler.(%{event: :notification, payload: %{method: "item/agentMessage/delta", params: %{itemId: "answer", delta: "partial"}}})
    assert Registry.lookup(Aiur.Conversation.Registry, Ref.conversation_id(c.ref)) == []
    handler.(item("agentMessage", "answer", %{text: "complete"}, c.now))
    assert :ok = flush(c.ref)
    assert Enum.map(rows(c.dir), & &1["body"]) == ["complete"]
  end

  test "remote worker writes durable records without a workspace event log", c do
    workspace = Path.join(c.root, "workspace")
    File.mkdir_p!(workspace)
    handler = MessageHandler.build(nil, c.issue, workspace, "ssh-worker", "codex", nil, c.opts)
    handler.(item("agentMessage", "answer", %{text: "remote"}, c.now))
    assert :ok = flush(c.ref)
    assert Enum.map(rows(c.dir), & &1["body"]) == ["remote"]
    refute File.exists?(Path.join(workspace, "logs/agent.ndjson"))
    {:ok, writer} = Ingest.writer(c.ref)
    DynamicSupervisor.terminate_child(Aiur.Conversation.JournalSupervisor, writer)
    Aiur.TestCleanup.rm_rf!(workspace)
    {:ok, restarted} = Ingest.writer(c.ref)
    :sys.get_state(restarted)
    assert Enum.map(rows(c.dir), & &1["body"]) == ["remote"]
  end

  test "display authority skips hook skeletons and journals live plus backfill once", c do
    opts = Keyword.put(c.opts, :live_conversation_authority, :display_tailer)
    handler(c, opts).(%{event: :agent_message, body: "hook skeleton"})
    assert Registry.lookup(Aiur.Conversation.Registry, Ref.conversation_id(c.ref)) == []
    display = SessionLifecycle.display_tailer_handler(c.issue, "claude", opts)
    event = %{role: :assistant, body: "display answer", msg_id: "uuid-live", timestamp: c.now}
    display.(%{source_session_id: "display-session", transcript_event: event})
    display.(%{source_session_id: "display-session", projection_ingress: :display_backfill, transcript_event: event})
    display.(%{source_session_id: "display-session", projection_ingress: :display_backfill, transcript_event: %{event | msg_id: "uuid-old", body: "older answer"}})
    assert :ok = flush(c.ref)
    assert Enum.map(rows(c.dir), & &1["body"]) == ["display answer", "older answer"]
    assert [start] = sessions(c.dir)
    assert {start["harness"], start["provider_session_id"]} == {"claude", "display-session"}
  end

  test "display file replay deduplicates across a new daemon run and a stopped session", c do
    display = SessionLifecycle.display_tailer_handler(c.issue, "claude", c.opts)
    event = %{role: :assistant, body: "old", msg_id: "uuid-old", timestamp: c.now}
    display.(%{source_session_id: "display-session", transcript_event: event})
    assert :ok = flush(c.ref)
    {:ok, writer} = Ingest.writer(c.ref)
    DynamicSupervisor.terminate_child(Aiur.Conversation.JournalSupervisor, writer)
    Application.put_env(:aiur, :conversation_journal, Application.fetch_env!(:aiur, :conversation_journal) |> Keyword.put(:run_id, "run-two"))
    display.(%{source_session_id: "display-session", projection_ingress: :display_backfill, transcript_event: event})
    display.(%{source_session_id: "display-session", transcript_event: %{event | msg_id: "uuid-new", body: "new"}})
    assert :ok = flush(c.ref)
    assert Enum.map(rows(c.dir), & &1["body"]) == ["old", "new"]
    assert :ok = MessageHandler.finish_live_conversation(c.issue, "claude", :ok, Keyword.put(c.opts, :session_id, "display-session"))
    assert :ok = flush(c.ref)
    display.(%{source_session_id: "display-session", projection_ingress: :display_backfill, transcript_event: event})
    display.(%{source_session_id: "display-session", transcript_event: %{event | msg_id: "uuid-last", body: "last"}})
    assert :ok = flush(c.ref)
    assert Enum.map(rows(c.dir), & &1["body"]) == ["old", "new", "last"]
  end

  test "provider file replay rebuilds its cache after an ambiguous write", c do
    display = SessionLifecycle.display_tailer_handler(c.issue, "claude", c.opts)
    event = %{role: :assistant, body: "first", msg_id: "uuid-first", timestamp: c.now}
    display.(%{source_session_id: "display-session", transcript_event: event})
    assert :ok = flush(c.ref)
    actions(c.control, :append, [:ambiguous])
    second = %{event | body: "second", msg_id: "uuid-second"}
    display.(%{source_session_id: "display-session", transcript_event: second})
    assert {:error, :degraded} = flush(c.ref)
    assert :ok = flush(c.ref)
    assert :ok = MessageHandler.finish_live_conversation(c.issue, "claude", :ok, Keyword.put(c.opts, :session_id, "display-session"))
    assert :ok = flush(c.ref)
    display.(%{source_session_id: "display-session", projection_ingress: :display_backfill, transcript_event: second})
    assert :ok = flush(c.ref)
    entries = rows(c.dir)
    assert entries |> Enum.reject(&(&1["kind"] == "gap")) |> Enum.map(& &1["body"]) == ["first", "second"]
    assert Enum.count(entries, &(&1["kind"] == "gap" and &1["meta"]["reason"] == "source_unreadable")) == 1
  end

  test "operator deliveries carry delivery refs, deduplicate and ignore empty text", c do
    item = %{id: 42, category: :operator_message, body: %{text: "continue"}}
    assert :ok = MessageHandler.observe_operator_delivery(c.issue, item, "codex", c.opts)
    assert :ok = MessageHandler.observe_operator_delivery(c.issue, item, "codex", c.opts)
    assert :ok = MessageHandler.observe_operator_delivery(c.issue, %{item | id: 43, body: %{text: ""}}, "codex", c.opts)
    assert :ok = flush(c.ref)
    assert [entry] = rows(c.dir)
    assert {entry["kind"], entry["body"], entry["refs"]["delivery_id"]} == {"operator_message", "continue", "42"}
  end

  test "cold worker closure returns while journal disk preparation is blocked", c do
    actions(c.control, :prepare, [:blocked])
    task = Task.async(fn -> handler(c).(item("agentMessage", "answer", %{text: "hello"}, c.now)) end)
    receive_barrier({:store_blocked, :prepare, writer})
    on_exit(fn -> send(writer, :release_store) end)
    assert :ok = Task.await(task, 2000)
    send(writer, :release_store)
    assert :ok = flush(c.ref)
    assert Enum.map(rows(c.dir), & &1["body"]) == ["hello"]
  end

  for {result, reason} <- [{{:error, :provider_failed}, "crashed"}, {:ok, "stopped"}] do
    test "session finishes as #{reason}", c do
      handler(c).(item("agentMessage", "answer", %{text: "hello"}, c.now))
      assert :ok = MessageHandler.finish_live_conversation(c.issue, "codex", unquote(Macro.escape(result)), c.opts)
      assert :ok = flush(c.ref)
      assert [start, ending] = sessions(c.dir)
      assert start["type"] == "start"
      assert {ending["type"], ending["end_reason"], ending["last_pos"]} == {"end", unquote(reason), 1}
    end
  end

  test "journal can be disabled without disabling the worker", c do
    handler(c, Keyword.put(c.opts, :conversation_journal, :disabled)).(%{event: :agent_message, body: "disabled"})
    assert Registry.lookup(Aiur.Conversation.Registry, Ref.conversation_id(c.ref)) == []
    handler(c).(%{event: :agent_message, body: "enabled"})
    assert :ok = flush(c.ref)
    assert Enum.map(rows(c.dir), & &1["body"]) == ["enabled"]
  end

  test "worker closure survives an unavailable journal supervisor", c do
    handler(c).(%{event: :agent_message, body: "before shutdown"})
    assert :ok = flush(c.ref)
    assert Enum.map(rows(c.dir), & &1["body"]) == ["before shutdown"]
    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.Conversation.JournalSupervisor)
    on_exit(fn -> Supervisor.restart_child(Aiur.Supervisor, Aiur.Conversation.JournalSupervisor) end)
    # Future regression guard: Ingest already isolates missing-supervisor exits.
    assert :ok = handler(c).(%{event: :agent_message, body: "unavailable"})
    assert :ok = MessageHandler.finish_live_conversation(c.issue, "codex", :ok, c.opts)
    assert Enum.map(rows(c.dir), & &1["body"]) == ["before shutdown"]
  end

  defp handler(c, opts \\ nil), do: MessageHandler.build(nil, c.issue, nil, nil, "codex", "turn-one", opts || c.opts)

  defp item(type, id, fields, now) do
    %{event: :notification, timestamp: now, payload: %{method: "item/completed", params: %{item: Map.merge(%{id: id, type: type}, fields)}}}
  end
end
