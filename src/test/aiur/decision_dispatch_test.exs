defmodule Aiur.DecisionDispatchTest do
  use ExUnit.Case, async: true

  alias Aiur.{DecisionAnswer, DecisionDispatch, DecisionValidation}

  defp answered_decision(answer_payload) do
    {:ok, decision} =
      DecisionValidation.normalize(
        %{
          "question" => "Should we deploy?",
          "blocking" => true,
          "source_id" => "dispatch-test",
          "options" => [%{"id" => "ship", "label" => "Ship it"}]
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

    assert_receive {:sent, :fake_operator_messages, "981", payload}
    assert payload.action_id == decision.answer.action_id
    assert payload.correlation.decision_id == decision.decision_id
    assert payload.correlation.decision_version == 1
    assert payload.correlation.attempt_id == "attempt-1"
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

    assert_receive {:payload, payload}
    assert payload.retry_failed == true
    assert String.length(payload.body) <= DecisionDispatch.max_message_chars()
    assert payload.body =~ "Custom response:"
  end
end
