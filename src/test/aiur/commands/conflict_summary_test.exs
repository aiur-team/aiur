defmodule Aiur.Commands.ConflictSummaryTest do
  use ExUnit.Case, async: true

  alias Aiur.Commands.ConflictSummary
  alias Aiur.{DecisionAnswer, DecisionRevision, DecisionValidation}

  @now ~U[2026-10-25 10:00:00Z]

  test "an unanswered Command has no winner summary" do
    assert ConflictSummary.for(decision(), %{kind: :executor}) == nil
  end

  test "option answers expose actor, surface, acceptance time and delivery state" do
    decision = answered(:operator, %{selected_option_id: "ship"})
    answer = %{decision.answer | actor: %{kind: :operator, id: "winner", source: :dashboard_session}}
    decision = %{decision | answer: answer, delivery_status: :queued}

    assert ConflictSummary.for(decision, %{kind: :executor}) == %{
             actor_kind: :operator,
             actor_id: "winner",
             actor_source: :dashboard_session,
             summary: "Ship it",
             accepted_at: @now,
             delivery_status: :queued,
             delivered?: false,
             in_flight?: false,
             replaceable: false
           }
  end

  test "custom answers are limited to 120 characters and old actors default to rpc" do
    decision = answered(:executor, %{custom_response: String.duplicate("é", 121)})
    summary = ConflictSummary.for(decision, %{kind: :executor})
    assert summary.summary == String.duplicate("é", 120)
    assert summary.actor_source == :rpc
    assert summary.replaceable
  end

  test "relay cannot replace a direct winner while operator can replace a relayed winner" do
    refute ConflictSummary.for(answered(:operator), %{kind: :operator_relayed}).replaceable
    assert ConflictSummary.for(answered(:operator_relayed), %{kind: :operator}).replaceable
    assert ConflictSummary.for(answered(:operator_relayed), %{kind: :operator_relayed}).replaceable
  end

  test "the active revision supplies the winner" do
    decision = answered(:executor)
    replacement = %{decision.answer | actor: %{kind: :operator, id: "reviser"}, custom_response: "Revised answer"}

    revision =
      struct!(DecisionRevision, %{
        decision_id: decision.decision_id,
        decision_version: 1,
        sequence: 1,
        action_id: "revision",
        prior_action_id: decision.answer.action_id,
        answer: replacement,
        content_hash: "revision-hash",
        reason: "Correct it",
        recorded_at: @now
      })

    summary = ConflictSummary.for(%{decision | revisions: [revision]}, %{kind: :executor})
    assert summary.actor_kind == :operator
    assert summary.actor_id == "reviser"
    assert summary.summary == "Revised answer"
    refute summary.replaceable
  end

  test "delivered and in-flight answers cannot be replaced even by an operator" do
    decision = answered(:executor)
    attempt = %{handed_off_at: @now, delivered_at: nil, failed_at: nil, restored_at: nil}
    in_flight = ConflictSummary.for(%{decision | dispatch_attempts: [attempt]}, %{kind: :operator})
    assert in_flight.in_flight?
    refute in_flight.delivered?
    refute in_flight.replaceable

    delivered = ConflictSummary.for(%{decision | dispatch_attempts: [%{attempt | delivered_at: @now}]}, %{kind: :operator})
    assert delivered.delivered?
    refute delivered.in_flight?
    refute delivered.replaceable
  end

  defp decision do
    {:ok, decision} =
      DecisionValidation.normalize(
        %{"question" => "Ship it?", "blocking" => true, "options" => [%{"id" => "ship", "label" => "Ship it"}]},
        ticket: %{identifier: "6393", title: "Precedence", url: nil},
        source: %{agent_id: "a", session_id: "s"},
        now: @now
      )

    decision
  end

  defp answered(kind, fields \\ %{}) do
    decision = decision()

    answer =
      struct!(
        DecisionAnswer,
        Map.merge(
          %{
            action_id: "answer",
            decision_id: decision.decision_id,
            decision_version: 1,
            idempotency_key: "answer",
            actor: %{kind: kind, id: "winner"},
            accepted_at: @now,
            content_hash: "hash",
            custom_response: "Answer"
          },
          fields
        )
      )

    %{decision | answer: answer, active_action_id: answer.action_id, decision_status: :decided}
  end
end
