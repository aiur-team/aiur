defmodule Aiur.LiveConversationIngestTest do
  use ExUnit.Case, async: true

  import Aiur.LiveConversationSupport

  alias Aiur.LiveConversation

  setup do
    server = start_supervised!({LiveConversation, name: nil})
    %{server: server}
  end

  test "starts known-empty, retains only sanitized allowlisted messages, and deduplicates", %{server: server} do
    source = source()

    unsafe_body =
      "token ghp_abcdefghijklmnopqrstuvwxyz0123456789" <>
        " at /tmp/secret and https://example.test/capability"

    assert {:ok, %{state: :known_empty, messages: []}} = LiveConversation.activate(source, server: server)

    assert {:ok, snapshot} =
             LiveConversation.observe(
               source,
               %{
                 role: :assistant,
                 msg_id: "m-1",
                 body: unsafe_body
               },
               server: server
             )

    assert snapshot.state == :live
    assert [%{id: id, role: "agent", body: body}] = snapshot.messages
    assert_opaque_id(id)
    assert body =~ "[REDACTED:ghp]"
    assert body =~ "[REDACTED:local_path]"
    assert body =~ "[REDACTED:url]"

    assert {:ok, duplicate} =
             LiveConversation.observe(
               source,
               %{role: :assistant, msg_id: "m-1", body: "different retry"},
               server: server
             )

    assert duplicate.messages == snapshot.messages
  end

  test "bounds messages and rejects unsafe payloads without retaining their content", %{server: server} do
    source = source()

    Enum.each(1..81, fn n ->
      assert {:ok, _} =
               LiveConversation.observe(
                 source,
                 %{role: :assistant, msg_id: "m-#{n}", body: "message #{n}"},
                 server: server
               )
    end)

    assert {:ok, snapshot} =
             LiveConversation.observe(
               source,
               %{role: :tool, msg_id: "tool", body: "cat /private/data", payload: %{output: "secret"}},
               server: server
             )

    assert length(snapshot.messages) == 80
    assert snapshot.truncated?
    assert snapshot.evicted_count == 1
    assert snapshot.diagnostic_counts.unsafe_tool == 1
    refute inspect(snapshot) =~ "private/data"
    refute inspect(snapshot) =~ "secret"
  end

  test "isolates worker generations and reports restart_unknown for absent projections", %{server: server} do
    old = source(worker_generation: 10)
    replacement = source(worker_generation: 11)

    assert {:ok, _} =
             LiveConversation.observe(old, %{role: :assistant, msg_id: "old", body: "old generation"}, server: server)

    assert %{state: :restart_unknown, health: :unknown, freshness: :unknown, messages: []} =
             LiveConversation.snapshot(replacement, server: server)

    assert {:ok, _} =
             LiveConversation.observe(
               replacement,
               %{role: :assistant, msg_id: "new", body: "replacement"},
               server: server
             )

    assert %{messages: [%{id: old_id, body: "old generation"}]} = LiveConversation.snapshot(old, server: server)
    assert %{messages: [%{id: new_id, body: "replacement"}]} = LiveConversation.snapshot(replacement, server: server)
    assert_opaque_id(old_id)
    assert_opaque_id(new_id)
  end

  test "rejects late predecessor generations and replaced exact sessions", %{server: server} do
    old = source(worker_generation: 40, session_id: "old-session")
    replacement = source(worker_generation: 41, session_id: "replacement-session")

    assert {:ok, _snapshot} =
             LiveConversation.observe(
               old,
               %{role: :assistant, msg_id: "old", body: "old generation"},
               server: server
             )

    assert {:ok, _snapshot} = LiveConversation.activate(replacement, server: server)

    assert {:error, :stale_generation} =
             LiveConversation.observe(
               old,
               %{role: :assistant, msg_id: "late-old", body: "must not enter"},
               server: server
             )

    assert %{messages: [%{body: "old generation"}]} =
             LiveConversation.snapshot(old, server: server)

    session_a = source(run_id: "session-fence", worker_generation: 50, session_id: "session-a")
    session_b = %{session_a | session_id: "session-b", attempt_id: "attempt-2"}

    assert {:ok, _snapshot} = LiveConversation.activate(session_a, server: server)
    assert {:ok, _snapshot} = LiveConversation.activate(session_b, server: server)

    assert {:error, :stale_source} =
             LiveConversation.observe(
               session_a,
               %{role: :assistant, msg_id: "late-session-a", body: "must not enter"},
               server: server
             )

    assert %{messages: []} = LiveConversation.snapshot(session_a, server: server)
    assert %{state: :known_empty, messages: []} = LiveConversation.snapshot(session_b, server: server)
  end

  test "isolates repositories, attempts, and sessions that share a display number", %{server: server} do
    first = source()

    second_identity = %{
      first.identity
      | repository: "other-repo",
        provider_id: "other-provider"
    }

    second = %{first | identity: second_identity}
    next_attempt = first |> Map.put(:attempt_id, "attempt-2") |> Map.put(:session_id, "session-2")

    assert {:ok, _} =
             LiveConversation.observe(first, %{role: :assistant, msg_id: "first", body: "first"}, server: server)

    assert {:ok, _} =
             LiveConversation.observe(second, %{role: :assistant, msg_id: "second", body: "second"}, server: server)

    assert {:ok, %{state: :known_empty}} =
             LiveConversation.activate(next_attempt, server: server)

    assert {:ok, _} =
             LiveConversation.observe(
               next_attempt,
               %{role: :assistant, msg_id: "attempt", body: "attempt"},
               server: server
             )

    assert %{messages: [%{body: "first"}]} = LiveConversation.snapshot(first, server: server)
    assert %{messages: [%{body: "second"}]} = LiveConversation.snapshot(second, server: server)

    assert %{messages: [%{body: "attempt"}]} = LiveConversation.snapshot(next_attempt, server: server)
  end

  test "keeps provider session identifiers private while preserving session isolation", %{server: server} do
    provider_session_id = "provider-thread-secret"
    source = source(session_id: provider_session_id)

    assert {:ok, snapshot} =
             LiveConversation.observe(source, %{role: :assistant, msg_id: "session", body: "safe"}, server: server)

    assert is_binary(snapshot.source.session_id)
    assert String.starts_with?(snapshot.source.session_id, "session:")
    refute inspect(snapshot) =~ provider_session_id
  end

  test "ended sources never accept late events", %{server: server} do
    source = source()

    assert {:ok, _} =
             LiveConversation.observe(source, %{role: :assistant, msg_id: "first", body: "first"}, server: server)

    assert {:ok, %{state: :ended}} = LiveConversation.end_generation(source, server: server)

    assert {:ok, snapshot} =
             LiveConversation.observe(source, %{role: :assistant, msg_id: "late", body: "late"}, server: server)

    assert snapshot.state == :ended
    assert [%{body: "first"}] = snapshot.messages

    assert {:ok, %{state: :ended}} = LiveConversation.mark_stale(source, server: server)
    assert {:ok, %{state: :ended}} = LiveConversation.mark_unavailable(source, server: server)
  end

  test "compacts streaming deltas and replaces only their matching completion", %{server: server} do
    source = source()

    assert {:ok, _} =
             LiveConversation.observe(
               source,
               %{kind: :assistant_delta, id: "turn-1", body: "hello ", sequence: 1},
               server: server
             )

    assert {:ok, partial} =
             LiveConversation.observe(
               source,
               %{kind: :assistant_delta, id: "turn-1", body: "world", sequence: 2},
               server: server
             )

    assert [%{id: message_id, body: "hello world", complete?: false}] = partial.messages
    assert_opaque_id(message_id)

    assert {:ok, replayed} =
             LiveConversation.observe(
               source,
               %{kind: :assistant_delta, id: "turn-1", body: "world", sequence: 2},
               server: server
             )

    assert replayed.messages == partial.messages

    assert {:ok, completed} =
             LiveConversation.observe(
               source,
               %{kind: :assistant_completed, id: "turn-1", body: "hello, world"},
               server: server
             )

    assert [%{id: ^message_id, body: "hello, world", complete?: true}] = completed.messages

    assert {:ok, late_delta} =
             LiveConversation.observe(source, %{kind: :assistant_delta, id: "turn-1", body: " ignored"}, server: server)

    assert late_delta.messages == completed.messages
  end

  test "orders reverse-arriving sequenced fragments by trusted sequence", %{server: server} do
    source = source()

    assert {:ok, _} =
             LiveConversation.observe(
               source,
               %{kind: :assistant_delta, id: "reverse", body: "second", sequence: 2},
               server: server
             )

    assert {:ok, snapshot} =
             LiveConversation.observe(
               source,
               %{kind: :assistant_delta, id: "reverse", body: "first ", sequence: 1},
               server: server
             )

    assert [%{body: "first second"}] = snapshot.messages
  end

  test "preserves last known messages only as explicitly stale", %{server: server} do
    source = source()
    assert {:ok, _} = LiveConversation.observe(source, %{role: :assistant, msg_id: "m", body: "known"}, server: server)

    assert {:ok, %{state: :stale, health: :healthy, freshness: :stale, messages: [%{body: "known"}]}} =
             LiveConversation.mark_stale(source, server: server)

    assert {:ok, %{state: :live, health: :healthy, freshness: :current}} =
             LiveConversation.observe(source, %{role: :assistant, msg_id: "recovered", body: "back"}, server: server)
  end

  test "recovers an unavailable generation only after authoritative activation", %{server: server} do
    source = source()

    assert {:ok, _} =
             LiveConversation.observe(source, %{role: :assistant, msg_id: "known", body: "known"}, server: server)

    assert {:ok, %{state: :unavailable, health: :unavailable, freshness: :unknown}} =
             LiveConversation.mark_unavailable(source, server: server)

    assert {:ok, %{state: :unavailable, health: :unavailable, freshness: :unknown}} =
             LiveConversation.observe(
               source,
               %{role: :assistant, msg_id: "known", body: "replayed"},
               server: server
             )

    assert {:ok, %{state: :live, health: :healthy, freshness: :current}} =
             LiveConversation.activate(source, server: server)
  end

  test "activation publishes known-empty and recovery snapshots", %{server: server} do
    source = source()
    assert :ok = LiveConversation.subscribe(source)

    assert {:ok, %{state: :known_empty}} = LiveConversation.activate(source, server: server)
    assert_receive {:live_conversation_changed, %{state: :known_empty, messages: []}}, 2_000

    assert {:ok, %{state: :unavailable}} = LiveConversation.mark_unavailable(source, server: server)
    assert_receive {:live_conversation_changed, %{state: :unavailable}}, 2_000

    assert {:ok, %{state: :known_empty}} = LiveConversation.activate(source, server: server)
    assert_receive {:live_conversation_changed, %{state: :known_empty}}, 2_000
  end
end
