defmodule Aiur.AgentRunner.DecisionLifecycleFailureAlertTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.Issue

  test "recording failure emits a system alert without opening another decision" do
    issue = %Issue{identifier: "TE-decision-lifecycle-reject"}
    parent = self()
    :ok = Aiur.AgentPubSub.subscribe_agent(issue.identifier)

    executor =
      ToolExecutor.build(issue, nil, nil, %{},
        decision_lifecycle_recorder: fn _type, _payload, _opts ->
          {:error, {:conflict, :wrong_action}}
        end,
        decision_requester: fn _payload, _opts -> send(parent, :unexpected_follow_up_decision) end
      )

    response =
      executor.("emit_event", %{
        "name" => "decision.acknowledged",
        "message" => "Applying",
        "payload" => %{
          "decision_id" => "dec_1",
          "action_id" => "act_wrong",
          "expected_version" => 1
        }
      })

    assert response["success"]
    result = Jason.decode!(response["output"])["result"]
    assert result["status"] == "recording_failed"
    assert result["reason"] == "{:conflict, :wrong_action}"

    assert_receive {:alert,
                    %{
                      name: "system.decision_lifecycle.recording_failed",
                      needs_attention: false,
                      severity: "error"
                    }},
                   2_000

    refute_receive :unexpected_follow_up_decision, 100
  end
end
