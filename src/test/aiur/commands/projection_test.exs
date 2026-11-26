defmodule Aiur.Commands.ProjectionTest do
  use ExUnit.Case, async: true

  alias Aiur.Commands.Requester
  alias Aiur.{DecisionEvent, DecisionProjection, DecisionValidation}

  defp decision do
    {:ok, decision} = DecisionValidation.normalize(%{question: "Choose scope?", blocking: false}, ticket: %{identifier: "123"})
    decision
  end

  defp event(decision, data, id, version \\ 1) do
    {:ok, event} = DecisionEvent.new(:request_attributed, decision.decision_id, version, data, event_id: id, run_id: "test")
    event
  end

  test "attribution copies all fields once per version and preserves lifecycle states" do
    decision = %{decision() | decision_status: :decided, delivery_status: :delivered}
    data = %{requester: %{kind: :executor}, origin: :executor_cli, native: %{harness: :claude, native_ref: "n", hold: :deferred}, questions: [%{"id" => "q"}], short_label: "Scope"}
    first = event(decision, data, "first")
    second = event(decision, %{origin: :attention}, "second")
    {projection, nil} = DecisionProjection.reduce_checked([decision, first, second])
    updated = projection.current[decision.decision_id]
    assert Map.take(updated, Map.keys(first.data)) == first.data
    assert updated.decision_status == :decided
    assert updated.delivery_status == :delivered
    assert Requester.executor?(updated)
    assert Requester.worker_ticket(updated) == nil

    replacement = %{decision() | decision_id: decision.decision_id, version: 2}
    third = event(replacement, %{origin: :supervisor_api}, "third", 2)
    {projection, nil} = DecisionProjection.reduce_checked([decision, first, replacement, third])
    assert projection.current[decision.decision_id].origin == :supervisor_api
  end

  test "missing request and mismatched versions fail closed" do
    decision = decision()
    attributed = event(decision, %{origin: :emit_event}, "attrs", 2)
    assert {_, {:corrupt, 1, {:invalid_transition, :decision_not_found}}} = DecisionProjection.reduce_checked([attributed])
    assert {_, {:corrupt, 2, {:invalid_transition, :version_mismatch}}} = DecisionProjection.reduce_checked([decision, attributed])
  end

  test "v1 requester and origin defaults and attributed worker ticket are readable" do
    decision = decision()
    assert Requester.kind(decision) == :worker
    refute Requester.executor?(decision)
    assert Requester.worker_ticket(decision) == "123"
    assert Requester.origin(decision) == :emit_event
    assert Requester.origin(%{decision | legacy_attention: %{slug: "legacy"}}) == :attention
    worker = %{decision | requester: %{kind: :worker, ticket: "456"}, origin: :native_question}
    assert Requester.worker_ticket(worker) == "456"
    assert Requester.origin(worker) == :native_question
    assert Requester.executor_ticket_identifier() == "executor"

    attributed = event(decision, %{}, "empty")
    {projection, nil} = DecisionProjection.reduce_checked([decision, attributed])
    assert projection.current[decision.decision_id].origin == :emit_event
  end

  # Characterizes the pre-existing rollback reader; not new-feature coverage.
  test "future regression guard: rollback reader retains the opaque event identity" do
    decision = decision()
    raw = decision |> event(%{origin: :executor_cli}, "attrs") |> DecisionEvent.to_json_safe()
    assert {:ok, unknown} = DecisionEvent.Unrecognized.decode(raw, "request_attributed")
    assert unknown.event_id == "attrs"
    assert unknown.event_type == "request_attributed"
    assert {projection, nil} = DecisionProjection.reduce_checked([decision, unknown])
    assert projection.current[decision.decision_id] == decision
  end
end
