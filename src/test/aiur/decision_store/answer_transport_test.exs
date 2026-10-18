Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.DecisionStore.AnswerTransportTest do
  use Aiur.DecisionStoreCase, async: false

  describe "answer outbox" do
    test "correlated handoff and consumption append idempotent transport evidence", %{dir: dir} do
      parent = self()

      dispatcher = fn _decision, opts ->
        send(parent, {:queue_attempt, opts[:attempt_id]})
        {:ok, %{status: :accepted, item: %{id: 91}}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-transport"))
      payload = %{"idempotency_key" => "transport-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, payload)
      assert_receive {:queue_attempt, attempt_id}, 1_000
      _queued = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))

      item = correlated_queue_item(decision, action, attempt_id, 91)
      assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)
      assert {:ok, :duplicate} = DecisionStore.record_delivery(item, pid)

      assert :ok = DecisionStore.record_transport_async(:consumed, item, nil, pid)
      consumed = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :consumed))
      assert consumed.decision_status == :decided

      assert :ok = DecisionStore.record_transport_async(:consumed, item, nil, pid)
      Process.sleep(20)
      assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
      assert Enum.count(audit, &(audit_type(&1) == :delivered)) == 1
      assert Enum.count(audit, &(audit_type(&1) == :consumed)) == 1
    end

    test "delivery adopts queue acceptance when handoff wins the settlement race", %{dir: dir} do
      parent = self()

      dispatcher = fn dispatched, opts ->
        item = correlated_queue_item(dispatched, dispatched.answer, opts[:attempt_id], 97)
        send(parent, {:handoff_before_settlement, self(), item})

        receive do
          :release_settlement -> {:ok, %{status: :accepted, item: item}}
        end
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-handoff-race"))
      payload = %{"idempotency_key" => "handoff-race-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, _result} = answer(pid, decision.decision_id, payload)
      assert_receive {:handoff_before_settlement, dispatcher_pid, item}, 1_000

      assert {:ok, :accepted} = DecisionStore.validate_delivery(item, pid)
      # The gate adopts the queue acceptance and marks the handoff (#2711), so
      # a withdrawal cannot race the send that follows.
      assert {:ok, before_delivery} = DecisionStore.get(decision.decision_id, pid)
      assert [%{status: :queued, handed_off_at: %DateTime{}, attempt_id: handed_off_attempt}] = before_delivery.dispatch_attempts
      assert handed_off_attempt == item.correlation.attempt_id

      assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)
      delivered = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :delivered))
      assert [%{attempt_id: attempt_id, status: :delivered}] = delivered.dispatch_attempts
      assert attempt_id == item.correlation.attempt_id

      send(dispatcher_pid, :release_settlement)
      Process.sleep(50)
      assert {:ok, settled} = DecisionStore.get(decision.decision_id, pid)
      assert [%{status: :delivered}] = settled.dispatch_attempts
    end

    test "delivery adopts restoration when a failed retry wins the settlement race", %{dir: dir} do
      parent = self()
      dispatches = :counters.new(1, [])

      dispatcher = fn dispatched, opts ->
        :ok = :counters.add(dispatches, 1, 1)

        case :counters.get(dispatches, 1) do
          1 ->
            item = correlated_queue_item(dispatched, dispatched.answer, opts[:attempt_id], 98)
            send(parent, {:initial_retry_item, item})
            {:ok, %{status: :accepted, item: item}}

          2 ->
            send(parent, {:retry_before_settlement, self()})

            receive do
              {:release_retry_settlement, item} -> {:ok, %{status: :retried, item: item}}
            end
        end
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0, retry_delays_ms: [])
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-retry-handoff-race"))
      payload = %{"idempotency_key" => "retry-handoff-race-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, payload)
      assert_receive {:initial_retry_item, item}, 1_000
      _queued = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))

      assert :ok = DecisionStore.record_transport_async(:failed, item, :send_failed, pid)
      _failed = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :failed))
      assert {:ok, :scheduled} = DecisionStore.retry_dispatch(decision.decision_id, action.action_id, pid)
      assert_receive {:retry_before_settlement, dispatcher_pid}, 1_000

      assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)
      delivered = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :delivered))
      assert [%{status: :delivered}] = delivered.dispatch_attempts

      send(dispatcher_pid, {:release_retry_settlement, Map.put(item, :status, :pending)})
      Process.sleep(50)
      assert {:ok, settled} = DecisionStore.get(decision.decision_id, pid)
      assert [%{status: :delivered}] = settled.dispatch_attempts
    end

    test "batched queue settlement records every item through one store message", %{dir: dir} do
      parent = self()
      ids = :counters.new(1, [])

      dispatcher = fn dispatched, opts ->
        :ok = :counters.add(ids, 1, 1)
        item_id = 100 + :counters.get(ids, 1)
        item = correlated_queue_item(dispatched, dispatched.answer, opts[:attempt_id], item_id)
        send(parent, {:batch_queue_item, dispatched.decision_id, item})
        {:ok, %{status: :accepted, item: item}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)

      decisions =
        for source <- ["batch-one", "batch-two"] do
          assert {:ok, %{decision: decision}} = request(pid, answerable_request(source))
          payload = %{"idempotency_key" => source, "expected_version" => 1, "option_id" => "ship"}
          assert {:ok, _result} = answer(pid, decision.decision_id, payload)
          decision
        end

      items_by_decision =
        for _index <- 1..2, into: %{} do
          assert_receive {:batch_queue_item, decision_id, item}, 1_000
          {decision_id, item}
        end

      items =
        for decision <- decisions do
          item = Map.fetch!(items_by_decision, decision.decision_id)
          _queued = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))
          assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)
          item
        end

      assert :ok = DecisionStore.record_transport_batch_async(:consumed, items, nil, pid)

      for decision <- decisions do
        consumed = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :consumed))
        assert [%{status: :consumed}] = consumed.dispatch_attempts
      end
    end

    test "target agent explicitly acknowledges and resolves with duplicate suppression", %{dir: dir} do
      parent = self()

      dispatcher = fn _decision, opts ->
        send(parent, {:lifecycle_attempt, opts[:attempt_id]})
        {:ok, %{status: :accepted, item: %{id: 93}}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-lifecycle"))
      decision_id = decision.decision_id
      answer_payload = %{"idempotency_key" => "lifecycle-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, answer_payload)
      assert_receive {:lifecycle_attempt, attempt_id}, 1_000
      _queued = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))
      item = correlated_queue_item(decision, action, attempt_id, 93)
      assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)

      assert {:ok, %{decision: advanced}} =
               request(
                 pid,
                 answerable_request("answer-lifecycle")
                 |> Map.merge(%{"question" => "Deploy now with the latest context?", "version" => 2})
               )

      assert advanced.version == 2
      assert Aiur.Decision.active_answer(advanced).action_id == action.action_id

      :ok = Exchange.subscribe("ticket.979.agent.decision.acknowledged")
      :ok = Exchange.subscribe("ticket.979.agent.decision.resolved")

      lifecycle_payload = %{
        "decision_id" => decision.decision_id,
        "action_id" => action.action_id,
        "expected_version" => 1,
        "detail" => "Observed and applying the answer"
      }

      lifecycle_opts = [
        ticket_identifier: "979",
        actor: %{kind: :agent, id: "ticket-agent"},
        source: %{agent_id: "codex", session_id: "session-1", invocation_id: "call-1"}
      ]

      assert {:ok, %{status: :accepted, decision_status: :acknowledged}} =
               DecisionStore.agent_lifecycle(:acknowledged, lifecycle_payload, lifecycle_opts, pid)

      assert_receive {:event,
                      %{
                        "decision_id" => ^decision_id,
                        topic: "ticket.979.agent.decision.acknowledged",
                        digest_source: :orchestrator
                      } = acknowledged},
                     500

      assert EventsDigest.render([acknowledged], "979") =~ "ticket.979.agent.decision.acknowledged"

      assert {:ok, %{status: :duplicate}} =
               DecisionStore.agent_lifecycle(:acknowledged, lifecycle_payload, lifecycle_opts, pid)

      refute_receive {:event, %{"decision_id" => ^decision_id, topic: "ticket.979.agent.decision.acknowledged"}}, 100

      reconnected_opts =
        Keyword.put(lifecycle_opts, :source, %{
          agent_id: "codex",
          session_id: "session-2",
          invocation_id: "call-2"
        })

      assert {:ok, %{status: :duplicate}} =
               DecisionStore.agent_lifecycle(:acknowledged, lifecycle_payload, reconnected_opts, pid)

      conflicting = Map.put(lifecycle_payload, "detail", "Different acknowledgement")

      assert {:error, {:conflict, {:already_acknowledged, action_id}}} =
               DecisionStore.agent_lifecycle(:acknowledged, conflicting, lifecycle_opts, pid)

      assert action_id == action.action_id

      resolved_payload = Map.put(lifecycle_payload, "detail", "Applied successfully")

      assert {:ok, %{status: :accepted, decision_status: :resolved}} =
               DecisionStore.agent_lifecycle(:resolved, resolved_payload, lifecycle_opts, pid)

      assert_receive {:event, %{"decision_id" => ^decision_id, topic: "ticket.979.agent.decision.resolved"}}, 500
      assert {:ok, current} = DecisionStore.get(decision.decision_id, pid)
      assert current.acknowledgement.detail == "Observed and applying the answer"
      assert current.acknowledgement.source.session_id == "session-1"
      assert current.resolution.detail == "Applied successfully"

      assert {:ok, %{status: :duplicate, action: ^action}} =
               answer(pid, decision.decision_id, answer_payload)

      changed_answer = Map.put(answer_payload, "option_id", nil) |> Map.put("custom_response", "Different")

      assert {:error, {:conflict, {:idempotency_conflict, action_id}}} =
               answer(pid, decision.decision_id, changed_answer)

      assert action_id == action.action_id
    end

    test "agent lifecycle rejects wrong correlation and illegal ordering without append", %{dir: dir} do
      parent = self()

      dispatcher = fn _decision, opts ->
        send(parent, {:invalid_lifecycle_attempt, opts[:attempt_id]})
        {:ok, %{status: :accepted, item: %{id: 94}}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-lifecycle-invalid"))
      answer_payload = %{"idempotency_key" => "lifecycle-2", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, answer_payload)
      assert_receive {:invalid_lifecycle_attempt, attempt_id}, 1_000
      _queued = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))

      payload = %{"decision_id" => decision.decision_id, "action_id" => action.action_id, "expected_version" => 1}
      opts = [ticket_identifier: "979", actor: %{kind: :agent, id: "agent-session-2"}]

      assert {:error, {:invalid_transition, :not_delivered}} =
               DecisionStore.agent_lifecycle(:acknowledged, payload, opts, pid)

      assert {:error, {:invalid_transition, :not_acknowledged}} =
               DecisionStore.agent_lifecycle(:resolved, payload, opts, pid)

      assert {:error, {:conflict, {:ticket_mismatch, "980", "979"}}} =
               DecisionStore.agent_lifecycle(:acknowledged, payload, Keyword.put(opts, :ticket_identifier, "980"), pid)

      wrong_action = Map.put(payload, "action_id", "act_wrong")

      assert {:error, {:conflict, {:action_mismatch, "act_wrong", _current}}} =
               DecisionStore.agent_lifecycle(:acknowledged, wrong_action, opts, pid)

      stale = Map.put(payload, "expected_version", 2)

      assert {:error, {:conflict, {:stale_version, 2, 1}}} =
               DecisionStore.agent_lifecycle(:acknowledged, stale, opts, pid)

      item = correlated_queue_item(decision, action, attempt_id, 94)
      assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)
      assert {:ok, %{status: :accepted}} = DecisionStore.agent_lifecycle(:acknowledged, payload, opts, pid)

      assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
      assert Enum.count(audit, &(audit_type(&1) == :acknowledged)) == 1
      refute Enum.any?(audit, &(audit_type(&1) == :resolved))
    end
  end
end
