defmodule Aiur.LiveConversationBoundsTest do
  use ExUnit.Case, async: true

  import Aiur.LiveConversationSupport

  alias Aiur.LiveConversation

  setup do
    server = start_supervised!({LiveConversation, name: nil})
    %{server: server}
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

  test "removes the unwired system capability and admits tool summaries only through trusted adapters", %{
    server: server
  } do
    source = source()

    assert {:ok, rejected_system} =
             LiveConversation.observe(
               source,
               %{role: :system, msg_id: "raw-system", body: "provider supplied"},
               server: server
             )

    assert rejected_system.messages == []
    assert rejected_system.diagnostic_counts.unsafe_system == 1

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

  test "retains bounded replay tombstones after visible-message eviction", %{server: server} do
    source = source()

    Enum.each(1..400, fn n ->
      assert {:ok, _snapshot} =
               LiveConversation.observe(
                 source,
                 %{role: :assistant, msg_id: "replay-#{n}", body: "message #{n}"},
                 server: server
               )
    end)

    before_replay = LiveConversation.snapshot(source, server: server)
    assert length(before_replay.messages) == 80

    assert {:ok, after_replay} =
             LiveConversation.observe(
               source,
               %{role: :assistant, msg_id: "replay-320", body: "resurrected retry"},
               server: server
             )

    assert after_replay.messages == before_replay.messages

    internal = server |> :sys.get_state() |> Map.fetch!(:snapshots) |> Map.values() |> List.first()
    assert map_size(internal.replay_tombstones) == 256
  end

  test "unknown-history activation stays restart_unknown while admitting only new live evidence", %{
    server: server
  } do
    source = source()

    assert {:ok, %{state: :restart_unknown, messages: []}} =
             LiveConversation.activate(source, server: server, history_known?: false)

    assert {:ok, %{state: :restart_unknown, messages: [%{body: "new evidence"}]}} =
             LiveConversation.observe(
               source,
               %{role: :assistant, msg_id: "after-restart", body: "new evidence"},
               server: server
             )
  end

  test "coalesces burst runtime status onto one authoritative epoch revision", %{server: _server} do
    server =
      start_supervised!(
        Supervisor.child_spec(
          {LiveConversation, name: nil, notification_delay_ms: 1_000},
          id: make_ref()
        )
      )

    source = source()
    opts = [server: server, runtime_subscriber: {self(), "gid-runtime"}]

    assert {:ok, _snapshot} = LiveConversation.activate(source, opts)

    Enum.each(1..50, fn n ->
      assert {:ok, _snapshot} =
               LiveConversation.observe(
                 source,
                 %{role: :assistant, msg_id: "burst-#{n}", body: "burst #{n}"},
                 opts
               )
    end)

    assert_receive {:worker_runtime_info, "gid-runtime", %{live_conversation: status}}, 2_000
    assert status.revision == 51
    assert status.source_revision == 1
    assert status.source.worker_generation == 1
    assert String.starts_with?(status.projection_epoch, "projection:")
    refute_receive {:worker_runtime_info, "gid-runtime", _status}, 200
  end

  test "replaces a stale runtime subscriber for the same issue and source", %{server: _server} do
    server =
      start_supervised!(
        Supervisor.child_spec(
          {LiveConversation, name: nil, notification_delay_ms: 60_000},
          id: make_ref()
        )
      )

    replacement =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(replacement, :stop) end)
    source = source()

    assert {:ok, _snapshot} =
             LiveConversation.activate(source,
               server: server,
               runtime_subscriber: {self(), "gid-runtime"}
             )

    assert {:ok, _snapshot} =
             LiveConversation.activate(source,
               server: server,
               runtime_subscriber: {replacement, "gid-runtime"}
             )

    assert [%{"gid-runtime" => ^replacement}] =
             server
             |> :sys.get_state()
             |> Map.fetch!(:runtime_subscribers)
             |> Map.values()
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
    assert map_size(internal_message.fragments) == 128
    assert %{message_index: 0} = internal_snapshot.seen[internal_message.id]
    refute Map.has_key?(internal_snapshot.seen[internal_message.id], :fragment_ids)
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
end
