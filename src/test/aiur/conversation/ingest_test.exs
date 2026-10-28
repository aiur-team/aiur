Code.require_file("journal_support.exs", __DIR__)

defmodule Aiur.Conversation.IngestTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.Conversation.{Ingest, Ref}
  import Aiur.Conversation.TestSupport
  setup context, do: Aiur.Conversation.TestSupport.setup(context)

  test "cold append returns while initial disk preparation is blocked", %{ref: ref, dir: dir, control: control} do
    actions(control, :prepare, [:blocked])
    assert :ok = Ingest.append(ref, source(), [event(1)])
    receive_barrier({:store_blocked, :prepare, writer})
    assert :ok = Ingest.append(ref, source(), [event(2)])
    send(writer, :release_store)
    assert :ok = flush(ref)
    assert Enum.map(rows(dir), & &1["body"]) == ["message 1", "message 2"]
  end

  test "entries and session changes broadcast only after the entry fsync completes", %{ref: ref, control: control} do
    id = Ref.conversation_id(ref)
    Phoenix.PubSub.subscribe(Aiur.PubSub, "conversation:" <> id)
    actions(control, :append, [:blocked])
    Ingest.append(ref, source(), [event(1)])
    task = Task.async(fn -> flush(ref) end)
    receive_barrier({:store_blocked, :append, writer})
    refute_received {:entries_appended, ^id, _}
    refute_received {:session_changed, ^id, _}
    send(writer, :release_store)
    assert :ok = Task.await(task)
    assert_received {:entries_appended, ^id, [entry]}
    assert {entry.body, entry.pos} == {"message 1", 1}
    assert_received {:session_changed, ^id, session}
    assert {session.provider_session_id, session.session_seq} == {"session-one", 1}
  end

  test "overloaded mailbox drops an entire batch and later persists its gap", %{ref: ref, dir: dir} do
    {:ok, writer} = Ingest.writer(ref)
    :sys.get_state(writer)
    :ok = :sys.suspend(writer)

    try do
      for _ <- 1..5001, do: GenServer.cast(writer, {:append, source(), []})
      assert :ok = Ingest.append(ref, source(), [event(1), event(2)])
      assert Ingest.dropped_count(ref) == 2
    after
      :sys.resume(writer)
    end

    assert :ok = flush(ref)
    assert [gap] = rows(dir)
    assert {gap["kind"], gap["meta"]["reason"]} == {"gap", "backpressure"}
    assert gap["meta"]["from"] <= gap["meta"]["to"]
  end

  test "uncertain gap writes recover without repeating backpressure or explicit gaps", %{ref: ref, dir: dir, control: control, now: now} do
    {:ok, writer} = Ingest.writer(ref)
    :sys.get_state(writer)
    GenServer.cast(writer, {:dropped, now, now})
    actions(control, :append, [:ambiguous])
    assert {:error, :degraded} = flush(ref)
    assert :ok = flush(ref)
    assert Enum.count(rows(dir), &(&1["meta"]["reason"] == "backpressure")) == 1
    actions(control, :append, [:ambiguous])
    Ingest.gap(ref, :import_missing, now, now)
    assert {:error, :degraded} = flush(ref)
    assert :ok = flush(ref)
    assert Enum.count(rows(dir), &(&1["meta"]["reason"] == "import_missing")) == 1
  end

  test "concurrent cold producers share one writer and positions", %{ref: ref, dir: dir} do
    1..12
    |> Task.async_stream(fn n -> Ingest.append(ref, source(), [event(n)]) end, max_concurrency: 4)
    |> Enum.each(fn result -> assert result == {:ok, :ok} end)

    assert :ok = flush(ref)
    assert Enum.map(rows(dir), & &1["pos"]) == Enum.to_list(1..12)
    assert rows(dir) |> Enum.map(& &1["body"]) |> Enum.sort() == Enum.map(1..12, &"message #{&1}") |> Enum.sort()
    assert [{pid, nil}] = Registry.lookup(Aiur.Conversation.Registry, Ref.conversation_id(ref))
    assert is_pid(pid)
  end

  test "facade skips deltas, preserves explicit gap spans and never raises on invalid input", %{ref: ref, dir: dir, now: now} do
    assert :ok = Ingest.append(ref, source(), [%{kind: :assistant_delta, role: :assistant, body: "delta"}])
    assert Registry.lookup(Aiur.Conversation.Registry, Ref.conversation_id(ref)) == []
    assert :ok = Ingest.append(nil, nil, nil)
    assert :ok = Ingest.end_session(nil, nil, :completed)
    assert :ok = Ingest.gap(nil, :source_unreadable, now, now)
    assert :ok = Ingest.gap(ref, :source_unreadable, now, now)
    assert :ok = flush(ref)
    assert [gap] = rows(dir)
    assert gap["meta"] == %{"reason" => "source_unreadable", "from" => DateTime.to_iso8601(now), "to" => DateTime.to_iso8601(now)}
    assert gap["session_seq"] == nil
  end
end
