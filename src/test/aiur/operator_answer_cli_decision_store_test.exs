Code.require_file("../support/decision_store_case.ex", __DIR__)

defmodule Aiur.OperatorAnswerCLIDecisionStoreTest do
  use Aiur.DecisionStoreCase, async: false

  import ExUnit.CaptureIO

  alias Aiur.OperatorAnswerCLI

  test "records an operator CLI answer for a human-required Command in the real DecisionStore", %{dir: dir} do
    store = start_store!(dir, dispatch_delay_ms: 60_000)

    assert {:ok, %{decision: decision}} =
             request(store, %{
               "question" => "Should the operator approve this CLI answer integration test?",
               "blocking" => true,
               "authority" => "human_required",
               "reversibility" => "irreversible",
               "options" => [%{"id" => "approve", "label" => "Approve"}]
             })

    capture_io(fn ->
      assert OperatorAnswerCLI.answer(
               decision_id: decision.decision_id,
               option_id: "approve",
               operator: true,
               expected_version: decision.version,
               confirmation: decision.decision_id,
               operator_name_fun: fn -> "operator-42" end,
               decision_store: store
             ) == 0
    end)

    assert {:ok, %Decision{decision_status: :decided, answer: answer}} =
             DecisionStore.get(decision.decision_id, store)

    assert answer.selected_option_id == "approve"
    assert answer.actor == %{kind: :operator, id: "cli:operator-42"}
  end
end
