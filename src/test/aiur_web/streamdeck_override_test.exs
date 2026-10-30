defmodule AiurWeb.StreamdeckOverrideTest do
  use AiurWeb.StreamdeckChannelCase

  alias Aiur.{Decision, DecisionStore}
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.StreamdeckChannel.CommandAnswers

  setup do
    dir = Aiur.TestSupport.tmp_root!("streamdeck-override")
    store = start_supervised!({DecisionStore, name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end, dispatch_delay_ms: 60_000, answer_comment_publisher: fn _ -> :ok end})
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    EndpointStubs.put(decision_store: store)

    {:ok, %{decision: decision}} =
      DecisionStore.request(
        %{source_id: "deck-override", question: "Ship?", authority: "human_required", context: %{authority_basis: "product"}, blocking: false, reversibility: "reversible"},
        [ticket: %{identifier: "AIUR-1"}, source: %{agent_id: "agent-1", session_id: "session-1"}],
        store
      )

    %{store: store, decision: decision}
  end

  test "explicit override selector accepts a delivered answer through the channel", %{store: store, decision: decision} do
    assert {:ok, %{decision: answered}} =
             DecisionStore.answer(decision.decision_id, %{expected_version: 1, idempotency_key: "first", custom_response: "Ship"}, [actor: %{kind: :operator, id: "dashboard"}], store)

    item = %{
      id: 1,
      target_issue_identifier: "AIUR-1",
      action_id: answered.active_action_id,
      correlation: %{decision_id: decision.decision_id, decision_version: 1, action_id: answered.active_action_id, attempt_id: "attempt"}
    }

    assert {:ok, :accepted} = DecisionStore.validate_delivery(item, store)
    assert {:ok, :accepted} = DecisionStore.record_delivery(item, store)
    socket = joined_socket()
    assert_reply(push(socket, "focus", %{"identifier" => "AIUR-1"}), :ok, %{"focused" => "AIUR-1"})
    receive_barrier(%Message{event: "commands"})

    ref =
      push(socket, "answer_command", %{
        "decision_id" => decision.decision_id,
        "version" => 1,
        "idempotency_key" => "deck-override",
        "custom_response" => "Hold",
        "override" => true,
        "rationale" => "New operator direction"
      })

    assert %{status: :ok, payload: %{"status" => "accepted"}} = receive_barrier(%Phoenix.Socket.Reply{ref: ^ref})
    assert {:ok, revised} = DecisionStore.get(decision.decision_id, store)
    assert Decision.active_answer(revised).custom_response == "Hold"
    assert Decision.active_answer(revised).rationale == "New operator direction"
    assert Decision.active_answer(revised).actor == %{kind: :operator, id: "streamdeck", source: :streamdeck}
    assert [%{decision_id: id, state: :queued}] = revised.overrides
    assert id == decision.decision_id
  end

  test "override selector requires a bounded rationale" do
    payload = %{"override" => true, "version" => 1, "idempotency_key" => "override", "custom_response" => "Hold"}

    for rationale <- [nil, " ", String.duplicate("x", 4_001)] do
      assert CommandAnswers.build_answer_payload(Map.put(payload, "rationale", rationale)) == {:error, :invalid_override_rationale}
    end
  end
end
