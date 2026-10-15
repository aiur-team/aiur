defmodule Aiur.AgentRunner.ToolExecutor.DecisionRequestsTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.{SessionLifecycle, ToolExecutor}
  alias Aiur.{DecisionAttention, DecisionStore, Issue}
  alias Aiur.Events.Exchange

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

    test "a factual Command can enrich an attention and receive an Executor answer (future regression guard)" do
      identifier = "TE-decision-attention-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier, title: "Adapter ticket"}
      coordination = Module.concat(__MODULE__, "DecisionCorrelation#{System.unique_integer([:positive])}")
      start_supervised!({Aiur.CoordinationTasks, name: coordination})
      test_pid = self()

      executor =
        ToolExecutor.build(issue, nil, nil, %{backend: "codex", thread_id: "thread-adapter"},
          coordination_enqueuer: fn key, operation, opts ->
            Aiur.CoordinationTasks.enqueue(key, operation, coordination, opts)
          end,
          coordination_runner: fn key, operation, opts ->
            Aiur.CoordinationTasks.run(key, operation, coordination, opts)
          end,
          attention_opener: fn issue, workspace, worker_host, slug, question, opts ->
            send(test_pid, {:attention_projection_started, self()})
            receive do: (:release_attention_projection -> :ok)
            DecisionAttention.open_with_decision(issue, workspace, worker_host, slug, question, opts)
          end
        )

      legacy =
        ToolExecutor.execute(
          executor,
          "emit_event",
          %{
            "name" => "attention.scope-question",
            "message" => "Did discovery consent open on the retry?"
          },
          "call-legacy"
        )

      legacy_result = Jason.decode!(legacy["output"])["result"]
      assert legacy_result["status"] == "pending"
      assert_receive {:attention_projection_started, projection_worker}, 2_000

      structured_arguments = %{
        "name" => "decision.requested",
        "message" => "Did discovery consent open on the retry?",
        "payload" => %{
          "attention_slug" => "scope-question",
          "decision_id" => "dec_attacker",
          "source_id" => "attacker-controlled",
          "legacy_attention" => %{
            "slug" => "other",
            "topic" => "ticket.attacker.agent.attention.other"
          },
          "blocking" => true,
          "kind" => "factual_observation",
          "authority" => "supervisor_allowed",
          "reversibility" => "reversible",
          "context" => %{"short_summary" => "Report the redacted outcome of the owner's retry."}
        }
      }

      enrich_call =
        Task.async(fn -> ToolExecutor.execute(executor, "emit_event", structured_arguments, "call-enrich") end)

      assert :ok = wait_for_coordination_queue(coordination, {:ticket, identifier})
      send(projection_worker, :release_attention_projection)

      enriched = Task.await(enrich_call, 2_000)
      retry = ToolExecutor.execute(executor, "emit_event", structured_arguments, "call-enrich")

      assert enriched["success"] == true, enriched["output"]
      assert retry["success"] == true, retry["output"]

      enriched_result = Jason.decode!(enriched["output"])["result"]
      retry_result = Jason.decode!(retry["output"])["result"]

      legacy_decision =
        DecisionStore.list()
        |> Enum.find(&(&1.ticket.identifier == identifier))

      assert enriched_result["decision_id"] == legacy_decision.decision_id
      assert enriched_result["version"] == 2
      assert enriched_result["status"] == "accepted"
      assert retry_result["decision_id"] == legacy_decision.decision_id
      assert retry_result["version"] == 2
      assert retry_result["status"] == "duplicate"

      {:ok, history} = DecisionStore.history(legacy_decision.decision_id)
      assert Enum.map(history, & &1.version) == [1, 2]
      assert hd(history).authority == :human_required
      assert hd(history).reversibility == :irreversible
      assert List.last(history).authority == :supervisor_allowed
      assert List.last(history).reversibility == :reversible

      assert [current] =
               DecisionStore.list()
               |> Enum.filter(&(&1.ticket.identifier == identifier))

      assert current.decision_id == legacy_decision.decision_id
      assert current.source_id == "legacy_attention:scope-question"
      assert current.legacy_attention.topic == "ticket.#{identifier}.agent.attention.scope-question"

      assert {:ok, %{status: :accepted, action: answer}} =
               DecisionStore.answer(
                 current.decision_id,
                 %{
                   "idempotency_key" => "executor-factual-observation",
                   "expected_version" => 2,
                   "custom_response" => "No; consent did not open on the retry."
                 },
                 actor: %{kind: :executor, id: "executor-1"}
               )

      assert answer.actor == %{kind: :executor, id: "executor-1"}
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

  defp wait_for_coordination_queue(name, key, attempts \\ 400)

  defp wait_for_coordination_queue(_name, _key, 0), do: :timeout

  defp wait_for_coordination_queue(name, key, attempts) do
    state = :sys.get_state(name)

    case Map.get(state.queues, key) do
      queue when not is_nil(queue) ->
        if :queue.is_empty(queue), do: retry_coordination_queue(name, key, attempts), else: :ok

      nil ->
        retry_coordination_queue(name, key, attempts)
    end
  end

  defp retry_coordination_queue(name, key, attempts) do
    receive do
    after
      5 -> wait_for_coordination_queue(name, key, attempts - 1)
    end
  end
end
