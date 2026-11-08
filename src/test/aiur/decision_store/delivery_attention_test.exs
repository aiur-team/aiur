Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.DecisionStore.DeliveryAttentionTest do
  use Aiur.DecisionStoreCase, async: false

  describe "answer outbox" do
    test "boot moots expired unanswered blockers for confirmed closed tickets", %{dir: dir} do
      resolver = fn identifiers ->
        assert Enum.sort(identifiers) == ["closed-42", "open-42"]
        {:ok, MapSet.new(["closed-42"])}
      end

      pid = start_store!(dir, terminal_ticket_resolver: resolver, dispatch_delay_ms: 60_000)

      assert {:ok, %{decision: decision}} =
               DecisionStore.request(
                 %{"question" => "Should this closed ticket proceed?", "blocking" => true},
                 [ticket: %{identifier: "closed-42", title: "Closed ticket", url: nil}, source: %{agent_id: "closed-boot-test", session_id: "session", event_id: nil}],
                 pid
               )

      assert {:ok, %{decision: open_decision}} =
               DecisionStore.request(
                 answerable_request("open-boot-test"),
                 [ticket: %{identifier: "open-42", title: "Open ticket", url: nil}, source: %{agent_id: "open-boot-test", session_id: "session", event_id: nil}],
                 pid
               )

      assert {:ok, %{decision: expired}} = DecisionStore.expire(decision.decision_id, "agent_not_running", [], pid)
      assert expired.decision_status == :expired

      assert {:ok, %{decision: open_expired}} =
               DecisionStore.expire(open_decision.decision_id, "agent_not_running", [], pid)

      assert open_expired.decision_status == :expired
      GenServer.stop(pid)

      pid = start_store!(dir, terminal_ticket_resolver: resolver, dispatch_delay_ms: 60_000)
      on_exit(fn -> Aiur.TestSupport.safe_stop(pid) end)

      mooted = wait_for_decision(pid, decision.decision_id, &(&1.decision_status == :moot))
      assert mooted.decision_status == :moot
      assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
      assert Enum.any?(audit, &match?(%{type: :decision_mooted, data: %{reason_class: "ticket_closed"}}, &1))

      still_answerable = wait_for_decision(pid, open_decision.decision_id, &(&1.decision_status == :expired))
      assert still_answerable.decision_status == :expired
      assert still_answerable.answer == nil

      assert {:ok, %{action: action, decision: answered}} =
               answer(
                 pid,
                 open_decision.decision_id,
                 %{"idempotency_key" => "answer-open-after-boot", "expected_version" => 1, "option_id" => "ship"}
               )

      assert action.selected_option_id == "ship"
      assert answered.decision_status == :decided

      assert {:ok, %{counts: %{blocking: 0}}} = DecisionStore.retained_counts(pid)
    end

    test "durable transport failure opens one stable attention and restoration resolves it", %{dir: dir} do
      parent = self()
      original_log_file = Application.get_env(:aiur, :log_file)
      log_root = Path.join(dir, "alert-log")
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
        send(parent, {:queue_attempt, opts[:attempt_id]})
        {:ok, %{status: :accepted, item: %{id: 92}}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-attention"))
      payload = %{"idempotency_key" => "attention-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, payload)
      assert_receive {:queue_attempt, attempt_id}, 1_000
      _queued = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))

      item = correlated_queue_item(decision, action, attempt_id, 92)
      assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)

      topic = "ticket.979.agent.attention.decision-delivery-#{String.replace(action.action_id, "_", "-")}"

      assert :ok = DecisionStore.record_transport_async(:failed, item, :send_failed, pid)
      failed = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :failed))
      assert List.last(failed.dispatch_attempts).failure_reason_class == "send_failed"
      assert [%{"topic" => ^topic}] = case_attention_alerts(log_root, topic)

      GenServer.stop(pid)

      pid2 =
        start_store!(dir,
          dispatcher: fn _decision, _opts -> {:error, :no_running_agent} end,
          terminal_ticket_resolver: fn _identifiers ->
            send(parent, {:failure_reprojection_started, self()})

            receive do
              :continue_failure_reprojection -> {:ok, MapSet.new()}
            end
          end
        )

      assert_receive {:failure_reprojection_started, reprojection_task}, 1_000

      assert [%{"topic" => ^topic}] = case_attention_alerts(log_root, topic)

      assert :ok = DecisionStore.record_transport_async(:restored, item, nil, pid2)
      # This call follows the cast from the same sender, so its reply is a barrier
      # for the restore projection and its synchronous alert-ledger append.
      assert {:ok, restored} = DecisionStore.get(decision.decision_id, pid2)
      assert restored.delivery_status == :queued

      # Let the delayed startup task run only after restoration has been
      # projected. It must re-read the current decision before re-raising its
      # boot snapshot, and this barrier waits until that check is complete.
      send(reprojection_task, :continue_failure_reprojection)
      assert :ok = DecisionStore.await_failure_attention_reprojection(pid2)
      assert AlertFeed.condition_state(topic, roots: [], log_roots: [log_root]) == :resolved
      assert case_attention_alerts(log_root, topic) == []
    end

    test "an absent agent leaves the answer pending without attention across restart",
         %{dir: dir} do
      original_log_file = Application.get_env(:aiur, :log_file)
      log_root = Path.join(dir, "absent-agent-alert-log")
      Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))
      Aiur.TestSupport.put_runtime_state_dir!(log_root)

      on_exit(fn ->
        if original_log_file do
          Application.put_env(:aiur, :log_file, original_log_file)
        else
          Application.delete_env(:aiur, :log_file)
        end
      end)

      dispatcher = fn _decision, _opts -> {:error, :no_running_agent} end
      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-absent-target"))
      payload = %{"idempotency_key" => "absent-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, payload)

      pending = wait_for_decision(pid, decision.decision_id, & &1.pending_for_session?)
      assert pending.delivery_status == :pending
      assert pending.dispatch_attempts == []

      topic =
        "ticket.979.agent.attention.decision-delivery-#{String.replace(action.action_id, "_", "-")}"

      # An absent agent is expected during a dispatch gap; retain the answer for
      # the next session without writing a delivery attention alert.
      assert case_attention_alerts(log_root, topic) == []

      # A listener restart retains the pending answer and does not retry it.
      GenServer.stop(pid)
      pid2 = start_store!(dir, dispatcher: fn _decision, _opts -> {:error, :no_running_agent} end)
      restored = wait_for_decision(pid2, decision.decision_id, & &1.pending_for_session?)
      assert restored.dispatch_attempts == []
      assert case_attention_alerts(log_root, topic) == []
    end

    test "a later target-agent-unavailable failure clears a previously raised delivery alert", %{dir: dir} do
      parent = self()
      counter = :counters.new(1, [])
      original_log_file = Application.get_env(:aiur, :log_file)
      log_root = Path.join(dir, "absent-agent-clears-alert-log")
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
        :counters.add(counter, 1, 1)
        attempt = :counters.get(counter, 1)
        send(parent, {:queue_attempt, attempt, opts[:attempt_id]})

        if attempt == 1 do
          {:ok, %{status: :accepted, item: %{id: 95}}}
        else
          {:error, :no_running_agent}
        end
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-absent-clear"))
      payload = %{"idempotency_key" => "absent-clear-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, payload)
      assert_receive {:queue_attempt, 1, attempt_id}, 1_000
      _queued = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))

      item = correlated_queue_item(decision, action, attempt_id, 95)
      topic = "ticket.979.agent.attention.decision-delivery-#{String.replace(action.action_id, "_", "-")}"

      # First attempt fails with a deliverable error: the delivery alert is raised.
      assert :ok = DecisionStore.record_transport_async(:failed, item, :send_failed, pid)
      _failed = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :failed))
      assert [%{"topic" => ^topic}] = case_attention_alerts(log_root, topic)

      # The agent disappears before the explicit retry. The answer becomes
      # pending for a future session, and the old failure alert is resolved.
      assert {:ok, :scheduled} = DecisionStore.retry_dispatch(decision.decision_id, action.action_id, pid)

      pending = wait_for_decision(pid, decision.decision_id, & &1.pending_for_session?)
      assert pending.delivery_status == :pending
      assert length(Decision.active_dispatch_attempts(pending)) == 1
      assert case_attention_alerts(log_root, topic) == []
    end

    test "an absent agent stays pending and visible on the decision surface", %{dir: dir} do
      dispatcher = fn _decision, _opts -> {:error, :no_running_agent} end
      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-absent-visible"))
      payload = %{"idempotency_key" => "absent-visible-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: _action}} = answer(pid, decision.decision_id, payload)
      _pending = wait_for_decision(pid, decision.decision_id, & &1.pending_for_session?)

      # The decision remains queryable and the answer stays pending for the next
      # session instead of looking like a failed delivery.
      assert {:ok, current} = DecisionStore.get(decision.decision_id, pid)
      assert current.delivery_status == :pending
      assert current.pending_for_session?
      assert current.dispatch_attempts == []

      [row] = DecisionPresenter.rows([current])
      assert row.lifecycle == :dispatch_pending
    end

    test "boot resolves a legacy raised alert for a non-actionable failed answer", %{dir: dir} do
      original_log_file = Application.get_env(:aiur, :log_file)
      log_root = Path.join(dir, "absent-agent-backlog-alert-log")
      Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))
      Aiur.TestSupport.put_runtime_state_dir!(log_root)

      on_exit(fn ->
        if original_log_file do
          Application.put_env(:aiur, :log_file, original_log_file)
        else
          Application.delete_env(:aiur, :log_file)
        end
      end)

      dispatcher = fn _decision, _opts -> {:error, :max_concurrent_agents_reached} end
      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-absent-backlog"))
      payload = %{"idempotency_key" => "absent-backlog-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, payload)
      failed = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :failed))
      assert List.last(failed.dispatch_attempts).failure_reason_class == "target_agent_unavailable"
      topic = "ticket.979.agent.attention.decision-delivery-#{String.replace(action.action_id, "_", "-")}"

      # Simulate an alert raised by an older build for a persisted failed
      # target-agent-unavailable record. Boot must clear that legacy alert.
      :ok =
        Alerts.emit_custom(
          topic,
          "stale raised delivery alert",
          issue: "979",
          reason: "stale",
          needs_attention: true,
          severity: "warning"
        )

      assert [%{"topic" => ^topic}] = case_attention_alerts(log_root, topic)

      GenServer.stop(pid)

      _pid2 = start_store!(dir, dispatcher: fn _decision, _opts -> {:error, :no_running_agent} end)
      wait_for_feed_empty(log_root, topic)
      assert case_attention_alerts(log_root, topic) == []
    end

    test "boot sweep retires the already-raised expired-unanswerable needs-attention backlog", %{dir: dir} do
      original_log_file = Application.get_env(:aiur, :log_file)
      log_root = Path.join(dir, "expired-backlog-alert-log")
      Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))
      Aiur.TestSupport.put_runtime_state_dir!(log_root)

      on_exit(fn ->
        if original_log_file do
          Application.put_env(:aiur, :log_file, original_log_file)
        else
          Application.delete_env(:aiur, :log_file)
        end
      end)

      now = ~U[2026-08-24 12:00:00Z]
      decision = expired_unanswerable_decision(now)
      topic = expired_unanswerable_topic(decision)

      # Simulate the backlog this fix exists to clear: an older build raised the
      # expired-unanswerable alert as needs-attention, so a raised entry is
      # already on disk before this sweep (a boot-time backlog, not a live
      # condition).
      :ok =
        Alerts.emit_custom(
          topic,
          "stale raised expired-unanswerable alert",
          issue: "979",
          reason: "stale",
          needs_attention: true,
          severity: "warning"
        )

      assert [%{"topic" => ^topic}] = case_attention_alerts(log_root, topic)

      # The boot sweep reconciles the whole historical expired-unanswerable
      # backlog through the real DecisionAttentionSignals path. An expired
      # Command is non-actionable, so the reconcile must resolve (clear) the
      # raised entry rather than leave it active forever — the feed must end up
      # empty, not merely smaller (a count assertion would pass on today's code
      # with one fewer entry).
      {:ok, pid} =
        DecisionExpiry.start_link(
          name: nil,
          initial_delay_ms: 0,
          interval_ms: 60_000,
          active_identifiers_fun: fn -> {:ok, []} end,
          decisions_fun: fn -> {:ok, [decision]} end,
          expire_fun: fn _decision_id, _reason_class, _occurred_at -> {:ok, %{status: :accepted}} end,
          now: now
        )

      on_exit(fn -> Aiur.TestSupport.safe_stop(pid) end)

      wait_for_feed_empty(log_root, topic)
      assert case_attention_alerts(log_root, topic) == []
    end

    test "an expired-unanswerable Command stays visible as history when the sweep retires its alert", %{dir: dir} do
      original_log_file = Application.get_env(:aiur, :log_file)
      log_root = Path.join(dir, "expired-visible-alert-log")
      Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))
      Aiur.TestSupport.put_runtime_state_dir!(log_root)

      on_exit(fn ->
        if original_log_file do
          Application.put_env(:aiur, :log_file, original_log_file)
        else
          Application.delete_env(:aiur, :log_file)
        end
      end)

      now = ~U[2026-08-24 12:00:00Z]
      pid = start_store!(dir, dispatch_delay_ms: 5_000, reconcile_delay_ms: 5_000)

      assert {:ok, %{decision: decision}} =
               request(pid, %{
                 "question" => "Which archival target?",
                 "blocking" => false,
                 "authority" => "human_required",
                 "source_id" => "expired-visible"
               })

      assert {:ok, %{decision: expired}} = DecisionStore.expire(decision.decision_id, "agent_not_running", [now: now], pid)
      assert expired.decision_status == :expired

      # The boot sweep reconciles the expired-unanswerable backlog through the
      # real store and the real DecisionAttentionSignals path. Retiring the
      # alert is an alert-surface choice, not a liveness one: the expired
      # Command must stay queryable as history on the decision surface.
      assert {:ok, 0} =
               DecisionExpiry.sweep(
                 now: DateTime.add(now, 60, :second),
                 grace_seconds: 300,
                 active_identifiers_fun: fn -> {:ok, []} end,
                 decisions_fun: fn -> {:ok, DecisionStore.list(pid)} end,
                 expire_fun: fn _decision_id, _reason_class, _occurred_at -> {:ok, %{status: :accepted}} end
               )

      assert {:ok, current} = DecisionStore.get(decision.decision_id, pid)
      assert current.decision_status == :expired

      [row] = DecisionPresenter.rows([current])
      assert row.decision_status == :expired
      assert row.lifecycle == :expired
    end

    test "default terminal resolver identity extraction falls back to issue id when identifier is blank" do
      terminal_states = MapSet.new(["done", "closed"])

      issues = [
        %Issue{id: "1471", identifier: nil, state: "done"},
        %Issue{id: "1582", identifier: "", state: "closed"},
        %Issue{id: "1660", identifier: "1660", state: "done"},
        %Issue{id: "2051", identifier: "2051", state: "open"}
      ]

      assert DecisionStore.terminal_identities(issues, terminal_states) ==
               MapSet.new(["1471", "1582", "1660"])
    end

    test "default terminal resolver identity extraction ignores non-terminal and non-issue entries" do
      terminal_states = MapSet.new(["done"])

      issues = [
        %Issue{id: "1471", identifier: nil, state: "done"},
        %Issue{id: "2051", identifier: "2051", state: "open"},
        %{id: "9999", state: "done"}
      ]

      assert DecisionStore.terminal_identities(issues, terminal_states) == MapSet.new(["1471"])
    end

    test "terminal-ticket delivery failure is resolved, not re-raised, on listener restart", %{dir: dir} do
      parent = self()
      original_log_file = Application.get_env(:aiur, :log_file)
      log_root = Path.join(dir, "terminal-alert-log")
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
        send(parent, {:queue_attempt, opts[:attempt_id]})
        {:ok, %{status: :accepted, item: %{id: 94}}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-terminal"))
      payload = %{"idempotency_key" => "terminal-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, payload)
      assert_receive {:queue_attempt, attempt_id}, 1_000
      _queued = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))

      item = correlated_queue_item(decision, action, attempt_id, 94)
      assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)

      topic =
        "ticket.979.agent.attention.decision-delivery-#{String.replace(action.action_id, "_", "-")}"

      assert :ok = DecisionStore.record_transport_async(:failed, item, :send_failed, pid)
      failed = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :failed))
      assert List.last(failed.dispatch_attempts).failure_reason_class == "send_failed"
      assert [%{"topic" => ^topic}] = case_attention_alerts(log_root, topic)

      GenServer.stop(pid)

      # Ticket #979 is terminal: the restarted listener must clear the stale
      # delivery alert instead of re-raising it — the feed must end up empty,
      # not merely smaller (a count assertion would pass on today's code with
      # one fewer entry, which is the non-constraining shape this test rejects).
      _pid2 =
        start_store!(dir,
          dispatcher: fn _decision, _opts -> {:error, :no_running_agent} end,
          terminal_ticket_resolver: fn _identifiers -> {:ok, MapSet.new(["979"])} end
        )

      wait_for_feed_empty(log_root, topic)

      assert case_attention_alerts(log_root, topic) == []
    end
  end
end
