defmodule Aiur.ExecutorCommandCLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Aiur.ExecutorCommandCLI

  describe "answer/2" do
    # The "answering does not alert the operator" guarantee is asserted where
    # alerting actually lives — see the DecisionStore test that installs a
    # flunking `executor_attention_opener`. This CLI test owns the narrower
    # claim it can genuinely enforce: the exact call it makes into the store.
    test "routes one attributed Executor answer through the serialized store API" do
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

    test "tells the Executor to escalate a Command the store refuses to let it answer" do
      output =
        capture_io(:stderr, fn ->
          assert ExecutorCommandCLI.answer(
                   [
                     decision_id: "decision:42",
                     expected_version: 3,
                     custom_response: "Looks obvious",
                     rationale: "Seemed fine",
                     idempotency_key: "key"
                   ],
                   answer_fun: fn _, _, _, _ ->
                     {:error, {:answer_invalid, {:executor_scope, {:reversibility, :irreversible}}}}
                   end
                 ) == 1
        end)

      assert output =~ "outside what the Executor may answer directly"
      assert output =~ "executor-escalate"
      assert output =~ "reversibility"
    end

    test "names the CLI flag for invalid answer fields" do
      for {reason, expected} <- [
            {{:idempotency_key, :missing}, "--idempotency-key"},
            {{:actor_kind, :invalid}, "Executor attribution"},
            {{:actor_id, :too_long}, "--executor-id"},
            {{:option_id, :unknown}, "--option is invalid"},
            {{:response, :ambiguous}, "exactly one of --option or --custom-response"},
            {{:custom_response, :too_long}, "--custom-response"},
            {{:future_field, :invalid}, "answer field future_field"}
          ] do
        output =
          capture_io(:stderr, fn ->
            assert ExecutorCommandCLI.answer(
                     [
                       decision_id: "decision:42",
                       expected_version: 3,
                       option_id: "yes",
                       rationale: "Known answer",
                       idempotency_key: "key"
                     ],
                     answer_fun: fn _, _, _, _ -> {:error, {:answer_invalid, reason}} end
                   ) == 1
          end)

        assert output =~ expected
      end
    end

    test "routes errors through an injected writer for control RPC callers" do
      for reason <- [
            {:stale_version, 3, 4},
            {:conflict, {:stale_version, 3, 4}}
          ] do
        test_pid = self()

        assert ExecutorCommandCLI.answer(
                 [
                   decision_id: "decision:42",
                   expected_version: 3,
                   option_id: "yes",
                   rationale: "Known answer",
                   idempotency_key: "key"
                 ],
                 answer_fun: fn _, _, _, _ -> {:error, reason} end,
                 error_fun: &send(test_pid, {:error, &1})
               ) == 1

        assert_received {:error, "aiur: cannot answer Command: stale version 3; current version is 4"}
      end
    end

    test "requires exactly one option or custom response" do
      answer_fun = fn _decision_id, _payload, _opts, _store -> flunk("invalid answers must not reach the store") end
      required = [decision_id: "decision:42", expected_version: 3, rationale: "Known answer", idempotency_key: "key"]

      for choice <- [[], [option_id: "yes", custom_response: "also yes"]] do
        output =
          capture_io(:stderr, fn ->
            assert ExecutorCommandCLI.answer(required ++ choice, answer_fun: answer_fun) == 64
          end)

        assert output =~ "exactly one of --option or --custom-response"
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

    test "reports a stale version as a command error" do
      output =
        capture_io(:stderr, fn ->
          assert ExecutorCommandCLI.escalate(
                   [decision_id: "decision:42", expected_version: 3, reason: "Needs operator review"],
                   escalate_fun: fn _, _, _ -> {:error, {:stale_version, 3, 4}} end
                 ) == 1
        end)

      assert output =~ "stale version"
    end

    test "routes escalation errors through an injected writer" do
      test_pid = self()

      assert ExecutorCommandCLI.escalate(
               [decision_id: "decision:42", expected_version: 3, reason: "Needs operator review"],
               escalate_fun: fn _, _, _ -> {:error, {:not_open, :resolved}} end,
               error_fun: &send(test_pid, {:error, &1})
             ) == 1

      assert_received {:error, "aiur: cannot escalate Command because it is not open (:resolved)"}
    end

    test "reports a non-open Command as a command error" do
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

  describe "moot/2" do
    test "routes one attributed moot retirement through the serialized store API" do
      test_pid = self()

      deps = [
        moot_fun: fn decision_id, payload, opts, store ->
          send(test_pid, {:moot, decision_id, payload, opts, store})
          {:ok, %{status: :accepted}}
        end,
        decision_store: :decision_store
      ]

      output =
        capture_io(fn ->
          assert ExecutorCommandCLI.moot(
                   [
                     decision_id: "decision:42",
                     expected_version: 3,
                     reason_class: "ticket_closed",
                     reason: "Ticket #2071 is closed.",
                     executor_id: "codex-executor"
                   ],
                   deps
                 ) == 0
        end)

      assert_received {:moot, "decision:42",
                       %{
                         expected_version: 3,
                         reason_class: "ticket_closed",
                         reason: "Ticket #2071 is closed."
                       }, [actor: actor], :decision_store}

      assert actor == %{kind: :executor, id: "codex-executor"}
      assert output =~ "Executor codex-executor mooted Command decision:42"
    end

    test "requires a non-empty reason class" do
      output =
        capture_io(:stderr, fn ->
          assert ExecutorCommandCLI.moot(
                   [decision_id: "decision:42", expected_version: 3, reason_class: ""],
                   moot_fun: fn _, _, _, _ -> flunk("missing reason-class must not reach the store") end
                 ) == 64
        end)

      assert output =~ "--reason-class is required"
    end

    test "reports a non-open Command as a command error" do
      output =
        capture_io(:stderr, fn ->
          assert ExecutorCommandCLI.moot(
                   [decision_id: "decision:42", expected_version: 3, reason_class: "ticket_closed"],
                   moot_fun: fn _, _, _, _ -> {:error, {:conflict, :decided}} end
                 ) == 1
        end)

      assert output =~ "cannot moot Command because it is :decided"
    end

    test "routes moot errors through an injected writer" do
      test_pid = self()

      assert ExecutorCommandCLI.moot(
               [decision_id: "decision:42", expected_version: 3, reason_class: "ticket_closed"],
               moot_fun: fn _, _, _, _ -> {:error, :store_unavailable} end,
               error_fun: &send(test_pid, {:error, &1})
             ) == 1

      assert_received {:error, "aiur: failed to moot Command (:store_unavailable)"}
    end

    test "reports a stale version as a command error" do
      output =
        capture_io(:stderr, fn ->
          assert ExecutorCommandCLI.moot(
                   [decision_id: "decision:42", expected_version: 3, reason_class: "ticket_closed"],
                   moot_fun: fn _, _, _, _ -> {:error, {:stale_version, 3, 4}} end
                 ) == 1
        end)

      assert output =~ "stale version"
    end
  end
end
