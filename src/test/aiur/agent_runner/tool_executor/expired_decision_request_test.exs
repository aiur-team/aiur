defmodule Aiur.AgentRunner.ToolExecutor.ExpiredDecisionRequestTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.{DecisionStore, Issue}

  test "an identical expired blocking request retry reopens the blocker" do
    identifier = "TE-decision-expired-#{System.unique_integer([:positive])}"
    issue = %Issue{identifier: identifier, title: "Test ticket"}
    executor = ToolExecutor.build(issue, nil, nil, %{backend: "codex", thread_id: "thread-expired"})
    payload = %{"blocking" => true}

    first =
      ToolExecutor.execute(
        executor,
        "emit_event",
        %{"name" => "decision.requested", "message" => "Deploy now?", "payload" => payload},
        "call-1"
      )

    assert first["success"] == true
    decision_id = Jason.decode!(first["output"])["result"]["decision_id"]

    assert {:ok, decision} = DecisionStore.get(decision_id)

    assert {:ok, %{status: :accepted, decision: %{decision_status: :expired}}} =
             DecisionStore.expire(decision_id, "agent_not_running", now: DateTime.add(decision.created_at, 600, :second))

    retry =
      ToolExecutor.execute(
        executor,
        "emit_event",
        %{"name" => "decision.requested", "message" => "Deploy now?", "payload" => payload},
        "call-2"
      )

    assert retry["success"] == true
    result = Jason.decode!(retry["output"])["result"]
    assert result["status"] == "accepted"
    refute result["decision_id"] == decision_id
    assert result["version"] == 1

    assert {:ok, old} = DecisionStore.get(decision_id)
    assert old.decision_status == :moot
    assert {:ok, replacement} = DecisionStore.get(result["decision_id"])
    assert replacement.decision_status == :open

    {:ok, blocked_ids} = DecisionStore.blocked_ticket_ids()
    assert identifier in MapSet.to_list(blocked_ids)
  end
end
