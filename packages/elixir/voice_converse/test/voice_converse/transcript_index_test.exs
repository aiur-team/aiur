defmodule VoiceConverse.TranscriptIndexTest do
  use ExUnit.Case, async: true

  alias VoiceConverse.{TestCleanup, TranscriptIndex, TranscriptStore}
  alias VoiceConverse.Testing.{FakeBriefingSource, StaticCredentials}

  @id "vc_aaaaaaaaaaaaaaaaaaaaaa"
  @second_id "vc_bbbbbbbbbbbbbbbbbbbbbb"
  @third_id "vc_cccccccccccccccccccccc"

  setup do
    root = Path.join(System.tmp_dir!(), "voice_converse_index_#{System.unique_integer([:positive])}")
    on_exit(fn -> TestCleanup.rm_rf!(root) end)
    %{root: root}
  end

  test "a long transcript paginates without gaps or duplicates", %{root: root} do
    store = open!(root, @id, ~U[2026-10-24 10:00:00Z])

    for turn <- 1..2_000 do
      :ok = TranscriptStore.append(store, %{type: "user_turn", turn_id: "turn-#{turn}", text: "turn #{turn}"})
    end

    :ok =
      TranscriptStore.append(store, %{
        type: "session_ended",
        reason: "user_end",
        at: "2026-10-24T10:20:00Z",
        duration_s: 1_200
      })

    :ok = TranscriptStore.close(store)
    assert {:ok, %{reconciled: 0, errors: []}} = TranscriptIndex.reconcile(root)

    {records, cursor} = get_all(root, @id, nil, [])

    assert length(records) == 2_002
    assert Enum.map(records, & &1.seq) == Enum.to_list(1..2_002)
    assert cursor == nil
  end

  test "get omits a cursor when its page reaches the transcript end", %{root: root} do
    store = open!(root, @id, ~U[2026-10-24 10:00:00Z])

    :ok =
      TranscriptStore.append(store, %{
        type: "session_ended",
        reason: "user_end",
        at: "2026-10-24T10:02:00Z",
        duration_s: 120
      })

    :ok = TranscriptStore.close(store)

    assert {:ok, [first, second], nil} = TranscriptIndex.get(root, @id, after: 0, limit: 2)
    assert [first.seq, second.seq] == [1, 2]
  end

  test "get skips a valid JSON record with a torn final newline", %{root: root} do
    store = open!(root, @id, ~U[2026-10-24 10:00:00Z])
    :ok = TranscriptStore.close(store)

    :ok =
      File.write(
        Path.join(root, @id <> ".ndjson"),
        ~s({"v":1,"type":"user_turn","at":"2026-10-24T10:01:00Z","turn_id":"torn","text":"ignored"}),
        [:append]
      )

    assert {:ok, [%{seq: 1, record: %{"type" => "session_started"}}], nil} =
             TranscriptIndex.get(root, @id, after: 0, limit: 10)
  end

  test "boot reconciliation closes crashes, queues every provider id and is idempotent", %{root: root} do
    store = open!(root, @id, ~U[2026-10-24 10:00:00Z])
    :ok = TranscriptStore.append(store, %{type: "provider_conversation", id: "provider-1", at: "2026-10-24T10:03:00Z"})
    :ok = TranscriptStore.append(store, %{type: "provider_conversation", id: "provider-2", at: "2026-10-24T10:04:00Z"})

    :ok =
      TranscriptStore.append(store, %{type: "user_turn", turn_id: "turn-1", text: "hello", at: "2026-10-24T10:12:00Z"})

    :ok = TranscriptStore.close(store)
    :ok = File.write(Path.join(root, @id <> ".ndjson"), "{\"torn", [:append])

    enqueue = fn provider_id, conversation_id ->
      send(self(), {:enqueue, provider_id, conversation_id})
      :ok
    end

    assert {:ok, %{reconciled: 1, errors: []}} = TranscriptIndex.reconcile(root, enqueue: enqueue)
    assert_received {:enqueue, "provider-1", @id}
    assert_received {:enqueue, "provider-2", @id}
    refute_received {:enqueue, _, _}

    assert {:ok, [%{record: %{"type" => "session_ended", "reason" => "daemon_restart", "duration_s" => 720}}], nil} =
             TranscriptIndex.get(root, @id, after: 4, limit: 10)

    assert {:ok, %{reconciled: 0, errors: []}} = TranscriptIndex.reconcile(root, enqueue: enqueue)
    refute_received {:enqueue, _, _}
  end

  test "reconciled crashes are listed with daemon_restart and count toward today's minutes", %{root: root} do
    store = open!(root, @id, ~U[2026-10-24 10:00:00Z])

    :ok =
      TranscriptStore.append(store, %{type: "user_turn", turn_id: "turn-1", text: "hello", at: "2026-10-24T10:12:00Z"})

    :ok = TranscriptStore.close(store)
    assert {:ok, %{reconciled: 1, errors: []}} = TranscriptIndex.reconcile(root, enqueue: fn _, _ -> :ok end)

    assert {:ok, [conversation], nil} = TranscriptIndex.list(root, limit: 10)
    assert conversation.end_reason == "daemon_restart"
    assert conversation.duration_s == 720
    assert 12 == TranscriptIndex.minutes_today(root, now: ~U[2026-10-24 13:00:00Z])
  end

  test "open sessions add elapsed minutes and only sessions that began today count", %{root: root} do
    closed = open!(root, @id, ~U[2026-10-24 09:00:00Z])

    :ok =
      TranscriptStore.append(closed, %{
        type: "session_ended",
        reason: "user_end",
        at: "2026-10-24T09:10:00Z",
        duration_s: 600
      })

    :ok = TranscriptStore.close(closed)

    previous = open!(root, @second_id, ~U[2026-10-23 23:59:00Z])

    :ok =
      TranscriptStore.append(previous, %{
        type: "session_ended",
        reason: "user_end",
        at: "2026-10-24T00:04:00Z",
        duration_s: 300
      })

    :ok = TranscriptStore.close(previous)
    assert {:ok, %{reconciled: 0, errors: []}} = TranscriptIndex.reconcile(root)

    assert 15 ==
             TranscriptIndex.minutes_today(root,
               now: ~U[2026-10-24 10:00:00Z],
               open_sessions: fn -> [%{started_at: ~U[2026-10-24 09:55:00Z]}] end
             )
  end

  test "a missing or torn index is rebuilt at boot from transcript files", %{root: root} do
    store = open!(root, @id, ~U[2026-10-24 10:00:00Z])

    :ok =
      TranscriptStore.append(store, %{
        type: "session_ended",
        reason: "user_end",
        at: "2026-10-24T10:02:00Z",
        duration_s: 120
      })

    :ok = TranscriptStore.close(store)
    assert {:ok, %{reconciled: 0, errors: []}} = TranscriptIndex.reconcile(root)
    :ok = File.write(Path.join(root, "index.ndjson"), "{\"op\": ")

    assert {:ok, %{reconciled: 0, errors: []}} = TranscriptIndex.reconcile(root)

    assert {:ok, [%{conversation_id: @id, end_reason: "user_end"}], nil} = TranscriptIndex.list(root, limit: 10)
  end

  test "list filters by target and since, then paginates by its before cursor", %{root: root} do
    for {id, started_at, target} <- [
          {@second_id, ~U[2026-10-24 08:00:00Z], "other-ticket"},
          {@id, ~U[2026-10-24 10:00:00Z], "ticket-4139"},
          {@third_id, ~U[2026-10-24 12:00:00Z], "ticket-4139"}
        ] do
      store = open!(root, id, started_at, target)

      :ok =
        TranscriptStore.append(store, %{
          type: "session_ended",
          reason: "user_end",
          at: DateTime.to_iso8601(DateTime.add(started_at, 60, :second)),
          duration_s: 60
        })

      :ok = TranscriptStore.close(store)
    end

    assert {:ok, [%{conversation_id: @third_id}], @third_id} =
             TranscriptIndex.list(root, filter: %{target: "ticket-4139"}, limit: 1)

    assert {:ok, [%{conversation_id: @id}], nil} =
             TranscriptIndex.list(root, filter: %{target: "ticket-4139"}, before: @third_id, limit: 1)

    assert {:ok, [%{conversation_id: @third_id}], nil} =
             TranscriptIndex.list(root, filter: %{since: ~U[2026-10-24 11:00:00Z]}, limit: 10)
  end

  test "normal transcript open and close maintain the index", %{root: root} do
    store = open!(root, @id, ~U[2026-10-24 10:00:00Z])

    :ok =
      TranscriptStore.append(store, %{
        type: "session_ended",
        reason: "user_end",
        at: "2026-10-24T10:02:00Z",
        duration_s: 120
      })

    :ok = TranscriptStore.close(store)

    assert {:ok, [%{conversation_id: @id, end_reason: "user_end", duration_s: 120}], nil} =
             TranscriptIndex.list(root, limit: 10)
  end

  test "instance startup reconciles transcripts before accepting later children", %{root: root} do
    store = open!(root, @id, ~U[2026-10-24 10:00:00Z])
    :ok = TranscriptStore.append(store, %{type: "provider_conversation", id: "provider-1", at: "2026-10-24T10:02:00Z"})
    :ok = TranscriptStore.close(store)

    instance = String.to_atom("VoiceConverseIndex#{System.unique_integer([:positive])}")

    start_supervised!(
      VoiceConverse.child_spec(
        name: instance,
        transcript_root: root,
        credentials: StaticCredentials,
        briefing_source: FakeBriefingSource
      )
    )

    assert {:ok, [%{end_reason: "daemon_restart"}], nil} = TranscriptIndex.list(root, limit: 10)
  end

  defp get_all(root, id, cursor, acc) do
    assert {:ok, records, next_cursor} = TranscriptIndex.get(root, id, after: cursor, limit: 137)
    acc = acc ++ records
    if is_nil(next_cursor), do: {acc, nil}, else: get_all(root, id, next_cursor, acc)
  end

  defp open!(root, id, started_at, target \\ "ticket-4139") do
    {:ok, store} =
      TranscriptStore.open(
        root,
        id,
        %{
          target: target,
          role_id: "operator",
          at: DateTime.to_iso8601(started_at)
        },
        sync_fs: fn -> :ok end
      )

    store
  end
end
