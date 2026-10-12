defmodule Aiur.LiveConversationHealthTest do
  use ExUnit.Case, async: true

  import Aiur.LiveConversationSupport

  alias Aiur.LiveConversation

  setup do
    server = start_supervised!({LiveConversation, name: nil})
    %{server: server}
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

    assert {:ok,
            %{
              state: :stale,
              health: :unavailable,
              freshness: :stale,
              messages: [%{body: "last known good"}]
            }} =
             LiveConversation.mark_degraded(populated, server: server)

    assert {:ok, %{state: :live, freshness: :current}} = LiveConversation.activate(populated, server: server)
  end

  test "ending a degraded source preserves its unavailable health", %{server: server} do
    populated = source(worker_generation: 22)

    assert {:ok, _snapshot} =
             LiveConversation.observe(
               populated,
               %{role: :assistant, msg_id: "known", body: "incomplete evidence"},
               server: server
             )

    assert {:ok, %{state: :stale, health: :unavailable, freshness: :stale}} =
             LiveConversation.mark_degraded(populated, server: server)

    assert {:ok,
            %{
              state: :ended,
              health: :unavailable,
              freshness: :stale,
              messages: [%{body: "incomplete evidence"}]
            }} = LiveConversation.end_generation(populated, server: server)
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

  test "redacts mixed-case and escaped HTTP and websocket capability URLs", %{server: server} do
    samples = [
      "HTTPS://capability.example.test/session/secret",
      "WsS://capability.example.test/socket/secret",
      ~S(https:\/\/capability.example.test\/escaped),
      ~S(HTTPS:\\/\\/capability.example.test\\/escaped),
      ~S(wss\u003A\u002F\u002Fcapability.example.test\u002Fescaped),
      ~S(https%3A%2F%2Fcapability.example.test%2Fescaped),
      "wss&colon;&sol;&sol;capability.example.test/socket"
    ]

    body = Enum.join(samples, " ")

    assert {:ok, snapshot} =
             LiveConversation.observe(
               source(),
               %{role: :assistant, msg_id: "capability-urls", body: body},
               server: server
             )

    [message] = snapshot.messages
    assert length(Regex.scan(~r/\[REDACTED:url\]/, message.body)) == length(samples)
    refute message.body =~ "capability.example.test"
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

  test "unknown provider records retain only a bounded diagnostic count", %{server: server} do
    sentinel = "SENTINEL_SECRET_1130 ghp_abcdefghijklmnopqrstuvwxyz0123456789 /home/private/raw"

    records = [
      %{"role" => "reasoning", "body" => sentinel, "raw" => %{"prompt" => sentinel}},
      %{"role" => "command", "body" => sentinel, "provider_kind" => "shell"},
      %{"kind" => "assistant_delta", "body" => sentinel, "payload" => sentinel},
      %{role: :reasoning, body: sentinel, raw: sentinel},
      %{provider_kind: :raw, record: sentinel}
    ]

    snapshot =
      Enum.reduce(records, nil, fn record, _snapshot ->
        assert {:ok, snapshot} = LiveConversation.observe(source(), record, server: server)
        snapshot
      end)

    assert snapshot.messages == []
    assert snapshot.diagnostic_counts == %{unknown_kind: length(records)}
    refute inspect(snapshot) =~ sentinel
    refute inspect(:sys.get_state(server)) =~ sentinel
    assert byte_size(Jason.encode!(snapshot)) <= 64_000
  end

  test "resolves and subscribes with an opaque generation handle", %{server: server} do
    provider_session = "provider-session-must-stay-private"
    source = source(session_id: provider_session)

    assert {:ok, %{generation_handle: handle}} = LiveConversation.activate(source, server: server)
    assert String.starts_with?(handle, "conversation:")
    assert :ok = LiveConversation.subscribe_handle(handle)

    assert {:ok, resolved} = LiveConversation.resolve(handle, server: server)
    assert resolved.generation_handle == handle
    refute inspect(resolved) =~ provider_session

    assert {:ok, _snapshot} =
             LiveConversation.observe(
               source,
               %{role: :assistant, msg_id: "handle-message", body: "visible"},
               server: server
             )

    assert_receive {:live_conversation_changed, %{generation_handle: ^handle}}, 2_000

    unknown_handle = "conversation:" <> String.duplicate("A", 43)

    assert {:ok, %{state: :restart_unknown, generation_handle: ^unknown_handle, messages: []}} =
             LiveConversation.resolve(unknown_handle, server: server)

    assert {:error, :invalid_handle} = LiveConversation.resolve("not-a-handle", server: server)
  end

  test "serializes barrier-controlled races without violating terminal or ordering invariants" do
    server = start_barrier_server()

    fragment_source = source(worker_generation: 31)

    {_sequence_two, _sequence_one} =
      concurrent_calls(
        server,
        fn ->
          LiveConversation.observe(
            fragment_source,
            %{kind: :assistant_delta, id: "barrier-fragment", body: "two", sequence: 2},
            server: server
          )
        end,
        fn ->
          LiveConversation.observe(
            fragment_source,
            %{kind: :assistant_delta, id: "barrier-fragment", body: "one ", sequence: 1},
            server: server
          )
        end
      )

    assert %{messages: [%{body: "one two"}]} =
             LiveConversation.snapshot(fragment_source, server: server)

    completion_source = source(worker_generation: 32)

    LiveConversation.observe(
      completion_source,
      %{kind: :assistant_delta, id: "barrier-completion", body: "partial", sequence: 1},
      server: server
    )

    {_completion, _late_delta} =
      concurrent_calls(
        server,
        fn ->
          LiveConversation.observe(
            completion_source,
            %{kind: :assistant_completed, id: "barrier-completion", body: "complete"},
            server: server
          )
        end,
        fn ->
          LiveConversation.observe(
            completion_source,
            %{kind: :assistant_delta, id: "barrier-completion", body: " late", sequence: 2},
            server: server
          )
        end
      )

    assert %{messages: [%{body: "complete"}]} =
             LiveConversation.snapshot(completion_source, server: server)

    terminal_source = source(worker_generation: 33)

    {_ended, _late_observe} =
      concurrent_calls(
        server,
        fn -> LiveConversation.end_generation(terminal_source, server: server) end,
        fn ->
          LiveConversation.observe(
            terminal_source,
            %{role: :assistant, msg_id: "too-late", body: "must not enter"},
            server: server
          )
        end
      )

    assert %{state: :ended, messages: []} =
             LiveConversation.snapshot(terminal_source, server: server)

    timestamp_source = source(worker_generation: 34)
    earlier = ~U[2026-01-01 00:00:00Z]
    later = ~U[2026-01-01 00:00:01Z]

    {_later_first, _earlier_second} =
      concurrent_calls(
        server,
        fn ->
          LiveConversation.observe(
            timestamp_source,
            %{role: :assistant, msg_id: "later", body: "later", timestamp: later},
            server: server
          )
        end,
        fn ->
          LiveConversation.observe(
            timestamp_source,
            %{role: :assistant, msg_id: "earlier", body: "earlier", timestamp: earlier},
            server: server
          )
        end
      )

    assert %{messages: [%{body: "earlier"}, %{body: "later"}]} =
             LiveConversation.snapshot(timestamp_source, server: server)
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
end
