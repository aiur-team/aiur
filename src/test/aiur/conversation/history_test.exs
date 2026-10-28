Code.require_file("journal_support.exs", __DIR__)

defmodule Aiur.Conversation.JournalHistoryTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Aiur.TestSupport, only: [receive_barrier: 1]
  import Aiur.Conversation.TestSupport
  alias Aiur.Conversation.{Anchors, Entry, History, Ingest, Ref, Session, Store, TestSupport}

  setup context, do: TestSupport.setup(context)

  property "random segmented page walks cover each position exactly once", context do
    check all(count <- integer(1..3000), segment_size <- integer(1..300), limit <- integer(1..200), max_runs: 12) do
      fixture(context, Enum.map(1..count, &entry/1), segment_size)
      assert walk(context.ref, [from_start: true, limit: limit], :next_cursor) == Enum.to_list(1..count)
      assert walk(context.ref, [tail: true, limit: limit], :prev_cursor) == Enum.to_list(1..count)
    end
  end

  test "around centers on position and rejects positions beyond the head", context do
    fixture(context, Enum.map(1..20, &entry/1))
    assert {:ok, page} = History.list_entries(context.ref, principal: :internal, around: 10, limit: 6)
    assert positions(page.entries) == [7, 8, 9, 10, 11, 12]
    assert {page.prev_cursor, page.next_cursor, page.head_pos} == {7, 12, 20}
    assert %DateTime{} = page.observed_at
    assert {:error, :not_found} = History.list_entries(context.ref, principal: :internal, around: 21)
  end

  test "a one-entry around page retains both navigation cursors", context do
    fixture(context, Enum.map(1..20, &entry/1))
    assert {:ok, page} = History.list_entries(context.ref, principal: :internal, around: 10, limit: 1)
    assert {positions(page.entries), page.prev_cursor, page.next_cursor} == {[10], 10, 10}
    assert {:ok, earlier} = History.list_entries(context.ref, principal: :internal, before: page.prev_cursor, limit: 1)
    assert positions(earlier.entries) == [9]
  end

  test "a recovered empty final segment remains readable", context do
    fixture(context, Enum.map(1..3, &entry/1))
    File.write!(Store.segment_path(context.dir, 2), "")
    assert {:ok, head} = Store.rebuild_head(context.dir)
    assert List.last(head["segments"]) == %{"n" => 2, "first_pos" => nil, "last_pos" => 3, "bytes" => 0}
    assert {:ok, page} = History.list_entries(context.ref, principal: :internal)
    assert {positions(page.entries), page.head_pos} == {[1, 2, 3], 3}
    assert {:ok, entries, 3} = History.catch_up(context.ref, 0, principal: :internal)
    assert positions(entries) == [1, 2, 3]
  end

  test "duplicate and out-of-range committed positions refuse catch-up rather than claiming completeness", context do
    for corrupt_pos <- [1, 9] do
      fixture(context, Enum.map(1..3, &entry/1))
      path = Store.segment_path(context.dir, 1)
      bytes = File.read!(path)
      corrupted = String.replace(bytes, ~s("pos":2), ~s("pos":#{corrupt_pos}))
      assert corrupted != bytes
      assert byte_size(corrupted) == byte_size(bytes)
      File.write!(path, corrupted)
      assert {:error, :unavailable} = History.list_entries(context.ref, principal: :internal, from_start: true)
      assert {:error, :unavailable} = History.catch_up(context.ref, 0, principal: :internal)
      assert File.read!(path) == corrupted
    end
  end

  test "cursor edges and empty conversations have truthful cursors", context do
    fixture(context, [])
    assert {:ok, %{entries: [], head_pos: 0, prev_cursor: nil, next_cursor: nil}} = History.list_entries(context.ref, principal: :internal)
    fixture(context, Enum.map(1..3, &entry/1))
    assert {:ok, %{entries: [], prev_cursor: nil}} = History.list_entries(context.ref, principal: :internal, before: 1)
    assert {:ok, %{entries: [], next_cursor: nil}} = History.list_entries(context.ref, principal: :internal, after: 3)
    assert {:ok, first} = History.list_entries(context.ref, principal: :internal, from_start: true, limit: 1)
    assert {positions(first.entries), first.prev_cursor, first.next_cursor} == {[1], nil, 1}
    assert {:ok, last} = History.list_entries(context.ref, principal: :internal, limit: 1)
    assert {positions(last.entries), last.prev_cursor, last.next_cursor} == {[3], 3, nil}
  end

  test "invalid options and malformed identities fail before reading a file", context do
    for opts <- [[before: 1, after: 2], [tail: true, from_start: true], [after: -1], [before: 0], [around: 0], [tail: false], [before: 2, before: 3]] do
      assert {:error, :invalid_cursor} = History.list_entries(context.ref, [principal: :internal] ++ opts)
    end

    for limit <- [0, 201, -1, "50", nil] do
      assert {:error, :invalid_limit} = History.list_entries(context.ref, principal: :internal, limit: limit)
    end

    for id <- ["../outside", "conv_../../outside", "conv_bad", nil] do
      assert {:error, :not_found} = History.list_entries(id, principal: :internal)
      assert {:error, :not_found} = History.list_sessions(id)
      assert {:error, :not_found} = History.list_anchors(id, [])
    end

    refute File.exists?(context.root)
    assert {:error, :not_found} = History.list_entries(context.ref, principal: :internal)
  end

  test "principal is required on pages and catch-up", %{ref: ref} do
    assert_raise ArgumentError, fn -> History.list_entries(ref, []) end
    assert_raise ArgumentError, fn -> History.catch_up(ref, 0) end
    assert_raise ArgumentError, fn -> History.list_entries(ref, principal: :unknown) end
  end

  test "writer publication bounds reads before a blocked append and after its flush", %{ref: ref, control: control} do
    Ingest.append(ref, source(), [event(1)])
    assert :ok = flush(ref)
    actions(control, :append, [:blocked])
    Ingest.append(ref, source(), [event(2)])
    flusher = Task.async(fn -> flush(ref) end)
    receive_barrier({:store_blocked, :append, writer})

    try do
      reader = Task.async(fn -> History.list_entries(ref, principal: :internal) end)
      assert {:ok, page} = Task.await(reader, 5000)
      assert {positions(page.entries), page.head_pos} == {[1], 1}
    after
      send(writer, :release_store)
    end

    assert :ok = Task.await(flusher, 5000)
    assert {:ok, page} = History.list_entries(ref, principal: :internal)
    assert {positions(page.entries), page.head_pos} == {[1, 2], 2}
  end

  test "unacknowledged complete and torn tails are neither returned nor repaired", %{ref: ref, dir: dir} do
    Ingest.append(ref, source(), [event(1)])
    assert :ok = flush(ref)
    path = Store.segment_path(dir, 1)
    File.write!(path, Jason.encode!(Entry.to_json(entry(2))) <> "\n" <> ~s({"v":1,"pos":3), [:append])
    bytes = File.read!(path)
    head_bytes = File.read!(Path.join(dir, "head.json"))
    assert {:ok, page} = History.list_entries(ref, principal: :internal)
    assert {positions(page.entries), page.head_pos} == {[1], 1}
    assert File.read!(path) == bytes
    assert File.read!(Path.join(dir, "head.json")) == head_bytes
  end

  test "a missing head row reads the writer snapshot without repairing its torn append", %{ref: ref, dir: dir} do
    Ingest.append(ref, source(), [event(1)])
    assert :ok = flush(ref)
    path = Store.segment_path(dir, 1)
    File.write!(path, ~s({"v":1,"pos":2), [:append])
    bytes = File.read!(path)
    head_bytes = File.read!(Path.join(dir, "head.json"))
    :ets.delete(:aiur_conversation_heads, {dir, Ref.conversation_id(ref)})
    assert {:ok, page} = History.list_entries(ref, principal: :internal)
    assert {positions(page.entries), page.head_pos} == {[1], 1}
    assert File.read!(path) == bytes
    assert File.read!(Path.join(dir, "head.json")) == head_bytes
  end

  test "a session-only closure survives cold reads after the writer and cached head are gone", %{ref: ref, dir: dir} do
    Ingest.append(ref, source(), [event(1)])
    assert :ok = flush(ref)
    Ingest.end_session(ref, "session-one", :completed)
    assert :ok = flush(ref)
    {:ok, writer} = Ingest.writer(ref)
    assert :ok = DynamicSupervisor.terminate_child(Aiur.Conversation.JournalSupervisor, writer)
    id = Ref.conversation_id(ref)
    refute Process.alive?(writer)
    :ets.delete(:aiur_conversation_heads, {dir, id})
    assert {:ok, [session]} = History.list_sessions(ref)
    assert {session.session_seq, session.first_pos, session.last_pos, session.end_reason} == {1, 1, 1, "completed"}
    assert session.ended_at != nil
    assert {:ok, %{sessions: [^session]}} = History.list_entries(ref, principal: :internal)
  end

  test "missing and corrupt committed segments return unavailable without a partial page", context do
    fixture(context, Enum.map(1..4, &entry/1), 2)
    second_path = Store.segment_path(context.dir, 2)
    bytes = File.read!(second_path)
    File.write!(second_path, String.duplicate("x", byte_size(bytes) - 1) <> "\n")
    assert {:error, :unavailable} = History.list_entries(context.ref, principal: :internal, from_start: true)
    File.rm!(second_path)
    assert {:error, :unavailable} = History.list_entries(context.ref, principal: :internal)
  end

  test "kind filters preserve gaps and continue beyond a bounded scan", context do
    entries = Enum.map(1..5002, fn pos -> entry(pos, if(pos == 2, do: [kind: "gap", role: "system"], else: [])) end)
    fixture(context, entries, 1000)
    assert {:ok, page} = History.list_entries(context.ref, principal: :internal, from_start: true, kinds: ["reasoning"])
    assert positions(page.entries) == [2]
    assert page.next_cursor == 5000
    assert {:ok, next} = History.list_entries(context.ref, principal: :internal, after: page.next_cursor, kinds: ["reasoning"])
    assert next.entries == []
    assert next.next_cursor == nil
  end

  test "folded sessions preserve closure fields and pages select only overlaps", %{ref: ref} do
    Ingest.append(ref, source(), Enum.map(1..3, &event/1))
    Ingest.append(ref, source("second"), Enum.map(4..6, &event/1))
    assert :ok = flush(ref)
    assert {:ok, [first, second]} = History.list_sessions(ref)
    assert {first.session_seq, first.first_pos, first.last_pos, first.end_reason} == {1, 1, 3, "superseded"}
    assert {second.session_seq, second.first_pos, second.last_pos, second.end_reason} == {2, 4, 6, nil}
    assert {:ok, page} = History.list_entries(ref, principal: :internal, after: 3)
    assert Enum.map(page.sessions, & &1.session_seq) == [2]
    Ingest.end_session(ref, "second", :completed)
    assert :ok = flush(ref)
    assert {:ok, [_, ended]} = History.list_sessions(ref)
    assert {ended.end_reason, ended.last_pos} == {"completed", 6}
  end

  test "pre-journal gaps and imported sessions make completeness false", context do
    fixture(context, [entry(1, kind: "gap", role: "system", meta: %{"reason" => "pre_journal"})])
    assert {:ok, %{complete_from_start: false}} = History.list_entries(context.ref, principal: :internal)
    fixture(context, [entry(1)], 100, "import")
    assert {:ok, %{complete_from_start: false}} = History.list_entries(context.ref, principal: :internal)
    fixture(context, [entry(1)])
    assert {:ok, %{complete_from_start: true}} = History.list_entries(context.ref, principal: :internal)
  end

  test "device masking changes body and output without rewriting journal bytes", context do
    token = "ghp_" <> String.duplicate("a", 36)
    url = "https://user:pw@host/private"
    raw = entry(1, body: "token #{token} #{url}", output: "#{url} #{token}")
    fixture(context, [raw])
    path = Store.segment_path(context.dir, 1)
    digest = :crypto.hash(:sha256, File.read!(path))
    assert {:ok, %{entries: [masked]}} = History.list_entries(context.ref, principal: {:device, "d1"}, reveal: true)
    refute masked.body =~ token
    refute masked.body =~ url
    refute masked.output =~ token
    refute masked.output =~ url
    assert masked.redacted
    assert masked.pos == 1
    assert :crypto.hash(:sha256, File.read!(path)) == digest
    live = History.mask_for(raw, principal: {:device, "d1"}, reveal: true)
    assert {live.body, live.output, live.redacted} == {masked.body, masked.output, masked.redacted}
    assert {:ok, [^masked], 1} = History.catch_up(context.ref, 0, principal: {:device, "d1"}, reveal: true)
    assert {:ok, %{entries: [internal]}} = History.list_entries(context.ref, principal: :internal)
    assert {internal.body, internal.output} == {raw.body, raw.output}
  end

  test "only loopback operators can reveal secrets and all principals share cursors", context do
    token = "ghp_" <> String.duplicate("b", 36)
    fixture(context, [entry(1), entry(2, body: token), entry(3)])
    assert {:ok, raw} = History.list_entries(context.ref, principal: {:operator, :loopback}, reveal: true, limit: 1, around: 2)
    assert hd(raw.entries).body == token

    for {principal, reveal} <- [{{:operator, :loopback}, false}, {{:operator, :basic_auth}, true}, {{:device, "d1"}, true}] do
      assert {:ok, masked} = History.list_entries(context.ref, principal: principal, reveal: reveal, limit: 1, around: 2)
      refute hd(masked.entries).body =~ token
      assert hd(masked.entries).redacted
      assert {masked.prev_cursor, masked.next_cursor, masked.head_pos} == {raw.prev_cursor, raw.next_cursor, raw.head_pos}
    end
  end

  test "subscribe then catch-up then discard overlapping live entries leaves contiguous positions", %{ref: ref} do
    Ingest.append(ref, source(), Enum.map(1..220, &event/1))
    assert :ok = flush(ref)
    assert :ok = History.subscribe(ref)
    Ingest.append(ref, source(), [event(221)])
    assert :ok = flush(ref)
    assert {:ok, caught_up, head} = History.catch_up(ref, 0, principal: :internal)
    assert positions(caught_up) == Enum.to_list(1..221)
    assert head == 221
    Ingest.append(ref, source(), [event(222)])
    assert :ok = flush(ref)
    id = Ref.conversation_id(ref)
    assert_received {:entries_appended, ^id, [overlap]}
    assert_received {:entries_appended, ^id, [fresh]}
    live = Enum.filter([overlap, fresh], &(&1.pos > head))
    assert positions(caught_up ++ live) == Enum.to_list(1..222)
  end

  test "anchors select strongest before filtering by kind, position and time", context do
    fixture(context, [entry(1), entry(2)])
    time = DateTime.utc_now()
    event = %{event_id: 7, kind: "progress", topic: "ticket.1.agent.progress", conversation_id: Ref.conversation_id(context.ref), observed_at: time}
    assert {:ok, observed} = Anchors.position(event, [entry(1, observed_at: time)], [%Session{started_at: DateTime.add(time, -1)}])
    exact = Map.merge(observed, %{"pos" => 2, "precision" => "exact"})
    other = Map.put(observed, "kind", "push")
    for anchor <- [observed, exact, other], do: assert(:ok = Store.append_anchor_line(context.dir, anchor))
    assert {:ok, anchors} = History.list_anchors(context.ref, [])
    assert anchors == [exact, other]
    assert {:ok, [^exact]} = History.list_anchors(context.ref, kinds: ["progress"], pos_range: {2, 2}, since: DateTime.add(time, -1))
    assert {:ok, []} = History.list_anchors(context.ref, since: DateTime.add(time, 1))
    assert {:ok, []} = History.list_anchors(context.ref, pos_range: {3, 4})
  end

  defp entry(pos, attrs \\ []) do
    struct(Entry, Keyword.merge([pos: pos, kind: "message", role: "agent", session_seq: 1, observed_at: DateTime.utc_now(), body: "message #{pos}"], attrs))
  end

  defp positions(entries), do: Enum.map(entries, & &1.pos)

  defp fixture(context, entries, segment_size \\ 100, start_reason \\ "start") do
    Aiur.TestCleanup.rm_rf!(context.dir)
    File.mkdir_p!(context.dir)
    session = %Session{session_seq: 1, harness: "codex", provider_session_id: "fixture", first_pos: 1, started_at: DateTime.utc_now(), start_reason: start_reason}
    session_bytes = if entries == [], do: "", else: Jason.encode!(Session.start_line(session)) <> "\n"
    File.write!(Path.join(context.dir, "sessions.jsonl"), session_bytes)
    File.write!(Path.join(context.dir, "anchors.jsonl"), "")

    segments =
      entries
      |> Enum.chunk_every(segment_size)
      |> Enum.with_index(1)
      |> Enum.map(fn {chunk, n} ->
        bytes = Enum.map_join(chunk, "", &(Jason.encode!(Entry.to_json(&1)) <> "\n"))
        File.write!(Store.segment_path(context.dir, n), bytes)
        %{"n" => n, "first_pos" => hd(chunk).pos, "last_pos" => List.last(chunk).pos, "bytes" => byte_size(bytes)}
      end)

    head = %{"v" => 1, "last_pos" => length(entries), "last_session_seq" => if(entries == [], do: 0, else: 1), "segments" => segments, "sessions_bytes" => byte_size(session_bytes)}
    File.write!(Path.join(context.dir, "head.json"), Jason.encode!(head))
  end

  defp walk(ref, opts, direction, acc \\ []) do
    assert {:ok, page} = History.list_entries(ref, [principal: :internal] ++ opts)
    acc = if direction == :next_cursor, do: acc ++ positions(page.entries), else: positions(page.entries) ++ acc

    case Map.fetch!(page, direction) do
      nil -> acc
      cursor -> walk(ref, [{if(direction == :next_cursor, do: :after, else: :before), cursor}, {:limit, opts[:limit]}], direction, acc)
    end
  end
end
