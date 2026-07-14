defmodule Aiur.AgentRunner.ToolExecutorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.AgentRunner.{SessionLifecycle, ToolExecutor}
  alias Aiur.{Boot, DecisionStore, Issue, TrackerIdentity}
  alias Aiur.Events.{Exchange, SubscriptionStore}

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

    test "invocation context preserves normal validation for malformed arguments" do
      issue = %Issue{id: "gid-te-invalid", identifier: "TE-invalid"}
      executor = ToolExecutor.build(issue, nil, nil)

      response = ToolExecutor.execute(executor, "emit_event", :invalid, "call-invalid")

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "expects an object"
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

    test "progress events carry the trusted issue identity and safe invocation provenance" do
      identifier = "TE-observation-#{System.unique_integer([:positive])}"

      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"node_id" => "I_kwDOObservation", "number" => 42},
          {"owner", "repo"},
          {"owner", "repo"}
        )

      # Keep :id nil so this focused producer test is independent of the
      # shared Publisher tracked-set fixture; the BO-004 identity is explicit.
      issue = %{identifier: identifier, tracker_identity: identity}
      executor = ToolExecutor.build(issue, nil, nil, %{thread_id: "session-observation"}, attempt_id: 1)
      :ok = Exchange.subscribe("ticket.#{identifier}.agent.progress")

      ToolExecutor.execute(executor, "emit_event", %{"name" => "progress", "message" => "private", "payload" => %{"percent" => 50}}, "tool-observation")

      assert_receive {:event, %{ticket_observation: observation}}, 2_000
      assert observation.status == :joinable
      assert observation.tracker_identity == identity
      assert observation.attributes == %{percent: 50}
      assert observation.provenance.attempt == 1
      assert observation.provenance.session_id == "session-observation"
      assert observation.provenance.source_event_id == "tool-observation"
      refute Jason.encode!(observation) =~ "private"
    end

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

      assert_receive {:projected_attention, "scope-question", "Approve the target?", opts}
      assert opts[:source].session_id == "thread-1"
      assert opts[:source].event_id == "call-attention"
      assert_receive {:event, %{topic: "ticket." <> _}}

      result = Jason.decode!(response["output"])["result"]
      assert result["decision_id"] == "dec_order"
      assert result["version"] == 1
      assert result["status"] == "accepted"
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

      log =
        capture_log(fn ->
          response =
            executor.("emit_event", %{
              "name" => "attention.scope-question",
              "message" => question
            })

          assert response["success"] == true
        end)

      expected_topic = "ticket.#{identifier}.agent.attention.scope-question"
      assert_receive {:event, %{topic: ^expected_topic}}, 200
      assert log =~ "phase=decision_attention_projection_failed"
      assert log =~ "question, :too_long"
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
      assert_receive {:event, %{topic: ^expected_topic}}, 200
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
      refute_receive :unexpected_attention_projection
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

      log =
        capture_log(fn ->
          response =
            executor.("emit_event", %{
              "name" => "attention.resolved",
              "message" => "Resolved",
              "payload" => %{"slug" => "scope-question"}
            })

          assert response["success"] == true
          assert Process.alive?(self())
        end)

      expected_topic = "ticket.#{identifier}.agent.attention.resolved"
      assert_receive {:event, %{topic: ^expected_topic}}, 200
      assert log =~ "phase=decision_attention_resolution_failed"
      assert log =~ "timeout"
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

    test "captures only trusted runtime/session provenance" do
      identifier = "TE-decision-provenance-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}

      executor =
        ToolExecutor.build(issue, nil, nil, %{
          backend: "codex",
          model: "gpt-5.6-terra",
          thread_id: "thread-abc",
          attempt_id: "attempt-123",
          account: "operator@example.com",
          raw_session: %{prompt: "do not persist", credential: "secret"},
          capability_url: "https://capability.example/token"
        })

      executor.("emit_event", %{
        "name" => "decision.requested",
        "message" => "Use the trusted session?",
        "payload" => %{
          "blocking" => true,
          "provenance" => %{
            "backend" => "forged",
            "requested_model" => "forged-model",
            "session_id" => "forged-session",
            "account" => "operator@example.com",
            "raw_session" => %{"prompt" => "do not persist"},
            "capability_url" => "https://capability.example/token"
          }
        }
      })

      [decision] = Aiur.DecisionStore.list() |> Enum.filter(&(&1.ticket.identifier == identifier))
      assert decision.provenance.agent_family == "codex"
      assert decision.provenance.backend == "codex"
      assert decision.provenance.requested_model == "gpt-5.6-terra"
      assert decision.provenance.session_id == "thread-abc"
      assert decision.provenance.attempt_id == "attempt-123"
      assert decision.provenance.resolved_model == nil

      assert Aiur.DecisionProvenance.to_json_safe(decision.provenance)
             |> Map.keys()
             |> Enum.sort() ==
               [
                 "agent_family",
                 "attempt_id",
                 "backend",
                 "captured_at",
                 "requested_model",
                 "schema_version",
                 "session_id",
                 "source"
               ]
    end

    test "leaves provenance unknown when runner context is unavailable" do
      identifier = "TE-decision-provenance-unknown-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil, %{})

      executor.("emit_event", %{
        "name" => "decision.requested",
        "message" => "Accept without runtime context?",
        "payload" => %{"blocking" => true}
      })

      [decision] = Aiur.DecisionStore.list() |> Enum.filter(&(&1.ticket.identifier == identifier))
      assert decision.provenance == nil
    end

    test "captures the actual fallback backend rather than the failed transport" do
      identifier = "TE-decision-provenance-fallback-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}

      start_fun = fn _workspace, opts ->
        case Keyword.fetch!(opts, :backend) do
          "claude-repl" -> {:error, :repl_not_ready}
          "claude" -> {:ok, %{model: "sonnet", thread_id: "thread-fallback"}}
        end
      end

      assert {:ok, session} =
               SessionLifecycle.start_agent_session(
                 "/ws",
                 [backend: "claude-repl", model: "sonnet", attempt_id: "attempt-fallback"],
                 start_fun
               )

      executor = ToolExecutor.build(issue, nil, nil, session)

      executor.("emit_event", %{
        "name" => "decision.requested",
        "message" => "Use the active backend?",
        "payload" => %{"blocking" => true}
      })

      [decision] = Aiur.DecisionStore.list() |> Enum.filter(&(&1.ticket.identifier == identifier))
      assert decision.provenance.agent_family == "claude"
      assert decision.provenance.backend == "claude"
      assert decision.provenance.requested_model == "sonnet"
      assert decision.provenance.attempt_id == "attempt-fallback"
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

    test "the trusted session and tool-call id deduplicate retries without agent source_id" do
      identifier = "TE-decision-trusted-dedup-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil, %{thread_id: "thread-abc"})

      arguments = %{
        "name" => "decision.requested",
        "message" => "Q?",
        "payload" => %{"blocking" => true, "source_id" => "agent-controlled"}
      }

      first = ToolExecutor.execute(executor, "emit_event", arguments, "call-1")
      retry = ToolExecutor.execute(executor, "emit_event", arguments, "call-1")
      distinct_call = ToolExecutor.execute(executor, "emit_event", arguments, "call-2")

      first_result = Jason.decode!(first["output"])["result"]
      retry_result = Jason.decode!(retry["output"])["result"]
      distinct_result = Jason.decode!(distinct_call["output"])["result"]

      assert first_result["status"] == "accepted"
      assert retry_result["status"] == "duplicate"
      assert retry_result["decision_id"] == first_result["decision_id"]
      assert distinct_result["status"] == "accepted"
      refute distinct_result["decision_id"] == first_result["decision_id"]
    end

    test "trusted identity overwrites atom-keyed agent source_id values" do
      identifier = "TE-decision-atom-source-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil, %{thread_id: "thread-abc"})

      arguments = fn source_id ->
        %{
          "name" => "decision.requested",
          "message" => "Q?",
          "payload" => %{blocking: true, source_id: source_id}
        }
      end

      first = ToolExecutor.execute(executor, "emit_event", arguments.("agent-one"), "call-atom")
      retry = ToolExecutor.execute(executor, "emit_event", arguments.("agent-two"), "call-atom")

      first_result = Jason.decode!(first["output"])["result"]
      retry_result = Jason.decode!(retry["output"])["result"]

      assert first_result["status"] == "accepted"
      assert retry_result["status"] == "duplicate"
      assert retry_result["decision_id"] == first_result["decision_id"]
    end

    test "a structured request enriches its legacy attention instead of duplicating it" do
      identifier = "TE-decision-attention-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier, title: "Adapter ticket"}
      executor = ToolExecutor.build(issue, nil, nil, %{backend: "codex", thread_id: "thread-adapter"})

      legacy =
        ToolExecutor.execute(
          executor,
          "emit_event",
          %{
            "name" => "attention.scope-question",
            "message" => "Which scope owns this?"
          },
          "call-legacy"
        )

      legacy_result = Jason.decode!(legacy["output"])["result"]
      assert legacy_result["version"] == 1

      structured_arguments = %{
        "name" => "decision.requested",
        "message" => "Which scope owns this?",
        "payload" => %{
          "attention_slug" => "scope-question",
          "decision_id" => "dec_attacker",
          "source_id" => "attacker-controlled",
          "legacy_attention" => %{
            "slug" => "other",
            "topic" => "ticket.attacker.agent.attention.other"
          },
          "blocking" => true,
          "kind" => "architecture",
          "context" => %{"short_summary" => "Two owners are viable."},
          "options" => [%{"id" => "runtime", "label" => "Runtime"}]
        }
      }

      enriched = ToolExecutor.execute(executor, "emit_event", structured_arguments, "call-enrich")
      retry = ToolExecutor.execute(executor, "emit_event", structured_arguments, "call-enrich")

      enriched_result = Jason.decode!(enriched["output"])["result"]
      retry_result = Jason.decode!(retry["output"])["result"]

      assert enriched_result["decision_id"] == legacy_result["decision_id"]
      assert enriched_result["version"] == 2
      assert enriched_result["status"] == "accepted"
      assert retry_result["decision_id"] == legacy_result["decision_id"]
      assert retry_result["version"] == 2
      assert retry_result["status"] == "duplicate"

      {:ok, history} = DecisionStore.history(legacy_result["decision_id"])
      assert Enum.map(history, & &1.version) == [1, 2]
      assert List.last(history).options != []

      assert [current] =
               DecisionStore.list()
               |> Enum.filter(&(&1.ticket.identifier == identifier))

      assert current.decision_id == legacy_result["decision_id"]
      assert current.source_id == "legacy_attention:scope-question"
      assert current.legacy_attention.topic == "ticket.#{identifier}.agent.attention.scope-question"
    end

    test "an unknown attention slug cannot create a correlated structured Decision" do
      identifier = "TE-decision-attention-missing-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil, %{thread_id: "thread-adapter"})

      response =
        ToolExecutor.execute(
          executor,
          "emit_event",
          %{
            "name" => "decision.requested",
            "message" => "Which scope owns this?",
            "payload" => %{"attention_slug" => "missing", "blocking" => true}
          },
          "call-missing"
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["reason"] =~ "not_found"

      refute Enum.any?(DecisionStore.list(), &(&1.ticket.identifier == identifier))
    end

    test "a non-scalar protocol call id cannot crash decision execution" do
      identifier = "TE-decision-call-shape-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil, %{thread_id: "thread-abc"})

      response =
        ToolExecutor.execute(
          executor,
          "emit_event",
          %{
            "name" => "decision.requested",
            "message" => "Q?",
            "payload" => %{"blocking" => true}
          },
          %{"unexpected" => "shape"}
        )

      assert response["success"] == true
      assert Jason.decode!(response["output"])["result"]["status"] == "accepted"
    end

    test "an invalid request fails without publishing a duplicate Exchange event" do
      identifier = "TE-decision-invalid-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil)

      Exchange.subscribe("ticket.#{identifier}.agent.decision.requested")

      response = executor.("emit_event", %{"name" => "decision.requested", "message" => "Q?", "payload" => %{}})

      assert response["success"] == false
      error = Jason.decode!(response["output"])["error"]
      assert error["message"] == "Decision request was rejected by the durable DecisionStore."
      assert error["reason"] =~ "blocking"
      refute_receive {:event, _}, 200
    end

    test "an issue with no identifier fails closed" do
      issue = %Issue{id: nil, identifier: nil}
      executor = ToolExecutor.build(issue, nil, nil)

      response = executor.("emit_event", %{"name" => "decision.requested", "message" => "Q?", "payload" => %{"blocking" => true}})

      assert response["success"] == false
      error = Jason.decode!(response["output"])["error"]
      assert error["message"] == "Decision requests require a ticket identifier."
      assert error["reason"] == "no_issue_identifier"
    end

    test "generic lookalikes of reserved Decision names fail cleanly, not with a crash" do
      identifier = "TE-decision-collision-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil)

      for name <- [
            "custom.decision.requested",
            "custom.decision.acknowledged",
            "custom.decision.resolved"
          ] do
        response = executor.("emit_event", %{"name" => name, "message" => "Q?", "payload" => %{}})

        assert response["success"] == false
        assert Jason.decode!(response["output"])["error"]["reason"] =~ "decision_requires_durable_publish"
      end
    end

    test "a DecisionStore call timeout becomes a tool failure instead of exiting the agent turn" do
      identifier = "TE-decision-timeout-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      blocked_store = spawn(fn -> receive do: (:stop -> :ok) end)
      on_exit(fn -> send(blocked_store, :stop) end)

      decision_requester = fn payload, opts ->
        Aiur.DecisionStore.request(payload, opts, blocked_store, 10)
      end

      executor =
        ToolExecutor.build(issue, nil, nil, %{}, decision_requester: decision_requester)

      response =
        executor.("emit_event", %{
          "name" => "decision.requested",
          "message" => "Q?",
          "payload" => %{"blocking" => true}
        })

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["reason"] =~ "timeout"
      assert Process.alive?(self())
    end
  end

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

      assert_receive {:lifecycle_recorded, :acknowledged, payload, opts}
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
      assert_receive {:resolved_through_store, :resolved}

      generic = executor.("emit_event", %{"name" => "decision.use-something", "message" => "ordinary"})
      assert generic["success"] == true
      refute_receive {:resolved_through_store, _}
    end

    test "lifecycle rejection is returned as a normal tool failure" do
      issue = %Issue{identifier: "TE-decision-lifecycle-reject"}
      recorder = fn _type, _payload, _opts -> {:error, {:conflict, :wrong_action}} end
      executor = ToolExecutor.build(issue, nil, nil, %{}, decision_lifecycle_recorder: recorder)

      response =
        executor.("emit_event", %{
          "name" => "decision.acknowledged",
          "message" => "Applying",
          "payload" => %{"decision_id" => "dec_1", "action_id" => "act_wrong", "expected_version" => 1}
        })

      assert response["success"] == false
      error = Jason.decode!(response["output"])["error"]
      assert error["message"] =~ "lifecycle"
      assert error["reason"] =~ "wrong_action"
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
