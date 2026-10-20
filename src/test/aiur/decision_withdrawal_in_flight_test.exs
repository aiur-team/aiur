defmodule Aiur.DecisionWithdrawalInFlightTest do
  @moduledoc """
  #2711: an unanswered `:decided` Command can be withdrawn or superseded;
  neither response reaches its worker or a later worker. Delivered answers stay immutable.

  The scenario mirrors Khala #12/#13: the Executor answers a blocking Command
  after its worker has gone, so every dispatch fails `target_agent_unavailable`
  and the answer stays decided but undelivered. Then a fresh worker exists for
  the same ticket (the dispatcher starts to accept) and the store restarts, which
  is the moment the old code re-dispatched the stale answer to it.
  """

  use ExUnit.Case, async: false

  alias Aiur.{AlertFeed, Decision, DecisionEvent, DecisionPubSub, DecisionStore}

  @ticket %{identifier: "2711", title: "Withdraw undelivered answers", url: "https://github.com/aiur-team/aiur/issues/2711"}

  @source %{agent_id: "codex", session_id: "worker-session-1", event_id: "request-1"}

  @executor %{kind: :executor, id: "khala-executor"}

  @operator %{kind: :operator, id: "operator-1"}

  @target_agent %{kind: :agent, id: "codex"}

  @no_worker 0

  @worker 1

  setup do
    original_override = Application.get_env(:aiur, :decision_state_dir)
    dir = Aiur.TestSupport.tmp_root!("aiur-decision-withdrawal")
    Application.put_env(:aiur, :decision_state_dir, dir)
    :ok = DecisionPubSub.subscribe()
    :ok = DecisionPubSub.subscribe_dispatches_reconciled()

    on_exit(fn ->
      case original_override do
        nil -> Application.delete_env(:aiur, :decision_state_dir)
        value -> Application.put_env(:aiur, :decision_state_dir, value)
      end

      Aiur.TestCleanup.rm_rf!(dir)
    end)

    worker = :atomics.new(1, [])
    :atomics.put(worker, 1, @no_worker)
    %{dir: dir, worker: worker}
  end

  describe "an answer handed to a worker is in flight (review of #2712)" do
    test "moot and supersede are refused between the gate and the provider confirmation", %{dir: dir, worker: worker} do
      pid = start_store!(dir, worker)
      {decision, original, item} = queued_answer(pid, worker)

      # Before the gate, the queued answer can still be withdrawn in principle.
      refute Decision.send_in_flight?(elem(DecisionStore.get(decision.decision_id, pid), 1))

      # The worker passes the gate: the handoff is durable before the send.
      assert {:ok, :accepted} = DecisionStore.validate_delivery(item, pid)
      assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
      assert [%DecisionEvent{data: %{action_id: action_id}}] = Enum.filter(audit, &(&1.type == :handed_off))
      assert action_id == original.action_id

      # The send is in progress. Neither withdrawal may race it, and the refusal
      # survives a daemon restart.
      assert {:error, {:conflict, :answer_in_flight}} = moot(pid, decision)
      assert {:error, {:conflict, :answer_in_flight}} = supersede(pid, decision, "too-late", "Other plan")

      GenServer.stop(pid)
      restarted = start_store!(dir, worker)
      assert {:error, {:conflict, :answer_in_flight}} = moot(restarted, decision)

      # The provider then confirms: the one answer that went out is the recorded one.
      assert {:ok, :accepted} = DecisionStore.record_delivery(item, restarted)
      delivered = wait_for(restarted, decision.decision_id, &(&1.delivery_status == :delivered))
      assert delivered.decision_status == :decided
      assert delivered.revisions == []
      assert {:error, {:conflict, :answer_delivered}} = moot(restarted, decision)
    end

    test "a send that failed after the handoff is no longer in flight and can be withdrawn", %{dir: dir, worker: worker} do
      pid = start_store!(dir, worker)
      {decision, _original, item} = queued_answer(pid, worker)
      assert {:ok, :accepted} = DecisionStore.validate_delivery(item, pid)
      assert {:error, {:conflict, :answer_in_flight}} = moot(pid, decision)

      # The provider rejected the send: a definite outcome.
      :ok = DecisionStore.record_transport_async(:failed, item, :send_failed, pid)
      failed = wait_for(pid, decision.decision_id, &(&1.delivery_status == :failed))
      refute Decision.send_in_flight?(failed)
      refute Decision.delivered?(failed)

      # This is the shape a new worker's redelivery (#2713) looks for: the newest
      # attempt failed and none was confirmed.
      attempts = Decision.active_dispatch_attempts(failed)
      assert match?(%{status: :failed}, List.last(attempts))
      assert Enum.all?(attempts, &is_nil(&1.delivered_at))

      assert {:ok, %{status: :accepted, decision: %{decision_status: :moot}}} = moot(pid, decision)
    end

    test "a send that failed after the handoff is sent again once, and that send is in flight", %{dir: dir, worker: worker} do
      pid = start_store!(dir, worker)
      {decision, original, item} = queued_answer(pid, worker)
      assert {:ok, :accepted} = DecisionStore.validate_delivery(item, pid)
      :ok = DecisionStore.record_transport_async(:failed, item, :send_failed, pid)
      _failed = wait_for(pid, decision.decision_id, &(&1.delivery_status == :failed))

      assert {:ok, :scheduled} = DecisionStore.retry_dispatch(decision.decision_id, original.action_id, pid)
      assert_receive {:dispatched, resent_action_id, resent_item}, 5_000
      assert resent_action_id == original.action_id
      assert resent_item.correlation.attempt_id != item.correlation.attempt_id
      _queued = wait_for(pid, decision.decision_id, &(&1.delivery_status == :queued))
      refute_received {:dispatched, _action_id, _item}

      # The new send passes the gate and gets its own handoff, so it is in
      # flight and cannot be withdrawn.
      assert {:ok, :accepted} = DecisionStore.validate_delivery(resent_item, pid)
      assert {:error, {:conflict, :answer_in_flight}} = moot(pid, decision)

      assert {:ok, :accepted} = DecisionStore.record_delivery(resent_item, pid)
      delivered = wait_for(pid, decision.decision_id, &(&1.delivery_status == :delivered))

      assert [confirmed] = Enum.reject(delivered.dispatch_attempts, &is_nil(&1.delivered_at))
      assert confirmed.attempt_id == resent_item.correlation.attempt_id
      assert length(delivered.dispatch_attempts) == 2
    end

    test "a send restored to the queue gets a fresh handoff when the worker picks it up again", %{dir: dir, worker: worker} do
      pid = start_store!(dir, worker)
      {decision, _original, item} = queued_answer(pid, worker)
      assert {:ok, :accepted} = DecisionStore.validate_delivery(item, pid)

      # The send failed before the provider took it, and a retry put the same
      # item back in the queue: the flight is over.
      :ok = DecisionStore.record_transport_async(:failed, item, :send_failed, pid)
      _failed = wait_for(pid, decision.decision_id, &(&1.delivery_status == :failed))
      :ok = DecisionStore.record_transport_async(:restored, item, nil, pid)

      restored =
        wait_for(pid, decision.decision_id, fn current ->
          match?([%{restored_at: %DateTime{}}], current.dispatch_attempts)
        end)

      refute Decision.send_in_flight?(restored)

      # The worker drains the same item again: a new flight, refused again.
      assert {:ok, :accepted} = DecisionStore.validate_delivery(item, pid)
      assert {:ok, again} = DecisionStore.get(decision.decision_id, pid)
      assert Decision.send_in_flight?(again)
      assert {:error, {:conflict, :answer_in_flight}} = moot(pid, decision)
    end

    test "a refused withdrawal of a send with an unknown outcome raises attention", %{dir: dir, worker: worker} do
      alert_opts = capture_alert_log(dir)
      pid = start_store!(dir, worker, handoff_unknown_after_ms: 0)
      {decision, original, item} = queued_answer(pid, worker)
      assert {:ok, :accepted} = DecisionStore.validate_delivery(item, pid)

      assert {:error, {:conflict, :answer_in_flight}} = moot(pid, decision)

      topic = "ticket.#{@ticket.identifier}.agent.attention.decision-delivery-#{String.replace(original.action_id, "_", "-")}-unknown"
      assert AlertFeed.active_ticket_attention?(topic, alert_opts)
    end

    test "a provider confirmation for a withdrawn answer raises attention and cannot revive it", %{dir: dir, worker: worker} do
      alert_opts = capture_alert_log(dir)
      pid = start_store!(dir, worker)
      {decision, original, item} = queued_answer(pid, worker)

      # Mooted while only queued, before any handoff.
      assert {:ok, %{status: :accepted}} = moot(pid, decision)

      # A worker that skipped the gate reports provider delivery anyway.
      assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)
      topic = "ticket.#{@ticket.identifier}.agent.attention.decision-delivery-#{String.replace(original.action_id, "_", "-")}-withdrawn"
      assert AlertFeed.active_ticket_attention?(topic, alert_opts)

      # The agent acknowledges it: refused, so the Command stays moot, also
      # after a restart.
      assert {:error, _reason} =
               DecisionStore.agent_lifecycle(
                 :acknowledged,
                 %{decision_id: decision.decision_id, action_id: original.action_id, expected_version: decision.version},
                 [ticket_identifier: @ticket.identifier, actor: @target_agent, source: @source],
                 pid
               )

      assert {:ok, %{decision_status: :moot}} = DecisionStore.get(decision.decision_id, pid)
      GenServer.stop(pid)
      restarted = start_store!(dir, worker)
      assert {:ok, %{decision_status: :moot}} = DecisionStore.get(decision.decision_id, restarted)
    end

    test "a revision cannot revive a mooted Command", %{dir: dir, worker: worker} do
      pid = start_store!(dir, worker)
      {decision, original} = undelivered_answer(pid)
      assert {:ok, %{status: :accepted}} = moot(pid, decision)

      assert {:error, {:conflict, :moot}} =
               DecisionStore.revise(
                 decision.decision_id,
                 %{
                   "idempotency_key" => "operator-revision",
                   "expected_version" => decision.version,
                   "expected_action_id" => original.action_id,
                   "expected_revision_sequence" => 0,
                   "custom_response" => "Revive it",
                   "rationale" => "Operator revision"
                 },
                 [actor: @operator],
                 pid
               )

      assert {:ok, %{decision_status: :moot, revisions: []}} = DecisionStore.get(decision.decision_id, pid)
    end

    test "a moot with a stale expected version is refused", %{dir: dir, worker: worker} do
      pid = start_store!(dir, worker)
      {decision, _original} = undelivered_answer(pid)

      assert {:error, {:conflict, {:stale_version, 7, 1}}} =
               DecisionStore.moot(
                 decision.decision_id,
                 %{"reason_class" => "operator_changed_direction", "expected_version" => 7},
                 [actor: @executor],
                 pid
               )

      assert {:ok, %{decision_status: :decided}} = DecisionStore.get(decision.decision_id, pid)
    end
  end

  defp undelivered_answer(pid) do
    assert {:ok, %{decision: decision}} = request(pid)
    assert {:ok, %{action: original}} = answer(pid, decision, "original-answer", "Use the fixture session")

    # The worker is gone, so the first dispatch fails and the answer stays
    # decided but undelivered.
    assert_receive {:dispatch_refused, action_id}, 5_000
    assert action_id == original.action_id
    failed = wait_for(pid, decision.decision_id, &(&1.delivery_status == :failed))
    assert failed.decision_status == :decided
    refute Decision.delivered?(failed)
    {decision, original}
  end

  defp request(pid, authority \\ "supervisor_allowed") do
    DecisionStore.request(
      %{
        "question" => "Provide a disposable session, or accept inventory-only evidence?",
        "blocking" => true,
        "authority" => authority,
        "reversibility" => "reversible",
        "context" => if(authority == "human_required", do: %{"authority_basis" => "security"}, else: nil)
      },
      [ticket: @ticket, source: @source],
      pid
    )
  end

  defp answer(pid, decision, key, response, actor \\ @executor) do
    DecisionStore.answer(
      decision.decision_id,
      %{
        "idempotency_key" => key,
        "expected_version" => decision.version,
        "custom_response" => response,
        "rationale" => "Executor answer"
      },
      [actor: actor],
      pid
    )
  end

  defp moot(pid, decision, actor \\ @executor) do
    DecisionStore.moot(
      decision.decision_id,
      %{"reason_class" => "operator_changed_direction", "expected_version" => decision.version},
      [actor: actor],
      pid
    )
  end

  # A queued, not yet handed-off answer: a worker exists, so the dispatch
  # enqueues it, but nothing has passed the delivery gate.

  defp queued_answer(pid, worker, authority \\ "supervisor_allowed", actor \\ @executor) do
    :atomics.put(worker, 1, @worker)
    assert {:ok, %{decision: decision}} = request(pid, authority)
    assert {:ok, %{action: original}} = answer(pid, decision, "queued-answer", "Proceed", actor)
    assert_receive {:dispatched, _action_id, item}, 5_000
    _queued = wait_for(pid, decision.decision_id, &(&1.delivery_status == :queued))
    {decision, original, item}
  end

  defp capture_alert_log(dir) do
    previous_log_file = Application.get_env(:aiur, :log_file)
    log_root = Path.join(dir, "withdrawal-alerts")
    Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))
    Aiur.TestSupport.put_runtime_state_dir!(log_root)

    on_exit(fn ->
      if previous_log_file,
        do: Application.put_env(:aiur, :log_file, previous_log_file),
        else: Application.delete_env(:aiur, :log_file)
    end)

    [roots: [], log_roots: [log_root]]
  end

  defp supersede(pid, decision, key, response) do
    DecisionStore.supersede(
      decision.decision_id,
      %{
        "idempotency_key" => key,
        "expected_version" => decision.version,
        "custom_response" => response,
        "rationale" => "Operator changed direction"
      },
      [actor: @executor],
      pid
    )
  end

  defp start_store!(dir, worker, extra_opts \\ []) do
    parent = self()

    dispatcher = fn decision, opts ->
      action_id = Decision.active_answer(decision).action_id

      case :atomics.get(worker, 1) do
        @no_worker ->
          send(parent, {:dispatch_refused, action_id})
          {:error, :no_running_agent}

        @worker ->
          item = queue_item(decision, action_id, opts[:attempt_id], System.unique_integer([:positive]))
          send(parent, {:dispatched, action_id, item})
          {:ok, %{status: :accepted, item: item}}
      end
    end

    Application.put_env(:aiur, :decision_state_dir, dir)

    {:ok, pid} =
      [
        name: nil,
        state_dir: dir,
        filesystem_sync_fun: fn -> :ok end,
        dispatch_delay_ms: 0,
        reconcile_delay_ms: 0,
        retry_delays_ms: [],
        dispatcher: dispatcher,
        revision_follow_up_projector: fn _decision, _action_id -> :ok end,
        revision_follow_up_resolver: fn _decision, _action_id -> :ok end
      ]
      |> Keyword.merge(extra_opts)
      |> DecisionStore.start_link()

    pid
  end

  defp queue_item(decision, action_id, attempt_id, id) do
    answer = Decision.answer_for_action(decision, action_id) || %{decision_version: decision.version}

    %{
      id: id,
      category: :operator_message,
      target_issue_identifier: decision.ticket.identifier,
      action_id: action_id,
      status: :pending,
      correlation: %{
        decision_id: decision.decision_id,
        decision_version: answer.decision_version,
        action_id: action_id,
        attempt_id: attempt_id
      }
    }
  end

  defp wait_for(pid, decision_id, predicate, attempts \\ 100)

  defp wait_for(_pid, _decision_id, _predicate, 0), do: flunk("decision did not reach expected state")

  defp wait_for(pid, decision_id, predicate, attempts) do
    {:ok, decision} = DecisionStore.get(decision_id, pid)

    if predicate.(decision) do
      decision
    else
      assert_receive {:decision_changed, ^decision_id, _version}, 2_000
      wait_for(pid, decision_id, predicate, attempts - 1)
    end
  end
end
