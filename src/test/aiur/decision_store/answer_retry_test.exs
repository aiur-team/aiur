Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.DecisionStore.AnswerRetryTest do
  use Aiur.DecisionStoreCase, async: false

  describe "answer outbox" do
    # Both halves of this test used to be claims about the passage of time: that
    # the first store had *not* dispatched (a 100 ms silence) and that the
    # restarted store had reconciled exactly once (a 1 s deadline over an
    # unbounded boot — log replay, projection and the dispatch task supervisor —
    # followed by another 100 ms silence). Neither silence observes the
    # exactly-once property the test exists to prove, and both verdicts move
    # with machine load, which is why this failed in `coverage (1/4)` at CI
    # concurrency while passing in isolation.
    #
    # Both are now assertions on state and on the reconciliation pass's own
    # report (`DecisionPubSub.subscribe_dispatches_reconciled/0`): the pass
    # names every dispatch it scheduled, so "exactly one" is read off the
    # payload rather than inferred from a quiet mailbox, and nothing here is
    # timed.
    test "restart reconciles a persisted answer that was not yet dispatched", %{dir: dir} do
      parent = self()

      # The reconciliation report is a best-effort broadcast: without a PubSub
      # server it is silently dropped, and this test would then wait for a
      # message that can never come. Fail on the missing dependency instead.
      assert is_pid(Process.whereis(Aiur.PubSub)), "Aiur.PubSub must be running to observe reconciliation"
      :ok = DecisionPubSub.subscribe_dispatches_reconciled()

      never = fn _decision, _opts -> send(parent, :old_dispatch) end
      pid1 = start_store!(dir, dispatcher: never, dispatch_delay_ms: 5_000, reconcile_delay_ms: 5_000)
      assert {:ok, %{decision: decision}} = request(pid1, answerable_request("answer-restart"))

      payload = %{"idempotency_key" => "restart-1", "expected_version" => 1, "custom_response" => "Proceed"}
      assert {:ok, %{status: :accepted, action: action}} = answer(pid1, decision.decision_id, payload)

      # The answer is durable but undelivered: that is the state the restart has
      # to recover from, and asserting it directly is what the 100 ms silence
      # was standing in for.
      assert {:ok, persisted} = DecisionStore.get(decision.decision_id, pid1)
      assert persisted.delivery_status == :pending
      assert persisted.dispatch_attempts == []
      GenServer.stop(pid1)
      refute_received :old_dispatch

      dispatcher = fn replayed, opts ->
        send(parent, {:reconciled, replayed.answer.action_id, opts[:attempt_id]})
        {:ok, %{status: :accepted, item: %{id: 77}}}
      end

      pid2 = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0, reconcile_delay_ms: 0)

      # The boot reconciliation pass is scheduled unconditionally by
      # `handle_continue(:schedule_reconciliation, …)`, so this report is
      # guaranteed to arrive; the wait is on the event, not on a duration long
      # enough to cover a loaded runner's boot.
      assert_receive {:decision_dispatches_reconciled, %{store: ^pid2, fences: fences, dispatched: dispatched}},
                     @reconcile_report_timeout_ms

      # `fences` is what the pass considered, `dispatched` what it scheduled.
      # Both are needed: on its own an empty `dispatched` cannot distinguish
      # "replay lost the decision" from "the pass saw it and declined".
      assert fences == 1
      assert [%{decision_id: reconciled_id, action_id: reconciled_action_id, kind: :dispatch}] = dispatched
      assert reconciled_id == decision.decision_id
      assert reconciled_action_id == action.action_id

      settled = wait_for_decision(pid2, decision.decision_id, &(&1.delivery_status == :queued))
      assert [attempt] = settled.dispatch_attempts
      assert attempt.status == :queued

      # The dispatcher sends before it returns, and the store only reaches
      # `:queued` after it returns, so this message is already in the mailbox:
      # a zero-timeout check, not a race.
      assert_received {:reconciled, ^reconciled_action_id, _attempt_id}
      refute_received {:reconciled, _, _}
    end

    test "transient dispatch failure is retried after request enrichment", %{dir: dir} do
      parent = self()
      counter = :counters.new(1, [])

      dispatcher = fn _decision, opts ->
        :ok = :counters.add(counter, 1, 1)
        attempt = :counters.get(counter, 1)
        send(parent, {:attempted, attempt, opts[:attempt_id]})

        if attempt == 1,
          do: {:error, :unavailable},
          else: {:ok, %{status: :accepted, item: %{id: 88}}}
      end

      dispatch_scheduler = fn recipient, message, delay_ms ->
        send(parent, {:retry_scheduled, recipient, message, delay_ms})
        make_ref()
      end

      pid =
        start_store!(dir,
          dispatcher: dispatcher,
          dispatch_delay_ms: 0,
          reconcile_delay_ms: 0,
          retry_delays_ms: [0],
          dispatch_scheduler: dispatch_scheduler
        )

      assert_receive {:retry_scheduled, ^pid, {:reconcile_dispatches, []}, 0}, 2_000
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-retry-enrichment"))
      payload = %{"idempotency_key" => "retry-1", "expected_version" => 1, "custom_response" => "Proceed"}
      assert {:ok, _result} = answer(pid, decision.decision_id, payload)

      assert_receive {:retry_scheduled, ^pid, first_dispatch, 0}, 2_000
      send(pid, first_dispatch)
      assert_receive {:attempted, 1, first_attempt}, 1_000
      assert_receive {:retry_scheduled, ^pid, scheduled_retry, 0}, 2_000

      patch = %{"context" => %{"short_summary" => "Context before retry"}}

      assert {:ok, %{status: :accepted, decision: enriched}} =
               enrich(pid, decision.decision_id, patch, 1)

      assert enriched.version == 2
      assert enriched.delivery_status == :failed
      assert Enum.map(enriched.dispatch_attempts, & &1.status) == [:failed]

      send(pid, scheduled_retry)
      assert_receive {:attempted, 2, second_attempt}, 1_000
      refute first_attempt == second_attempt

      settled = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))
      assert settled.version == 2
      assert Enum.map(settled.dispatch_attempts, & &1.status) == [:failed, :queued]
      assert hd(settled.dispatch_attempts).failure_reason_class == "orchestrator_unavailable"
    end

    # #2558 half one. A recorded answer whose delivery failed because the target
    # agent was momentarily unreachable used to sit at `failed` forever: the
    # class was not on the answer's retry ladder, and — being non-actionable —
    # it was not raised either, so the answer was dropped with no operator-
    # visible trace. The recorded answer must reach the agent without an
    # operator touching anything.
    test "an unreachable target is retried automatically without an operator retry", %{dir: dir} do
      parent = self()
      counter = :counters.new(1, [])
      original_log_file = Application.get_env(:aiur, :log_file)
      log_root = Path.join(dir, "target-failure-alert-log")
      Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))
      Aiur.TestSupport.put_runtime_state_dir!(log_root)

      on_exit(fn ->
        if original_log_file do
          Application.put_env(:aiur, :log_file, original_log_file)
        else
          Application.delete_env(:aiur, :log_file)
        end
      end)

      dispatcher = fn _decision, opts ->
        :ok = :counters.add(counter, 1, 1)
        attempt = :counters.get(counter, 1)
        send(parent, {:target_attempt, attempt, opts[:retry_failed]})

        if attempt == 1,
          do: {:error, :no_running_agent},
          else: {:ok, %{status: :accepted, item: %{id: 89}}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0, retry_delays_ms: [0])
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-explicit-retry"))
      payload = %{"idempotency_key" => "retry-2", "expected_version" => 1, "custom_response" => "Proceed"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, payload)

      assert_receive {:target_attempt, 1, false}, 1_000

      # The bounded ladder — not an operator — schedules the second attempt.
      assert_receive {:target_attempt, 2, false}, 1_000

      settled = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))
      assert Enum.map(settled.dispatch_attempts, & &1.status) == [:failed, :queued]
      assert List.first(settled.dispatch_attempts).failure_reason_class == "target_agent_unavailable"

      topic = "ticket.979.agent.attention.decision-delivery-#{String.replace(action.action_id, "_", "-")}"

      # Recovered before the ladder was spent, so nothing is left demanding
      # operator attention (#2419's non-actionable suppression still holds
      # while automatic recovery is still possible).
      assert case_attention_alerts(log_root, topic) == []
    end

    # #2558 half one, the other acceptance branch: when the bounded ladder is
    # spent the answer really is stuck, so it must be raised. The
    # non-actionable suppression that keeps `target_agent_unavailable` off the
    # feed is what made this failure mode invisible in the first place.
    test "an exhausted delivery ladder raises instead of going quiet", %{dir: dir} do
      parent = self()
      counter = :counters.new(1, [])
      original_log_file = Application.get_env(:aiur, :log_file)
      log_root = Path.join(dir, "target-exhausted-alert-log")
      Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))
      Aiur.TestSupport.put_runtime_state_dir!(log_root)

      on_exit(fn ->
        if original_log_file do
          Application.put_env(:aiur, :log_file, original_log_file)
        else
          Application.delete_env(:aiur, :log_file)
        end
      end)

      dispatcher = fn _decision, _opts ->
        :ok = :counters.add(counter, 1, 1)
        send(parent, {:exhausted_attempt, :counters.get(counter, 1)})
        {:error, :no_running_agent}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0, retry_delays_ms: [0])
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-exhausted-retry"))
      payload = %{"idempotency_key" => "retry-3", "expected_version" => 1, "custom_response" => "Proceed"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, payload)

      assert_receive {:exhausted_attempt, 1}, 1_000
      assert_receive {:exhausted_attempt, 2}, 1_000

      # A one-rung ladder is spent after the retry: no third attempt, so the
      # bound holds and there is no retry storm.
      refute_receive {:exhausted_attempt, _}, 200

      failed = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :failed))
      assert length(failed.dispatch_attempts) == 2

      topic = "ticket.979.agent.attention.decision-delivery-#{String.replace(action.action_id, "_", "-")}"

      assert [%{"needs_attention" => true} = alert] = case_attention_alerts(log_root, topic)
      assert alert["reason"] =~ action.action_id
      assert alert["reason"] =~ "exhausted its bounded delivery retries"
    end

    test "projection repair failure after answer append suppresses dispatch", %{dir: dir} do
      parent = self()
      dispatcher = fn _decision, _opts -> send(parent, :unexpected_dispatch) end
      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-repair"))

      File.chmod!(dir, 0o500)
      on_exit(fn -> File.chmod!(dir, 0o700) end)

      payload = %{"idempotency_key" => "repair-1", "expected_version" => 1, "custom_response" => "Proceed"}
      assert {:ok, %{status: :accepted}} = answer(pid, decision.decision_id, payload)
      assert {:projection_stale, %DateTime{}} = DecisionStore.health(pid)
      refute_receive :unexpected_dispatch, 100
    end

    test "background lifecycle append failure stays scoped and can be retried", %{dir: dir} do
      parent = self()
      reservation_count = :counters.new(1, [])
      original_log_file = Application.get_env(:aiur, :log_file)
      log_root = Path.join(dir, "append-failure-alert-log")
      Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))
      Aiur.TestSupport.put_runtime_state_dir!(log_root)

      on_exit(fn ->
        if original_log_file do
          Application.put_env(:aiur, :log_file, original_log_file)
        else
          Application.delete_env(:aiur, :log_file)
        end
      end)

      event_id_reserver = fn ->
        :ok = :counters.add(reservation_count, 1, 1)
        reservation = :counters.get(reservation_count, 1)
        send(parent, {:lifecycle_reservation, reservation})

        if reservation == 2,
          do: {:error, :not_durable},
          else: IdGenerator.reserve_durable_id()
      end

      dispatcher = fn _decision, _opts ->
        send(parent, :background_dispatch)
        {:ok, %{status: :accepted, item: %{id: 96}}}
      end

      pid =
        start_store!(dir,
          dispatcher: dispatcher,
          dispatch_delay_ms: 0,
          retry_delays_ms: [],
          event_id_reserver: event_id_reserver
        )

      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-append-failure"))
      payload = %{"idempotency_key" => "append-failure-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, payload)
      assert_receive {:lifecycle_reservation, 1}, 1_000
      assert_receive :background_dispatch, 1_000
      assert_receive {:lifecycle_reservation, 2}, 1_000

      assert DecisionStore.health(pid) == :writable
      assert {:ok, %{status: :accepted}} = request(pid, %{"question" => "Independent?", "blocking" => false})

      topic =
        "ticket.979.agent.attention.decision-lifecycle-persistence-#{String.replace(action.action_id, "_", "-")}"

      assert [%{"topic" => ^topic}] = case_attention_alerts(log_root, topic)

      assert {:ok, :scheduled} = DecisionStore.retry_dispatch(decision.decision_id, action.action_id, pid)
      assert_receive :background_dispatch, 1_000
      assert_receive {:lifecycle_reservation, 3}, 1_000
      _queued = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))
      assert case_attention_alerts(log_root, topic) == []
    end

    test "boot reconciliation tolerates failed delivery without an attempt", %{dir: dir} do
      pid =
        start_store!(dir,
          dispatch_delay_ms: 5_000,
          reconcile_delay_ms: 5_000,
          terminal_ticket_resolver: fn _identifiers -> {:ok, MapSet.new()} end
        )

      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-empty-failure"))
      payload = %{"idempotency_key" => "empty-failure-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, _result} = answer(pid, decision.decision_id, payload)
      assert {:ok, current} = DecisionStore.get(decision.decision_id, pid)

      malformed = %{current | delivery_status: :failed, dispatch_attempts: []}
      state = :sys.get_state(pid)
      state = %{state | current: Map.put(state.current, decision.decision_id, malformed)}

      assert {:noreply, _state} = DecisionStore.handle_continue(:schedule_reconciliation, state)
    end
  end
end
