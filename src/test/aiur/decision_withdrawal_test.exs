defmodule Aiur.DecisionWithdrawalTest do
  @moduledoc """
  #2711: a `:decided` Command whose answer never reached an agent can be
  withdrawn (moot) or replaced (supersede) by the Executor, and neither the
  withdrawn nor the replaced answer is ever delivered — not to the original
  worker, and not to a later worker of the same ticket. A delivered answer
  stays immutable.

  The scenario mirrors Khala #12/#13: the Executor answers a blocking Command
  after its worker has gone, so every dispatch fails `target_agent_unavailable`
  and the answer stays decided but undelivered. Then a fresh worker exists for
  the same ticket (the dispatcher starts to accept) and the store restarts, which
  is the moment the old code re-dispatched the stale answer to it.
  """
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.QueueDrain
  alias Aiur.{AlertFeed, Decision, DecisionEvent, DecisionPubSub, DecisionStore}

  @ticket %{identifier: "2711", title: "Withdraw undelivered answers", url: "https://github.com/aiur-team/aiur/issues/2711"}
  @source %{agent_id: "codex", session_id: "worker-session-1", event_id: "request-1"}
  @executor %{kind: :executor, id: "khala-executor"}
  @operator %{kind: :operator, id: "operator-1"}
  @target_agent %{kind: :agent, id: "codex"}
  @reconcile_report_timeout_ms 30_000

  # Worker presence for the ticket, read by the injected dispatcher.
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

      File.rm_rf!(dir)
    end)

    worker = :atomics.new(1, [])
    :atomics.put(worker, 1, @no_worker)
    %{dir: dir, worker: worker}
  end

  describe "moot a decided but undelivered Command" do
    test "records an audited moot and never delivers the answer, even to a later worker", %{dir: dir, worker: worker} do
      pid = start_store!(dir, worker)
      {decision, original} = undelivered_answer(pid)

      assert {:ok, %{status: :accepted, decision: mooted}} =
               DecisionStore.moot(
                 decision.decision_id,
                 %{"reason_class" => "operator_changed_direction", "reason" => "Operator chose a new approach."},
                 [actor: @executor],
                 pid
               )

      assert mooted.decision_status == :moot
      # The answer is kept for the audit trail; the status is what withdraws it.
      assert mooted.answer == original

      assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)

      assert %DecisionEvent{
               type: :decision_mooted,
               data: %{reason_class: "operator_changed_direction", detail: "Operator chose a new approach.", actor: @executor}
             } = List.last(audit)

      # Idempotent.
      assert {:ok, %{status: :duplicate}} =
               DecisionStore.moot(decision.decision_id, %{"reason_class" => "operator_changed_direction"}, [actor: @executor], pid)

      # A queue item made for the answer before the moot is refused at the
      # delivery gate, and the worker settles it as failed without retrying.
      stale_item = queue_item(decision, original.action_id, "#{original.action_id}:1", 41)
      assert {:error, {:answer_withdrawn, :moot}} = DecisionStore.validate_delivery(stale_item, pid)

      assert {:error, {:failed, {:answer_withdrawn, :moot}}} =
               QueueDrain.prepare_operator_delivery(stale_item, %{identifier: @ticket.identifier}, pid)

      # Nothing can revive it: no new answer, no revision, no explicit retry.
      assert {:error, {:conflict, :moot}} = supersede(pid, decision, "replacement", "Use the new approach")
      assert {:error, _reason} = DecisionStore.retry_dispatch(decision.decision_id, original.action_id, pid)

      # A fresh worker now runs the same ticket and the daemon restarts. The
      # reconciliation pass sees the Command and schedules nothing for it.
      :atomics.put(worker, 1, @worker)
      GenServer.stop(pid)
      restarted = start_store!(dir, worker)

      assert_receive {:decision_dispatches_reconciled, %{store: ^restarted, fences: 1, dispatched: []}},
                     @reconcile_report_timeout_ms

      assert {:ok, durable} = DecisionStore.get(decision.decision_id, restarted)
      assert durable.decision_status == :moot
      assert Enum.all?(durable.dispatch_attempts, &is_nil(&1.delivered_at))
      refute_received {:dispatched, _action_id, _item}
    end
  end

  describe "supersede a decided but undelivered Command" do
    test "records the new answer as a revision and delivers only the newest answer", %{dir: dir, worker: worker} do
      pid = start_store!(dir, worker)
      {decision, original} = undelivered_answer(pid)

      assert {:ok, %{status: :accepted, action: replacement, decision: superseded}} =
               supersede(pid, decision, "replace-1", "Use the new approach")

      assert superseded.answer == original
      assert Decision.active_answer(superseded) == replacement.answer
      assert replacement.prior_action_id == original.action_id
      assert replacement.answer.actor == @executor
      assert replacement.reason == "Operator changed direction"

      # Exact retry replays; the audit holds one revision.
      assert {:ok, %{status: :duplicate, action: replayed}} = supersede(pid, decision, "replace-1", "Use the new approach")
      assert replayed.action_id == replacement.action_id

      assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
      assert Enum.count(audit, &match?(%DecisionEvent{type: :revision_recorded}, &1)) == 1

      # A second change of direction supersedes the replacement too.
      assert {:ok, %{status: :accepted, action: newest}} = supersede(pid, decision, "replace-2", "Use the newest approach")
      assert newest.prior_action_id == replacement.action_id

      # With no worker, the newest answer is undelivered too.
      _failed =
        wait_for(pid, decision.decision_id, fn current ->
          match?(%{action_id: action_id, status: :failed} when action_id == newest.action_id, List.last(Decision.active_dispatch_attempts(current)))
        end)

      # The gate refuses every replaced action and admits only the newest.
      assert {:error, {:answer_withdrawn, :superseded}} =
               DecisionStore.validate_delivery(queue_item(decision, original.action_id, "#{original.action_id}:1", 51), pid)

      assert {:error, {:answer_withdrawn, :superseded}} =
               DecisionStore.validate_delivery(queue_item(decision, replacement.action_id, "#{replacement.action_id}:1", 52), pid)

      # A fresh worker runs the ticket and the daemon restarts: only the newest
      # answer is dispatched to it.
      :atomics.put(worker, 1, @worker)
      GenServer.stop(pid)
      flush_dispatches()
      restarted = start_store!(dir, worker)

      assert_receive {:decision_dispatches_reconciled, %{store: ^restarted, dispatched: dispatched}},
                     @reconcile_report_timeout_ms

      assert [%{action_id: newest_action_id, kind: :dispatch}] = dispatched
      assert newest_action_id == newest.action_id

      assert_receive {:dispatched, dispatched_action_id, item}, 5_000
      assert dispatched_action_id == newest.action_id
      refute_received {:dispatched, _other_action_id, _other_item}

      _queued = wait_for(restarted, decision.decision_id, &(&1.delivery_status == :queued))
      assert {:ok, :accepted} = DecisionStore.validate_delivery(item, restarted)
      assert {:ok, :accepted} = DecisionStore.record_delivery(item, restarted)
      delivered = wait_for(restarted, decision.decision_id, &(&1.delivery_status == :delivered))

      delivered_actions =
        delivered.dispatch_attempts |> Enum.reject(&is_nil(&1.delivered_at)) |> Enum.map(& &1.action_id)

      assert delivered_actions == [newest.action_id]
    end

    test "is refused for a Command that has no answer yet", %{dir: dir, worker: worker} do
      pid = start_store!(dir, worker)
      assert {:ok, %{decision: decision}} = request(pid)

      assert {:error, {:not_decided, :open}} = supersede(pid, decision, "too-early", "Answer first")
    end
  end

  describe "a delivered Command stays immutable" do
    test "moot and supersede are refused once the answer reached the agent", %{dir: dir, worker: worker} do
      :atomics.put(worker, 1, @worker)
      pid = start_store!(dir, worker)
      assert {:ok, %{decision: decision}} = request(pid)
      assert {:ok, %{action: original}} = answer(pid, decision, "delivered-answer", "Proceed")

      assert_receive {:dispatched, _action_id, item}, 5_000
      _queued = wait_for(pid, decision.decision_id, &(&1.delivery_status == :queued))
      assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)
      delivered = wait_for(pid, decision.decision_id, &(&1.delivery_status == :delivered))
      assert delivered.decision_status == :decided

      assert {:error, {:conflict, :answer_delivered}} =
               DecisionStore.moot(decision.decision_id, %{"reason_class" => "operator_changed_direction"}, [actor: @executor], pid)

      assert {:error, {:conflict, :answer_delivered}} = supersede(pid, decision, "late", "Too late")

      assert {:ok, %{status: :accepted}} =
               DecisionStore.agent_lifecycle(
                 :acknowledged,
                 %{decision_id: decision.decision_id, action_id: original.action_id, expected_version: decision.version},
                 [ticket_identifier: @ticket.identifier, actor: @target_agent, source: @source],
                 pid
               )

      assert {:error, {:conflict, :answer_delivered}} =
               DecisionStore.moot(decision.decision_id, %{"reason_class" => "operator_changed_direction"}, [actor: @executor], pid)

      assert {:ok, current} = DecisionStore.get(decision.decision_id, pid)
      assert current.answer == original
      assert current.revisions == []
      assert current.decision_status == :acknowledged
    end
  end

  describe "an answer handed to a worker is in flight (review of #2712)" do
    test "moot and supersede are refused between the gate and the provider confirmation", %{dir: dir, worker: worker} do
      pid = start_store!(dir, worker)
      {decision, original, item} = queued_answer(pid, worker)

      # Before the gate, the queued answer can still be withdrawn in principle.
      refute Decision.handed_off?(elem(DecisionStore.get(decision.decision_id, pid), 1))

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

  describe "Executor authority to withdraw a decided answer (review of #2712)" do
    test "an Executor cannot moot an operator answer it could not have given", %{dir: dir, worker: worker} do
      pid = start_store!(dir, worker)
      assert {:ok, %{decision: decision}} = request(pid, "human_required")
      assert {:ok, %{action: _answer}} = answer(pid, decision, "operator-answer", "Operator plan", @operator)

      assert {:error, {:answer_invalid, {:executor_scope, {:authority, :human_required}}}} = moot(pid, decision)
      assert {:ok, %{decision_status: :decided}} = DecisionStore.get(decision.decision_id, pid)

      # The operator can still withdraw it.
      assert {:ok, %{status: :accepted}} = moot(pid, decision, @operator)
    end

    test "an Executor can moot an operator answer it could have given itself", %{dir: dir, worker: worker} do
      pid = start_store!(dir, worker)
      assert {:ok, %{decision: decision}} = request(pid, "supervisor_allowed")
      assert {:ok, %{action: _answer}} = answer(pid, decision, "operator-answer", "Operator plan", @operator)

      assert {:ok, %{status: :accepted, decision: %{decision_status: :moot}}} = moot(pid, decision)
    end
  end

  # -- helpers ---------------------------------------------------------------

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
        "reversibility" => "reversible"
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

  defp start_store!(dir, worker) do
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
      DecisionStore.start_link(
        name: nil,
        state_dir: dir,
        filesystem_sync_fun: fn -> :ok end,
        dispatch_delay_ms: 0,
        reconcile_delay_ms: 0,
        retry_delays_ms: [],
        dispatcher: dispatcher,
        revision_follow_up_projector: fn _decision, _action_id -> :ok end,
        revision_follow_up_resolver: fn _decision, _action_id -> :ok end
      )

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

  defp flush_dispatches do
    receive do
      {:dispatched, _action_id, _item} -> flush_dispatches()
      {:dispatch_refused, _action_id} -> flush_dispatches()
    after
      0 -> :ok
    end
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
