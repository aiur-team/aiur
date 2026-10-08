defmodule Aiur.Orchestrator.OperatorMessages.QueueClaimTest do
  use Aiur.TestSupport

  alias Aiur.{AgentQueue, AgentQueueStore, Orchestrator}
  alias Aiur.Orchestrator.OperatorMessages

  defmodule SlowPollClient do
    def fetch_issues_by_states(_states, _opts \\ []), do: {:ok, []}

    def fetch_candidate_issues do
      send(Application.fetch_env!(:aiur, :queue_claim_test_pid), {:poll_blocked, self()})

      receive do
        :release_poll -> {:ok, []}
      end
    end
  end

  setup do
    previous = for key <- [:linear_client_module, :queue_claim_test_pid], do: {key, Application.fetch_env(:aiur, key)}
    Application.put_env(:aiur, :linear_client_module, SlowPollClient)
    Application.put_env(:aiur, :queue_claim_test_pid, self())
    on_exit(fn -> Aiur.TestSupport.restore_app_env(previous) end)
    :ok
  end

  test "queue claims keep their receipts while a tracker poll is held off the owner" do
    server = start_supervised!({Orchestrator, initial_poll?: false})
    test_pid = self()

    :sys.replace_state(server, fn state ->
      {store, item} = AgentQueueStore.enqueue(state.queue_store, AgentQueue.operator_message("MT-3203", "/approve yes"))
      send(test_pid, {:queued, item.id})
      %{state | queue_store: store}
    end)

    assert_received {:queued, item_id}
    assert {:ok, :pending} = OperatorMessages.operator_message_status(server, item_id)
    send(server, :run_poll_cycle)
    receive_barrier({:poll_blocked, poller})
    on_exit(fn -> send(poller, :release_poll) end)

    # The held poll runs in a tracker task, so the owner keeps answering within the
    # claim deadline instead of letting a late claim consume a receipt (#3203, #3213).
    refute poller == server
    assert is_list(GenServer.call(server, :status, 5_000))

    claims = [
      {:claim_next_queue_item, fn -> OperatorMessages.claim_next_queue_item(server, "MT-3203") end},
      {:claim_next_checkpoint_queue_item, fn -> OperatorMessages.claim_next_checkpoint_queue_item(server, "MT-3203") end},
      {:claim_blocker_critical_events_digest, fn -> OperatorMessages.claim_blocker_critical_events_digest(server, "MT-3203") end},
      {:claim_next_operator_queue_item, fn -> OperatorMessages.claim_next_operator_queue_item(server, "MT-3203") end},
      {:claim_operator_response, fn -> OperatorMessages.claim_operator_response(server, "MT-3203", "/approve") end}
    ]

    tasks = Enum.map(claims, fn {method, claim} -> start_waiting_claim(server, method, claim) end)

    send(poller, :release_poll)
    results = Enum.map(tasks, &Task.await(&1, :infinity))
    assert Enum.count(results, &(&1 == :empty)) == 4
    assert [{:ok, claimed}] = Enum.filter(results, &match?({:ok, _item}, &1))
    assert claimed.id == item_id
    assert claimed.body.text == "/approve yes"
    assert claimed.delivery_attempts == 1
    assert {:ok, :delivered} = OperatorMessages.operator_message_status(server, item_id)
    assert :empty = OperatorMessages.claim_next_queue_item(server, "MT-3203")
    assert :ok = OperatorMessages.mark_queue_item_consumed(server, item_id)
    assert {:ok, :consumed} = OperatorMessages.operator_message_status(server, item_id)
  end

  # Deliberate future guard: this already passed before the timeout repair.
  test "waiting claim returns unavailable when its queue owner stops" do
    server = start_supervised!({Orchestrator, initial_poll?: false})
    :ok = :sys.suspend(server)
    task = start_waiting_claim(server, :claim_next_queue_item, fn -> OperatorMessages.claim_next_queue_item(server, "MT-3203") end)
    assert :ok = stop_supervised(Orchestrator)
    assert {:error, :unavailable} = Task.await(task, :infinity)
  end

  defp start_waiting_claim(server, method, claim) do
    task =
      Task.async(fn ->
        receive do
          :claim -> claim.()
        end
      end)

    task_pid = task.pid
    :erlang.trace(task_pid, true, [:send])
    send(task_pid, :claim)
    receive_barrier({:trace, ^task_pid, :send, {:"$gen_call", _from, request}, ^server})
    :erlang.trace(task_pid, false, [:send])
    assert elem(request, 0) == method
    task
  end
end
