defmodule Aiur.DecisionDeliveryIntegrationTest do
  use ExUnit.Case, async: false

  alias Aiur.{DecisionDispatch, DecisionEvent, DecisionMetrics, DecisionStore, Issue, Orchestrator}
  alias Aiur.DecisionMetrics.{Log, Writer}
  alias Aiur.Orchestrator.OperatorMessages

  @ticket %{
    identifier: "981",
    title: "OCC-3",
    url: "https://github.com/its-everdred/aiur/issues/981"
  }
  @source %{agent_id: "agent-981", session_id: "session-981", event_id: nil}
  @actor %{kind: :operator, id: "operator-1"}

  setup do
    original_dir = Application.get_env(:aiur, :decision_state_dir)
    dir = Aiur.TestSupport.tmp_root!("aiur-decision-delivery")
    Application.put_env(:aiur, :decision_state_dir, dir)

    on_exit(fn ->
      restore_env(:decision_state_dir, original_dir)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "request through resolution preserves one action and independent delivery state", %{dir: dir} do
    {orchestrator, _orchestrator_pid, _worker_pid} =
      start_orchestrator!(Module.concat(__MODULE__, :HappyPathOrchestrator), "981")

    store = start_store!(dir, dispatcher: dispatch_via(orchestrator), dispatch_delay_ms: 50)
    {metrics, metrics_path} = start_metrics!(dir)

    assert {:ok, %{status: :accepted, decision: decision}} = request(store, request_payload("happy"))

    answer_payload = %{
      "idempotency_key" => "submit-happy",
      "expected_version" => 1,
      "option_id" => "ship",
      "rationale" => "The release checks are green."
    }

    assert {:ok, %{status: :accepted, action: action}} =
             DecisionStore.answer(decision.decision_id, answer_payload, [actor: @actor], store)

    assert {:ok, %{status: :duplicate, action: ^action}} =
             DecisionStore.answer(decision.decision_id, answer_payload, [actor: @actor], store)

    queued = wait_for_decision(store, decision.decision_id, &(&1.delivery_status == :queued))
    assert queued.decision_status == :decided
    assert_receive {:agent_queue_updated, "981", queue_item_id, _delivery}, 1_000

    assert {:ok, %{status: :duplicate}} =
             DecisionStore.answer(decision.decision_id, answer_payload, [actor: @actor], store)

    refute_receive {:agent_queue_updated, "981", _, _}, 100

    assert {:ok, %{id: ^queue_item_id, action_id: action_id} = item} =
             OperatorMessages.claim_next_queue_item(orchestrator, "981")

    assert action_id == action.action_id
    assert :empty = OperatorMessages.claim_next_queue_item(orchestrator, "981")
    assert {:ok, :accepted} = DecisionStore.validate_delivery(item, store)
    assert {:ok, queued_after_preflight} = DecisionStore.get(decision.decision_id, store)
    assert [%{action_id: ^action_id, status: :queued}] = queued_after_preflight.dispatch_attempts

    assert {:ok, :accepted} = DecisionStore.record_delivery(item, store)

    delivered = wait_for_decision(store, decision.decision_id, &(&1.delivery_status == :delivered))
    assert delivered.decision_status == :decided

    assert :ok = OperatorMessages.mark_queue_item_consumed(orchestrator, item.id)
    assert :ok = DecisionStore.record_transport_async(:consumed, item, nil, store)

    consumed = wait_for_decision(store, decision.decision_id, &(&1.delivery_status == :consumed))
    assert consumed.decision_status == :decided

    lifecycle_payload = %{
      "decision_id" => decision.decision_id,
      "action_id" => action.action_id,
      "expected_version" => 1,
      "detail" => "Answer observed and applied"
    }

    lifecycle_opts = [
      ticket_identifier: "981",
      actor: %{kind: :agent, id: "ticket-agent"},
      source: %{agent_id: "codex", session_id: "session-1", invocation_id: "call-1"}
    ]

    assert {:ok, %{status: :accepted, decision_status: :acknowledged}} =
             DecisionStore.agent_lifecycle(:acknowledged, lifecycle_payload, lifecycle_opts, store)

    assert {:ok, %{status: :duplicate, action: ^action}} =
             DecisionStore.answer(decision.decision_id, answer_payload, [actor: @actor], store)

    assert {:ok, %{status: :accepted, decision_status: :resolved}} =
             DecisionStore.agent_lifecycle(
               :resolved,
               Map.put(lifecycle_payload, "detail", "Work completed"),
               lifecycle_opts,
               store
             )

    assert {:ok, current} = DecisionStore.get(decision.decision_id, store)
    assert current.decision_status == :resolved
    assert current.delivery_status == :consumed
    assert current.answer.action_id == action.action_id

    assert_receive {:decision_metric_persisted, decision_id, "acknowledged"}, 2_000
    assert decision_id == decision.decision_id
    assert {:ok, snapshot} = DecisionMetrics.snapshot(decision.decision_id, metrics)

    for field <- [
          :request_to_decision_ms,
          :decision_to_dispatch_ms,
          :dispatch_to_delivery_ms,
          :delivery_to_ack_ms,
          :blocked_time_ms
        ] do
      assert is_integer(snapshot[field]) and snapshot[field] >= 0
    end

    assert snapshot.actor == "human"
    assert :ok = DecisionMetrics.flush(metrics)
    assert metrics_path |> File.read!() |> String.split("\n", trim: true) |> length() >= 5

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, store)

    assert Enum.map(audit, &audit_type/1) == [
             :requested,
             :answer_recorded,
             :dispatch_queued,
             :delivered,
             :consumed,
             :acknowledged,
             :resolved
           ]

    assert audit |> Enum.map(& &1.event_id) |> Enum.uniq() |> length() == length(audit)
  end

  test "stale browser answer cannot mutate an enriched decision", %{dir: dir} do
    parent = self()
    dispatcher = fn _decision, _opts -> send(parent, :unexpected_dispatch) end
    store = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
    v1_payload = request_payload("stale")

    assert {:ok, %{decision: v1}} = request(store, v1_payload)

    assert {:ok, %{decision: v2}} =
             request(store, Map.merge(v1_payload, %{"version" => 2, "question" => "Revised question?"}))

    stale_answer = %{
      "idempotency_key" => "submit-stale",
      "expected_version" => 1,
      "custom_response" => "Proceed"
    }

    assert {:error, {:conflict, {:stale_version, 1, 2}}} =
             DecisionStore.answer(v1.decision_id, stale_answer, [actor: @actor], store)

    refute_receive :unexpected_dispatch, 100
    assert {:ok, current} = DecisionStore.get(v1.decision_id, store)
    assert current.version == v2.version
    assert current.decision_status == :open
    assert current.answer == nil
    assert {:ok, audit} = DecisionStore.audit_history(v1.decision_id, store)
    assert Enum.map(audit, &audit_type/1) == [:requested, :requested]
  end

  test "store restart adopts the surviving queue item without a second wake", %{dir: dir} do
    parent = self()

    {orchestrator, _orchestrator_pid, _worker_pid} =
      start_orchestrator!(Module.concat(__MODULE__, :StoreRestartOrchestrator), "981")

    blocking_dispatcher = fn decision, opts ->
      result = dispatch_via(orchestrator).(decision, opts)
      send(parent, {:queue_accepted_before_store_crash, self(), result})

      receive do
        :release_dispatch -> result
      end
    end

    store1 =
      start_store!(dir,
        dispatcher: blocking_dispatcher,
        dispatch_delay_ms: 0,
        reconcile_delay_ms: 5_000
      )

    assert {:ok, %{decision: decision}} = request(store1, request_payload("store-restart"))
    answer_payload = custom_answer("store-restart")

    assert {:ok, %{action: action}} =
             DecisionStore.answer(decision.decision_id, answer_payload, [actor: @actor], store1)

    assert_receive {:queue_accepted_before_store_crash, dispatch_task, {:ok, %{status: :accepted}}}, 1_000
    assert_receive {:agent_queue_updated, "981", queue_item_id, _delivery}, 1_000
    GenServer.stop(store1)
    send(dispatch_task, :release_dispatch)

    store2 =
      start_store!(dir,
        dispatcher: dispatch_via(orchestrator),
        dispatch_delay_ms: 0,
        reconcile_delay_ms: 0
      )

    queued = wait_for_decision(store2, decision.decision_id, &(&1.delivery_status == :queued))
    assert [%{queue_item_id: ^queue_item_id, status: :queued}] = queued.dispatch_attempts
    refute_receive {:agent_queue_updated, "981", _, _}, 100

    assert {:ok, %{id: ^queue_item_id, action_id: action_id}} =
             OperatorMessages.claim_next_queue_item(orchestrator, "981")

    assert action_id == action.action_id
    assert :empty = OperatorMessages.claim_next_queue_item(orchestrator, "981")
    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, store2)
    assert Enum.count(audit, &(audit_type(&1) == :dispatch_queued)) == 1
  end

  test "full restart creates a correlated attempt when the old in-memory queue is gone", %{dir: dir} do
    orchestrator_name = Module.concat(__MODULE__, :FullRestartOrchestrator)
    {orchestrator1, orchestrator_pid1, worker_pid1} = start_orchestrator!(orchestrator_name, "981")
    store1 = start_store!(dir, dispatcher: dispatch_via(orchestrator1), dispatch_delay_ms: 0)

    assert {:ok, %{decision: decision}} = request(store1, request_payload("full-restart"))

    assert {:ok, %{action: action}} =
             DecisionStore.answer(decision.decision_id, custom_answer("full-restart"), [actor: @actor], store1)

    queued1 = wait_for_decision(store1, decision.decision_id, &(&1.delivery_status == :queued))
    assert_receive {:agent_queue_updated, "981", first_queue_id, _delivery}, 1_000
    assert [%{attempt_id: first_attempt_id, queue_item_id: ^first_queue_id}] = queued1.dispatch_attempts

    GenServer.stop(store1)
    GenServer.stop(orchestrator_pid1)
    Process.exit(worker_pid1, :normal)

    {orchestrator2, _orchestrator_pid2, _worker_pid2} = start_orchestrator!(orchestrator_name, "981")

    store2 =
      start_store!(dir,
        dispatcher: dispatch_via(orchestrator2),
        dispatch_delay_ms: 0,
        reconcile_delay_ms: 0
      )

    queued2 = wait_for_decision(store2, decision.decision_id, &(length(&1.dispatch_attempts) == 2))
    assert_receive {:agent_queue_updated, "981", second_queue_id, _delivery}, 1_000

    assert [first_attempt, second_attempt] = queued2.dispatch_attempts
    assert first_attempt.attempt_id == first_attempt_id
    assert second_attempt.attempt_id != first_attempt_id
    assert second_attempt.action_id == action.action_id
    assert second_attempt.queue_item_id == second_queue_id
    assert first_attempt.queue_item_id == second_attempt.queue_item_id

    assert {:ok, %{id: ^second_queue_id, action_id: action_id}} =
             OperatorMessages.claim_next_queue_item(orchestrator2, "981")

    assert action_id == action.action_id
    assert :empty = OperatorMessages.claim_next_queue_item(orchestrator2, "981")
    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, store2)
    assert Enum.count(audit, &(audit_type(&1) == :dispatch_queued)) == 2
  end

  defp start_store!(dir, opts) do
    Application.put_env(:aiur, :decision_state_dir, dir)

    defaults = [name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end, reconcile_delay_ms: 5_000]
    {:ok, pid} = DecisionStore.start_link(Keyword.merge(defaults, opts))

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(pid)
    end)

    pid
  end

  defp start_metrics!(dir) do
    path = Path.join(dir, "decision-delivery-metrics.ndjson")
    owner = self()

    append_fun = fn append_path, records -> append_and_notify(append_path, records, owner) end

    {:ok, writer} =
      Writer.start_link(name: nil, path: path, flush_interval_ms: 5, append_fun: append_fun)

    {:ok, metrics} =
      DecisionMetrics.start_link(
        name: nil,
        writer: writer,
        subscribe?: true,
        seed?: false
      )

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(metrics)
      Aiur.TestSupport.safe_stop(writer)
    end)

    {metrics, path}
  end

  defp append_and_notify(path, records, owner) do
    with :ok <- Log.append_batch(path, records) do
      Enum.each(records, &notify_metric_persisted(&1, owner))
    end
  end

  defp notify_metric_persisted(record, owner) do
    send(owner, {:decision_metric_persisted, record.decision_id, record.stage})
  end

  defp start_orchestrator!(name, identifier) do
    {:ok, pid} = Orchestrator.start_link(name: name)
    parent = self()
    worker_pid = spawn(fn -> worker_probe(parent) end)
    issue_id = "issue-#{identifier}"

    :sys.replace_state(pid, fn state ->
      %{state | running: %{issue_id => running_entry(issue_id, identifier, worker_pid)}}
    end)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(pid)
      if Process.alive?(worker_pid), do: Process.exit(worker_pid, :normal)
    end)

    {name, pid, worker_pid}
  end

  defp running_entry(issue_id, identifier, worker_pid) do
    %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: identifier,
      issue: %Issue{id: issue_id, identifier: identifier, state: "In Progress", title: "OCC-3"},
      control: %{can_interrupt: true, safe_checkpoints: [:notification], status: :working},
      session_id: "thread-#{identifier}",
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      started_at: DateTime.utc_now()
    }
  end

  defp worker_probe(parent) do
    receive do
      message ->
        send(parent, message)
        worker_probe(parent)
    end
  end

  defp dispatch_via(orchestrator) do
    fn decision, opts ->
      DecisionDispatch.dispatch(decision, Keyword.put(opts, :operator_messages, orchestrator))
    end
  end

  defp request(store, payload) do
    DecisionStore.request(payload, [ticket: @ticket, source: @source], store)
  end

  defp request_payload(source_id) do
    %{
      "source_id" => source_id,
      "question" => "Should we deploy?",
      "blocking" => true,
      "options" => [%{"id" => "ship", "label" => "Ship it"}]
    }
  end

  defp custom_answer(key) do
    %{
      "idempotency_key" => key,
      "expected_version" => 1,
      "custom_response" => "Proceed"
    }
  end

  defp wait_for_decision(store, decision_id, predicate, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_decision(store, decision_id, predicate, deadline)
  end

  defp do_wait_for_decision(store, decision_id, predicate, deadline) do
    {:ok, decision} = DecisionStore.get(decision_id, store)

    cond do
      predicate.(decision) ->
        decision

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for Decision: #{inspect(decision)}")

      true ->
        Process.sleep(10)
        do_wait_for_decision(store, decision_id, predicate, deadline)
    end
  end

  defp audit_type(%DecisionEvent{type: type}), do: type

  defp restore_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_env(key, value), do: Application.put_env(:aiur, key, value)
end
