defmodule Aiur.DecisionDispatchTest do
  use ExUnit.Case, async: true

  alias Aiur.{DecisionAnswer, DecisionDispatch, DecisionValidation}

  defp answered_decision(answer_payload) do
    {:ok, decision} =
      DecisionValidation.normalize(
        %{
          "question" => "Should we deploy?",
          "blocking" => false,
          "source_id" => "dispatch-test",
          "options" => [%{"id" => "ship", "label" => "Ship it"}, %{"id" => "wait", "label" => "Wait"}],
          "recommendation" => %{"option_id" => "ship", "reason" => "Reversible"}
        },
        ticket: %{identifier: "981", title: "OCC-3", url: nil},
        source: %{agent_id: "agent-1", session_id: "session-1"},
        now: ~U[2026-07-12 10:00:00Z]
      )

    {:ok, answer} =
      DecisionAnswer.normalize(answer_payload,
        decision_id: decision.decision_id,
        decision_version: decision.version,
        options: decision.options,
        actor: %{kind: :operator, id: "operator-1"},
        now: ~U[2026-07-12 10:01:00Z]
      )

    %{decision | answer: answer, decision_status: :decided, delivery_status: :pending}
  end

  test "renders an option answer with correlation and explicit lifecycle guidance" do
    decision =
      answered_decision(%{
        "idempotency_key" => "submit-1",
        "expected_version" => 1,
        "option_id" => "ship",
        "rationale" => "All checks are green."
      })

    send_fun = fn server, identifier, payload ->
      send(self(), {:sent, server, identifier, payload})
      {:ok, %{status: :accepted, item: %{id: 41}}}
    end

    assert {:ok, %{status: :accepted, item: %{id: 41}}} =
             DecisionDispatch.dispatch(decision,
               attempt_id: "attempt-1",
               operator_messages: :fake_operator_messages,
               send_fun: send_fun
             )

    assert_receive {:sent, :fake_operator_messages, "981", payload}, 1000
    assert payload.action_id == decision.answer.action_id
    assert payload.delivery_policy == :interrupt
    assert payload.fallback == :queue_next
    assert payload.correlation.decision_id == decision.decision_id
    assert payload.correlation.decision_version == 1
    assert payload.correlation.attempt_id == "attempt-1"
    assert payload.correlation.action_id == decision.answer.action_id
    assert payload.correlation.decision_version == decision.answer.decision_version

    correlation_json =
      payload.body
      |> String.split("Decision lifecycle correlation: ")
      |> List.last()
      |> String.split("\n")
      |> hd()

    assert Jason.decode!(correlation_json) == %{
             "decision_id" => decision.decision_id,
             "expected_version" => decision.answer.decision_version,
             "action_id" => decision.answer.action_id
           }

    # The envelope keeps the answer readable and includes lifecycle identifiers
    # in the body so the agent can record its acknowledgement.
    refute payload.body =~ "Durable Executor answer for ticket 981"
    refute payload.body =~ "Request version"
    assert payload.body =~ "Selected option `ship`: Ship it"
    assert payload.body =~ "All checks are green."
    assert payload.body =~ "decision.acknowledged"
    assert payload.body =~ "decision.resolved"
  end

  test "renders a bounded custom answer and threads explicit failed retry intent" do
    decision =
      answered_decision(%{
        "idempotency_key" => "submit-2",
        "expected_version" => 1,
        "custom_response" => String.duplicate("x", 4_000),
        "rationale" => String.duplicate("y", 4_000)
      })

    send_fun = fn _server, _identifier, payload ->
      send(self(), {:payload, payload})
      {:error, :no_running_agent}
    end

    assert {:error, :no_running_agent} =
             DecisionDispatch.dispatch(decision,
               attempt_id: "attempt-2",
               retry_failed: true,
               send_fun: send_fun
             )

    assert_receive {:payload, payload}, 1000
    assert payload.retry_failed == true
    assert String.length(payload.body) <= DecisionDispatch.max_message_chars()
    assert payload.body =~ "Custom response:"
    assert payload.body =~ "Decision lifecycle correlation:"
  end

  test "tells the worker when a late answer changes its recorded optional default" do
    decision =
      answered_decision(%{
        "idempotency_key" => "override-default",
        "expected_version" => 1,
        "option_id" => "wait"
      })
      |> Map.merge(%{
        blocking: false,
        recommendation: %{option_id: "ship", reason: "Ship is reversible"},
        default_applied: %{option_id: "ship", at: ~U[2026-07-12 10:01:00Z]}
      })

    assert DecisionDispatch.render(decision) =~ "This overrides the default you proceeded on; change course."
  end

  test "re-dispatches an idle ticket when a correlated answer is queued for its next worker" do
    alias Aiur.Orchestrator.OperatorMessages.EnqueueNextWorker

    dir = Aiur.TestSupport.tmp_root!("optional-answer-redispatch")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    Application.put_env(:aiur, :pending_operator_messages_store_path, Path.join(dir, "pending.json"))
    on_exit(fn -> Application.delete_env(:aiur, :pending_operator_messages_store_path) end)
    parent = self()
    queue_store = Aiur.AgentQueueStore.new()

    state = %Aiur.Orchestrator.State{queue_store: queue_store, running: %{}}

    request = %{
      origin: :decision,
      actor: "executor",
      turn_id: nil,
      action_id: "answer-action",
      correlation: %{decision_id: "decision-1"},
      mode: :correlated
    }

    enqueue_plain = fn store, attrs, _request ->
      {next_store, item} = Aiur.AgentQueueStore.enqueue(store, attrs)
      {:ok, next_store, item, :accepted}
    end

    record_evidence = fn _item -> :ok end

    assert {{:ok, %{status: :accepted}}, _next_state} =
             EnqueueNextWorker.enqueue(state, "979", "Answer", request, enqueue_plain, record_evidence,
               redispatch_fun: fn identifier ->
                 send(parent, {:redispatch, identifier})
                 :ok
               end
             )

    assert_receive {:redispatch, "979"}, 1_000
  end
end
