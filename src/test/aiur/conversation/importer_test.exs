Code.require_file("journal_support.exs", __DIR__)

defmodule Aiur.Conversation.ImporterTest do
  use ExUnit.Case, async: false
  alias Aiur.Conversation.{History, Importer, Ingest, Ref, TestSupport}
  alias Aiur.IssueLog.Encoding
  alias Aiur.TrackerIdentity
  import TestSupport
  import Aiur.TestSupport, only: [receive_barrier: 1]

  setup context do
    c = TestSupport.setup(context)
    previous_log = Application.fetch_env(:aiur, :log_file)
    Application.put_env(:aiur, :log_file, Path.join(c.root, "daemon.log"))

    on_exit(fn ->
      case previous_log do
        {:ok, value} -> Application.put_env(:aiur, :log_file, value)
        :error -> Application.delete_env(:aiur, :log_file)
      end
    end)

    id = Integer.to_string(System.unique_integer([:positive]))
    {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => "I_#{id}", "number" => 6638}, {"test", "repo"}, {"test", "repo"})
    {:ok, ref} = Ref.worker(identity)
    workspace = Path.join(c.root, "workspace")
    File.mkdir_p!(Path.join(workspace, "logs"))
    hint = %{workspace: workspace, backend: "codex", identifier: identity}
    source = source() |> Map.merge(%{role: :worker, import_hint: hint})
    Map.merge(c, %{ref: ref, dir: Path.join(c.root, Ref.conversation_id(ref)), workspace: workspace, hint: hint, source: source})
  end

  test "codex workspace full bodies follow the gap and precede the live session", c do
    body = String.duplicate("history", 300)
    write_workspace(c, [codex("old", body, c.now), codex("message-1", "message 1", c.now), codex("queued-live", "must stay live", c.now)])
    Ingest.append(c.ref, c.source, [event(1)])
    assert :ok = flush(c.ref)
    assert [gap, imported, live] = rows(c.dir)
    assert gap["meta"] == %{"reason" => "pre_journal", "from" => nil, "to" => DateTime.to_iso8601(c.now)}
    assert {imported["body"], imported["body_truncated"], imported["session_seq"], imported["refs"]["provider_item_id"]} == {body, false, 1, "old"}
    assert {live["body"], live["session_seq"], live["pos"]} == {"message 1", 2, 3}
    assert {:ok, %{complete_from_start: false, head_pos: 3}} = History.list_entries(c.ref, principal: :internal)
    assert [start, ended, live_start] = sessions(c.dir)
    assert {start["start_reason"], start["transcript_source"]["kind"], ended["end_reason"], live_start["start_reason"]} == {"import", "provider_file", "superseded", "start"}
  end

  test "no workspace falls back to current launch IssueLog and flags the exact truncation cut", c do
    path = Aiur.IssueLog.transcript_path(c.hint.identifier)
    File.write!(path, Jason.encode!(%{role: "assistant", body: String.duplicate("é", 1000), msg_id: "old"}) <> "\n")
    assert {:issue_log, ^path} = Importer.plan(%{c.hint | workspace: nil})
    Ingest.append(c.ref, c.source, [event(1)])
    assert :ok = flush(c.ref)
    assert [_, entry, _] = rows(c.dir)
    assert entry["body_truncated"]
    assert entry["meta"]["import_source"] == "issue_log"
    assert String.length(entry["body"]) == 1000
    File.write!(path, Encoding.encode(%{role: :assistant, body: String.duplicate("é", 1001), msg_id: "encoded-old", payload: nil}) <> "\n")
    assert [{:entry, encoded}] = Enum.to_list(Importer.stream({:issue_log, path}, "codex"))
    assert encoded.body_truncated
    assert String.ends_with?(encoded.body, "…")
  end

  test "IssueLog truncation cannot import an ID-less first live record twice", c do
    body = String.duplicate("reasoning ", 200)
    record = %{role: :reasoning, body: body, timestamp: c.now, turn_id: "turn", payload: nil}
    old = %{role: "assistant", body: "older", msg_id: "old"}
    File.write!(Aiur.IssueLog.transcript_path(c.hint.identifier), [Jason.encode!(old) <> "\n", Encoding.encode(record) <> "\n"])
    Ingest.append(c.ref, c.source, [%{record | body: body}])
    assert :ok = flush(c.ref)
    assert Enum.map(rows(c.dir), & &1["body"]) == ["", "older", body]
    assert Enum.map(rows(c.dir), & &1["session_seq"]) == [nil, 1, 2]
  end

  test "IssueLog payload stripping cannot import a short first live item twice", c do
    live = %{role: :reasoning, body: "short live reasoning", timestamp: c.now, payload: %{provider_item_id: "reasoning-item"}}
    records = [%{role: :assistant, body: "older", msg_id: "old", payload: nil}, live, %{role: :assistant, body: "later live", payload: nil}]
    File.write!(Aiur.IssueLog.transcript_path(c.hint.identifier), Enum.map(records, &(Encoding.encode(&1) <> "\n")))
    Ingest.append(c.ref, c.source, [live])
    assert :ok = flush(c.ref)
    assert Enum.map(rows(c.dir), & &1["body"]) == ["", "older", "short live reasoning"]
    assert List.last(rows(c.dir))["session_seq"] == 2
  end

  test "unextractable and disappeared workspace sources fall back to IssueLog", c do
    path = Aiur.IssueLog.transcript_path(c.hint.identifier)
    File.write!(path, Jason.encode!(%{role: "assistant", body: "fallback", msg_id: "old"}) <> "\n")
    write_workspace(c, [%{event: "unrelated"}])
    plan = Importer.plan(c.hint)
    File.rm!(Path.join(c.workspace, "logs/agent.ndjson"))
    assert [{:skipped, 1}] = Enum.to_list(Importer.stream(plan, "codex"))
    write_workspace(c, [%{event: "unrelated"}])
    Ingest.append(c.ref, c.source, [event(1)])
    assert :ok = flush(c.ref)
    assert [_, imported, _] = rows(c.dir)
    assert {imported["body"], imported["meta"]["import_source"]} == {"fallback", "issue_log"}
  end

  test "stored Claude notifications and REPL events replay while atom-only extractors fall back", c do
    path = Path.join(c.workspace, "logs/agent.ndjson")
    claude = %{payload: %{method: "item/created", params: %{item: %{id: "old", type: "text", text: "Claude history"}}}}
    write_workspace(c, [claude])
    assert [{:entry, entry}] = Enum.to_list(Importer.stream({:workspace, path}, "claude"))
    assert entry.body == "Claude history"
    write_workspace(c, [%{transcript_event: %{role: "assistant", body: "REPL history", msg_id: "repl-old"}}])
    assert [{:entry, entry}] = Enum.to_list(Importer.stream({:workspace, path}, "claude-repl"))
    assert entry.body == "REPL history"

    for backend <- ["muse", "kimi", "deepseek", "openrouter"] do
      write_workspace(c, [%{event: "assistant", payload: %{text: "atom-only history"}}])
      assert [:skip] = Enum.to_list(Importer.stream({:workspace, path}, backend))
    end
  end

  test "malformed lines are skipped and counted in the import end record", c do
    write_workspace(c, [codex("old", "old", c.now)])
    File.write!(Path.join(c.workspace, "logs/agent.ndjson"), "bad\n[]\n", [:append])
    Ingest.append(c.ref, c.source, [event(1)])
    assert :ok = flush(c.ref)
    assert [_, ended, _] = sessions(c.dir)
    assert ended["meta"]["skipped_lines"] == 2
    assert {:ok, [imported, _live]} = History.list_sessions(c.ref)
    assert imported.meta == %{"skipped_lines" => 2}
    assert Enum.map(rows(c.dir), & &1["body"]) == ["", "old", "message 1"]
  end

  test "symlinked file and parent directory cannot redirect workspace reads", c do
    secret = Path.join(c.root, "secret")
    File.write!(secret, Jason.encode!(codex("secret", "secret", c.now)) <> "\n")
    File.ln_s!(secret, Path.join(c.workspace, "logs/agent.ndjson"))
    refute Importer.safe_file?(Path.join(c.workspace, "logs/agent.ndjson"))
    Ingest.append(c.ref, c.source, [event(1)])
    assert :ok = flush(c.ref)
    assert Enum.map(rows(c.dir), & &1["body"]) == ["", "message 1"]
    other = Path.join(c.root, "linked-workspace")
    File.ln_s!(c.workspace, other)
    refute Importer.safe_file?(Path.join(other, "logs/agent.ndjson"))
  end

  test "a regular-file replacement after planning cannot change the opened import source", c do
    write_workspace(c, [codex("original", "original", c.now)])
    path = Path.join(c.workspace, "logs/agent.ndjson")
    stream = Importer.stream({:workspace, path}, "codex")
    File.rename!(path, path <> ".original")
    write_workspace(c, [codex("replacement", "must not read replacement", c.now)])
    assert [{:skipped, 1}] = Enum.to_list(stream)
    File.rename!(path <> ".original", path)
    assert [{:entry, entry}] = Enum.to_list(Importer.stream({:workspace, path}, "codex"))
    assert entry.body == "original"
  end

  test "live inputs received during import remain after every imported chunk", c do
    write_workspace(c, Enum.map(1..1200, &codex("old-#{&1}", "old #{&1}", c.now)))
    actions(c.control, :append, [:pass, :blocked])
    Ingest.append(c.ref, c.source, [event(1)])
    receive_barrier({:store_blocked, :append, pid})
    Ingest.append(c.ref, c.source, Enum.map(2..70, &event/1))
    send(pid, :release_store)
    assert :ok = flush(c.ref)
    entries = rows(c.dir)
    assert Enum.map(Enum.slice(entries, 1, 1200), & &1["body"]) == Enum.map(1..1200, &"old #{&1}")
    assert Enum.map(Enum.drop(entries, 1201), & &1["body"]) == Enum.map(1..70, &"message #{&1}")
    assert Enum.map(entries, & &1["pos"]) == Enum.to_list(1..1271)
  end

  test "a 500-line source chunk exceeding the store byte limit imports in bounded writes", c do
    body = String.duplicate("x", 20_000)
    write_workspace(c, Enum.map(1..500, &codex("large-#{&1}", body, c.now)))
    Ingest.append(c.ref, c.source, [event(1)])
    assert :ok = flush(c.ref)
    assert [gap | entries] = rows(c.dir)
    assert gap["meta"]["reason"] == "pre_journal"
    assert length(entries) == 501
    assert Enum.all?(Enum.take(entries, 500), &(&1["body"] == body))
    assert List.last(entries)["body"] == "message 1"
    refute_received {:journal_alert, _, _}
  end

  test "acknowledged import writes clear failures and preserve buffered live records", c do
    write_workspace(c, Enum.map(1..600, &codex("old-#{&1}", "old #{&1}", c.now)))
    actions(c.control, :prepare, [{:error, :enospc}])
    actions(c.control, :append, [:pass, :pass, :uncertain])
    Ingest.append(c.ref, c.source, [event(1)])
    assert {:error, :degraded} = flush(c.ref)
    assert :ok = flush(c.ref)
    assert Enum.map(Enum.reject(rows(c.dir), &(&1["kind"] == "gap")), & &1["body"]) == Enum.map(1..600, &"old #{&1}") ++ ["message 1"]
    gaps = Enum.filter(rows(c.dir), &(&1["meta"]["reason"] == "source_unreadable"))
    assert length(gaps) == 1
    assert hd(rows(c.dir))["meta"]["reason"] == "pre_journal"
    assert state(c.ref).retries == 0
    refute state(c.ref).outage
  end

  test "rebuild failure during import returns degraded to flush callers", c do
    write_workspace(c, [codex("old", "old", c.now)])
    actions(c.control, :append, [:pass, {:error, :eio}])
    actions(c.control, :rebuild, List.duplicate({:error, :eacces}, 10))
    Ingest.append(c.ref, c.source, [event(1)])
    assert {:error, :degraded} = flush(c.ref)
    assert {:error, :degraded} = flush(c.ref)
    actions(c.control, :rebuild, [])
    assert :ok = flush(c.ref)
    assert Enum.map(Enum.reject(rows(c.dir), &(&1["kind"] == "gap")), & &1["body"]) == ["old", "message 1"]
  end

  test "controlled shutdown finishes import before flushing buffered live records", c do
    write_workspace(c, Enum.map(1..20, &codex("old-#{&1}", "old #{&1}", c.now)))
    actions(c.control, :prepare, [{:error, :enospc}])
    Ingest.append(c.ref, c.source, [event(1)])
    {:ok, pid} = Ingest.writer(c.ref)
    # Suspend after the append cast, before any fake retry timer can start recovery.
    token = make_ref()
    send(pid, {:system, {self(), token}, :suspend})
    receive_barrier({^token, :ok})
    suspended = :sys.get_state(pid)
    assert is_nil(suspended.importing)
    assert suspended.recover
    assert :ok = DynamicSupervisor.terminate_child(Aiur.Conversation.JournalSupervisor, pid)
    assert hd(rows(c.dir))["meta"]["reason"] == "pre_journal"
    assert Enum.map(Enum.reject(rows(c.dir), &(&1["kind"] == "gap")), & &1["body"]) == Enum.map(1..20, &"old #{&1}") ++ ["message 1"]
    assert [_, ended, _] = sessions(c.dir)
    assert ended["end_reason"] == "superseded"
  end

  test "writer killed mid-import resumes without adding duplicate imported entries", c do
    write_workspace(c, Enum.map(1..1200, &codex("old-#{&1}", "old #{&1}", c.now)))
    actions(c.control, :append, [:pass, :pass, :blocked])
    Ingest.append(c.ref, c.source, [event(1)])
    receive_barrier({:store_blocked, :append, pid})
    opts = Application.fetch_env!(:aiur, :conversation_journal)
    Application.put_env(:aiur, :conversation_journal, Keyword.put(opts, :run_id, "run-two"))
    monitor = Process.monitor(pid)
    actions(c.control, :prepare, [{:error, :enospc}])
    Process.exit(pid, :kill)
    receive_barrier({:DOWN, ^monitor, :process, ^pid, :killed})
    Ingest.append(c.ref, c.source, [event(1)])
    assert :ok = flush(c.ref)
    assert Enum.map(Enum.reject(rows(c.dir), &(&1["kind"] == "gap")), & &1["body"]) == Enum.map(1..1200, &"old #{&1}") ++ ["message 1"]
    assert Enum.count(sessions(c.dir), &(&1["start_reason"] == "import")) == 1
  end

  test "restart after workspace removal does not apply its line cursor to IssueLog", c do
    write_workspace(c, Enum.map(1..600, &codex("old-#{&1}", "old #{&1}", c.now)))
    actions(c.control, :append, List.duplicate(:pass, 11) ++ [:blocked])
    Ingest.append(c.ref, c.source, [event(1)])
    receive_barrier({:store_blocked, :append, pid})
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    receive_barrier({:DOWN, ^monitor, :process, ^pid, :killed})
    File.rm!(Path.join(c.workspace, "logs/agent.ndjson"))
    File.write!(Aiur.IssueLog.transcript_path(c.hint.identifier), Jason.encode!(%{role: "assistant", body: "fallback older record", msg_id: "fallback-old"}) <> "\n")
    Ingest.append(c.ref, c.source, [event(1)])
    assert :ok = flush(c.ref)
    entries = rows(c.dir)
    assert Enum.map(Enum.take(entries, 501), & &1["body"]) == [""] ++ Enum.map(1..500, &"old #{&1}")
    assert Enum.map(Enum.drop(entries, 501), & &1["body"]) == ["fallback older record", "message 1"]
  end

  test "an existing conversation is never imported again", c do
    write_workspace(c, [codex("old", "old", c.now)])
    Ingest.append(c.ref, c.source, [event(1)])
    assert :ok = flush(c.ref)
    {:ok, pid} = Ingest.writer(c.ref)
    DynamicSupervisor.terminate_child(Aiur.Conversation.JournalSupervisor, pid)
    write_workspace(c, [codex("new-old", "must not import", c.now)])
    Ingest.append(c.ref, c.source, [event(2)])
    assert :ok = flush(c.ref)
    assert Enum.map(rows(c.dir), & &1["body"]) == ["", "old", "message 1", "message 2"]
    assert Enum.count(sessions(c.dir), &(&1["start_reason"] == "import")) == 1
  end

  defp write_workspace(c, records), do: File.write!(Path.join(c.workspace, "logs/agent.ndjson"), Enum.map(records, &(Jason.encode!(&1) <> "\n")))
  defp codex(id, text, now), do: %{timestamp: now, payload: %{method: "item/completed", params: %{item: %{id: id, type: "agentMessage", text: text}}}}
end
