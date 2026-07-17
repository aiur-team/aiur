defmodule Aiur.LiveConversationTest do
  use ExUnit.Case, async: true

  alias Aiur.{LiveConversation, TrackerIdentity}

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
    assert body =~ "[REDACTED:path]"
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

    assert [%{id: message_id, body: "hello world"}] = partial.messages
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

    assert [%{id: ^message_id, body: "hello, world"}] = completed.messages

    assert {:ok, late_delta} =
             LiveConversation.observe(source, %{kind: :assistant_delta, id: "turn-1", body: " ignored"}, server: server)

    assert late_delta.messages == completed.messages
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

  test "ended-generation eviction cannot crash a pending notification", %{server: server} do
    first = source(worker_generation: 1)
    assert :ok = LiveConversation.subscribe(first)

    Enum.each(1..17, fn generation ->
      assert {:ok, %{state: :ended}} =
               LiveConversation.end_generation(source(worker_generation: generation), server: server)
    end)

    assert_receive {:live_conversation_changed, _snapshot}, 2_000
    assert Process.alive?(server)
    assert %{state: :restart_unknown} = LiveConversation.snapshot(first, server: server)
  end

  test "accepts only trusted operator deliveries and canonicalizes notification topics", %{server: server} do
    source = source() |> Map.delete(:run_id)

    assert :ok = LiveConversation.subscribe(source)

    assert {:ok, rejected} =
             LiveConversation.observe(
               source,
               %{role: :user, msg_id: "untrusted", body: "workspace prompt"},
               server: server
             )

    assert rejected.messages == []
    assert rejected.diagnostic_counts.untrusted_operator == 1

    assert {:ok, _snapshot} =
             LiveConversation.observe_operator_message(
               source,
               %{role: :user, msg_id: "operator-1", body: "approved question", payload: %{source: :operator_delivery}},
               server: server
             )

    assert_receive {:live_conversation_changed, %{messages: [%{id: operator_id, role: "operator"}]}}, 2_000
    assert_opaque_id(operator_id)
  end

  test "admits system transitions and tool summaries only through trusted adapters", %{server: server} do
    source = source()

    assert {:ok, rejected_system} =
             LiveConversation.observe(
               source,
               %{role: :system, msg_id: "raw-system", body: "provider supplied"},
               server: server
             )

    assert rejected_system.messages == []
    assert rejected_system.diagnostic_counts.unsafe_system == 1

    assert {:ok, with_system} =
             LiveConversation.observe_system_transition(
               source,
               %{msg_id: "transition", title: "Lifecycle", body: "Agent paused"},
               server: server
             )

    assert [%{id: system_id, role: "system", title: "Lifecycle", body: "Agent paused"}] =
             with_system.messages

    assert_opaque_id(system_id)

    assert {:ok, rejected_tool} =
             LiveConversation.observe(
               source,
               %{role: :tool, msg_id: "raw-tool", body: "full command output"},
               server: server
             )

    assert rejected_tool.diagnostic_counts.unsafe_tool == 1

    assert {:ok, with_tool} =
             LiveConversation.observe_tool_summary(
               source,
               %{msg_id: "tool-result", title: "Tool result", body: "Tool completed"},
               server: server
             )

    assert %{id: tool_id, role: "tool", title: "Tool result", body: "Tool completed"} =
             List.last(with_tool.messages)

    assert_opaque_id(tool_id)
  end

  test "retains bounded partial state and enforces the total message byte ceiling", %{server: server} do
    source = source()
    body = String.duplicate("x", 1_600)

    Enum.each(1..80, fn n ->
      assert {:ok, _} =
               LiveConversation.observe(
                 source,
                 %{kind: :assistant_delta, id: "partial-#{n}", body: body},
                 server: server
               )
    end)

    assert {:ok, snapshot} =
             LiveConversation.observe(source, %{kind: :assistant_delta, id: "partial-1", body: body}, server: server)

    assert byte_size(Jason.encode!(snapshot)) <= 64_000
    assert snapshot.truncated?
    assert Enum.all?(snapshot.messages, &(String.length(&1.body) <= 1_600))
  end

  test "bounds the actual JSON wire representation for escape-heavy bodies", %{server: server} do
    source = source()
    body = String.duplicate(~s("\\), 800)

    Enum.each(1..80, fn n ->
      assert {:ok, _} =
               LiveConversation.observe(
                 source,
                 %{role: :assistant, msg_id: "escaped-#{n}", body: body},
                 server: server
               )
    end)

    snapshot = LiveConversation.snapshot(source, server: server)
    assert byte_size(Jason.encode!(snapshot)) <= 64_000
    assert snapshot.truncated?
  end

  test "bounds partial fragment bookkeeping before completion", %{server: server} do
    source = source()

    Enum.each(1..256, fn sequence ->
      assert {:ok, _snapshot} =
               LiveConversation.observe(
                 source,
                 %{kind: :assistant_delta, id: "partial", body: "x", sequence: sequence},
                 server: server
               )
    end)

    snapshot = LiveConversation.snapshot(source, server: server)
    assert [%{body: body}] = snapshot.messages
    assert String.length(body) == 128
    assert snapshot.truncated?
    assert snapshot.diagnostic_counts.partial_fragment_limit == 128

    internal_snapshot = server |> :sys.get_state() |> Map.fetch!(:snapshots) |> Map.values() |> List.first()
    [internal_message] = internal_snapshot.messages
    assert MapSet.size(internal_message.fragment_ids) == 128
    assert MapSet.size(internal_snapshot.seen[internal_message.id].fragment_ids) == 128
  end

  test "bounds live generations that miss end cleanup" do
    counter = :atomics.new(1, [])

    clock = fn ->
      DateTime.add(~U[2026-01-30 00:00:00Z], :atomics.add_get(counter, 1, 1) * 86_400, :second)
    end

    server =
      start_supervised!(Supervisor.child_spec({LiveConversation, name: nil, clock: clock}, id: make_ref()))

    Enum.each(1..129, fn generation ->
      assert {:ok, %{state: :live}} =
               LiveConversation.observe(
                 source(worker_generation: generation),
                 %{role: :assistant, msg_id: "message-#{generation}", body: "generation #{generation}"},
                 server: server
               )
    end)

    assert map_size(:sys.get_state(server).snapshots) == 128

    assert %{state: :restart_unknown, messages: []} =
             LiveConversation.snapshot(source(worker_generation: 1), server: server)

    assert %{state: :live, messages: [%{body: "generation 129"}]} =
             LiveConversation.snapshot(source(worker_generation: 129), server: server)
  end

  test "preserves original ordering when a partial message completes", %{server: server} do
    source = source()
    first_at = ~U[2026-01-01 00:00:00Z]
    second_at = ~U[2026-01-01 00:00:01Z]
    completed_at = ~U[2026-01-01 00:00:02Z]

    assert {:ok, _} =
             LiveConversation.observe(
               source,
               %{kind: :assistant_delta, id: "first", body: "par", timestamp: first_at},
               server: server
             )

    assert {:ok, _} =
             LiveConversation.observe(
               source,
               %{role: :assistant, msg_id: "second", body: "second", timestamp: second_at},
               server: server
             )

    assert {:ok, _} =
             LiveConversation.observe(
               source,
               %{kind: :assistant_completed, id: "first", body: "first", timestamp: completed_at},
               server: server
             )

    assert {:ok, snapshot} =
             LiveConversation.observe(
               source,
               %{role: :assistant, msg_id: "third", body: "third", timestamp: completed_at},
               server: server
             )

    assert Enum.map(snapshot.messages, & &1.body) == ["first", "second", "third"]
    assert hd(snapshot.messages).occurred_at == first_at
  end

  test "replaces malformed Unicode and omits opaque provider identity from the public source", %{server: server} do
    source = source()

    assert {:ok, snapshot} =
             LiveConversation.observe(
               source,
               %{role: :assistant, msg_id: "unicode", body: <<"hello ", 255>>},
               server: server
             )

    assert [%{body: "hello �"}] = snapshot.messages

    assert snapshot.source.identity == %{
             version: 1,
             kind: :github,
             owner: "owner",
             repository: "repo",
             identifier: "42"
           }

    refute Map.has_key?(snapshot.source.identity, :provider_id)
  end

  test "hashes and bounds provider message ids before publication", %{server: server} do
    raw_ids = [
      "Bearer credential-shaped-value",
      "https://example.test/capability/message",
      "/home/operator/private/message-id"
    ]

    snapshot =
      Enum.reduce(raw_ids, nil, fn raw_id, _snapshot ->
        assert {:ok, snapshot} =
                 LiveConversation.observe(
                   source(),
                   %{role: :assistant, msg_id: raw_id, body: "safe body"},
                   server: server
                 )

        snapshot
      end)

    public_ids = Enum.map(snapshot.messages, & &1.id)
    assert length(public_ids) == length(raw_ids)
    assert Enum.uniq(public_ids) == public_ids
    assert Enum.all?(public_ids, &(String.starts_with?(&1, "message:") and byte_size(&1) <= 64))

    Enum.each(raw_ids, fn raw_id ->
      refute inspect(snapshot) =~ raw_id
    end)
  end

  test "degraded health preserves evidence as stale and reports an empty source unavailable", %{server: server} do
    empty = source(worker_generation: 20)
    populated = source(worker_generation: 21)

    assert {:ok, %{state: :known_empty}} = LiveConversation.activate(empty, server: server)
    assert {:ok, %{state: :unavailable, messages: []}} = LiveConversation.mark_degraded(empty, server: server)

    assert {:ok, _} =
             LiveConversation.observe(
               populated,
               %{role: :assistant, msg_id: "known", body: "last known good"},
               server: server
             )

    assert {:ok, %{state: :stale, messages: [%{body: "last known good"}]}} =
             LiveConversation.mark_degraded(populated, server: server)

    assert {:ok, %{state: :live, freshness: :current}} = LiveConversation.activate(populated, server: server)
  end

  test "bounds public source fields within the total snapshot byte ceiling", %{server: server} do
    oversized = String.duplicate("x", 100_000)
    maximum = String.duplicate("x", 256)

    maximum_source =
      source()
      |> Map.put(:run_id, maximum)
      |> Map.put(:session_id, maximum)
      |> Map.put(:attempt_id, maximum)
      |> Map.put(:backend, maximum)

    assert {:ok, snapshot} = LiveConversation.activate(maximum_source, server: server)
    assert byte_size(Jason.encode!(snapshot)) <= 64_000

    assert {:error, :invalid_source} =
             LiveConversation.activate(%{source() | run_id: oversized}, server: server)

    assert {:error, :invalid_source} =
             LiveConversation.activate(%{source() | attempt_id: %{}}, server: server)
  end

  test "bounds titles and bodies and tolerates malformed timestamps", %{server: server} do
    long_title = String.duplicate("t", 121)
    long_body = String.duplicate("b", 1_601)

    assert {:ok, snapshot} =
             LiveConversation.observe(
               source(),
               %{
                 role: :assistant,
                 msg_id: "bounded",
                 title: long_title,
                 body: long_body,
                 timestamp: "not-a-timestamp"
               },
               server: server
             )

    assert [%{title: title, body: body, occurred_at: %DateTime{}}] = snapshot.messages
    assert String.length(title) == 120
    assert String.length(body) == 1_600
  end

  test "redacts generic credential fields before retaining trusted message content", %{server: server} do
    body = ~s(password=correct-horse api_key=abc123 {"token":"opaque"})

    assert {:ok, snapshot} =
             LiveConversation.observe(source(), %{role: :assistant, msg_id: "secrets", body: body}, server: server)

    [message] = snapshot.messages
    assert message.body =~ "[REDACTED:credential]"
    refute message.body =~ "correct-horse"
    refute message.body =~ "abc123"
    refute message.body =~ "opaque"
  end

  test "caps diagnostic counters for indefinitely rejected event streams", %{server: server} do
    snapshot =
      Enum.reduce(1..1_100, nil, fn _, _snapshot ->
        assert {:ok, snapshot} = LiveConversation.observe(source(), %{role: :tool, body: "unsafe"}, server: server)
        snapshot
      end)

    assert snapshot.diagnostic_counts.unsafe_tool == 1_000
    assert snapshot.truncated?
    assert byte_size(Jason.encode!(snapshot)) <= 64_000
  end

  test "drops malformed structured fields without crashing the projection", %{server: server} do
    malformed = [
      %{role: :assistant, msg_id: %{}, body: "bad id"},
      %{role: :assistant, msg_id: "bad-title", title: %{}, body: "bad title"},
      %{role: :assistant, msg_id: "bad-delivery", delivery: :unknown, body: "bad delivery"}
    ]

    snapshot =
      Enum.reduce(malformed, nil, fn event, _snapshot ->
        assert {:ok, snapshot} = LiveConversation.observe(source(), event, server: server)
        snapshot
      end)

    assert snapshot.messages == []
    assert snapshot.diagnostic_counts.invalid_event == 3
    assert Process.alive?(server)
  end

  defp source(overrides \\ []) do
    Map.merge(
      %{
        identity: %TrackerIdentity{
          status: :joinable,
          kind: :github,
          owner: "owner",
          repository: "repo",
          provider_id: "opaque-provider",
          identifier: "42",
          reason: nil
        },
        run_id: "run-1",
        attempt_id: "attempt-1",
        backend: "codex",
        worker_generation: 1
      },
      Map.new(overrides)
    )
  end

  defp assert_opaque_id(id) do
    assert String.starts_with?(id, "message:")
    assert byte_size(id) <= 64
  end
end
