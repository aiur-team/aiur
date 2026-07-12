defmodule Aiur.AgentRunner.ToolExecutorTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.Events.{Exchange, SubscriptionStore}
  alias Aiur.Issue

  describe "build/3" do
    test "returns a 2-arity closure" do
      issue = %Issue{id: "gid-te-01", identifier: "TE-01"}
      executor = ToolExecutor.build(issue, nil, nil)

      assert is_function(executor, 2)
    end

    test "delegates unknown tools to DynamicTool failure response" do
      issue = %Issue{id: "gid-te-02", identifier: "TE-02"}
      executor = ToolExecutor.build(issue, nil, nil)

      response = executor.("not_a_real_tool", %{})

      assert response["success"] == false
    end
  end

  describe "declare_blocker_for_issue via blocker_declarer closure" do
    test "returns :no_issue_number failure for an issue with nil identifier" do
      issue = %Issue{id: "gid-te-03", identifier: nil}
      executor = ToolExecutor.build(issue, nil, nil)

      response = executor.("aiur_declare_blocker", %{"issue_number" => 5})

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["reason"] =~ "no_issue_number"
    end
  end

  describe "prefix_with_ticket_namespace via event_publisher closure" do
    test "bare names are published under ticket.<id>.agent.<name>" do
      identifier = "TE-prefix-#{System.unique_integer([:positive])}"
      # id: nil so issue_identifier/1 falls back to :identifier for topic namespacing
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil)

      Exchange.subscribe("ticket.#{identifier}.agent.#")

      executor.("emit_event", %{"name" => "progress", "message" => "test"})

      assert_receive {:event, %{topic: "ticket." <> _}}, 2_000
    end

    test "ticket.* names pass through the publisher unchanged" do
      identifier = "TE-prefix2-#{System.unique_integer([:positive])}"
      # id: nil so issue_identifier/1 falls back to :identifier for topic namespacing
      issue = %Issue{identifier: identifier}

      Exchange.subscribe("ticket.#{identifier}.agent.#")

      executor = ToolExecutor.build(issue, nil, nil)
      executor.("emit_event", %{"name" => "progress", "message" => "check"})

      assert_receive {:event, %{topic: topic}}, 2_000
      assert topic == "ticket.#{identifier}.agent.progress"
    end
  end

  describe "emit_agent_event via event_publisher closure" do
    test "publish succeeds and returns a result map" do
      identifier = "TE-emit-#{System.unique_integer([:positive])}"
      issue = %Issue{id: "gid-te-06", identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil)

      response = executor.("emit_event", %{"name" => "blocked", "message" => "waiting"})

      assert response["success"] == true
      result = Jason.decode!(response["output"])
      assert result["ok"] == true
    end

    test "Exchange subscribers receive the event with the namespaced topic" do
      identifier = "TE-recv-#{System.unique_integer([:positive])}"
      # id: nil so issue_identifier/1 falls back to :identifier; no issue_number
      # passed to Publisher so tracked?(nil) = true → passes contamination filter
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil)

      Exchange.subscribe("ticket.#{identifier}.#")

      executor.("emit_event", %{"name" => "unblocked", "message" => "done waiting"})

      assert_receive {:event, event}, 2_000
      assert event.topic =~ "ticket."
      assert event["name"] == "unblocked"
    end

    test "attention events create and resolve a durable decision attention" do
      identifier = "TE-attention-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil)

      assert executor.("emit_event", %{"name" => "attention.scope-question", "message" => "Approve the target?"})["success"] == true
      assert SubscriptionStore.snapshot(identifier).open_attentions == ["scope-question"]

      assert executor.("emit_event", %{"name" => "attention.resolved", "message" => "Approved", "payload" => %{"slug" => "scope-question"}})["success"] == true
      assert SubscriptionStore.snapshot(identifier).open_attentions == []
    end

    test "operator-decision pause requests raise a durable attention" do
      identifier = "TE-decision-pause-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil)

      assert executor.(
               "emit_event",
               %{
                 "name" => "pause.request",
                 "message" => "Should this facade target change?",
                 "payload" => %{"reason" => "operator_decision"}
               }
             )["success"] == true

      assert SubscriptionStore.snapshot(identifier).open_attentions == ["operator-decision"]
      assert executor.("emit_event", %{"name" => "attention.resolved", "message" => "Approved", "payload" => %{"slug" => "operator-decision"}})["success"] == true
    end
  end

  describe "decision.requested routes through Aiur.DecisionStore" do
    test "persists and returns the accepted decision_id/version/status" do
      identifier = "TE-decision-req-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier, title: "Test ticket", url: "https://example.com/#{identifier}"}
      executor = ToolExecutor.build(issue, nil, nil, %{backend: "codex", thread_id: "thread-abc"})

      response =
        executor.("emit_event", %{
          "name" => "decision.requested",
          "message" => "Deploy now?",
          "payload" => %{"blocking" => true}
        })

      assert response["success"] == true
      result = Jason.decode!(response["output"])["result"]
      assert result["status"] == "accepted"
      assert result["version"] == 1
      assert is_binary(result["decision_id"])

      {:ok, decision} = Aiur.DecisionStore.get(result["decision_id"])
      assert decision.question == "Deploy now?"
      assert decision.ticket.identifier == identifier
      assert decision.source.agent_id == "codex"
      assert decision.source.session_id == "thread-abc"
    end

    test "an omitted payload question falls back to the tool message" do
      identifier = "TE-decision-msg-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil)

      executor.("emit_event", %{
        "name" => "decision.requested",
        "message" => "Use the required tool message?",
        "payload" => %{"blocking" => false}
      })

      [decision] = Aiur.DecisionStore.list() |> Enum.filter(&(&1.ticket.identifier == identifier))
      assert decision.question == "Use the required tool message?"
    end

    test "the agent-supplied ticket/source in payload cannot override the trusted issue context" do
      identifier = "TE-decision-trust-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil)

      executor.("emit_event", %{
        "name" => "decision.requested",
        "message" => "Q?",
        "payload" => %{"blocking" => true, "ticket" => %{"identifier" => "attacker"}}
      })

      [decision] = Aiur.DecisionStore.list() |> Enum.filter(&(&1.ticket.identifier == identifier))
      assert decision.ticket.identifier == identifier
    end

    test "a repeat with the same source_id is deduplicated, not re-accepted" do
      identifier = "TE-decision-dedup-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil)
      payload = %{"blocking" => true, "source_id" => "retry-key"}

      first = executor.("emit_event", %{"name" => "decision.requested", "message" => "Q?", "payload" => payload})
      second = executor.("emit_event", %{"name" => "decision.requested", "message" => "Q?", "payload" => payload})

      assert Jason.decode!(first["output"])["result"]["status"] == "accepted"
      assert Jason.decode!(second["output"])["result"]["status"] == "duplicate"
    end

    test "an invalid request fails without publishing a duplicate Exchange event" do
      identifier = "TE-decision-invalid-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil)

      Exchange.subscribe("ticket.#{identifier}.agent.decision.requested")

      response = executor.("emit_event", %{"name" => "decision.requested", "message" => "Q?", "payload" => %{}})

      assert response["success"] == false
      refute_receive {:event, _}, 200
    end

    test "an issue with no identifier fails closed" do
      issue = %Issue{id: nil, identifier: nil}
      executor = ToolExecutor.build(issue, nil, nil)

      response = executor.("emit_event", %{"name" => "decision.requested", "message" => "Q?", "payload" => %{"blocking" => true}})

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["reason"] =~ "no_issue_identifier"
    end

    test "a generic event name that only collides with the decision.requested topic suffix fails cleanly, not with a crash" do
      # "custom.decision.requested" is allowlisted by the emit_event tool's
      # generic `custom.<slug>` pattern and does NOT match this module's
      # literal "decision.requested" special case, so it takes the generic
      # Publisher.publish/3 path — which now rejects any topic ending in
      # ".decision.requested" (Aiur.Events.Publisher's decision-durability
      # guard). That must surface as a normal tool failure, not an unhandled
      # CaseClauseError.
      identifier = "TE-decision-collision-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil)

      response =
        executor.("emit_event", %{"name" => "custom.decision.requested", "message" => "Q?", "payload" => %{}})

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["reason"] =~ "decision_requires_durable_publish"
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
