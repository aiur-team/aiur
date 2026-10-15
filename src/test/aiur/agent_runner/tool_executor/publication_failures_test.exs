defmodule Aiur.AgentRunner.ToolExecutor.PublicationFailuresTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.{Boot, Issue, TrackerIdentity}
  alias Aiur.Events.{Exchange, SubscriptionStore}

  describe "emit_agent_event via event_publisher closure" do
    test "progress check-ins and phase updates preserve retry provenance without changing identity" do
      identifier = "TE-observation-retry-#{System.unique_integer([:positive])}"

      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"node_id" => "I_kwDOObservationRetry", "number" => 42},
          {"owner", "repo"},
          {"owner", "repo"}
        )

      issue = %{identifier: identifier, tracker_identity: identity}

      publish = fn name, session_id, attempt, invocation_id ->
        topic = "ticket.#{identifier}.agent.#{name}"
        executor = ToolExecutor.build(issue, nil, nil, %{thread_id: session_id}, attempt_id: attempt)
        :ok = Exchange.subscribe(topic)

        ToolExecutor.execute(
          executor,
          "emit_event",
          %{"name" => name, "message" => "private", "payload" => %{"percent" => 60}},
          invocation_id
        )

        assert_receive {:event, %{ticket_observation: observation}}, 2_000
        assert observation.status == :joinable
        assert observation.attributes == %{percent: 60}
        observation
      end

      first = publish.("progress.checkin", "session-first", 1, "tool-first")
      retry = publish.("progress.phase", "session-retry", 2, "tool-retry")

      assert first.tracker_identity == retry.tracker_identity
      assert first.provenance.attempt == 1
      assert retry.provenance.attempt == 2
      assert first.provenance.session_id == "session-first"
      assert retry.provenance.session_id == "session-retry"
      assert first.provenance.source_event_id == "tool-first"
      assert retry.provenance.source_event_id == "tool-retry"
    end

    test "producer observations retain identity across a Boot restart" do
      identifier = "TE-observation-restart-#{System.unique_integer([:positive])}"

      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"node_id" => "I_kwDOObservationRestart", "number" => 42},
          {"owner", "repo"},
          {"owner", "repo"}
        )

      topic = "ticket.#{identifier}.agent.progress.checkin"
      issue = %{identifier: identifier, tracker_identity: identity}
      :ok = Exchange.subscribe(topic)

      publish = fn session_id, attempt, invocation_id ->
        executor = ToolExecutor.build(issue, nil, nil, %{thread_id: session_id}, attempt_id: attempt)

        ToolExecutor.execute(
          executor,
          "emit_event",
          %{"name" => "progress.checkin", "message" => "private", "payload" => %{"percent" => 60}},
          invocation_id
        )

        assert_receive {:event, %{ticket_observation: observation}}, 2_000
        observation
      end

      first = publish.("session-before-restart", 1, "tool-before-restart")
      assert :ok = Boot.remark()
      restarted = publish.("session-after-restart", 2, "tool-after-restart")

      assert first.tracker_identity == restarted.tracker_identity
      refute first.provenance.run_id == restarted.provenance.run_id
      assert first.provenance.attempt == 1
      assert restarted.provenance.attempt == 2
      assert first.provenance.session_id == "session-before-restart"
      assert restarted.provenance.session_id == "session-after-restart"
    end

    test "alerts attach typed stage and safe evidence observations with retry provenance" do
      identifier = "TE-observation-alert-#{System.unique_integer([:positive])}"

      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"node_id" => "I_kwDOObservationAlert", "number" => 42},
          {"owner", "repo"},
          {"owner", "repo"}
        )

      # Alerts pass an Issue struct's identifier through the Publisher's
      # contamination filter. A map keeps this focused adapter test independent
      # of the shared tracked-set fixture while retaining trusted identity.
      issue = %{identifier: identifier, tracker_identity: identity}
      executor = ToolExecutor.build(issue, nil, nil, %{thread_id: "session-alert"}, attempt_id: 3)

      for {name, expected_attributes} <- [
            {"phase.review.end", %{stage: :review, transition: :end}},
            {"evidence.safe", %{needs_attention: true, severity: "warning"}}
          ] do
        topic = "ticket.#{identifier}.agent.#{name}"
        :ok = Exchange.subscribe(topic)

        assert ToolExecutor.execute(
                 executor,
                 "emit_alert",
                 %{
                   "name" => name,
                   "message" => "private evidence",
                   "reason" => "private reason",
                   "needs_attention" => true,
                   "severity" => "warning"
                 },
                 "alert-#{name}"
               )["success"] == true

        assert_receive {:event, %{ticket_observation: observation}}, 2_000
        assert observation.status == :joinable
        assert observation.attributes == expected_attributes
        assert observation.provenance.attempt == 3
        assert observation.provenance.session_id == "session-alert"
        assert observation.provenance.source_event_id == "alert-#{name}"
        refute Jason.encode!(observation) =~ "private"
      end
    end

    test "event and alert producers leave missing trusted identity unattributed" do
      identifier = "TE-observation-unattributed-#{System.unique_integer([:positive])}"
      issue = %{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil, %{thread_id: "session-unattributed"}, attempt_id: 1)

      :ok = Exchange.subscribe("ticket.#{identifier}.agent.progress.checkin")
      ToolExecutor.execute(executor, "emit_event", %{"name" => "progress.checkin", "message" => "private", "payload" => %{"percent" => 50}}, "event-unattributed")
      assert_receive {:event, %{ticket_observation: %{status: :unattributed}}}, 2_000

      :ok = Exchange.subscribe("ticket.#{identifier}.agent.evidence.safe")

      assert ToolExecutor.execute(
               executor,
               "emit_alert",
               %{
                 "name" => "evidence.safe",
                 "message" => "private",
                 "reason" => "private",
                 "needs_attention" => false
               },
               "alert-unattributed"
             )["success"] == true

      assert_receive {:event, %{ticket_observation: %{status: :unattributed}}}, 2_000
    end

    test "attention events create and resolve a durable decision attention" do
      identifier = "TE-attention-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil)

      assert executor.("emit_event", %{"name" => "attention.scope-question", "message" => "Approve the target?"})["success"] == true
      assert :drained = Aiur.CoordinationTasks.run({:ticket, identifier}, fn -> :drained end)
      assert open_attentions(identifier) == ["scope-question"]

      assert executor.("emit_event", %{"name" => "attention.resolved", "message" => "Approved", "payload" => %{"slug" => "scope-question"}})["success"] == true
      assert :drained = Aiur.CoordinationTasks.run({:ticket, identifier}, fn -> :drained end)
      assert open_attentions(identifier) == []
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

      assert :drained = Aiur.CoordinationTasks.run({:ticket, identifier}, fn -> :drained end)
      assert open_attentions(identifier) == ["operator-decision"]
      assert executor.("emit_event", %{"name" => "attention.resolved", "message" => "Approved", "payload" => %{"slug" => "operator-decision"}})["success"] == true
    end

    test "legacy attention persistence precedes generic event publication and returns Decision correlation" do
      identifier = "TE-attention-order-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      test_pid = self()

      attention_opener = fn _issue, _workspace, _worker_host, slug, question, opts ->
        send(test_pid, {:projected_attention, slug, question, opts})
        {:ok, %{status: :accepted, decision: %{decision_id: "dec_order", version: 1}}}
      end

      executor = ToolExecutor.build(issue, nil, nil, %{backend: "codex", thread_id: "thread-1"}, attention_opener: attention_opener)
      :ok = Exchange.subscribe("ticket.#{identifier}.agent.attention.scope-question")

      response =
        ToolExecutor.execute(
          executor,
          "emit_event",
          %{"name" => "attention.scope-question", "message" => "Approve the target?"},
          "call-attention"
        )

      assert_receive {:projected_attention, "scope-question", "Approve the target?", opts}, 2_000
      assert opts[:source].session_id == "thread-1"
      assert opts[:source].event_id == "call-attention"
      assert_receive {:event, %{topic: "ticket." <> _}}, 2_000

      result = Jason.decode!(response["output"])["result"]
      assert result["status"] == "pending"
    end

    test "an overlong attention still publishes its generic operator signal when projection fails" do
      identifier = "TE-attention-fail-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      question = String.duplicate("x", 2_001)

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          attention_opener: fn _issue, _workspace, _worker_host, _slug, ^question, _opts ->
            {:error, {:decision_invalid, {:question, :too_long}}}
          end
        )

      :ok = Exchange.subscribe("ticket.#{identifier}.agent.attention.scope-question")

      response =
        executor.("emit_event", %{
          "name" => "attention.scope-question",
          "message" => question
        })

      assert response["success"] == true

      expected_topic = "ticket.#{identifier}.agent.attention.scope-question"
      assert_receive {:event, %{topic: ^expected_topic}}, 2_000
    end

    test "a control-character operator-decision block still publishes when projection fails" do
      identifier = "TE-blocked-fail-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      question = "Approve this?\u0007"

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          attention_opener: fn _issue, _workspace, _worker_host, "operator-decision", ^question, _opts ->
            {:error, {:decision_invalid, {:question, :unsafe_characters}}}
          end
        )

      :ok = Exchange.subscribe("ticket.#{identifier}.agent.blocked")

      response =
        executor.("emit_event", %{
          "name" => "blocked",
          "message" => "Waiting for a decision",
          "payload" => %{"reason" => "operator_decision", "question" => question}
        })

      assert response["success"] == true
      expected_topic = "ticket.#{identifier}.agent.blocked"
      assert_receive {:event, %{topic: ^expected_topic}}, 2_000
    end

    test "ordinary blocked events do not enter the legacy Decision adapter" do
      identifier = "TE-blocked-no-decision-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      test_pid = self()

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          attention_opener: fn _issue, _workspace, _worker_host, _slug, _question, _opts ->
            send(test_pid, :unexpected_attention_projection)
            {:error, :unexpected}
          end
        )

      assert executor.("emit_event", %{"name" => "blocked", "message" => "Waiting for a dependency"})["success"] == true
      refute_receive :unexpected_attention_projection, 100
    end

    test "a resolution timeout cannot suppress the published resolved event or exit the caller" do
      identifier = "TE-resolution-timeout-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      blocked_registry = spawn(fn -> receive do: (:stop -> :ok) end)
      on_exit(fn -> send(blocked_registry, :stop) end)

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          attention_resolver: fn _issue, _slug ->
            GenServer.call(blocked_registry, :resolve, 10)
          end
        )

      :ok = Exchange.subscribe("ticket.#{identifier}.agent.attention.resolved")

      response =
        executor.("emit_event", %{
          "name" => "attention.resolved",
          "message" => "Resolved",
          "payload" => %{"slug" => "scope-question"}
        })

      assert response["success"] == true
      assert Process.alive?(self())

      expected_topic = "ticket.#{identifier}.agent.attention.resolved"
      assert_receive {:event, %{topic: ^expected_topic}}, 2_000
    end
  end

  defp open_attentions(identifier) do
    case SubscriptionStore.snapshot(identifier) do
      :not_found -> []
      snapshot -> snapshot.open_attentions
    end
  end
end
