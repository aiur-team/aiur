defmodule Aiur.Orchestrator.Status.OperatorMessageFencesTest do
  use Aiur.TestSupport

  import Aiur.OrchestratorStatusSupport

  alias Aiur.AgentPubSub
  alias Aiur.AgentRunner.QueueDrain
  alias Aiur.Opencode.ActiveTurns
  alias Aiur.Orchestrator.OperatorMessages

  test "orchestrator enqueues operator messages and pause requests for the running agent task" do
    orchestrator_name = Module.concat(__MODULE__, :OperatorMessageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)
    :ok = ActiveTurns.put("MT-CHAT", "turn-chat")

    on_exit(fn ->
      ActiveTurns.mark_closed("MT-CHAT", "turn-chat", :test_cleanup)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    parent = self()

    assert %{next_poll_due_at_ms: nil, tick_timer_ref: nil} = :sys.get_state(pid)

    worker_pid =
      spawn(fn ->
        operator_message_probe(parent)
      end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-chat" => %{
              pid: worker_pid,
              ref: make_ref(),
              identifier: "MT-CHAT",
              issue: %Issue{
                id: "issue-chat",
                identifier: "MT-CHAT",
                state: "In Progress",
                tracker_identity: tracker_identity("MT-CHAT")
              },
              control: %{
                can_interrupt: true,
                safe_checkpoints: [:notification, :tool_result],
                application_confirmation: :confirmed,
                generation: 1,
                version: 0,
                status: :working
              },
              session_id: "thread-chat-turn-chat",
              agent_input_tokens: 0,
              agent_output_tokens: 0,
              agent_total_tokens: 0,
              started_at: DateTime.utc_now()
            }
          }
      }
    end)

    assert {:ok, request_id} =
             Orchestrator.send_operator_message(orchestrator_name, "MT-CHAT", %{kind: :text, body: "hello"})

    assert is_integer(request_id)
    assert_receive {:agent_queue_updated, "MT-CHAT", ^request_id, false}, 1000

    assert {:ok, %{id: ^request_id, category: :operator_message, body: %{text: "hello"}}} =
             OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-CHAT")

    assert {:ok,
            %{
              accepts_operator_messages: true,
              can_interrupt: true,
              accepted_delivery_policies: [:checkpoint, :interrupt],
              queue_depth: 0
            }} = Orchestrator.control_capabilities(orchestrator_name, "MT-CHAT")

    assert {:ok, pause_request_id} = Orchestrator.pause_agent(orchestrator_name, "MT-CHAT")
    assert_receive {:pause_agent, ^pause_request_id, _generation}, 1000

    assert {:ok, interrupt_request_id} =
             Orchestrator.send_operator_message(
               orchestrator_name,
               "MT-CHAT",
               %{kind: :text, body: "stop now", delivery_policy: :interrupt}
             )

    assert is_integer(interrupt_request_id)

    checkpoint_result = Orchestrator.claim_next_checkpoint_queue_item(orchestrator_name, "MT-CHAT")
    assert Process.alive?(pid)
    assert :empty = checkpoint_result

    assert {:ok,
            %{
              id: ^interrupt_request_id,
              category: :operator_message,
              delivery: %{interrupt_requested: true, priority: :now}
            }} =
             OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-CHAT")

    assert {:error, :empty_message} =
             Orchestrator.send_operator_message(orchestrator_name, "MT-CHAT", %{kind: :text, body: "   "})

    assert {:error, :no_running_agent} =
             Orchestrator.send_operator_message(orchestrator_name, "MT-MISSING", %{kind: :text, body: "hello"})
  end

  test "orchestrator records queued evidence before notifying the worker" do
    orchestrator_name = Module.concat(__MODULE__, :QueuedEvidenceOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)
    parent = self()

    worker_pid =
      spawn(fn ->
        :ok = AgentPubSub.subscribe_agent("MT-QUEUED-EVIDENCE")
        send(parent, :queued_evidence_worker_ready)

        for position <- [:first, :second] do
          receive do
            message -> send(parent, {:queued_evidence_worker_message, position, message})
          end
        end
      end)

    assert_receive :queued_evidence_worker_ready, 1000

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-queued-evidence" =>
              running_entry(
                "issue-queued-evidence",
                "MT-QUEUED-EVIDENCE",
                :working,
                worker_pid
              )
          }
      }
    end)

    assert {:ok, request_id} =
             Orchestrator.send_operator_message(
               orchestrator_name,
               "MT-QUEUED-EVIDENCE",
               %{kind: :text, body: "authoritative rework"}
             )

    assert_receive {:queued_evidence_worker_message, :first,
                    {:transcript_event,
                     %{
                       role: :user,
                       body: "authoritative rework",
                       payload: %{
                         operator_message: %{request_id: ^request_id, status: :queued}
                       }
                     }}},
                   1000

    assert_receive {:queued_evidence_worker_message, :second, {:agent_queue_updated, "MT-QUEUED-EVIDENCE", ^request_id, _deliver_now?}}, 1000
  end

  test "provider acknowledgements clear only matching lifecycle fence items" do
    orchestrator_name = Module.concat(__MODULE__, :ProviderDeliveryFenceOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)
    :ok = AgentPubSub.subscribe_agent("MT-FENCE")
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-fence" => running_entry("issue-fence", "MT-FENCE", :working, parent)
          }
      }
    end)

    assert {:ok, first_id} =
             Orchestrator.send_operator_message(orchestrator_name, "MT-FENCE", %{
               kind: :text,
               body: "first review instruction"
             })

    assert {:ok, second_id} =
             Orchestrator.send_operator_message(orchestrator_name, "MT-FENCE", %{
               kind: :text,
               body: "second review instruction"
             })

    state = :sys.get_state(pid)

    assert state.running["issue-fence"].lifecycle_fence.pending_item_ids ==
             MapSet.new([first_id, second_id])

    assert {:ok, %{id: ^first_id}} =
             Orchestrator.claim_next_queue_item(orchestrator_name, "MT-FENCE")

    assert OperatorMessages.pending_operator_messages_for_issue(
             :sys.get_state(pid),
             "MT-FENCE"
           ) == [
             %{id: first_id, text: "first review instruction", status: :queued},
             %{id: second_id, text: "second review instruction", status: :queued}
           ]

    assert :ok =
             Orchestrator.acknowledge_queue_item_delivery(
               orchestrator_name,
               first_id,
               %{turn_id: "provider-turn-1"}
             )

    state = :sys.get_state(pid)

    assert state.running["issue-fence"].lifecycle_fence.pending_item_ids ==
             MapSet.new([second_id])

    assert_receive {:transcript_event,
                    %{
                      role: :system,
                      payload: %{
                        operator_message: %{
                          request_id: ^first_id,
                          status: :delivered,
                          provider_turn_id: "provider-turn-1"
                        }
                      }
                    }},
                   1000

    assert {:ok, %{id: ^second_id}} =
             Orchestrator.claim_next_queue_item(orchestrator_name, "MT-FENCE")

    assert :ok =
             Orchestrator.acknowledge_queue_item_delivery(
               orchestrator_name,
               second_id,
               %{turn_id: "provider-turn-2"}
             )

    refute Map.has_key?(:sys.get_state(pid).running["issue-fence"], :lifecycle_fence)

    assert OperatorMessages.pending_operator_messages_for_issue(
             :sys.get_state(pid),
             "MT-FENCE"
           ) == [
             %{id: first_id, text: "first review instruction", status: :delivered},
             %{id: second_id, text: "second review instruction", status: :delivered}
           ]

    assert {:ok, failed_id} =
             Orchestrator.send_operator_message(orchestrator_name, "MT-FENCE", %{
               kind: :text,
               body: "delivery will fail"
             })

    assert {:ok, %{id: ^failed_id}} =
             Orchestrator.claim_next_queue_item(orchestrator_name, "MT-FENCE")

    assert :ok =
             Orchestrator.mark_queue_item_failed(
               orchestrator_name,
               failed_id,
               :provider_down
             )

    state = :sys.get_state(pid)
    assert state.running["issue-fence"].lifecycle_fence.pending_item_ids == MapSet.new([failed_id])

    assert List.last(OperatorMessages.pending_operator_messages_for_issue(state, "MT-FENCE")) == %{id: failed_id, text: "delivery will fail", status: :failed}
  end

  test "provider acknowledgement clears every fence item folded into one event digest" do
    orchestrator_name = Module.concat(__MODULE__, :CoalescedFenceOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-coalesced-fence" =>
              running_entry(
                "issue-coalesced-fence",
                "MT-COALESCED-FENCE",
                :working,
                parent
              )
          }
      }
    end)

    for event_id <- [101, 102] do
      assert :ok =
               GenServer.call(orchestrator_name, {
                 :enqueue_event_digest,
                 "MT-COALESCED-FENCE",
                 %{
                   id: event_id,
                   topic: "ticket.MT-COALESCED-FENCE.issue.commented",
                   source: :github,
                   author_trusted?: true,
                   comment: %{id: event_id, body: "authoritative review #{event_id}"}
                 }
               })
    end

    assert_receive {:agent_queue_updated, "MT-COALESCED-FENCE", first_id, _deliver_now?}, 1000
    assert_receive {:agent_queue_updated, "MT-COALESCED-FENCE", second_id, _deliver_now?}, 1000

    state = :sys.get_state(pid)

    assert state.running["issue-coalesced-fence"].lifecycle_fence.pending_item_ids ==
             MapSet.new([first_id, second_id])

    assert {:ok, item} =
             Orchestrator.claim_next_queue_item(
               orchestrator_name,
               "MT-COALESCED-FENCE"
             )

    assert item.delivery.coalesced_item_ids == [first_id, second_id]

    assert :ok =
             QueueDrain.acknowledge_provider_delivery(
               orchestrator_name,
               item,
               %{turn_id: "provider-turn-coalesced"}
             )

    refute Map.has_key?(
             :sys.get_state(pid).running["issue-coalesced-fence"],
             :lifecycle_fence
           )
  end

  test "correlated operator messages return queue snapshots and notify only on enqueue or failed retry" do
    orchestrator_name = Module.concat(__MODULE__, :CorrelatedOperatorMessageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()
    worker_pid = spawn(fn -> operator_message_probe(parent) end)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      if Process.alive?(worker_pid), do: Process.exit(worker_pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-occ" => running_entry("issue-occ", "MT-OCC", :working, worker_pid)}}
    end)

    correlation = %{
      decision_id: "dec_123",
      decision_version: 1,
      action_id: "act_123",
      actor: %{kind: :operator, id: "operator-1"}
    }

    payload = %{
      kind: :text,
      body: "Decision dec_123 answered: ship",
      action_id: "act_123",
      correlation: correlation
    }

    assert {:ok, %{status: :accepted, item: accepted}} =
             Orchestrator.send_correlated_operator_message(orchestrator_name, "MT-OCC", payload)

    assert accepted.status == :pending
    assert accepted.correlation == correlation
    assert_receive {:agent_queue_updated, "MT-OCC", accepted_id, _}, 1000
    assert accepted_id == accepted.id

    running = :sys.get_state(pid).running
    :sys.replace_state(pid, &%{&1 | running: %{}})

    assert {:ok, %{status: :duplicate, item: duplicate}} =
             Orchestrator.send_correlated_operator_message(orchestrator_name, "MT-OCC", payload)

    assert duplicate.id == accepted.id
    refute_receive {:agent_queue_updated, "MT-OCC", _, _}, 100

    :sys.replace_state(pid, &%{&1 | running: running})

    assert {:ok, delivered} = OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-OCC")
    assert :ok = OperatorMessages.mark_queue_item_failed(orchestrator_name, delivered.id, :agent_unavailable)

    assert {:ok, %{status: :retried, item: retried}} =
             Orchestrator.send_correlated_operator_message(
               orchestrator_name,
               "MT-OCC",
               Map.put(payload, :retry_failed, true)
             )

    assert retried.id == accepted.id
    assert retried.status == :pending
    assert_receive {:agent_queue_updated, "MT-OCC", retried_id, _}, 1000
    assert retried_id == accepted.id

    assert {:error, {:idempotency_conflict, "act_123"}} =
             Orchestrator.send_correlated_operator_message(
               orchestrator_name,
               "MT-OCC",
               Map.put(payload, :body, "Decision dec_123 answered differently")
             )
  end
end
