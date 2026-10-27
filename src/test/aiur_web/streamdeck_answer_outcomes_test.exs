defmodule AiurWeb.StreamdeckAnswerOutcomesTest do
  use AiurWeb.StreamdeckChannelCase
  alias Aiur.Commands.Answering
  alias Aiur.DecisionStore
  alias Aiur.TestSupport.EndpointStubs

  setup do
    dir = Path.join(System.tmp_dir!(), "deck-outcomes-#{System.unique_integer([:positive])}")
    {:ok, store} = DecisionStore.start_link(name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end)
    EndpointStubs.put(decision_store: store)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(store)
      Aiur.TestCleanup.rm_rf!(dir)
    end)

    payload = %{
      "source_id" => "deck-outcomes",
      "question" => "Ship?",
      "authority" => "human_required",
      "context" => %{"authority_basis" => "product"},
      "blocking" => false,
      "reversibility" => "reversible",
      "options" => [%{"id" => "ship", "label" => "Ship it"}]
    }

    {:ok, %{decision: decision}} = DecisionStore.request(payload, [ticket: %{identifier: "AIUR-1"}, source: %{agent_id: "agent-1", session_id: "session-1", event_id: "evt-1"}], store)
    socket = joined_socket()
    assert_reply(push(socket, "focus", %{"identifier" => "AIUR-1"}), :ok, %{"focused" => "AIUR-1"})
    receive_barrier(%Message{event: "commands"})
    %{store: store, decision: decision, socket: socket}
  end

  test "answer after another surface wins returns the winner", %{store: store, decision: decision, socket: socket} do
    payload = %{"expected_version" => decision.version, "idempotency_key" => "dashboard", "option_id" => "ship"}
    outcome = Answering.answer(decision.decision_id, payload, actor: %{kind: :operator, id: "dashboard"}, actor_source: :dashboard_session, client: %{surface: :dashboard}, store: store)
    assert outcome.status == :accepted
    ref = push(socket, "answer_command", wire_answer(decision, "deck"))
    reply = receive_barrier(%Phoenix.Socket.Reply{ref: ^ref})
    assert reply.status == :error
    assert reply.payload == %{reason: "already_answered", winner: %{"actor_kind" => "operator", "summary" => "Ship it", "accepted_at" => DateTime.to_iso8601(outcome.decision.answer.accepted_at)}}
    assert {:ok, current} = DecisionStore.get(decision.decision_id, store)
    assert current.answer.actor.id == "dashboard"
  end

  test "retry after a lost deck reply is duplicate", %{store: store, decision: decision, socket: socket} do
    payload = wire_answer(decision, "retry")
    assert %{status: :ok, payload: %{"status" => "accepted"}} = reply(socket, payload)
    assert %{status: :ok, payload: %{"status" => "duplicate"}} = reply(socket, payload)
    assert {:ok, current} = DecisionStore.get(decision.decision_id, store)
    assert current.answer.actor == %{kind: :operator, id: "streamdeck", source: :streamdeck}
  end

  test "expired nonblocking Command is withdrawn", %{store: store, decision: decision, socket: socket} do
    assert {:ok, _} = DecisionStore.expire(decision.decision_id, "timeout", [], store)
    assert %{status: :error, payload: %{reason: "withdrawn", status: "expired"}} = reply(socket, wire_answer(decision, "expired"))
    assert {:ok, current} = DecisionStore.get(decision.decision_id, store)
    assert current.answer == nil
  end

  test "stale version is structured and does not record an answer", %{store: store, decision: decision, socket: socket} do
    payload = Map.put(wire_answer(decision, "stale"), "version", decision.version + 1)
    assert %{status: :error, payload: %{reason: "stale"}} = reply(socket, payload)
    assert {:ok, current} = DecisionStore.get(decision.decision_id, store)
    assert current.answer == nil
  end

  defp reply(socket, payload) do
    ref = push(socket, "answer_command", payload)
    receive_barrier(%Phoenix.Socket.Reply{ref: ^ref})
  end

  defp wire_answer(decision, key), do: %{"decision_id" => decision.decision_id, "version" => decision.version, "idempotency_key" => key, "option_id" => "ship"}
end
