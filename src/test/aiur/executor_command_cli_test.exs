defmodule Aiur.ExecutorCommandCLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Aiur.ExecutorCommandCLI

  describe "answer/2" do
    test "records an attributed Executor answer without emitting an alert" do
      test_pid = self()

      params = [
        decision_id: "decision:42",
        expected_version: 3,
        option_id: "rebase",
        rationale: "The branch is stale against the established base.",
        idempotency_key: "executor:decision:42:v3",
        executor_id: "codex-executor"
      ]

      deps = [
        answer_fun: fn decision_id, payload, opts, store ->
          send(test_pid, {:answer, decision_id, payload, opts, store})
          {:ok, %{status: :accepted, action: %{action_id: "action-1"}}}
        end,
        alert_fun: fn _topic, _message, _opts -> flunk("direct answers must not alert the operator") end,
        decision_store: :decision_store
      ]

      output = capture_io(fn -> assert ExecutorCommandCLI.answer(params, deps) == 0 end)

      assert_received {:answer, "decision:42", payload, [actor: actor], :decision_store}
      assert actor == %{kind: :executor, id: "codex-executor"}

      assert payload == %{
               "expected_version" => 3,
               "idempotency_key" => "executor:decision:42:v3",
               "option_id" => "rebase",
               "rationale" => "The branch is stale against the established base."
             }

      assert output =~ "Executor codex-executor answered Command decision:42"
    end

    test "requires exactly one option or custom response" do
      answer_fun = fn _decision_id, _payload, _opts, _store -> flunk("invalid answers must not reach the store") end
      required = [decision_id: "decision:42", expected_version: 3, rationale: "Known answer", idempotency_key: "key"]

      for choice <- [[], [option_id: "yes", custom_response: "also yes"]] do
        output =
          capture_io(:stderr, fn ->
            assert ExecutorCommandCLI.answer(required ++ choice, answer_fun: answer_fun) == 64
          end)

        assert output =~ "exactly one of option_id or custom_response"
      end
    end
  end

  describe "escalate/2" do
    test "routes one attributed escalation through the serialized store API" do
      test_pid = self()

      deps = [
        escalate_fun: fn decision_id, payload, store ->
          send(test_pid, {:escalate, decision_id, payload, store})
          {:ok, %{status: :opened}}
        end,
        decision_store: :decision_store
      ]

      output =
        capture_io(fn ->
          assert ExecutorCommandCLI.escalate(
                   [
                     decision_id: "decision:42",
                     expected_version: 3,
                     reason: "This changes scope and cannot be safely inferred.",
                     executor_id: "codex-executor"
                   ],
                   deps
                 ) == 0
        end)

      assert_received {:escalate, "decision:42",
                       %{
                         expected_version: 3,
                         executor_id: "codex-executor",
                         reason: "This changes scope and cannot be safely inferred."
                       }, :decision_store}

      assert output =~ "escalated Command decision:42 to the operator"

      replay_output =
        capture_io(fn ->
          assert ExecutorCommandCLI.escalate(
                   [decision_id: "decision:42", expected_version: 3, reason: "Same replay"],
                   escalate_fun: fn _, _, _ -> {:ok, %{status: :already_open}} end
                 ) == 0
        end)

      assert replay_output =~ "already escalated"
    end

    test "rejects a stale version without alerting" do
      output =
        capture_io(:stderr, fn ->
          assert ExecutorCommandCLI.escalate(
                   [decision_id: "decision:42", expected_version: 3, reason: "Needs operator review"],
                   escalate_fun: fn _, _, _ -> {:error, {:stale_version, 3, 4}} end
                 ) == 1
        end)

      assert output =~ "stale version"
    end

    test "rejects a non-open Command without alerting" do
      output =
        capture_io(:stderr, fn ->
          assert ExecutorCommandCLI.escalate(
                   [decision_id: "decision:42", expected_version: 3, reason: "Needs operator review"],
                   escalate_fun: fn _, _, _ -> {:error, {:not_open, :resolved}} end
                 ) == 1
        end)

      assert output =~ "not open"
    end

    test "keeps re-answer and revision handling out of the Executor CLI" do
      output =
        capture_io(:stderr, fn ->
          assert ExecutorCommandCLI.escalate(
                   [decision_id: "decision:42", expected_version: 3, reason: "Needs a changed answer"],
                   escalate_fun: fn _, _, _ -> {:error, :already_answered} end
                 ) == 1
        end)

      assert output =~ "already has an answer; revise it in the dashboard"
    end

    test "exposes the keyed resolution topic for lifecycle-wide cleanup" do
      topic = ExecutorCommandCLI.escalation_topic("decision:42", "42")

      assert topic == ExecutorCommandCLI.escalation_topic("decision:42", "42")
      assert topic != ExecutorCommandCLI.escalation_topic("decision:43", "42")
      assert ExecutorCommandCLI.escalation_resolution_topic("decision:42", "42") == topic <> ".resolved"
    end
  end
end
