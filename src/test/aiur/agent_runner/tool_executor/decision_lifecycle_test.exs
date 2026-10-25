defmodule Aiur.AgentRunner.ToolExecutor.DecisionLifecycleTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.Issue

  describe "decision lifecycle events route through Aiur.DecisionStore" do
    test "exact acknowledgement carries trusted ticket/session/invocation context" do
      identifier = "TE-decision-ack-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      parent = self()

      recorder = fn type, payload, opts ->
        send(parent, {:lifecycle_recorded, type, payload, opts})

        {:ok,
         %{
           decision_id: payload["decision_id"],
           version: 3,
           answered_version: payload["expected_version"],
           action_id: payload["action_id"],
           status: :accepted,
           decision_status: type
         }}
      end

      executor =
        ToolExecutor.build(
          issue,
          nil,
          nil,
          %{backend: "codex", thread_id: "thread-ack"},
          decision_lifecycle_recorder: recorder
        )

      response =
        ToolExecutor.execute(
          executor,
          "emit_event",
          %{
            "name" => "decision.acknowledged",
            "message" => "Applying it",
            "payload" => %{
              "decision_id" => "dec_123",
              "action_id" => "act_123",
              "expected_version" => 2,
              "actor" => %{"kind" => "operator", "id" => "attacker"}
            }
          },
          "call-ack-1"
        )

      assert response["success"] == true
      result = Jason.decode!(response["output"])["result"]
      assert result["status"] == "accepted"
      assert result["decision_status"] == "acknowledged"

      assert_receive {:lifecycle_recorded, :acknowledged, payload, opts}, 2_000
      assert payload["detail"] == "Applying it"
      assert opts[:ticket_identifier] == identifier
      assert opts[:actor].kind == :agent
      assert opts[:actor].id == "ticket-agent"
      refute opts[:actor].id =~ "attacker"
      assert opts[:source] == %{agent_id: "codex", session_id: "thread-ack", invocation_id: "call-ack-1"}
    end

    test "exact resolution is reserved while a generic decision slug stays generic" do
      identifier = "TE-decision-resolve-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      parent = self()

      recorder = fn type, payload, _opts ->
        send(parent, {:resolved_through_store, type})

        {:ok,
         %{
           decision_id: payload["decision_id"],
           version: 1,
           answered_version: 1,
           action_id: payload["action_id"],
           status: :duplicate,
           decision_status: :resolved
         }}
      end

      executor = ToolExecutor.build(issue, nil, nil, %{}, decision_lifecycle_recorder: recorder)

      resolution =
        executor.("emit_event", %{
          "name" => "decision.resolved",
          "message" => "Done",
          "payload" => %{"decision_id" => "dec_1", "action_id" => "act_1", "expected_version" => 1}
        })

      assert resolution["success"] == true
      assert_receive {:resolved_through_store, :resolved}, 2_000

      generic = executor.("emit_event", %{"name" => "decision.use-something", "message" => "ordinary"})
      assert generic["success"] == true
      refute_receive {:resolved_through_store, _}, 100
    end

    test "lifecycle recording failure does not fail the tool" do
      issue = %Issue{identifier: "TE-decision-lifecycle-reject"}
      recorder = fn _type, _payload, _opts -> {:error, {:conflict, :wrong_action}} end
      executor = ToolExecutor.build(issue, nil, nil, %{}, decision_lifecycle_recorder: recorder)

      response =
        executor.("emit_event", %{
          "name" => "decision.acknowledged",
          "message" => "Applying",
          "payload" => %{"decision_id" => "dec_1", "action_id" => "act_wrong", "expected_version" => 1}
        })

      assert response["success"]
      assert Jason.decode!(response["output"])["result"]["status"] == "recording_failed"
    end
  end

  describe "subscriber closure" do
    test "missing topic pattern returns failure response" do
      issue = %Issue{id: "gid-te-08", identifier: "TE-08"}
      executor = ToolExecutor.build(issue, nil, nil)

      response = executor.("aiur_subscribe", %{"topic_pattern" => ""})

      assert response["success"] == false
    end
  end
end
