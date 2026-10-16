Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.DecisionStore.AuthorityReclassificationTest do
  use Aiur.DecisionStoreCase, async: false

  test "an unbased engineering decision is recorded as Executor-answerable", %{dir: dir} do
    pid = start_store!(dir, dispatch_delay_ms: 60_000)

    assert {:ok, %{status: :accepted, decision: %{authority: :supervisor_allowed, reversibility: :reversible}}} =
             request(pid, %{"question" => "Should we keep the established cap?", "blocking" => true})
  end

  test "Executor reclassifies with rationale, then answers; audit attributes both actions", %{dir: dir} do
    pid = start_store!(dir, dispatch_delay_ms: 60_000)

    assert {:ok, %{decision: decision}} =
             request(pid, %{"question" => "Should we keep the established cap?", "blocking" => true, "authority" => "human_required"})

    assert {:ok, %{status: :accepted, decision: %{authority: :supervisor_allowed}}} =
             DecisionStore.reclassify_authority(
               decision.decision_id,
               %{expected_version: 1, executor_id: "executor-1", rationale: "Acceptance already defines the fallback."},
               pid
             )

    assert {:ok, %{status: :accepted, action: %{actor: %{kind: :executor, id: "executor-1"}}}} =
             DecisionStore.answer(
               decision.decision_id,
               %{"expected_version" => 1, "idempotency_key" => "reclassified-answer", "custom_response" => "Keep the cap."},
               [actor: %{kind: :executor, id: "executor-1"}],
               pid
             )

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
    assert Enum.any?(audit, &match?(%DecisionEvent{type: :authority_reclassified, data: %{actor: %{kind: :executor, id: "executor-1"}, detail: "Acceptance already defines the fallback."}}, &1))
    assert Enum.any?(audit, &match?(%DecisionEvent{type: :answer_recorded, data: %{actor: %{kind: :executor, id: "executor-1"}}}, &1))

    GenServer.stop(pid)
    recovered = start_store!(dir, dispatch_delay_ms: 60_000)
    assert {:ok, %{authority: :supervisor_allowed, decision_status: :decided}} = DecisionStore.get(decision.decision_id, recovered)
    assert {:ok, recovered_audit} = DecisionStore.audit_history(decision.decision_id, recovered)
    assert Enum.any?(recovered_audit, &match?(%DecisionEvent{type: :authority_reclassified, data: %{actor: %{kind: :executor, id: "executor-1"}}}, &1))
    assert Enum.any?(recovered_audit, &match?(%DecisionEvent{type: :answer_recorded, data: %{actor: %{kind: :executor, id: "executor-1"}}}, &1))
  end
end
