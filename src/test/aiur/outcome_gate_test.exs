defmodule Aiur.OutcomeGateTest do
  use ExUnit.Case, async: true

  alias Aiur.Commands.OutcomeGate

  test "creator review handoff requires an open actionable creator Command" do
    assert {:error, :missing_actionable_creator_command} = OutcomeGate.validate_handoff(["creator-facing"], "42", [])

    assert :ok =
             OutcomeGate.validate_handoff(
               ["creator-facing"],
               "42",
               [command("42", :open, :with_human, :creator)]
             )

    assert {:error, :missing_actionable_creator_command} =
             OutcomeGate.validate_handoff(
               ["creator-facing"],
               "42",
               [command("42", :resolved, :with_human, :creator)]
             )
  end

  test "engineering-only handoff requires an open Executor-only Command" do
    assert {:error, :missing_executor_command} = OutcomeGate.validate_handoff(["engineering-only"], "42", [])

    assert :ok =
             OutcomeGate.validate_handoff(
               ["engineering-only"],
               "42",
               [command("42", :open, :with_executor, :executor)]
             )

    assert {:error, :missing_executor_command} =
             OutcomeGate.validate_handoff(
               ["engineering-only"],
               "42",
               [command("42", :open, :with_human, :creator)]
             )
  end

  test "creator outcome accepts human or Executor confirmation when reason is recorded" do
    for actor <- [:operator, :executor] do
      decisions = [confirmed_command("42", actor, "The production result passed.")]
      assert OutcomeGate.outcome_confirmed?(["creator-facing"], "42", decisions)
      assert OutcomeGate.merge_target(["creator-facing"], "42", decisions) == "done"
    end
  end

  test "creator outcome stays incomplete without a reason, authorized actor, or confirmed status" do
    incomplete = [
      confirmed_command("42", :operator, nil),
      confirmed_command("42", :agent, "Looks good."),
      command("42", :open, :with_human, :creator)
    ]

    refute OutcomeGate.outcome_confirmed?(["creator-facing"], "42", incomplete)
    assert OutcomeGate.merge_target(["creator-facing"], "42", incomplete) == "human-review"
  end

  test "pending post-deploy checks hold merge closure until marked complete" do
    pending = [%{"ticket" => "42", "done_at" => nil}]
    complete = [%{"ticket" => "42", "done_at" => "2026-11-27T12:00:00Z"}]

    assert OutcomeGate.merge_target([], "42", [], pending) == "human-review"
    assert OutcomeGate.merge_target([], "42", [], complete) == "done"
  end

  test "epic closure waits for closed and triaged children and follow-ups" do
    assert OutcomeGate.related_work_complete?([%{state: "closed", triaged?: true}], [%{state: "closed", triaged?: true}])
    refute OutcomeGate.related_work_complete?([%{state: "open"}], [])
    refute OutcomeGate.related_work_complete?([%{state: "closed"}], [%{state: "closed", triaged?: false}])
    refute OutcomeGate.related_work_complete?([%{state: "closed"}], [%{state: "open", triaged?: true}])
    refute OutcomeGate.related_work_complete?([%{state: "closed"}], [%{state: "open", triaged?: false}])
  end

  defp command(identifier, status, route_state, audience) do
    %{
      ticket: %{identifier: identifier},
      decision_status: status,
      route_state: route_state,
      audience: audience,
      blocking: true
    }
  end

  defp confirmed_command(identifier, actor, reason) do
    %{
      ticket: %{identifier: identifier},
      decision_status: :decided,
      answer: %{actor: %{kind: actor}, rationale: reason}
    }
  end
end
