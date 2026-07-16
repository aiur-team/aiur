defmodule Aiur.LiveConversationTest do
  use ExUnit.Case, async: true

  alias Aiur.{LiveConversation, TrackerIdentity}

  setup do
    server = start_supervised!({LiveConversation, name: nil})
    %{server: server}
  end

  test "starts known-empty, retains only sanitized allowlisted messages, and deduplicates", %{server: server} do
    source = source()

    assert {:ok, %{state: :known_empty, messages: []}} = LiveConversation.activate(source, server: server)

    assert {:ok, snapshot} =
             LiveConversation.observe(
               source,
               %{
                 role: :assistant,
                 msg_id: "m-1",
                 body:
                   "token ghp_abcdefghijklmnopqrstuvwxyz0123456789 at /tmp/secret and https://example.test/capability"
               },
               server: server
             )

    assert snapshot.state == :live
    assert [%{id: "m-1", role: "agent", body: body}] = snapshot.messages
    assert body =~ "[REDACTED:ghp]"
    assert body =~ "[REDACTED:path]"
    assert body =~ "[REDACTED:url]"

    assert {:ok, duplicate} =
             LiveConversation.observe(source, %{role: :assistant, msg_id: "m-1", body: "different retry"},
               server: server
             )

    assert duplicate.messages == snapshot.messages
  end

  test "bounds messages and rejects unsafe payloads without retaining their content", %{server: server} do
    source = source()

    Enum.each(1..81, fn n ->
      assert {:ok, _} =
               LiveConversation.observe(source, %{role: :assistant, msg_id: "m-#{n}", body: "message #{n}"},
                 server: server
               )
    end)

    assert {:ok, snapshot} =
             LiveConversation.observe(
               source,
               %{role: :tool, msg_id: "tool", body: "cat /private/data", payload: %{output: "secret"}}, server: server)

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

    assert %{state: :restart_unknown, messages: []} = LiveConversation.snapshot(replacement, server: server)

    assert {:ok, _} =
             LiveConversation.observe(replacement, %{role: :assistant, msg_id: "new", body: "replacement"},
               server: server
             )

    assert %{messages: [%{id: "old"}]} = LiveConversation.snapshot(old, server: server)
    assert %{messages: [%{id: "new"}]} = LiveConversation.snapshot(replacement, server: server)
  end

  test "ended sources never accept late events", %{server: server} do
    source = source()

    assert {:ok, _} =
             LiveConversation.observe(source, %{role: :assistant, msg_id: "first", body: "first"}, server: server)

    assert {:ok, %{state: :ended}} = LiveConversation.end_generation(source, server: server)

    assert {:ok, snapshot} =
             LiveConversation.observe(source, %{role: :assistant, msg_id: "late", body: "late"}, server: server)

    assert snapshot.state == :ended
    assert [%{id: "first"}] = snapshot.messages
  end

  test "compacts streaming deltas and replaces only their matching completion", %{server: server} do
    source = source()

    assert {:ok, _} =
             LiveConversation.observe(source, %{kind: :assistant_delta, id: "turn-1", body: "hello "}, server: server)

    assert {:ok, partial} =
             LiveConversation.observe(source, %{kind: :assistant_delta, id: "turn-1", body: "world"}, server: server)

    assert [%{id: "turn-1", body: "hello world"}] = partial.messages

    assert {:ok, completed} =
             LiveConversation.observe(source, %{kind: :assistant_completed, id: "turn-1", body: "hello, world"},
               server: server
             )

    assert [%{id: "turn-1", body: "hello, world"}] = completed.messages

    assert {:ok, late_delta} =
             LiveConversation.observe(source, %{kind: :assistant_delta, id: "turn-1", body: " ignored"}, server: server)

    assert late_delta.messages == completed.messages
  end

  test "preserves last known messages only as explicitly stale", %{server: server} do
    source = source()
    assert {:ok, _} = LiveConversation.observe(source, %{role: :assistant, msg_id: "m", body: "known"}, server: server)
    assert {:ok, %{state: :stale, messages: [%{id: "m"}]}} = LiveConversation.mark_stale(source, server: server)
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
end
