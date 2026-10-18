Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.DecisionStore.WithdrawalsTest do
  use Aiur.DecisionStoreCase, async: false

  test "dismiss is durable, idempotent, historic, and write-gated", %{dir: dir} do
    pid = start_store!(dir)

    # Non-blocking: dismissal closes a notice outright. A blocking Command is
    # covered separately — dismissal cannot release its agent.
    assert {:ok, %{decision: decision}} =
             request(pid, %{
               "question" => "Use blue or green?",
               "blocking" => false,
               "options" => [
                 %{"id" => "blue", "label" => "Blue"},
                 %{"id" => "green", "label" => "Green"}
               ]
             })

    opts = [actor: %{kind: :operator, id: "dashboard"}]

    assert {:ok, %{status: :accepted, decision: dismissed}} =
             DecisionStore.dismiss(decision.decision_id, opts, pid)

    assert dismissed.decision_status == :dismissed
    assert dismissed.answer == nil

    assert {:ok, %{status: :duplicate, decision: replayed}} =
             DecisionStore.dismiss(decision.decision_id, opts, pid)

    assert replayed.decision_status == :dismissed

    assert {:ok, %{decisions: [historic], total: 1}} =
             DecisionStore.retained_query(
               %{limit: 25, cursor: nil, lifecycle: :historic, search: nil, ticket: nil},
               pid
             )

    assert historic.decision_id == decision.decision_id

    :sys.replace_state(pid, &%{&1 | writable?: false, health: {:corrupt, 1, :test}})

    assert {:error, {:store_unavailable, {:corrupt, 1, :test}}} =
             DecisionStore.dismiss(decision.decision_id, opts, pid)

    GenServer.stop(pid)
    restarted = start_store!(dir)
    assert {:ok, durable} = DecisionStore.get(decision.decision_id, restarted)
    assert durable.decision_status == :dismissed
  end

  test "deferral is durable, idempotent, and remains answerable", %{dir: dir} do
    pid = start_store!(dir)

    assert {:ok, %{decision: decision}} = request(pid, %{"question" => "Use the release train?", "blocking" => true})
    opts = [actor: %{kind: :operator, id: "dashboard"}]

    assert {:ok, %{status: :accepted, decision: deferred}} = DecisionStore.defer(decision.decision_id, opts, pid)
    assert deferred.decision_status == :deferred
    assert deferred.answer == nil

    assert {:ok, %{status: :duplicate, decision: replayed}} = DecisionStore.defer(decision.decision_id, opts, pid)
    assert replayed.decision_status == :deferred

    GenServer.stop(pid)
    restarted = start_store!(dir)
    assert {:ok, durable} = DecisionStore.get(decision.decision_id, restarted)
    assert durable.decision_status == :deferred

    assert {:ok, %{decision: answerable}} =
             answer(restarted, decision.decision_id, %{
               "idempotency_key" => "deferred-answer",
               "expected_version" => 1,
               "custom_response" => "Use the release train"
             })

    assert answerable.decision_status == :decided
  end

  test "operator dismissal closes a deferred legacy blocker durably", %{dir: dir} do
    pid = start_store!(dir)

    assert {:ok, %{decision: decision}} = project_attention(pid, minimal_attention("Still blocked?"))
    opts = [actor: %{kind: :operator, id: "dashboard"}]
    assert {:ok, %{decision: deferred}} = DecisionStore.defer(decision.decision_id, opts, pid)
    assert {:ok, %{status: :accepted, decision: dismissed}} = DecisionStore.dismiss(deferred.decision_id, opts, pid)
    assert dismissed.decision_status == :dismissed

    GenServer.stop(pid)
    restarted = start_store!(dir)
    assert {:ok, durable} = DecisionStore.get(decision.decision_id, restarted)
    assert durable.decision_status == :dismissed
  end

  test "dismissal is refused for a blocking Command it cannot release", %{dir: dir} do
    pid = start_store!(dir)
    opts = [actor: %{kind: :operator, id: "dashboard"}]

    # Agent-filed: blocking, with no legacy attention to resolve alongside it.
    # Dismissal delivers nothing to the agent, so closing it would hide a live
    # block rather than clear it.
    assert {:ok, %{decision: decision}} = request(pid, %{"question" => "Push or hold?", "blocking" => true})

    assert {:error, {:conflict, :blocking_requires_answer}} =
             DecisionStore.dismiss(decision.decision_id, opts, pid)

    assert {:ok, still_open} = DecisionStore.get(decision.decision_id, pid)
    assert still_open.decision_status == :open

    # Deferring first must not open a back door to the same hidden close.
    assert {:ok, %{decision: deferred}} = DecisionStore.defer(decision.decision_id, opts, pid)

    assert {:error, {:conflict, :blocking_requires_answer}} =
             DecisionStore.dismiss(deferred.decision_id, opts, pid)

    # Answering is the path that actually releases the agent.
    assert {:ok, %{decision: answered}} =
             answer(pid, decision.decision_id, %{
               "idempotency_key" => "blocking-answer",
               "expected_version" => 1,
               "custom_response" => "Hold the push"
             })

    assert answered.decision_status == :decided
  end

  test "expiration is durable, idempotent, historic, and auditable", %{dir: dir} do
    test_pid = self()

    dispatcher = fn dispatched, opts ->
      item = correlated_queue_item(dispatched, dispatched.answer, opts[:attempt_id], 3801)
      send(test_pid, {:expired_answer_queued, item})
      {:ok, %{status: :accepted, item: item}}
    end

    pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
    created_at = ~U[2026-07-24 12:00:00Z]
    expired_at = DateTime.add(created_at, 600, :second)

    assert {:ok, %{decision: decision}} =
             request(pid, %{"question" => "Still waiting?", "blocking" => true}, now: created_at)

    assert {:ok, %{status: :accepted, decision: expired}} =
             DecisionStore.expire(decision.decision_id, "agent_not_running", [now: expired_at], pid)

    assert expired.decision_status == :expired
    assert expired.answer == nil

    assert {:ok, %{status: :duplicate, decision: duplicate}} =
             DecisionStore.expire(decision.decision_id, "agent_not_running", [], pid)

    assert duplicate.decision_status == :expired

    answer_payload = %{"idempotency_key" => "answer-after-expiry", "expected_version" => 1, "custom_response" => "Continue waiting"}
    assert {:ok, %{status: :accepted, decision: answered}} = answer(pid, decision.decision_id, answer_payload)
    assert answered.decision_status == :decided
    assert answered.answer.custom_response == "Continue waiting"
    assert_receive {:expired_answer_queued, item}, 1_000
    assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)
    assert :ok = DecisionStore.record_transport_async(:consumed, item, nil, pid)
    delivered = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :consumed))
    assert delivered.answer.custom_response == "Continue waiting"

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)

    assert Enum.map(audit, & &1.type) == [
             :requested,
             :decision_expired,
             :answer_recorded,
             :dispatch_queued,
             :delivered,
             :consumed
           ]

    assert {:ok, %{decisions: [historic], total: 1}} =
             DecisionStore.retained_query(
               %{limit: 25, cursor: nil, lifecycle: :historic, search: nil, ticket: nil},
               pid
             )

    assert historic.decision_id == decision.decision_id
    assert Enum.any?(audit, &match?(%DecisionEvent{type: :decision_expired, data: %{reason_class: "agent_not_running"}}, &1))

    GenServer.stop(pid)
    restarted = start_store!(dir)
    assert {:ok, replayed} = DecisionStore.get(decision.decision_id, restarted)
    assert replayed.decision_status == :decided
  end

  test "expired blockers can be mooted or dismissed after their ticket is no longer active", %{dir: dir} do
    pid = start_store!(dir)
    opts = [actor: %{kind: :operator, id: "dashboard"}]

    assert {:ok, %{decision: closed_ticket}} =
             request(pid, %{"question" => "Should closed work continue?", "blocking" => true}, ticket: %{@ticket | identifier: "closed-41"})

    assert {:ok, %{decision: dismissed_ticket}} =
             request(pid, %{"question" => "Should retired work continue?", "blocking" => true}, ticket: %{@ticket | identifier: "closed-42"})

    for decision <- [closed_ticket, dismissed_ticket] do
      assert {:ok, %{decision: %{decision_status: :expired}}} =
               DecisionStore.expire(
                 decision.decision_id,
                 "agent_not_running",
                 [now: DateTime.add(decision.created_at, 600, :second)],
                 pid
               )
    end

    assert {:ok, %{status: :accepted, decision: mooted}} =
             DecisionStore.moot(
               closed_ticket.decision_id,
               %{"reason_class" => "ticket_closed"},
               opts,
               pid
             )

    assert mooted.decision_status == :moot
    assert mooted.answer == nil

    assert {:ok, %{status: :accepted, decision: dismissed}} =
             DecisionStore.dismiss(dismissed_ticket.decision_id, opts, pid)

    assert dismissed.decision_status == :dismissed
    assert {:ok, ids} = DecisionStore.blocked_ticket_ids(pid)
    assert ids == MapSet.new()
  end

  describe "moot disposition (#2099)" do
    test "retires an open Command with a recorded reason and no answer", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{decision: decision}} =
               request(pid, %{"question" => "Reclassify #2071?", "blocking" => true})

      assert {:ok, %{status: :accepted, decision: mooted}} =
               DecisionStore.moot(
                 decision.decision_id,
                 %{
                   "reason_class" => "ticket_closed",
                   "reason" => "Ticket #2071 was folded into #2073."
                 },
                 [actor: %{kind: :operator, id: "dashboard"}],
                 pid
               )

      assert mooted.decision_status == :moot
      assert mooted.answer == nil

      assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)

      assert [
               %DecisionEvent{type: :requested},
               %DecisionEvent{
                 type: :decision_mooted,
                 data: %{
                   reason_class: "ticket_closed",
                   detail: "Ticket #2071 was folded into #2073.",
                   actor: %{kind: :operator, id: "dashboard"}
                 }
               }
             ] = audit

      # Distinguishable from a real answer: the Command is not decided, and the
      # audit record carries an actor + reason, never a DecisionAnswer.
      assert {:error, {:conflict, :moot}} =
               answer(pid, decision.decision_id, %{
                 "idempotency_key" => "too-late",
                 "expected_version" => 1,
                 "custom_response" => "Ship"
               })
    end

    test "moot is durable, idempotent, and historic", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{decision: decision}} = request(pid, %{"question" => "Defer or close?", "blocking" => true})
      opts = [actor: %{kind: :operator, id: "dashboard"}]
      assert {:ok, %{decision: deferred}} = DecisionStore.defer(decision.decision_id, opts, pid)
      assert deferred.decision_status == :deferred

      assert {:ok, %{status: :accepted, decision: mooted}} =
               DecisionStore.moot(decision.decision_id, %{"reason_class" => "origin_agent_gone"}, opts, pid)

      assert mooted.decision_status == :moot

      assert {:ok, %{status: :duplicate, decision: duplicate}} =
               DecisionStore.moot(decision.decision_id, %{"reason_class" => "origin_agent_gone"}, opts, pid)

      assert duplicate.decision_status == :moot

      assert {:ok, %{decisions: [historic], total: 1}} =
               DecisionStore.retained_query(
                 %{limit: 25, cursor: nil, lifecycle: :historic, search: nil, ticket: nil},
                 pid
               )

      assert historic.decision_id == decision.decision_id

      # A mooted Command leaves the open surface entirely.
      assert {:ok, %{decisions: [], total: 0}} =
               DecisionStore.retained_query(
                 %{limit: 25, cursor: nil, lifecycle: :open, search: nil, ticket: nil},
                 pid
               )

      GenServer.stop(pid)
      restarted = start_store!(dir)
      assert {:ok, durable} = DecisionStore.get(decision.decision_id, restarted)
      assert durable.decision_status == :moot
    end

    test "a blocking human_required legacy Command about a closed ticket is retirable", %{dir: dir} do
      pid = start_store!(dir)

      # The exact #2099 daemon shape: legacy_attention, blocking, human_required.
      assert {:ok, %{status: :accepted, decision: decision}} =
               DecisionStore.project_attention(
                 %{
                   "question" => "Should ticket #2071 be reclassified for fresh implementation?",
                   "blocking" => true,
                   "authority" => "human_required",
                   "reversibility" => "irreversible",
                   "kind" => "legacy_attention",
                   "source_id" => "legacy_attention:2071-reclassify"
                 },
                 [
                   ticket: @ticket,
                   source: %{agent_id: "codex", session_id: nil, event_id: nil},
                   legacy_attention: %{slug: "2071-reclassify", topic: "ticket.979.agent.attention.2071-reclassify"}
                 ],
                 pid
               )

      assert decision.blocking
      assert decision.authority == :human_required
      assert decision.decision_status == :open

      # `executor-answer` is refused by the floor for this Command…
      assert {:error, {:answer_invalid, {:executor_scope, {:authority, :human_required}}}} =
               DecisionStore.answer(
                 decision.decision_id,
                 %{
                   "idempotency_key" => "executor-try",
                   "expected_version" => 1,
                   "custom_response" => "Reclassify"
                 },
                 [actor: %{kind: :executor, id: "aiur-cli"}],
                 pid
               )

      # …and it sits in the open blocking surface (R4: `commands --blocking`).
      assert {:ok, %{decisions: [open_blocker], total: 1}} =
               DecisionStore.retained_query(
                 %{limit: 25, cursor: nil, lifecycle: :open, blocking: true, search: nil, ticket: nil},
                 pid
               )

      assert open_blocker.decision_id == decision.decision_id

      # Moot is the disposition for a question that is void: it retires the
      # Command — and the block with it — recording why and by whom, with no
      # answer fabricated.
      assert {:ok, %{status: :accepted, decision: mooted}} =
               DecisionStore.moot(
                 decision.decision_id,
                 %{
                   "reason_class" => "ticket_closed",
                   "reason" => "Ticket #2071 was folded into #2073."
                 },
                 [actor: %{kind: :operator, id: "dashboard"}],
                 pid
               )

      assert mooted.decision_status == :moot
      assert mooted.answer == nil

      # The blocking surface reports only Commands a human genuinely still needs.
      assert {:ok, %{decisions: [], total: 0}} =
               DecisionStore.retained_query(
                 %{limit: 25, cursor: nil, lifecycle: :open, blocking: true, search: nil, ticket: nil},
                 pid
               )

      assert {:ok, %{counts: %{blocking: 0, open: 0}}} =
               DecisionStore.retained_counts(pid)
    end

    test "an expired blocker for a closed ticket can be mooted", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{decision: decision}} =
               request(pid, %{"question" => "Should closed ticket be deployed?", "blocking" => true})

      assert {:ok, %{decision: expired}} =
               DecisionStore.expire(
                 decision.decision_id,
                 "agent_not_running",
                 [now: DateTime.add(decision.created_at, 600, :second)],
                 pid
               )

      assert expired.decision_status == :expired

      assert {:ok, %{status: :accepted, decision: mooted}} =
               DecisionStore.moot(
                 decision.decision_id,
                 %{"reason_class" => "ticket_closed", "reason" => "The ticket is closed."},
                 [actor: %{kind: :operator, id: "dashboard"}],
                 pid
               )

      assert mooted.decision_status == :moot
      assert mooted.answer == nil

      assert {:ok, %{decisions: [], total: 0}} =
               DecisionStore.retained_query(
                 %{limit: 25, cursor: nil, lifecycle: :open, search: nil, ticket: nil},
                 pid
               )
    end

    test "moot requires a reason class and is write-gated", %{dir: dir} do
      pid = start_store!(dir)
      opts = [actor: %{kind: :operator, id: "dashboard"}]
      assert {:ok, %{decision: decision}} = request(pid, %{"question" => "Void?", "blocking" => false})

      assert {:error, {:moot_invalid, {:reason_class, :missing}}} =
               DecisionStore.moot(decision.decision_id, %{}, opts, pid)

      :sys.replace_state(pid, &%{&1 | writable?: false, health: {:corrupt, 1, :test}})

      assert {:error, {:store_unavailable, {:corrupt, 1, :test}}} =
               DecisionStore.moot(decision.decision_id, %{"reason_class" => "ticket_closed"}, opts, pid)
    end

    # #2711: a decided answer that never reached an agent can be withdrawn. The
    # delivered case stays refused; see `Aiur.DecisionWithdrawalTest`.
    test "moot withdraws a decided answer that was never delivered", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{decision: decision}} =
               request(pid, %{
                 "question" => "Push or hold?",
                 "blocking" => false,
                 "options" => [%{"id" => "push", "label" => "Push"}]
               })

      assert {:ok, %{decision: answered}} =
               answer(pid, decision.decision_id, %{
                 "idempotency_key" => "answer",
                 "expected_version" => 1,
                 "option_id" => "push"
               })

      assert answered.decision_status == :decided
      refute Decision.delivered?(answered)

      assert {:ok, %{status: :accepted, decision: mooted}} =
               DecisionStore.moot(decision.decision_id, %{"reason_class" => "ticket_closed"}, [actor: %{kind: :operator, id: "dashboard"}], pid)

      assert mooted.decision_status == :moot
      assert mooted.answer == answered.answer
    end
  end
end
