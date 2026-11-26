Code.require_file("../../../aiur/conversation/journal_support.exs", __DIR__)

defmodule AiurWeb.Build.ConversationSource.JournalTest do
  use Aiur.TestSupport
  import Aiur.Conversation.TestSupport
  alias Aiur.Conversation.{History, Ingest, Ref, Store, TestSupport}
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.Build.{ConversationPayload, ConversationSource, Payload}
  alias AiurWeb.Build.ConversationSource.Journal

  setup context do
    context = TestSupport.setup(context)
    workspace_root = Aiur.TestSupport.tmp_root!("deck-journal-workspace")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/aiur", workspace_root: workspace_root)
    {:ok, identity} = Aiur.TrackerIdentity.from_github(%{"node_id" => "node-seven", "number" => 7}, {"owner", "aiur"}, {"owner", "aiur"})
    {:ok, worker} = Ref.worker(identity)
    workspace = Path.join([workspace_root, "owner", "aiur", "7"])
    running = %{identifier: "7", issue_id: "node-seven", tracker_identity: identity, workspace_path: workspace}
    EndpointStubs.scope(build_conversation_snapshot_fun: fn _, _ -> {:ok, %{running: [running]}} end)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace_root) end)
    Map.merge(context, %{worker: worker, identity: identity, workspace: workspace, deck_ref: %{id: "7"}})
  end

  test "default source reads a live worker journal with no workspace and survives a stopped writer", context do
    append(context.worker, [event(1)])
    refute File.exists?(context.workspace)
    source = ConversationSource.source()
    assert {:ok, ref} = ConversationSource.call(source, :prepare, [context.deck_ref])
    assert {:ok, %{state: :live, live?: true, entries: [entry]} = view} = ConversationSource.call(source, :tail, [ref, nil])
    assert entry.text == "message 1"
    assert entry.id == "journal:#{Ref.conversation_id(context.worker)}:1"
    assert Payload.validate(ConversationPayload.view("7", view)) == :ok
    {:ok, writer} = Ingest.writer(context.worker)
    :ok = DynamicSupervisor.terminate_child(Aiur.Conversation.JournalSupervisor, writer)
    assert {:ok, %{entries: [^entry]}} = Journal.tail(context.deck_ref, nil, [])
    append(context.worker, [event(2)])
    assert {:ok, %{entries: [%{text: "message 2"}], state: :live}} = Journal.tail(ref, view.last, [])
    assert {:ok, %{entries: [], state: :live}} = Journal.tail(ref, "journal:#{ref.journal_id}:2", [])
  end

  test "no journal visibly falls back to workspace rows; a new journal resets the old cursor", context do
    File.mkdir_p!(Path.join(context.workspace, "logs"))
    File.write!(Path.join(context.workspace, "logs/agent.ndjson"), line("workspace fallback"))
    EndpointStubs.scope(build_conversation_snapshot_fun: fn _, _ -> {:ok, %{running: []}} end)
    assert {:ok, %{entries: [%{text: "workspace fallback"}], last: cursor}} = Journal.tail(context.deck_ref, nil, [])
    append(context.worker, [event(1)])
    assert {:error, :reset} = Journal.tail(context.deck_ref, cursor, [])
    assert {:ok, %{entries: [%{text: "message 1"}]}} = Journal.tail(context.deck_ref, nil, [])
  end

  test "empty and corrupt journals do not silently substitute workspace history", context do
    File.mkdir_p!(Path.join(context.workspace, "logs"))
    File.write!(Path.join(context.workspace, "logs/agent.ndjson"), line("must not leak fallback"))
    dir = Path.join(context.root, Ref.conversation_id(context.worker))
    assert {:ok, _} = Store.prepare(dir, context.worker)
    assert {:ok, %{state: :known_empty, entries: []}} = Journal.tail(context.deck_ref, nil, [])
    File.write!(Path.join(dir, "head.json"), "broken")
    assert {:error, :unavailable} = Journal.tail(context.deck_ref, nil, [])
  end

  test "tail and backward pages are bounded, ordered and cursors stay scoped to the conversation", context do
    append(context.worker, Enum.map(1..450, &event/1))
    assert {:ok, tail} = Journal.tail(context.deck_ref, nil, [])
    assert Enum.map(tail.entries, & &1.text) == Enum.map(251..450, &"message #{&1}")
    assert tail.more?
    assert {:ok, older} = Journal.page(context.deck_ref, tail.before, [])
    assert Enum.map(older.entries, & &1.text) == Enum.map(51..250, &"message #{&1}")
    assert {:ok, first} = Journal.page(context.deck_ref, older.before, [])
    assert Enum.map(first.entries, & &1.text) == Enum.map(1..50, &"message #{&1}")
    refute first.more?
    assert first.before == nil
    assert {:error, :reset} = Journal.page(context.deck_ref, "journal:#{Ref.conversation_id(Ref.executor())}:10", [])
    assert {:error, :invalid_cursor} = Journal.page(context.deck_ref, nil, [])
  end

  test "catch-up pages advance at 200 and reset above the 5000-position cap", context do
    append(context.worker, Enum.map(1..5_002, &event/1))
    cursor = "journal:#{Ref.conversation_id(context.worker)}:"
    assert {:error, :reset} = Journal.tail(context.deck_ref, cursor <> "1", [])
    assert {:ok, page} = Journal.tail(context.deck_ref, cursor <> "2", [])
    assert length(page.entries) == 200
    assert hd(page.entries).text == "message 3"
    assert List.last(page.entries).text == "message 202"
    assert page.last == cursor <> "202"
    assert page.more?
    assert {:error, :reset} = Journal.tail(context.deck_ref, cursor <> "5003", [])
  end

  test "masked body and output match the JSON entries route for a device principal", context do
    token = "ghp_" <> String.duplicate("a", 36)
    append(context.worker, [event(1) |> Map.put(:body, "answer #{token}"), %{role: "command", msg_id: "cmd", body: "", payload: %{command: "echo #{token}", output: "result #{token}", exit_code: 0}}])
    id = Ref.conversation_id(context.worker)
    conn = Plug.Test.conn(:get, "/entries") |> Plug.Conn.assign(:device_id, "test-deck") |> AiurWeb.ConversationApiController.entries(%{"conversation_id" => id})
    assert conn.status == 200
    [message, command] = Jason.decode!(conn.resp_body)["entries"]
    assert {:ok, %{entries: [say, tool]}} = Journal.tail(context.deck_ref, nil, [])
    assert say.text == message["body"]
    assert tool.arg == command["body"]
    assert tool.res == command["output"]
    assert say.text == "answer [REDACTED:ghp]"
    refute Jason.encode!([say, tool]) =~ token
    assert {:ok, masked} = History.list_entries(context.worker, principal: {:device, "test-deck"})
    assert Enum.map(masked.entries, & &1.body) == [say.text, tool.arg]
  end

  defp append(ref, events) do
    Ingest.append(ref, source(), events)
    assert :ok = flush(ref)
  end

  defp line(text) do
    Jason.encode!(%{event: "notification", timestamp: DateTime.to_iso8601(DateTime.utc_now()), raw: Jason.encode!(%{method: "item/completed", params: %{item: %{type: "agentMessage", text: text}}})}) <>
      "\n"
  end
end
