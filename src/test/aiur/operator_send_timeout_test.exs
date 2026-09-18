defmodule Aiur.OperatorSendTimeoutTest do
  @moduledoc """
  #2717. A send to the Orchestrator can time out on the caller while the
  Orchestrator still handles the call and queues the item seconds later. The
  timeout is an unknown outcome, not a failure. Enqueue is idempotent by the
  caller's key, and the DecisionStore adopts a late item as its attempt.

  The Orchestrator is made slow with `:sys.suspend/1`: calls stay in its
  mailbox and run, in order, after `:sys.resume/1`.
  """

  use ExUnit.Case, async: false

  alias Aiur.{AgentPubSub, AgentQueueStore, DecisionDispatch, DecisionEvent, DecisionStore, Issue, Orchestrator}
  alias Aiur.Orchestrator.OperatorMessages

  @identifier "2717"
  @ticket %{
    identifier: @identifier,
    title: "Send timeout",
    url: "https://github.com/aiur-team/aiur/issues/2717"
  }
  @source %{agent_id: "agent-2717", session_id: "session-2717", event_id: nil}
  @actor %{kind: :operator, id: "operator-1"}
  @call_timeout_ms 150

  setup do
    original_dir = Application.get_env(:aiur, :decision_state_dir)
    original_timeout = Application.get_env(:aiur, :operator_message_call_timeout_ms)
    dir = Aiur.TestSupport.tmp_root!("aiur-send-timeout")
    Application.put_env(:aiur, :decision_state_dir, dir)
    Application.put_env(:aiur, :operator_message_call_timeout_ms, @call_timeout_ms)

    on_exit(fn ->
      restore_env(:decision_state_dir, original_dir)
      restore_env(:operator_message_call_timeout_ms, original_timeout)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  describe "Decision answer dispatch" do
    test "a timed-out dispatch that the Orchestrator still queues is adopted at the gate and delivered once",
         %{dir: dir} do
      {orchestrator, orchestrator_pid} = start_orchestrator!(:GateAdoption)
      :ok = AgentPubSub.subscribe_agent(@identifier)

      # No automatic retry: only the delivery gate can learn that the item exists.
      store = start_store!(dir, dispatcher: dispatch_via(orchestrator), dispatch_delay_ms: 0, retry_delays_ms: [60_000])
      {decision, action} = answer_while_orchestrator_is_slow!(store, orchestrator_pid, "gate")

      unknown = wait_for_decision(store, decision.decision_id, &match?([%{status: :unknown}], &1.dispatch_attempts))
      assert unknown.delivery_status == :pending
      assert [%{attempt_id: attempt_id, queue_item_id: nil, failed_at: nil}] = unknown.dispatch_attempts

      :ok = :sys.resume(orchestrator_pid)
      assert_receive {:agent_queue_updated, @identifier, queue_item_id, _delivery}, 1_000

      # The queue echo is labelled queued, with its item and decision id.
      decision_id = decision.decision_id

      assert_receive {:transcript_event,
                      %{
                        role: :user,
                        payload: %{
                          operator_message: %{status: :queued, request_id: ^queue_item_id, decision_id: ^decision_id}
                        }
                      }},
                     1_000

      assert {:ok, %{id: ^queue_item_id} = item} = OperatorMessages.claim_next_queue_item(orchestrator, @identifier)
      assert :empty = OperatorMessages.claim_next_queue_item(orchestrator, @identifier)

      assert {:ok, :accepted} = DecisionStore.validate_delivery(item, store)
      assert {:ok, :accepted} = DecisionStore.record_delivery(item, store)

      delivered = wait_for_decision(store, decision.decision_id, &(&1.delivery_status == :delivered))

      assert [%{attempt_id: ^attempt_id, action_id: action_id, queue_item_id: ^queue_item_id, status: :delivered}] =
               delivered.dispatch_attempts

      assert action_id == action.action_id

      # A build with the #2711 handoff mark also records `handed_off` at the gate.
      assert store |> audit_types(decision.decision_id) |> Enum.reject(&(&1 == :handed_off)) ==
               [:requested, :answer_recorded, :dispatch_outcome_unknown, :dispatch_queued, :delivered]
    end

    test "a retry after a timeout adopts the late item and queues no duplicate", %{dir: dir} do
      {orchestrator, orchestrator_pid} = start_orchestrator!(:RetryAdoption)
      store = start_store!(dir, dispatcher: dispatch_via(orchestrator), dispatch_delay_ms: 0, retry_delays_ms: [400])
      {decision, _action} = answer_while_orchestrator_is_slow!(store, orchestrator_pid, "retry")

      unknown = wait_for_decision(store, decision.decision_id, &match?([%{status: :unknown}], &1.dispatch_attempts))
      assert [%{attempt_id: attempt_id}] = unknown.dispatch_attempts

      :ok = :sys.resume(orchestrator_pid)
      assert_receive {:agent_queue_updated, @identifier, queue_item_id, _delivery}, 1_000

      queued = wait_for_decision(store, decision.decision_id, &(&1.delivery_status == :queued))
      assert [%{attempt_id: ^attempt_id, queue_item_id: ^queue_item_id, status: :queued}] = queued.dispatch_attempts

      # The retry found the late item by its action id instead of queueing it again.
      refute_receive {:agent_queue_updated, @identifier, _second, _delivery}, 200
      assert {:ok, %{id: ^queue_item_id} = item} = OperatorMessages.claim_next_queue_item(orchestrator, @identifier)
      assert :empty = OperatorMessages.claim_next_queue_item(orchestrator, @identifier)

      assert {:ok, :accepted} = DecisionStore.validate_delivery(item, store)
      assert {:ok, :accepted} = DecisionStore.record_delivery(item, store)
      delivered = wait_for_decision(store, decision.decision_id, &(&1.delivery_status == :delivered))
      assert [%{queue_item_id: ^queue_item_id, status: :delivered}] = delivered.dispatch_attempts
      refute :failed in audit_types(store, decision.decision_id)
    end

    test "an answer whose late item was refused and failed is still delivered", %{dir: dir} do
      {orchestrator, orchestrator_pid} = start_orchestrator!(:RefusedOrphan)
      store1 = start_store!(dir, dispatcher: dispatch_via(orchestrator), dispatch_delay_ms: 0, retry_delays_ms: [])
      {decision, _action} = answer_while_orchestrator_is_slow!(store1, orchestrator_pid, "refused")
      wait_for_decision(store1, decision.decision_id, &match?([%{status: :unknown}], &1.dispatch_attempts))

      :ok = :sys.resume(orchestrator_pid)
      assert_receive {:agent_queue_updated, @identifier, queue_item_id, _delivery}, 1_000

      # An older build refused the late item at the gate and failed it.
      assert {:ok, %{id: ^queue_item_id}} = OperatorMessages.claim_next_queue_item(orchestrator, @identifier)

      assert :ok =
               OperatorMessages.mark_queue_item_failed(
                 orchestrator,
                 queue_item_id,
                 {:decision_correlation_failed, :queue_item_mismatch}
               )

      GenServer.stop(store1)

      # The restarted store dispatches the answer again. It must restore the
      # refused item, not replay its failed copy.
      store2 =
        start_store!(dir,
          dispatcher: dispatch_via(orchestrator),
          dispatch_delay_ms: 0,
          reconcile_delay_ms: 0,
          retry_delays_ms: []
        )

      queued = wait_for_decision(store2, decision.decision_id, &(&1.delivery_status == :queued))
      assert [%{queue_item_id: ^queue_item_id, status: :queued}] = queued.dispatch_attempts

      assert {:ok, %{id: ^queue_item_id} = item} = OperatorMessages.claim_next_queue_item(orchestrator, @identifier)
      assert :empty = OperatorMessages.claim_next_queue_item(orchestrator, @identifier)
      assert {:ok, :accepted} = DecisionStore.validate_delivery(item, store2)
      assert {:ok, :accepted} = DecisionStore.record_delivery(item, store2)
      wait_for_decision(store2, decision.decision_id, &(&1.delivery_status == :delivered))
    end
  end

  describe "plain Executor messages" do
    test "a timeout is an unknown outcome and a retry with the same message id queues no duplicate" do
      {orchestrator, orchestrator_pid} = start_orchestrator!(:PlainRetry)
      payload = %{kind: :text, body: "Please rebase", message_id: "msg-2717"}

      :ok = :sys.suspend(orchestrator_pid)

      assert {:error, {:outcome_unknown, %{message_id: "msg-2717", item_id: nil}}} =
               OperatorMessages.send_operator_message(orchestrator, @identifier, payload)

      :ok = :sys.resume(orchestrator_pid)
      assert_receive {:agent_queue_updated, @identifier, queue_item_id, _delivery}, 1_000

      assert {:ok, ^queue_item_id} = OperatorMessages.send_operator_message(orchestrator, @identifier, payload)
      refute_receive {:agent_queue_updated, @identifier, _second, _delivery}, 200

      assert {:ok, %{id: ^queue_item_id}} = OperatorMessages.claim_next_queue_item(orchestrator, @identifier)
      assert :empty = OperatorMessages.claim_next_queue_item(orchestrator, @identifier)
    end

    test "a send that times out reports the item once the Orchestrator catches up" do
      {orchestrator, orchestrator_pid} = start_orchestrator!(:PlainLookup)
      payload = %{kind: :text, body: "Please rebase", message_id: "msg-lookup"}

      :ok = :sys.suspend(orchestrator_pid)
      # Resume after the send timed out but before the follow-up lookup does.
      spawn(fn ->
        Process.sleep(@call_timeout_ms + div(@call_timeout_ms, 2))
        :sys.resume(orchestrator_pid)
      end)

      assert {:ok, queue_item_id} = OperatorMessages.send_operator_message(orchestrator, @identifier, payload)
      assert_receive {:agent_queue_updated, @identifier, ^queue_item_id, _delivery}, 1_000
      assert {:ok, %{id: ^queue_item_id}} = OperatorMessages.claim_next_queue_item(orchestrator, @identifier)
      assert :empty = OperatorMessages.claim_next_queue_item(orchestrator, @identifier)
    end

    # Executors repeat short replies such as "continue". Without a message id,
    # each send is its own message, even after the first was delivered.
    test "the same text sent twice without a message id queues two messages" do
      {orchestrator, _orchestrator_pid} = start_orchestrator!(:SameTextTwice)
      payload = %{kind: :text, body: "continue"}

      assert {:ok, first_id} = OperatorMessages.send_operator_message(orchestrator, @identifier, payload)
      assert {:ok, %{id: ^first_id}} = OperatorMessages.claim_next_queue_item(orchestrator, @identifier)
      assert :ok = OperatorMessages.mark_queue_item_consumed(orchestrator, first_id)

      assert {:ok, second_id} = OperatorMessages.send_operator_message(orchestrator, @identifier, payload)
      refute second_id == first_id
      assert_receive {:agent_queue_updated, @identifier, ^first_id, _delivery}, 1_000
      assert_receive {:agent_queue_updated, @identifier, ^second_id, _delivery}, 1_000
      assert {:ok, %{id: ^second_id}} = OperatorMessages.claim_next_queue_item(orchestrator, @identifier)
    end

    # The facade the dashboard, Stream Deck and opencode use adds no key of
    # its own, so a repeated "continue" is never folded into the first one.
    test "AgentChat sends the same text twice as two messages" do
      free_global_orchestrator_name!()
      {Orchestrator, _orchestrator_pid} = start_orchestrator!({:name, Orchestrator})

      assert {:ok, first_id} = Aiur.AgentChat.send(@identifier, "continue")
      assert {:ok, second_id} = Aiur.AgentChat.send(@identifier, "continue")
      refute second_id == first_id

      # Only the caller's own id makes a repeat a retry of the same send.
      assert {:ok, third_id} = Aiur.AgentChat.send(@identifier, "continue", message_id: "press-1")
      assert {:ok, ^third_id} = Aiur.AgentChat.send(@identifier, "continue", message_id: "press-1")
      refute third_id in [first_id, second_id]
    end

    # A message id names one send. Reusing it for other text is a caller
    # error, and it must never report the other message as this send.
    test "a message id reused for different text is refused, not replayed" do
      {orchestrator, _orchestrator_pid} = start_orchestrator!(:IdConflict)

      assert {:ok, first_id} =
               OperatorMessages.send_operator_message(orchestrator, @identifier, %{kind: :text, body: "yes", message_id: "m-1"})

      assert {:error, {:message_id_conflict, ^first_id}} =
               OperatorMessages.send_operator_message(orchestrator, @identifier, %{kind: :text, body: "no", message_id: "m-1"})

      assert {:ok, ^first_id} =
               OperatorMessages.send_operator_message(orchestrator, @identifier, %{kind: :text, body: "yes", message_id: "m-1"})

      assert {:ok, %{id: ^first_id}} = OperatorMessages.claim_next_queue_item(orchestrator, @identifier)
      assert :empty = OperatorMessages.claim_next_queue_item(orchestrator, @identifier)
    end

    test "the queue store replays only the same target and text under one message id" do
      attrs = Map.put(Aiur.AgentQueue.operator_message(@identifier, "ship it"), :message_id, "m-2")
      {:ok, store, first, :accepted} = AgentQueueStore.enqueue_idempotent(AgentQueueStore.new(), attrs)
      assert {:ok, ^store, ^first, :duplicate} = AgentQueueStore.enqueue_idempotent(store, attrs)

      other_text = Map.put(Aiur.AgentQueue.operator_message(@identifier, "hold"), :message_id, "m-2")
      assert {:error, {:message_id_conflict, first_id}} = AgentQueueStore.enqueue_idempotent(store, other_text)
      assert first_id == first.id

      other_target = Map.put(Aiur.AgentQueue.operator_message("other", "ship it"), :message_id, "m-2")
      assert {:error, {:message_id_conflict, ^first_id}} = AgentQueueStore.enqueue_idempotent(store, other_target)
    end
  end

  defp answer_while_orchestrator_is_slow!(store, orchestrator_pid, key) do
    assert {:ok, %{decision: decision}} = DecisionStore.request(request_payload(key), [ticket: @ticket, source: @source], store)
    :ok = :sys.suspend(orchestrator_pid)

    answer = %{"idempotency_key" => key, "expected_version" => 1, "option_id" => "ship"}
    assert {:ok, %{status: :accepted, action: action}} = DecisionStore.answer(decision.decision_id, answer, [actor: @actor], store)

    {decision, action}
  end

  # AgentChat always calls the globally named Orchestrator, so the test
  # borrows that name and gives it back afterwards.
  defp free_global_orchestrator_name! do
    original = Process.whereis(Orchestrator)
    if is_pid(original), do: Process.unregister(Orchestrator)

    on_exit(fn ->
      if is_pid(original) and Process.alive?(original) and is_nil(Process.whereis(Orchestrator)) do
        Process.register(original, Orchestrator)
      end
    end)
  end

  defp start_store!(dir, opts) do
    defaults = [name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end, reconcile_delay_ms: 5_000]
    {:ok, pid} = DecisionStore.start_link(Keyword.merge(defaults, opts))
    on_exit(fn -> Aiur.TestSupport.safe_stop(pid) end)
    pid
  end

  defp start_orchestrator!({:name, name}), do: start_named_orchestrator!(name)
  defp start_orchestrator!(suffix), do: start_named_orchestrator!(Module.concat(__MODULE__, suffix))

  defp start_named_orchestrator!(name) do
    {:ok, pid} = Orchestrator.start_link(name: name)
    parent = self()
    worker_pid = spawn(fn -> worker_probe(parent) end)
    issue_id = "issue-#{@identifier}"

    :sys.replace_state(pid, fn state ->
      %{state | running: %{issue_id => running_entry(issue_id, worker_pid)}}
    end)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(pid)
      if Process.alive?(worker_pid), do: Process.exit(worker_pid, :normal)
    end)

    {name, pid}
  end

  defp running_entry(issue_id, worker_pid) do
    %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: @identifier,
      issue: %Issue{id: issue_id, identifier: @identifier, state: "In Progress", title: "Send timeout"},
      control: %{can_interrupt: true, safe_checkpoints: [:notification], status: :working},
      session_id: "thread-#{@identifier}",
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

  defp request_payload(source_id) do
    %{
      "source_id" => source_id,
      "question" => "Should we deploy?",
      "blocking" => true,
      "options" => [%{"id" => "ship", "label" => "Ship it"}]
    }
  end

  defp audit_types(store, decision_id) do
    {:ok, audit} = DecisionStore.audit_history(decision_id, store)
    Enum.map(audit, fn %DecisionEvent{type: type} -> type end)
  end

  defp wait_for_decision(store, decision_id, predicate, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_decision(store, decision_id, predicate, deadline)
  end

  defp do_wait_for_decision(store, decision_id, predicate, deadline) do
    {:ok, decision} = DecisionStore.get(decision_id, store)

    cond do
      predicate.(decision) ->
        decision

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for Decision: #{inspect(decision.dispatch_attempts)} #{decision.delivery_status}")

      true ->
        Process.sleep(10)
        do_wait_for_decision(store, decision_id, predicate, deadline)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_env(key, value), do: Application.put_env(:aiur, key, value)
end
