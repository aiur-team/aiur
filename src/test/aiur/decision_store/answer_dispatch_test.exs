Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.DecisionStore.AnswerDispatchTest do
  use Aiur.DecisionStoreCase, async: false

  describe "answer outbox" do
    test "persists the answer before dispatch and then records queue acceptance", %{dir: dir} do
      parent = self()

      dispatcher = fn decision, opts ->
        audit = DecisionStore.audit_history(decision.decision_id, opts[:store])
        send(parent, {:dispatch_observed, audit, opts[:attempt_id]})
        {:ok, %{status: :accepted, item: %{id: 41}}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)

      assert {:ok, %{decision: decision}} =
               request(pid, %{
                 "question" => "Deploy now?",
                 "blocking" => true,
                 "source_id" => "answer-1",
                 "options" => [%{"id" => "ship", "label" => "Ship it"}]
               })

      :ok = Exchange.subscribe("ticket.979.agent.decision.answered")
      :ok = Exchange.subscribe("ticket.979.agent.decision.queued")
      :ok = DecisionPubSub.subscribe()

      payload = %{"idempotency_key" => "submit-1", "expected_version" => 1, "option_id" => "ship"}

      assert {:ok, %{status: :accepted, action: accepted, dispatch_status: :dispatch_pending}} =
               answer(pid, decision.decision_id, payload)

      assert_receive {:dispatch_observed, {:ok, audit}, attempt_id}, 1_000
      assert Enum.map(audit, &audit_type/1) == [:requested, :answer_recorded]
      assert String.starts_with?(attempt_id, accepted.action_id)

      settled = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))
      assert settled.answer == accepted
      assert [%{queue_item_id: 41, attempt_id: ^attempt_id, status: :queued}] = settled.dispatch_attempts
      assert_receive {:event, %{topic: "ticket.979.agent.decision.answered"}}, 500
      assert_receive {:event, %{topic: "ticket.979.agent.decision.queued"}}, 500
      assert_receive {:decision_changed, decision_id, 1}, 500
      assert decision_id == decision.decision_id
      assert_receive {:decision_changed, ^decision_id, 1}, 500
    end

    test "exact answer replay is duplicate while changed content under the action conflicts", %{dir: dir} do
      parent = self()

      dispatcher = fn _decision, _opts ->
        send(parent, :dispatched)
        {:ok, %{status: :accepted, item: %{id: 42}}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0, reconcile_delay_ms: 5_000)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-dedup"))

      payload = %{
        "idempotency_key" => "submit-1",
        "expected_version" => 1,
        "custom_response" => "Proceed carefully",
        "rationale" => "Checks passed"
      }

      assert {:ok, %{status: :accepted, action: accepted}} = answer(pid, decision.decision_id, payload)
      assert_receive :dispatched, 1_000
      _settled = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))

      assert {:ok, %{status: :duplicate, action: ^accepted}} = answer(pid, decision.decision_id, payload)
      refute_receive :dispatched, 100

      changed = Map.put(payload, "rationale", "Different rationale")

      assert {:error, {:conflict, {:idempotency_conflict, action_id}}} =
               answer(pid, decision.decision_id, changed)

      assert action_id == accepted.action_id
      assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
      assert Enum.count(audit, &(audit_type(&1) == :answer_recorded)) == 1
      assert Enum.count(audit, &(audit_type(&1) == :dispatch_queued)) == 1
    end

    test "dispatch timeout settles once and ignores a late correlated result", %{dir: dir} do
      parent = self()
      coordinator = unique_coordinator_name("Timeout")

      start_supervised!(
        {DecisionDispatchTasks, name: coordinator, operation_timeout_ms: 20},
        id: coordinator
      )

      dispatcher = fn _decision, opts ->
        send(parent, {:timeout_dispatch_started, self(), opts[:attempt_id]})
        receive do: (:never -> :ok)
      end

      pid =
        start_store!(dir,
          decision_dispatch_tasks: coordinator,
          dispatcher: dispatcher,
          dispatch_delay_ms: 0
        )

      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-timeout"))
      payload = %{"idempotency_key" => "timeout-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, payload)
      assert_receive {:timeout_dispatch_started, worker, attempt_id}, 1_000
      worker_ref = Process.monitor(worker)

      failed = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :failed))
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 1_000
      assert List.last(failed.dispatch_attempts).failure_reason_class == "decision_dispatch_timeout"

      correlation = %{decision_id: decision.decision_id, action_id: action.action_id, attempt_id: attempt_id}
      send(pid, {:dispatch_result, correlation, {:ok, %{status: :accepted, item: %{id: 401}}}})
      _state = :sys.get_state(pid)

      assert {:ok, still_failed} = DecisionStore.get(decision.decision_id, pid)
      assert still_failed.delivery_status == :failed
      assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
      assert Enum.count(audit, &(audit_type(&1) == :failed)) == 1
      refute Enum.any?(audit, &(audit_type(&1) == :dispatch_queued))
    end

    test "an externally killed dispatch worker settles a specific durable failure", %{dir: dir} do
      parent = self()
      coordinator = unique_coordinator_name("KilledWorker")
      start_supervised!({DecisionDispatchTasks, name: coordinator}, id: coordinator)

      dispatcher = fn _decision, _opts ->
        send(parent, {:kill_dispatch_worker, self()})
        receive do: (:never -> :ok)
      end

      pid =
        start_store!(dir,
          decision_dispatch_tasks: coordinator,
          dispatcher: dispatcher,
          dispatch_delay_ms: 0
        )

      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-killed-worker"))
      payload = %{"idempotency_key" => "killed-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, _result} = answer(pid, decision.decision_id, payload)
      assert_receive {:kill_dispatch_worker, worker}, 1_000
      Process.exit(worker, :kill)

      failed = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :failed))
      assert List.last(failed.dispatch_attempts).failure_reason_class == "decision_dispatch_task_exit"
      assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
      assert Enum.count(audit, &(audit_type(&1) == :failed)) == 1
    end

    test "saturation fails admission durably and opens delivery attention", %{dir: dir} do
      parent = self()
      coordinator = unique_coordinator_name("Saturation")
      log_root = Path.join(dir, "dispatch-saturation-alert-log")
      original_log_file = Application.get_env(:aiur, :log_file)
      Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))
      Aiur.TestSupport.put_runtime_state_dir!(log_root)

      on_exit(fn ->
        if original_log_file,
          do: Application.put_env(:aiur, :log_file, original_log_file),
          else: Application.delete_env(:aiur, :log_file)
      end)

      start_supervised!(
        {DecisionDispatchTasks, name: coordinator, max_concurrency: 1, max_pending: 1, saturation_notifier: fn _ -> :ok end},
        id: coordinator
      )

      dispatcher = fn dispatched, opts ->
        send(parent, {:saturation_dispatch_started, dispatched.decision_id, self()})

        receive do
          :release -> {:ok, %{status: :accepted, item: %{id: 500 + String.length(opts[:attempt_id])}}}
        end
      end

      pid =
        start_store!(dir,
          decision_dispatch_tasks: coordinator,
          dispatcher: dispatcher,
          dispatch_delay_ms: 0
        )

      # Distinct questions so creation-time dedup (#2099) does not collapse the
      # three concurrently-open Commands this scenario needs for dispatch
      # admission; they represent three separate dispatch attempts.
      requests = [
        {"saturation-active", "Deploy the active change?"},
        {"saturation-queued", "Deploy the queued change?"},
        {"saturation-rejected", "Deploy the rejected change?"}
      ]

      decisions =
        for {source, question} <- requests do
          assert {:ok, %{decision: decision}} =
                   request(pid, %{answerable_request(source) | "question" => question})

          decision
        end

      [active, queued, rejected] = decisions

      for {decision, key} <- Enum.zip([active, queued], ["active-1", "queued-1"]) do
        payload = %{"idempotency_key" => key, "expected_version" => 1, "option_id" => "ship"}
        assert {:ok, _result} = answer(pid, decision.decision_id, payload)
      end

      assert_receive {:saturation_dispatch_started, active_id, active_worker}, 1_000
      assert active_id == active.decision_id
      wait_for_dispatch_count(pid, 2)

      payload = %{"idempotency_key" => "rejected-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: rejected_action}} = answer(pid, rejected.decision_id, payload)

      failed = wait_for_decision(pid, rejected.decision_id, &(&1.delivery_status == :failed))
      assert List.last(failed.dispatch_attempts).failure_reason_class == "decision_dispatch_overloaded"

      topic =
        "ticket.979.agent.attention.decision-delivery-#{String.replace(rejected_action.action_id, "_", "-")}"

      assert [%{"topic" => ^topic}] = case_attention_alerts(log_root, topic)
      send(active_worker, :release)
      assert_receive {:saturation_dispatch_started, queued_id, queued_worker}, 1_000
      assert queued_id == queued.decision_id
      send(queued_worker, :release)
    end

    test "coordinator restart fails active and queued work and allows explicit retry", %{dir: dir} do
      parent = self()
      coordinator = unique_coordinator_name("Restart")

      coordinator_pid =
        start_supervised!(
          {DecisionDispatchTasks, name: coordinator, max_concurrency: 1},
          id: coordinator
        )

      dispatcher = fn dispatched, opts ->
        if String.ends_with?(opts[:attempt_id], ":1") do
          send(parent, {:restart_dispatch_started, dispatched.decision_id, self()})
          receive do: (:never -> :ok)
        else
          send(parent, {:restart_retry_started, dispatched.decision_id, opts[:attempt_id]})
          {:ok, %{status: :accepted, item: %{id: 601}}}
        end
      end

      pid =
        start_store!(dir,
          decision_dispatch_tasks: coordinator,
          dispatcher: dispatcher,
          dispatch_delay_ms: 0
        )

      decisions =
        for source <- ["restart-active", "restart-queued"] do
          assert {:ok, %{decision: decision}} = request(pid, answerable_request(source))
          payload = %{"idempotency_key" => source, "expected_version" => 1, "option_id" => "ship"}
          assert {:ok, %{action: action}} = answer(pid, decision.decision_id, payload)
          {decision, action}
        end

      [{active, _active_action}, {queued, queued_action}] = decisions
      assert_receive {:restart_dispatch_started, active_id, orphaned_worker}, 1_000
      assert active_id == active.decision_id
      wait_for_dispatch_count(pid, 2)
      orphaned_worker_ref = Process.monitor(orphaned_worker)

      Process.exit(coordinator_pid, :kill)
      assert_receive {:DOWN, ^orphaned_worker_ref, :process, ^orphaned_worker, :killed}, 1_000

      for {decision, _action} <- decisions do
        failed = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :failed))
        assert List.last(failed.dispatch_attempts).failure_reason_class == "decision_dispatch_coordinator_exit"
      end

      restarted = wait_for_named_process(coordinator, coordinator_pid)
      assert Process.alive?(restarted)

      assert {:ok, :scheduled} = DecisionStore.retry_dispatch(queued.decision_id, queued_action.action_id, pid)
      assert_receive {:restart_retry_started, queued_id, retry_attempt_id}, 1_000
      assert queued_id == queued.decision_id
      assert String.ends_with?(retry_attempt_id, ":2")

      settled = wait_for_decision(pid, queued.decision_id, &(&1.delivery_status == :queued))
      assert Enum.map(settled.dispatch_attempts, & &1.status) == [:failed, :queued]
    end

    test "store restart purges old-owner dispatches before boot reconciliation", %{dir: dir} do
      parent = self()
      coordinator = unique_coordinator_name("StoreRestart")
      start_supervised!({DecisionDispatchTasks, name: coordinator, max_concurrency: 1}, id: coordinator)
      {:ok, mode} = Agent.start_link(fn -> :hang end)

      dispatcher = fn dispatched, _opts ->
        case Agent.get(mode, & &1) do
          :hang ->
            send(parent, {:old_store_dispatch_started, dispatched.decision_id, self()})
            receive do: (:never -> :ok)

          :recover ->
            send(parent, {:reconciled_dispatch_started, dispatched.decision_id})
            {:ok, %{status: :accepted, item: %{id: System.unique_integer([:positive])}}}
        end
      end

      pid1 =
        start_store!(dir,
          decision_dispatch_tasks: coordinator,
          dispatcher: dispatcher,
          dispatch_delay_ms: 0,
          reconcile_delay_ms: 0
        )

      decisions =
        for source <- ["store-restart-active", "store-restart-queued"] do
          assert {:ok, %{decision: decision}} = request(pid1, answerable_request(source))
          payload = %{"idempotency_key" => source, "expected_version" => 1, "option_id" => "ship"}
          assert {:ok, _result} = answer(pid1, decision.decision_id, payload)
          decision
        end

      assert_receive {:old_store_dispatch_started, _decision_id, old_worker}, 2_000
      wait_for_dispatch_count(pid1, 2)
      old_worker_ref = Process.monitor(old_worker)
      Agent.update(mode, fn _ -> :recover end)
      GenServer.stop(pid1)
      assert_receive {:DOWN, ^old_worker_ref, :process, ^old_worker, _reason}, 2_000

      pid2 =
        start_store!(dir,
          decision_dispatch_tasks: coordinator,
          dispatcher: dispatcher,
          dispatch_delay_ms: 0,
          reconcile_delay_ms: 0
        )

      for decision <- decisions do
        assert_receive {:reconciled_dispatch_started, decision_id}, 2_000
        assert decision_id in Enum.map(decisions, & &1.decision_id)

        queued = wait_for_decision(pid2, decision.decision_id, &(&1.delivery_status == :queued))
        assert Enum.map(queued.dispatch_attempts, & &1.status) == [:queued]
      end
    end

    test "concurrent distinct answers serialize to one winner", %{dir: dir} do
      dispatcher = fn _decision, _opts -> {:error, :no_running_agent} end
      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 20)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-race"))

      submissions = [
        %{"idempotency_key" => "race-1", "expected_version" => 1, "custom_response" => "First"},
        %{"idempotency_key" => "race-2", "expected_version" => 1, "custom_response" => "Second"}
      ]

      results =
        submissions
        |> Enum.map(&Task.async(fn -> answer(pid, decision.decision_id, &1) end))
        |> Enum.map(&Task.await/1)

      assert Enum.count(results, &match?({:ok, %{status: :accepted}}, &1)) == 1
      assert Enum.count(results, &match?({:error, {:conflict, {:already_decided, _}}}, &1)) == 1
    end

    test "a stale request version rejects before append or dispatch", %{dir: dir} do
      parent = self()
      dispatcher = fn _decision, _opts -> send(parent, :unexpected_dispatch) end
      pid = start_store!(dir, dispatcher: dispatcher)
      base = answerable_request("answer-stale")

      assert {:ok, %{decision: v1}} = request(pid, base)
      assert {:ok, %{decision: v2}} = request(pid, Map.merge(base, %{"question" => "Revised?", "version" => 2}))

      stale = %{"idempotency_key" => "stale-1", "expected_version" => 1, "custom_response" => "Proceed"}
      assert {:error, {:conflict, {:stale_version, 1, 2}}} = answer(pid, v1.decision_id, stale)
      refute_receive :unexpected_dispatch, 100
      assert v2.answer == nil
      assert {:ok, audit} = DecisionStore.audit_history(v1.decision_id, pid)
      assert Enum.map(audit, &audit_type/1) == [:requested, :requested]
    end

    test "request enrichment after answer keeps dispatch tied to the answered version", %{dir: dir} do
      parent = self()

      dispatcher = fn addressed, _opts ->
        send(parent, {:addressed_request, addressed.version, addressed.question})
        {:ok, %{status: :accepted, item: %{id: 55}}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 100)
      base = answerable_request("answer-enrichment")
      assert {:ok, %{decision: v1}} = request(pid, base)

      payload = %{"idempotency_key" => "enrich-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, v1.decision_id, payload)

      assert {:ok, %{decision: v2}} =
               request(pid, Map.merge(base, %{"question" => "Revised after answer?", "version" => 2}))

      assert v2.version == 2
      assert v2.answer == action
      assert_receive {:addressed_request, 1, "Deploy now?"}, 1_000

      settled = wait_for_decision(pid, v1.decision_id, &(&1.delivery_status == :queued))
      assert settled.version == 2
      assert settled.answer.decision_version == 1
    end
  end
end
