defmodule AiurWeb.OperatorControlCenter.DecisionOutcomesTest do
  use ExUnit.Case, async: true
  alias AiurWeb.OperatorControlCenter.DecisionOutcomes

  test "accepted, delivered and stopped-agent outcomes name the actual target and time" do
    at = DateTime.utc_now()
    decision = %{ticket: %{identifier: "123"}, dispatch_attempts: [%{delivered_at: at}], acknowledgement: nil}

    for status <- [:accepted, :duplicate] do
      assert {:success, "Answer recorded. Delivering to #123…", []} = DecisionOutcomes.outcome_notice(%{status: status, delivery: :pending, decision: decision})

      assert {:success, "Answer recorded. #123 is not running; it will receive it when it restarts.", []} =
               DecisionOutcomes.outcome_notice(%{status: status, delivery: :queued_for_restart, decision: decision})

      assert {:success, text, []} = DecisionOutcomes.outcome_notice(%{status: status, delivery: :delivered, decision: decision})
      assert text == "Delivered to #123 at #{DateTime.to_iso8601(DateTime.truncate(at, :second))}"
    end
  end

  test "race notices identify the winner and preserve their actual accepted answer and time" do
    at = DateTime.utc_now()

    for {kind, label} <- [executor: "the Executor", operator: "you on another device"] do
      winner = %{actor_kind: kind, accepted_at: at, summary: "Hold deployment"}
      assert {:error, text, []} = DecisionOutcomes.outcome_notice(%{status: :already_answered, winner: winner})
      assert text == "Already answered by #{label} at #{DateTime.to_iso8601(DateTime.truncate(at, :second))}: 'Hold deployment'"
    end
  end

  test "in-flight is distinct from confirmed delivery and unknown delivery time stays unknown" do
    assert {:error, "Delivery is in progress. Send a follow-up message instead.", [:follow_up]} = DecisionOutcomes.outcome_notice(%{status: :too_late, reason: :answer_in_flight})
    assert {:error, "Already delivered at an unknown time. Send a follow-up message instead.", [:follow_up]} = DecisionOutcomes.outcome_notice(%{status: :too_late, reason: :answer_delivered})
    at = DateTime.utc_now()
    assert {:error, text, [:follow_up]} = DecisionOutcomes.outcome_notice(%{status: :too_late, reason: :answer_delivered, delivered_at: at})
    assert text == "Already delivered at #{DateTime.to_iso8601(DateTime.truncate(at, :second))}. Send a follow-up message instead."
  end

  test "withdrawn and stale Commands explain recovery without success" do
    for reason <- [:expired, :moot, :resolved, :dismissed] do
      assert {:error, "No longer needed: " <> suffix, []} = DecisionOutcomes.outcome_notice(%{status: :withdrawn, reason: reason})
      assert suffix == Atom.to_string(reason)
      assert DecisionOutcomes.disabled?(%{}, %{outcome: %{status: :withdrawn, reason: reason}})
    end

    assert {:error, "This Command changed. Refresh to see the latest.", [:refresh]} = DecisionOutcomes.outcome_notice(%{status: :stale, current_version: 4})
  end

  test "replacement visibility requires an executor winner without delivery or flight" do
    for {actor, delivered, flight} <- [{:executor, false, false}, {:operator, false, false}, {:executor, true, false}, {:executor, false, true}] do
      decision = %{decision_status: :decided, conflict_summary: %{actor_kind: actor, replaceable: not delivered and not flight, delivered?: delivered, in_flight?: flight}}
      assert DecisionOutcomes.replaceable?(decision) == (actor == :executor and not delivered and not flight)
      assert DecisionOutcomes.disabled?(decision, %{}) == (delivered or flight)
    end
  end

  test "unknown outcomes and unavailable storage render neutral errors, never success" do
    assert DecisionOutcomes.outcome_notice(%{status: :error, reason: :unexpected}) == {:error, "The command was rejected. Canonical state was refreshed.", []}
    assert DecisionOutcomes.outcome_notice(%{status: :unknown}) == {:error, "The command was rejected. Canonical state was refreshed.", []}
    assert DecisionOutcomes.outcome_notice(%{status: :error, reason: :store_unavailable}) == {:error, "Command storage is currently unavailable.", []}
    assert DecisionOutcomes.outcome_notice(%{status: :not_allowed, reason: :human_answer}) == {:error, "You cannot replace this answer.", []}
  end
end
