defmodule Aiur.DecisionStore.CorrectiveOverridesTest do
  use ExUnit.Case, async: true

  alias Aiur.DecisionDispatchTasks
  alias Aiur.DecisionStore.CorrectiveOverrides

  test "reconciliation uses the bounded queue once until completion, then retries" do
    tasks = start_supervised!({DecisionDispatchTasks, name: nil})
    owner = self()

    reconcile = fn decision, record ->
      send(owner, {:corrective_started, decision.decision_id, record.action_id})
      {:ok, []}
    end

    record = %{route: :corrective_ticket, state: :queued, action_id: "action"}
    decision = %{decision_id: "command", ticket: %{identifier: "50"}, active_action_id: "action", overrides: [record]}
    state = %{current: %{"command" => decision}, writable?: true, health: :writable, decision_dispatch_tasks: tasks}
    state = CorrectiveOverrides.configure(state, corrective_override_reconciler: reconcile)
    pending = CorrectiveOverrides.reconcile(state)
    assert Map.has_key?(pending.corrective_override_jobs, "command")
    assert CorrectiveOverrides.reconcile(pending) == pending
    assert_receive {:corrective_started, "command", "action"}, 2_000
    assert_receive {:corrective_override_result, correlation, {:ok, []}}, 2_000
    assert %{decision_id: "command", action_id: "action", job_id: job_id} = correlation
    assert is_reference(job_id)
    assert CorrectiveOverrides.settle(pending, %{correlation | job_id: make_ref()}, {:ok, []}) == pending
    refute_receive {:corrective_started, "command", "action"}, 10
    completed = CorrectiveOverrides.settle(pending, correlation, {:ok, []})
    assert completed.corrective_override_jobs == %{}
    assert Map.has_key?(CorrectiveOverrides.reconcile(completed).corrective_override_jobs, "command")
    assert_receive {:corrective_started, "command", "action"}, 2_000
  end

  test "read-only and implemented records never schedule work" do
    tasks = start_supervised!({DecisionDispatchTasks, name: nil})
    owner = self()

    reconcile = fn decision, record ->
      send(owner, {:unexpected_corrective_job, decision.decision_id, record.action_id})
      {:ok, []}
    end

    record = %{route: :corrective_ticket, state: :implemented, action_id: "action"}
    decision = %{decision_id: "command", ticket: %{identifier: "50"}, active_action_id: "action", overrides: [record]}
    state = %{current: %{"command" => decision}, writable?: true, health: :writable, decision_dispatch_tasks: tasks}
    state = CorrectiveOverrides.configure(state, corrective_override_reconciler: reconcile)
    assert CorrectiveOverrides.reconcile(state) == state
    refute_receive {:unexpected_corrective_job, "command", "action"}, 10
    queued = %{decision | overrides: [%{record | state: :queued}]}
    held = %{state | writable?: false, current: %{"command" => queued}}
    assert CorrectiveOverrides.reconcile(held) == held
    refute_receive {:unexpected_corrective_job, "command", "action"}, 10
  end
end
