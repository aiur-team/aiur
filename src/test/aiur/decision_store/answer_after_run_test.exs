Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.DecisionStore.AnswerAfterRunTest do
  use Aiur.DecisionStoreCase, async: false

  describe "answer after the asking run ended (#2713)" do
    # A blocking Command ends its agent's run, so the answer arrives when no
    # worker runs the ticket. The fake dispatcher models `OperatorMessages`:
    # it refuses with `:no_running_agent` until a worker runs the ticket, and
    # then reports what the worker received.
    defp worker_dispatcher(parent, worker) do
      fn decision, opts ->
        if Agent.get(worker, & &1) do
          item_id = System.unique_integer([:positive])
          send(parent, {:worker_received, decision.decision_id, Decision.active_answer(decision).action_id, opts[:attempt_id]})
          send(parent, {:worker_queue_item, decision.decision_id, item_id})
          {:ok, %{status: :accepted, item: %{id: item_id}}}
        else
          send(parent, {:no_worker, decision.decision_id})
          {:error, :no_running_agent}
        end
      end
    end

    defp start_worker_flag!, do: start_supervised!({Agent, fn -> false end})

    defp start_worker!(worker), do: Agent.update(worker, fn _running -> true end)

    defp two_option_request(source_id) do
      %{
        "question" => "Which rollout should this ticket use?",
        "blocking" => true,
        "source_id" => source_id,
        "options" => [%{"id" => "ship", "label" => "Ship it"}, %{"id" => "hold", "label" => "Hold it"}]
      }
    end

    defp assert_no_worker_attempts(decision_id, count) do
      for _attempt <- 1..count, do: assert_receive({:no_worker, ^decision_id}, 1_000)
    end

    test "an answer with no running agent stays pending for the next session", %{dir: dir} do
      worker = start_worker_flag!()

      pid =
        start_store!(dir,
          dispatcher: worker_dispatcher(self(), worker),
          dispatch_delay_ms: 0,
          retry_delays_ms: [0, 0, 0]
        )

      assert {:ok, %{decision: decision}} = request(pid, two_option_request("resume-after-answer"))
      id = decision.decision_id
      assert {:ok, blocked} = DecisionStore.blocked_ticket_ids(pid)
      assert MapSet.member?(blocked, "979")

      payload = %{"idempotency_key" => "resume-1", "expected_version" => 1, "option_id" => "ship"}
      later = DateTime.add(DateTime.utc_now(), 60, :second)
      assert {:ok, _answer} = answer(pid, id, payload, now: later)

      # Recording the answer clears the dispatch hold at once.
      assert {:ok, released} = DecisionStore.blocked_ticket_ids(pid)
      refute MapSet.member?(released, "979")

      # No worker runs the ticket. This is a normal wait for its next session,
      # not a failed delivery that should spend the retry ladder.
      assert_no_worker_attempts(id, 1)
      pending = wait_for_decision(pid, id, & &1.pending_for_session?)
      assert pending.delivery_status == :pending
      refute_receive {:no_worker, ^id}, 100

      # Queue redelivery stays disabled; dispatch carries the answer in its
      # launch prompt instead.
      start_worker!(worker)
      assert :ok = DecisionStore.deliver_pending_answers("979", pid)
      refute_receive {:worker_received, ^id, _action_id, _attempt_id}, 200

      # A worker of another ticket does not receive it.
      assert :ok = DecisionStore.deliver_pending_answers("980", pid)
      refute_receive {:worker_received, _id, _action_id, _attempt_id}, 100
    end

    test "a restart preserves the pending answer without retrying it", %{dir: dir} do
      worker = start_worker_flag!()
      pid = start_store!(dir, dispatcher: worker_dispatcher(self(), worker), dispatch_delay_ms: 0, retry_delays_ms: [])

      assert {:ok, %{decision: decision}} = request(pid, two_option_request("resume-after-restart"))
      id = decision.decision_id
      payload = %{"idempotency_key" => "restart-1", "expected_version" => 1, "option_id" => "hold"}
      assert {:ok, _answer} = answer(pid, id, payload)
      assert_no_worker_attempts(id, 1)
      _pending = wait_for_decision(pid, id, & &1.pending_for_session?)

      GenServer.stop(pid)

      # Boot does not schedule a retry for an answer awaiting its next session.
      pid2 =
        start_store!(dir,
          dispatcher: worker_dispatcher(self(), worker),
          dispatch_delay_ms: 0,
          reconcile_delay_ms: 0,
          retry_delays_ms: []
        )

      refute_receive {:no_worker, ^id}, 100
      _pending = wait_for_decision(pid2, id, & &1.pending_for_session?)
      refute_receive {:no_worker, ^id}, 100

      start_worker!(worker)
      assert :ok = DecisionStore.deliver_pending_answers("979", pid2)
      assert :ok = DecisionStore.deliver_pending_answers("979", pid2)
      refute_receive {:worker_received, ^id, _action_id, _attempt_id}, 200
    end

    test "a revision leaves only its newest answer pending for the next session", %{dir: dir} do
      worker = start_worker_flag!()
      pid = start_store!(dir, dispatcher: worker_dispatcher(self(), worker), dispatch_delay_ms: 0, retry_delays_ms: [])

      assert {:ok, %{decision: decision}} = request(pid, two_option_request("resume-after-revision"))
      id = decision.decision_id
      payload = %{"idempotency_key" => "revision-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: first}} = answer(pid, id, payload)
      assert_no_worker_attempts(id, 1)
      _pending = wait_for_decision(pid, id, & &1.pending_for_session?)

      assert {:ok, %{action: revision}} =
               DecisionStore.revise(
                 id,
                 %{
                   "idempotency_key" => "revision-2",
                   "expected_version" => 1,
                   "expected_action_id" => first.action_id,
                   "expected_revision_sequence" => 0,
                   "option_id" => "hold",
                   "rationale" => "Changed direction before any agent saw the answer."
                 },
                 [actor: %{kind: :operator, id: "operator-1"}],
                 pid
               )

      pending =
        wait_for_decision(pid, id, fn current ->
          current.active_action_id == revision.action_id and current.pending_for_session?
        end)

      assert pending.active_action_id == revision.action_id

      start_worker!(worker)
      assert :ok = DecisionStore.deliver_pending_answers("979", pid)
      refute_receive {:worker_received, ^id, _action_id, _attempt_id}, 200
    end

    test "several unanswered deliveries stay pending without retries", %{dir: dir} do
      worker = start_worker_flag!()
      pid = start_store!(dir, dispatcher: worker_dispatcher(self(), worker), dispatch_delay_ms: 0, retry_delays_ms: [])

      questions = ["Pick the database engine?", "Name the release branch?", "Choose the rollout region?"]

      ids =
        for {question, index} <- Enum.with_index(questions) do
          payload = %{two_option_request("ordered-#{index}") | "question" => question}
          assert {:ok, %{decision: decision}} = request(pid, payload)
          decision.decision_id
        end

      # Answer against the store's own key order, so map order cannot pass.
      answer_order = Enum.sort(ids, :desc)

      for id <- answer_order do
        assert {:ok, _answer} = answer(pid, id, %{"idempotency_key" => "order-#{id}", "expected_version" => 1, "option_id" => "ship"})
        assert_no_worker_attempts(id, 1)
        pending = wait_for_decision(pid, id, & &1.pending_for_session?)
        assert pending.delivery_status == :pending
      end

      start_worker!(worker)
      assert :ok = DecisionStore.deliver_pending_answers("979", pid)
      refute_receive {:worker_received, _id, _action_id, _attempt_id}, 200
      for id <- answer_order, do: assert(wait_for_decision(pid, id, & &1.pending_for_session?).pending_for_session?)
    end

    test "an answer the provider confirmed is not sent again after its turn failed", %{dir: dir} do
      worker = start_worker_flag!()
      pid = start_store!(dir, dispatcher: worker_dispatcher(self(), worker), dispatch_delay_ms: 0, retry_delays_ms: [])
      start_worker!(worker)

      assert {:ok, %{decision: decision}} = request(pid, two_option_request("delivered-then-failed"))
      id = decision.decision_id
      payload = %{"idempotency_key" => "confirmed-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, id, payload)
      assert_receive {:worker_received, ^id, _action_id, attempt_id}, 1_000
      assert_receive {:worker_queue_item, ^id, item_id}, 1000
      queued = wait_for_decision(pid, id, &(&1.delivery_status == :queued))

      # The provider confirms the answer, then the worker's turn fails.
      item = correlated_queue_item(queued, action, attempt_id, item_id)
      assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)
      assert :ok = DecisionStore.record_transport_async(:failed, item, :send_failed, pid)

      failed = wait_for_decision(pid, id, &(&1.delivery_status == :failed))
      assert [%{status: :failed, delivered_at: %DateTime{}}] = Decision.active_dispatch_attempts(failed)

      # The next worker must not receive it a second time.
      assert :ok = DecisionStore.deliver_pending_answers("979", pid)
      refute_receive {:worker_received, ^id, _action_id, _attempt_id}, 300
    end

    test "a mooted answer is not retried while awaiting its next session", %{dir: dir} do
      worker = start_worker_flag!()
      pid = start_store!(dir, dispatcher: worker_dispatcher(self(), worker), dispatch_delay_ms: 0, retry_delays_ms: [])

      assert {:ok, %{decision: decision}} = request(pid, two_option_request("moot-before-spawn"))
      id = decision.decision_id
      assert {:ok, _answer} = answer(pid, id, %{"idempotency_key" => "moot-1", "expected_version" => 1, "option_id" => "ship"})
      assert_no_worker_attempts(id, 1)
      _pending = wait_for_decision(pid, id, & &1.pending_for_session?)

      assert {:ok, %{status: :accepted}} =
               DecisionStore.moot(id, %{"reason_class" => "operator_changed_direction"}, [actor: %{kind: :executor, id: "executor"}], pid)

      start_worker!(worker)
      assert :ok = DecisionStore.deliver_pending_answers("979", pid)
      refute_receive {:worker_received, ^id, _action_id, _attempt_id}, 300
    end

    test "after a supersede only the newest answer remains pending for the next session", %{dir: dir} do
      worker = start_worker_flag!()
      pid = start_store!(dir, dispatcher: worker_dispatcher(self(), worker), dispatch_delay_ms: 0, retry_delays_ms: [])

      assert {:ok, %{decision: decision}} = request(pid, two_option_request("supersede-before-spawn"))
      id = decision.decision_id

      assert {:ok, %{action: _first}} =
               answer(pid, id, %{"idempotency_key" => "supersede-1", "expected_version" => 1, "option_id" => "ship"})

      assert_no_worker_attempts(id, 1)
      _pending = wait_for_decision(pid, id, & &1.pending_for_session?)

      assert {:ok, %{action: newest}} =
               DecisionStore.supersede(
                 id,
                 %{"idempotency_key" => "supersede-2", "expected_version" => 1, "option_id" => "hold", "rationale" => "Changed direction."},
                 [actor: %{kind: :executor, id: "executor"}],
                 pid
               )

      pending = wait_for_decision(pid, id, &(&1.active_action_id == newest.action_id and &1.pending_for_session?))
      assert pending.active_action_id == newest.action_id

      start_worker!(worker)
      assert :ok = DecisionStore.deliver_pending_answers("979", pid)
      refute_receive {:worker_received, ^id, _action_id, _attempt_id}, 200
      refute_receive {:worker_received, ^id, _action_id, _attempt_id}, 300
    end

    test "an answer whose send failed after handoff is sent again once at the next spawn", %{dir: dir} do
      worker = start_worker_flag!()
      pid = start_store!(dir, dispatcher: worker_dispatcher(self(), worker), dispatch_delay_ms: 0, retry_delays_ms: [])
      start_worker!(worker)

      assert {:ok, %{decision: decision}} = request(pid, two_option_request("failed-after-handoff"))
      id = decision.decision_id
      payload = %{"idempotency_key" => "handoff-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, id, payload)
      assert_receive {:worker_received, ^id, _action_id, attempt_id}, 1_000
      assert_receive {:worker_queue_item, ^id, item_id}, 1000
      queued = wait_for_decision(pid, id, &(&1.delivery_status == :queued))

      # The delivery gate hands the answer to the worker, and the send fails
      # without a provider confirmation.
      item = correlated_queue_item(queued, action, attempt_id, item_id)
      assert {:ok, :accepted} = DecisionStore.validate_delivery(item, pid)
      assert :ok = DecisionStore.record_transport_async(:failed, item, :send_failed, pid)

      failed = wait_for_decision(pid, id, &(&1.delivery_status == :failed))
      assert [%{status: :failed, handed_off_at: %DateTime{}, delivered_at: nil}] = Decision.active_dispatch_attempts(failed)
      refute Decision.send_in_flight?(failed)

      # The next worker receives it exactly once, even if spawned twice.
      assert :ok = DecisionStore.deliver_pending_answers("979", pid)
      assert :ok = DecisionStore.deliver_pending_answers("979", pid)
      assert_receive {:worker_received, ^id, action_id, _attempt_id}, 1_000
      assert action_id == action.action_id
      _queued = wait_for_decision(pid, id, &(&1.delivery_status == :queued))
      assert :ok = DecisionStore.deliver_pending_answers("979", pid)
      refute_receive {:worker_received, ^id, _action_id, _attempt_id}, 300
    end

    test "an unanswered blocking Command sends nothing to a new worker", %{dir: dir} do
      worker = start_worker_flag!()
      pid = start_store!(dir, dispatcher: worker_dispatcher(self(), worker), dispatch_delay_ms: 0)

      assert {:ok, %{decision: decision}} = request(pid, two_option_request("resume-unanswered"))
      id = decision.decision_id
      start_worker!(worker)
      assert :ok = DecisionStore.deliver_pending_answers("979", pid)
      refute_receive {:worker_received, ^id, _action_id, _attempt_id}, 200
      refute_receive {:no_worker, ^id}, 0
    end
  end
end
