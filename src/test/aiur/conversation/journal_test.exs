Code.require_file("journal_support.exs", __DIR__)

defmodule Aiur.Conversation.JournalTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.Conversation.{Ingest, Journal, JournalSessions, Ref, Store, TestSupport}
  import TestSupport
  setup context, do: TestSupport.setup(context)

  test "positions are dense across bounded batches and duplicate replay is discarded", %{ref: ref, dir: dir} do
    events = Enum.map(1..123, &event/1)
    assert :ok = Ingest.append(ref, source(), events)
    assert :ok = flush(ref)
    assert :ok = Ingest.append(ref, source(), events)
    assert :ok = flush(ref)
    entries = rows(dir)
    assert Enum.map(entries, & &1["pos"]) == Enum.to_list(1..123)
    assert Enum.map(entries, & &1["body"]) == Enum.map(events, & &1.body)
    assert Enum.uniq(Enum.map(entries, & &1["session_seq"])) == [1]
    assert_received {:journal_batch, 50}
    assert_received {:journal_batch, 50}
    assert_received {:journal_batch, 23}
    refute_received {:journal_batch, _}
  end

  test "writer crash in the same run rebuilds dedup without opening another session", %{ref: ref, dir: dir} do
    Ingest.append(ref, source(), [event(1)])
    assert :ok = flush(ref)
    {:ok, pid} = Ingest.writer(ref)
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    receive_barrier({:DOWN, ^monitor, :process, ^pid, :killed})
    # Starting through the supervisor is the rendezvous with its automatic restart.
    assert :ok = Ingest.append(ref, source(), [event(1), event(2)])
    assert :ok = flush(ref)
    assert Enum.map(rows(dir), & &1["body"]) == ["message 1", "message 2"]
    assert [%{"type" => "start", "session_seq" => 1}] = sessions(dir)
  end

  test "provider changes supersede sessions and explicit end only closes the matching provider", %{ref: ref, dir: dir} do
    Ingest.append(ref, source(), [event(1)])
    Ingest.append(ref, source("two"), [event(1)])
    Ingest.end_session(ref, "session-one", :completed)
    Ingest.append(ref, source("two"), [event(2)])
    Ingest.end_session(ref, "two", :completed)
    assert :ok = flush(ref)
    assert Enum.map(rows(dir), &{&1["body"], &1["session_seq"]}) == [{"message 1", 1}, {"message 1", 2}, {"message 2", 2}]
    assert [start, ended, second, completed] = sessions(dir)
    assert {start["first_pos"], ended["end_reason"], ended["last_pos"]} == {1, "superseded", 1}
    assert {second["first_pos"], completed["end_reason"], completed["last_pos"]} == {2, "completed", 3}
  end

  test "a new daemon run closes the old session and resumes with a new sequence", %{ref: ref, dir: dir} do
    Ingest.append(ref, source(), [event(1)])
    assert :ok = flush(ref)
    {:ok, pid} = Ingest.writer(ref)
    :ok = DynamicSupervisor.terminate_child(Aiur.Conversation.JournalSupervisor, pid)
    opts = Application.fetch_env!(:aiur, :conversation_journal)
    Application.put_env(:aiur, :conversation_journal, Keyword.put(opts, :run_id, "run-two"))
    Ingest.append(ref, source(), [event(2)])
    assert :ok = flush(ref)
    assert [_, ended, resumed] = sessions(dir)
    assert ended["end_reason"] == "daemon_restart_unknown"
    assert {resumed["session_seq"], resumed["start_reason"], resumed["aiur_run_id"]} == {2, "resume", "run-two"}
  end

  test "failed writes retry after recovery and put one honest gap before retained entries", %{ref: ref, dir: dir, control: control, now: now} do
    actions(control, :append, [{:error, :enospc}, {:error, :enospc}])
    Ingest.append(ref, source(), [event(1)])
    assert {:error, :degraded} = flush(ref)
    assert_received {:journal_alert, "system.conversation.journal.degraded", opts}
    assert opts[:needs_attention]
    refute opts[:message] =~ "message 1"
    tick(ref)
    refute_received {:journal_alert, "system.conversation.journal.degraded", _}
    tick(ref)
    assert [gap, entry] = rows(dir)
    assert {gap["kind"], gap["meta"]["reason"], gap["meta"]["to"]} == {"gap", "source_unreadable", DateTime.to_iso8601(now)}
    assert gap["meta"]["from"] <= gap["meta"]["to"]
    assert {entry["body"], entry["pos"]} == {"message 1", 2}
    assert_received {:journal_alert, "system.conversation.journal.degraded.resolved", opts}
    refute opts[:needs_attention]
    assert :ok = flush(ref)
    refute_received {:journal_alert, _, _}
  end

  test "a partial write is rebuilt before retry and surviving records are not duplicated", %{ref: ref, dir: dir, control: control} do
    actions(control, :append, [:partial])
    Ingest.append(ref, source(), [event(1), event(2), event(3)])
    assert {:error, :degraded} = flush(ref)
    assert :ok = flush(ref)
    entries = rows(dir)
    assert Enum.map(entries, & &1["pos"]) == [1, 2, 3, 4]
    assert Enum.map(entries, & &1["kind"]) == ["message", "gap", "message", "message"]
    assert Enum.map(Enum.reject(entries, &(&1["kind"] == "gap")), & &1["body"]) == ["message 1", "message 2", "message 3"]
  end

  test "retry exhaustion drops inputs but retains the gap for a later successful write", %{ref: ref, dir: dir, control: control} do
    actions(control, :append, List.duplicate({:error, :enospc}, 6))
    Ingest.append(ref, source(), [event(1)])
    for _ <- 1..6, do: assert({:error, :degraded} = flush(ref))
    assert :queue.is_empty(state(ref).buffer)
    assert Ingest.dropped_count(ref) == 1
    Ingest.append(ref, source(), [event(2)])
    assert :ok = flush(ref)
    assert [gap, entry] = rows(dir)
    assert gap["meta"]["reason"] == "source_unreadable"
    assert entry["body"] == "message 2"
  end

  test "outage gaps include later inputs dropped when retries are exhausted", %{ref: ref, dir: dir, control: control, now: now} do
    actions(control, :append, List.duplicate({:error, :enospc}, 6))
    Ingest.append(ref, source(), [event(1)])
    assert {:error, :degraded} = flush(ref)
    later = DateTime.add(now, 10, :second)
    Agent.update(control, &Map.put(&1, :now, later))
    Ingest.append(ref, source(), [%{event(2) | timestamp: later}])
    for _ <- 1..5, do: assert({:error, :degraded} = flush(ref))
    Ingest.append(ref, source(), [event(3)])
    assert :ok = flush(ref)
    assert [gap, entry] = rows(dir)
    assert gap["meta"]["to"] == DateTime.to_iso8601(later)
    assert entry["body"] == "message 3"
    assert Ingest.dropped_count(ref) == 2
  end

  test "session notifications and surviving entries publish after uncertain writes recover", %{ref: ref, dir: dir, control: control} do
    id = Ref.conversation_id(ref)
    Phoenix.PubSub.subscribe(Aiur.PubSub, "conversation:" <> id)
    actions(control, :append, [:ambiguous])
    Ingest.append(ref, source(), [event(1)])
    assert {:error, :degraded} = flush(ref)
    refute_received {:entries_appended, ^id, _}
    refute_received {:session_changed, ^id, _}
    assert :ok = flush(ref)
    assert_received {:entries_appended, ^id, [recovered]}
    assert {recovered.body, recovered.pos} == {"message 1", 1}
    assert_received {:session_changed, ^id, session}
    assert {session.session_seq, session.provider_session_id} == {1, "session-one"}
    assert Enum.count(rows(dir), &(&1["body"] == "message 1")) == 1
  end

  test "recovery does not repeat a previously acknowledged session closure", %{ref: ref, control: control} do
    Ingest.append(ref, source(), [event(1)])
    assert :ok = flush(ref)
    Ingest.end_session(ref, "session-one", :completed)
    assert :ok = flush(ref)
    id = Ref.conversation_id(ref)
    Phoenix.PubSub.subscribe(Aiur.PubSub, "conversation:" <> id)
    actions(control, :append, [{:error, :enospc}])
    Ingest.append(ref, source("two"), [event(2)])
    assert {:error, :degraded} = flush(ref)
    assert :ok = flush(ref)
    assert_received {:session_changed, ^id, %{session_seq: 2}}
    refute_received {:session_changed, ^id, %{session_seq: 1}}
  end

  test "dedup evicts only the oldest keys at its bound" do
    initial = %{dedup: MapSet.new(), dedup_order: :queue.new()}
    remembered = Enum.reduce(1..50_001, initial, &JournalSessions.remember(&2, "key-#{&1}"))
    refute MapSet.member?(remembered.dedup, "key-1")
    assert MapSet.member?(remembered.dedup, "key-2")
    assert MapSet.member?(remembered.dedup, "key-50001")
    assert MapSet.size(remembered.dedup) == 50_000
  end

  test "corrupt segments refuse appends, retain bytes and count lost inputs", %{ref: ref, dir: dir} do
    assert {:ok, _} = Store.prepare(dir, ref)
    bytes = "not-json\n"
    path = Store.segment_path(dir, 1)
    File.write!(path, bytes)
    Ingest.append(ref, source(), [event(1)])
    assert {:error, :degraded} = flush(ref)
    assert state(ref).read_only
    assert Ingest.dropped_count(ref) == 1
    assert File.read!(path) == bytes
    assert sessions(dir) == []
  end

  test "idle writers flush and stop normally, and the next input restarts them", %{ref: ref, dir: dir} do
    Ingest.append(ref, source(), [event(1)])
    {:ok, pid} = Ingest.writer(ref)
    monitor = Process.monitor(pid)
    {_timer, token} = :sys.get_state(pid).idle
    send(pid, {:idle, token})
    receive_barrier({:DOWN, ^monitor, :process, ^pid, :normal})
    Ingest.append(ref, source(), [event(2)])
    assert :ok = flush(ref)
    assert Enum.map(rows(dir), & &1["body"]) == ["message 1", "message 2"]
    assert [{new_pid, _}] = Registry.lookup(Aiur.Conversation.Registry, Ref.conversation_id(ref))
    refute new_pid == pid
  end

  test "timer flushes small batches and stale timer messages do nothing", %{ref: ref, dir: dir} do
    Ingest.append(ref, source(), [event(1)])
    tick(ref)
    assert [%{"body" => "message 1"}] = rows(dir)
    {:ok, pid} = Ingest.writer(ref)
    send(pid, {:flush, make_ref()})
    :sys.get_state(pid)
    assert length(rows(dir)) == 1
    assert Journal.via(ref) == {:via, Registry, {Aiur.Conversation.Registry, Ref.conversation_id(ref)}}
  end
end
