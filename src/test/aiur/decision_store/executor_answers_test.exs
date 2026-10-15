Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.DecisionStore.ExecutorAnswersTest do
  use Aiur.DecisionStoreCase, async: false

  test "accepts and replays an executor-attributed answer without supervisor policy evidence", %{dir: dir} do
    pid = start_store!(dir, dispatch_delay_ms: 60_000)

    assert {:ok, %{decision: decision}} =
             request(pid, %{
               "question" => "Reuse the established answer?",
               "blocking" => true,
               "authority" => "supervisor_allowed",
               "reversibility" => "reversible",
               "options" => [%{"id" => "yes", "label" => "Yes"}]
             })

    assert {:ok, %{status: :accepted, action: answer}} =
             DecisionStore.answer(
               decision.decision_id,
               %{
                 "idempotency_key" => "executor-answer",
                 "expected_version" => 1,
                 "option_id" => "yes"
               },
               [actor: %{kind: :executor, id: "executor-1"}],
               pid
             )

    assert answer.actor == %{kind: :executor, id: "executor-1"}
    assert answer.supervisor_basis == nil

    assert {:ok, [_requested, %DecisionEvent{type: :answer_recorded, data: ^answer}]} =
             DecisionStore.audit_history(decision.decision_id, pid)

    GenServer.stop(pid)
    replayed = start_store!(dir, dispatch_delay_ms: 60_000)
    assert DecisionStore.health(replayed) == :writable
    assert {:ok, durable} = DecisionStore.get(decision.decision_id, replayed)
    assert durable.answer == answer
  end

  test "a reversible low-risk operational recommendation is Executor-answerable only when classified delegable", %{dir: dir} do
    pid = start_store!(dir, dispatch_delay_ms: 60_000)

    payload = %{
      "question" => "Resume after the reversible sandbox grant?",
      "blocking" => true,
      "authority" => "supervisor_allowed",
      "reversibility" => "reversible",
      "kind" => "operational",
      "options" => [
        %{"id" => "resume", "label" => "Resume", "description" => "Resume the agent.", "risk" => "low"},
        %{"id" => "wait", "label" => "Wait", "description" => "Leave the agent paused.", "risk" => "low"}
      ],
      "recommendation" => %{"option_id" => "resume", "reason" => "The grant is already verified."}
    }

    assert {:ok, %{decision: delegable}} = request(pid, payload)

    assert {:ok, %{status: :accepted}} =
             DecisionStore.answer(
               delegable.decision_id,
               %{"idempotency_key" => "executor-delegable", "expected_version" => 1, "option_id" => "resume"},
               [actor: %{kind: :executor, id: "executor-1"}],
               pid
             )

    assert {:ok, %{decision: human_only}} =
             request(
               pid,
               payload
               |> Map.put("question", "Resume the second agent after the reversible sandbox grant?")
               |> Map.put("authority", "human_required")
             )

    assert {:error, {:answer_invalid, {:executor_scope, {:authority, :human_required}}}} =
             DecisionStore.answer(
               human_only.decision_id,
               %{"idempotency_key" => "executor-human-only", "expected_version" => 1, "option_id" => "resume"},
               [actor: %{kind: :executor, id: "executor-1"}],
               pid
             )
  end

  test "refuses an Executor answer for any Command the operator should see", %{dir: dir} do
    pid = start_store!(dir, dispatch_delay_ms: 60_000)

    delegable = %{
      "blocking" => true,
      "authority" => "supervisor_allowed",
      "reversibility" => "reversible",
      "options" => [%{"id" => "yes", "label" => "Yes"}]
    }

    refused = [
      {"human_required authority", %{"authority" => "human_required"}, {:authority, :human_required}},
      {"an irreversible outcome", %{"reversibility" => "irreversible"}, {:reversibility, :irreversible}},
      {"a partially reversible outcome", %{"reversibility" => "partially_reversible"}, {:reversibility, :partially_reversible}}
    ]

    for {label, override, expected} <- refused do
      payload = delegable |> Map.merge(override) |> Map.put("question", "Escalate #{label}?")
      assert {:ok, %{decision: decision}} = request(pid, payload)

      assert {:error, {:answer_invalid, {:executor_scope, ^expected}}} =
               DecisionStore.answer(
                 decision.decision_id,
                 %{"idempotency_key" => "executor-#{label}", "expected_version" => 1, "option_id" => "yes"},
                 [actor: %{kind: :executor, id: "executor-1"}],
                 pid
               )

      # Refused, not recorded: the Command stays open for the operator.
      assert {:ok, %Decision{decision_status: :open, answer: nil}} = DecisionStore.get(decision.decision_id, pid)

      # The operator keeps the authority the Executor was just denied.
      assert {:ok, %{status: :accepted}} =
               answer(pid, decision.decision_id, %{
                 "idempotency_key" => "operator-#{label}",
                 "expected_version" => 1,
                 "option_id" => "yes"
               })
    end
  end

  test "fails an Executor answer closed only when the Command declares a non-delegable policy", %{dir: dir} do
    pid = start_store!(dir, dispatch_delay_ms: 60_000)

    # An omitted authority/reversibility now defaults to the Executor-answerable
    # pair, so an absent declaration no longer strands the agent. The floor
    # still refuses an explicitly non-delegable declaration.
    assert {:ok, %{decision: decision}} = request(pid, %{"question" => "Undeclared policy?", "blocking" => true})
    assert decision.authority == :supervisor_allowed
    assert decision.reversibility == :reversible

    assert {:ok, %{status: :accepted}} =
             DecisionStore.answer(
               decision.decision_id,
               %{
                 "idempotency_key" => "executor-undeclared",
                 "expected_version" => 1,
                 "custom_response" => "Looks obvious to me."
               },
               [actor: %{kind: :executor, id: "executor-1"}],
               pid
             )

    assert {:ok, %{decision: refused}} =
             request(pid, %{
               "question" => "Explicitly operator-scoped?",
               "blocking" => true,
               "authority" => "human_required",
               "reversibility" => "irreversible"
             })

    assert {:error, {:answer_invalid, {:executor_scope, {:authority, :human_required}}}} =
             DecisionStore.answer(
               refused.decision_id,
               %{
                 "idempotency_key" => "executor-explicitly-refused",
                 "expected_version" => 1,
                 "custom_response" => "Looks obvious to me."
               },
               [actor: %{kind: :executor, id: "executor-1"}],
               pid
             )
  end

  test "a re-review request Command is Executor-answerable and releases the agent", %{dir: dir} do
    pid = start_store!(dir, dispatch_delay_ms: 60_000)

    # The issue's most common Command shape: completed rework is green but
    # reviewDecision is stuck on a stale review. It classifies
    # supervisor_preferred + reversible, so the Executor answers directly and
    # the requesting agent resumes without an operator.
    assert {:ok, %{decision: decision}} =
             request(pid, %{
               "question" => "Rework is complete and CI is green, but reviewDecision is stuck on a stale review — please re-review to release it.",
               "blocking" => true,
               "kind" => "rework_review"
             })

    assert decision.authority == :supervisor_preferred
    assert decision.reversibility == :reversible

    assert {:ok, %{status: :accepted, action: answer}} =
             DecisionStore.answer(
               decision.decision_id,
               %{
                 "idempotency_key" => "executor-re-review",
                 "expected_version" => 1,
                 "custom_response" => "Re-reviewing now."
               },
               [actor: %{kind: :executor, id: "executor-1"}],
               pid
             )

    assert answer.actor == %{kind: :executor, id: "executor-1"}
    assert {:ok, %Decision{answer: %{actor: %{kind: :executor}}, decision_status: status}} = DecisionStore.get(decision.decision_id, pid)
    assert status in [:acknowledged, :resolved, :decided]
  end

  test "a sequencing Command is Executor-answerable and releases the agent", %{dir: dir} do
    pid = start_store!(dir, dispatch_delay_ms: 60_000)

    assert {:ok, %{decision: decision}} =
             request(pid, %{
               "question" => "Reconcile the precedence overlap: strip and stack, or keep and close?",
               "blocking" => true,
               "kind" => "sequencing"
             })

    assert decision.authority == :supervisor_allowed
    assert decision.reversibility == :reversible

    assert {:ok, %{status: :accepted, action: answer}} =
             DecisionStore.answer(
               decision.decision_id,
               %{
                 "idempotency_key" => "executor-sequencing",
                 "expected_version" => 1,
                 "custom_response" => "Keep and close: strip the overlap onto #2438 and stack."
               },
               [actor: %{kind: :executor, id: "executor-1"}],
               pid
             )

    assert answer.actor == %{kind: :executor, id: "executor-1"}
  end

  test "a known-irreversible Command still refuses the Executor and still escalates", %{dir: dir} do
    opener = fn _decision, _executor_id, _reason -> {:ok, :opened} end
    pid = start_store!(dir, executor_attention_opener: opener, dispatch_delay_ms: 60_000)

    # Genuinely irreversible / spend / product-direction Commands stay outside
    # the Executor floor: this is the guard that keeps the classification fix
    # from becoming a blanket widening.
    assert {:ok, %{decision: decision}} =
             request(pid, %{
               "question" => "Spend on the paid provider to unblock the build?",
               "blocking" => true,
               "authority" => "human_required",
               "reversibility" => "irreversible",
               "kind" => "spend"
             })

    assert {:error, {:answer_invalid, {:executor_scope, {:authority, :human_required}}}} =
             DecisionStore.answer(
               decision.decision_id,
               %{"idempotency_key" => "executor-irreversible", "expected_version" => 1, "custom_response" => "Go."},
               [actor: %{kind: :executor, id: "executor-1"}],
               pid
             )

    # Refused, not recorded: the Command stays open for the operator.
    assert {:ok, %Decision{decision_status: :open, answer: nil}} = DecisionStore.get(decision.decision_id, pid)

    # The Executor's remaining option is escalation, which still notifies the
    # operator and leaves the Command answerable.
    assert {:ok, %{status: :opened}} =
             DecisionStore.escalate_executor_command(
               decision.decision_id,
               %{expected_version: 1, executor_id: "executor-1", reason: "This involves spend and is not reversible."},
               pid
             )

    assert {:ok, %Decision{decision_status: :open, answer: nil}} = DecisionStore.get(decision.decision_id, pid)
  end

  test "an Executor answer never opens an operator attention", %{dir: dir} do
    # `executor_attention_opener` is the store's only path to an operator
    # alert for a Command, so flunking it is the real form of "answering
    # directly does not page the operator".
    opener = fn _decision, _executor_id, _reason -> flunk("a direct Executor answer must not alert the operator") end
    pid = start_store!(dir, executor_attention_opener: opener, dispatch_delay_ms: 60_000)

    assert {:ok, %{decision: decision}} =
             request(pid, %{
               "question" => "Answer this without paging anyone?",
               "blocking" => true,
               "authority" => "supervisor_preferred",
               "reversibility" => "reversible",
               "options" => [%{"id" => "yes", "label" => "Yes"}]
             })

    assert {:ok, %{status: :accepted, action: answer}} =
             DecisionStore.answer(
               decision.decision_id,
               %{"idempotency_key" => "executor-quiet", "expected_version" => 1, "option_id" => "yes"},
               [actor: %{kind: :executor, id: "executor-1"}],
               pid
             )

    assert answer.actor == %{kind: :executor, id: "executor-1"}
  end

  test "records an Executor escalation durably, attributably, and idempotently", %{dir: dir} do
    pid = start_store!(dir, executor_attention_opener: fn _d, _e, _r -> {:ok, :opened} end, dispatch_delay_ms: 60_000)

    assert {:ok, %{decision: decision}} =
             request(pid, %{"question" => "Rename the public API?", "blocking" => true})

    assert {:ok, %{status: :opened}} =
             DecisionStore.escalate_executor_command(
               decision.decision_id,
               %{expected_version: 1, executor_id: "executor-1", reason: "This changes a published contract."},
               pid
             )

    assert {:ok, history} = DecisionStore.audit_history(decision.decision_id, pid)

    assert [%DecisionEvent{type: :executor_escalated, decision_version: 1, data: data}] =
             Enum.filter(history, &(&1.type == :executor_escalated))

    assert data.actor == %{kind: :executor, id: "executor-1"}
    assert data.detail == "This changes a published contract."

    # Deferring to the operator must not consume the Command.
    assert {:ok, %Decision{decision_status: :open, answer: nil}} = DecisionStore.get(decision.decision_id, pid)

    # A repeated escalation of the same version is a no-op append.
    assert {:ok, %{status: _status}} =
             DecisionStore.escalate_executor_command(
               decision.decision_id,
               %{expected_version: 1, executor_id: "executor-1", reason: "Same reason, retried."},
               pid
             )

    assert {:ok, replayed_history} = DecisionStore.audit_history(decision.decision_id, pid)
    assert Enum.count(replayed_history, &(&1.type == :executor_escalated)) == 1

    GenServer.stop(pid)
    restarted = start_store!(dir, dispatch_delay_ms: 60_000)
    assert DecisionStore.health(restarted) == :writable

    assert {:ok, durable} = DecisionStore.audit_history(decision.decision_id, restarted)

    assert [%DecisionEvent{type: :executor_escalated, data: durable_data}] =
             Enum.filter(durable, &(&1.type == :executor_escalated))

    assert durable_data == data
    assert {:ok, %Decision{decision_status: :open}} = DecisionStore.get(decision.decision_id, restarted)
  end

  test "answering an escalated Command clears its operator attention", %{dir: dir} do
    previous_log_file = Application.get_env(:aiur, :log_file)
    log_root = Path.join(dir, "executor-escalation-log")
    Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))
    Aiur.TestSupport.put_runtime_state_dir!(log_root)

    on_exit(fn ->
      if previous_log_file,
        do: Application.put_env(:aiur, :log_file, previous_log_file),
        else: Application.delete_env(:aiur, :log_file)
    end)

    pid = start_store!(dir, dispatch_delay_ms: 60_000)

    assert {:ok, %{decision: decision}} =
             request(pid, %{"question" => "Change the release scope?", "blocking" => true})

    assert ExUnit.CaptureIO.capture_io(fn ->
             assert ExecutorCommandCLI.escalate(
                      [
                        decision_id: decision.decision_id,
                        expected_version: decision.version,
                        reason: "This changes product scope."
                      ],
                      decision_store: pid
                    ) == 0
           end) =~ "escalated Command"

    topic = ExecutorCommandAttention.topic(decision.decision_id, decision.ticket.identifier)
    alert_opts = [roots: [], log_roots: [log_root]]
    assert AlertFeed.active_ticket_attention?(topic, alert_opts)

    assert {:ok, %{status: :accepted}} =
             answer(pid, decision.decision_id, %{
               "idempotency_key" => "operator-answer-after-escalation",
               "expected_version" => decision.version,
               "custom_response" => "Keep the existing scope."
             })

    refute AlertFeed.active_ticket_attention?(topic, alert_opts)
  end

  test "serializes Executor escalation before a concurrent answer", %{dir: dir} do
    parent = self()

    opener = fn _decision, _executor_id, _reason ->
      send(parent, {:attention_opening, self()})

      receive do
        :finish_attention -> {:ok, :opened}
      end
    end

    pid = start_store!(dir, executor_attention_opener: opener, dispatch_delay_ms: 60_000)

    assert {:ok, %{decision: decision}} =
             request(pid, %{
               "question" => "Serialize this escalation?",
               "blocking" => true,
               "options" => [%{"id" => "yes", "label" => "Yes"}]
             })

    spawn(fn ->
      result =
        DecisionStore.escalate_executor_command(
          decision.decision_id,
          %{expected_version: 1, executor_id: "executor-1", reason: "Needs operator judgment"},
          pid
        )

      send(parent, {:escalation_result, result})
    end)

    receive_barrier({:attention_opening, opener_pid})

    decision_id = decision.decision_id
    :erlang.trace(pid, true, [:receive])

    try do
      spawn(fn ->
        result =
          answer(pid, decision_id, %{
            "idempotency_key" => "answer-after-escalation",
            "expected_version" => 1,
            "option_id" => "yes"
          })

        send(parent, {:answer_result, result})
      end)

      receive_barrier({:trace, ^pid, :receive, {:"$gen_call", _from, {:answer, ^decision_id, _payload, _opts}}})
      refute_received {:answer_result, _result}
    after
      :erlang.trace(pid, false, [:receive])
    end

    send(opener_pid, :finish_attention)

    receive_barrier({:escalation_result, {:ok, %{status: :opened}}})
    receive_barrier({:answer_result, {:ok, %{status: :accepted}}})
  end
end
