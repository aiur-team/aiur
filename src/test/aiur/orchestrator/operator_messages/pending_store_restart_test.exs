defmodule Aiur.Orchestrator.OperatorMessages.PendingStoreRestartTest do
  use Aiur.TestSupport, async: false

  alias Aiur.{AgentQueue, AgentQueueStore}
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.OperatorMessages
  alias Aiur.Orchestrator.OperatorMessages.PendingStore

  defmodule AlertSink do
    def emit_custom(topic, message, opts) do
      send(Application.fetch_env!(:aiur, :pending_operator_messages_test_pid), {:pending_store_alert, topic, message, opts})
      :ok
    end
  end

  test "idle operator message survives restart until provider delivery, then is pruned after consume" do
    root = Aiur.TestSupport.tmp_root!("pending-operator-messages-restart")
    path = Path.join(root, "messages.json")
    previous = Application.get_env(:aiur, :pending_operator_messages_store_path)
    Application.put_env(:aiur, :pending_operator_messages_store_path, path)
    name = Module.concat(__MODULE__, RestartableOrchestrator)

    on_exit(fn ->
      restore_application_env(:pending_operator_messages_store_path, previous)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    {:ok, first_pid} = Orchestrator.start_link(name: name, initial_poll?: false)
    assert {:ok, queued_id} = Orchestrator.send_operator_message(name, "45", %{kind: :text, body: "resume this work"})
    assert length(persisted_items(path)) == 1
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    GenServer.stop(first_pid)

    {:ok, second_pid} = Orchestrator.start_link(name: name, initial_poll?: false)

    assert {:ok, %{id: ^queued_id, target_issue_identifier: "45", body: %{text: "resume this work"}}} =
             OperatorMessages.claim_next_queue_item(name, "45")

    assert length(persisted_items(path)) == 1
    GenServer.stop(second_pid)

    {:ok, third_pid} = Orchestrator.start_link(name: name, initial_poll?: false)

    assert {:ok, %{id: ^queued_id, target_issue_identifier: "45", body: %{text: "resume this work"}}} =
             OperatorMessages.claim_next_queue_item(name, "45")

    assert :ok = OperatorMessages.acknowledge_queue_item_delivery(name, queued_id, %{turn_id: "worker-turn"})
    assert persisted_items(path) == []
    assert :ok = OperatorMessages.mark_queue_item_consumed(name, queued_id)
    assert persisted_items(path) == []
    assert :empty = OperatorMessages.claim_next_queue_item(name, "45")
    GenServer.stop(third_pid)

    {:ok, fourth_pid} = Orchestrator.start_link(name: name, initial_poll?: false)
    assert :empty = OperatorMessages.claim_next_queue_item(name, "45")
    GenServer.stop(fourth_pid)
  end

  test "corrupt pending state is quarantined, alerts and starts with an empty queue" do
    root = Aiur.TestSupport.tmp_root!("pending-operator-messages-corrupt")
    path = Path.join(root, "messages.json")
    File.mkdir_p!(root)
    File.write!(path, "{broken json")
    previous_path = Application.get_env(:aiur, :pending_operator_messages_store_path)
    previous_signal = Application.get_env(:aiur, :signal)
    Application.put_env(:aiur, :pending_operator_messages_store_path, path)
    Application.put_env(:aiur, :pending_operator_messages_test_pid, self())
    Application.put_env(:aiur, :signal, alert_sink: AlertSink)
    name = Module.concat(__MODULE__, CorruptStoreOrchestrator)

    on_exit(fn ->
      restore_application_env(:pending_operator_messages_store_path, previous_path)
      restore_application_env(:signal, previous_signal)
      Application.delete_env(:aiur, :pending_operator_messages_test_pid)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    {:ok, pid} = Orchestrator.start_link(name: name, initial_poll?: false)
    assert :sys.get_state(pid).queue_store.items == %{}
    assert [quarantined] = Path.wildcard(path <> ".corrupt-*")
    assert File.read!(quarantined) == "{broken json"

    {:pending_store_alert, "operator_message_queue.recovery", message, opts} =
      receive_barrier({:pending_store_alert, "operator_message_queue.recovery", _, _})

    assert message =~ path
    assert message =~ "Starting with an empty queue"
    assert opts[:needs_attention]
    GenServer.stop(pid)
  end

  test "provider-acknowledged message is not redelivered after restart before consume" do
    root = Aiur.TestSupport.tmp_root!("pending-operator-messages-provider-ack")
    path = Path.join(root, "messages.json")
    previous = Application.get_env(:aiur, :pending_operator_messages_store_path)
    Application.put_env(:aiur, :pending_operator_messages_store_path, path)
    name = Module.concat(__MODULE__, ProviderAckOrchestrator)

    on_exit(fn ->
      restore_application_env(:pending_operator_messages_store_path, previous)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    {:ok, first_pid} = Orchestrator.start_link(name: name, initial_poll?: false)
    assert {:ok, queued_id} = Orchestrator.send_operator_message(name, "45", %{kind: :text, body: "already delivered"})
    assert {:ok, %{id: ^queued_id}} = OperatorMessages.claim_next_queue_item(name, "45")
    assert :ok = OperatorMessages.acknowledge_queue_item_delivery(name, queued_id, %{turn_id: "worker-turn"})
    assert persisted_items(path) == []
    GenServer.stop(first_pid)

    {:ok, second_pid} = Orchestrator.start_link(name: name, initial_poll?: false)
    assert :empty = OperatorMessages.claim_next_queue_item(name, "45")
    GenServer.stop(second_pid)
  end

  test "failed persistence returns an error and leaves the message out of memory" do
    root = Aiur.TestSupport.tmp_root!("pending-operator-messages-write-failure")
    path = Path.join(root, "messages.json")
    blocker = Path.join(root, "not-a-directory")
    File.mkdir_p!(root)
    File.write!(blocker, "block")
    previous = Application.get_env(:aiur, :pending_operator_messages_store_path)
    Application.put_env(:aiur, :pending_operator_messages_store_path, path)
    name = Module.concat(__MODULE__, FailedWriteOrchestrator)

    on_exit(fn ->
      restore_application_env(:pending_operator_messages_store_path, previous)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    {:ok, pid} = Orchestrator.start_link(name: name, initial_poll?: false)
    Application.put_env(:aiur, :pending_operator_messages_store_path, Path.join(blocker, "messages.json"))

    assert {:error, {:persistence_failed, _reason}} =
             Orchestrator.send_operator_message(name, "45", %{kind: :text, body: "must not queue"})

    state = :sys.get_state(pid)
    assert AgentQueueStore.list_pending(state.queue_store, "45") == []
    assert state.queue_store.items == %{}
    GenServer.stop(pid)
  end

  test "failed provider acknowledgement persistence leaves the unacknowledged state intact" do
    root = Aiur.TestSupport.tmp_root!("pending-operator-messages-ack-write-failure")
    path = Path.join(root, "messages.json")
    blocker = Path.join(root, "not-a-directory")
    File.mkdir_p!(root)
    File.write!(blocker, "block")
    previous = Application.get_env(:aiur, :pending_operator_messages_store_path)
    Application.put_env(:aiur, :pending_operator_messages_store_path, path)
    name = Module.concat(__MODULE__, FailedAckWriteOrchestrator)

    on_exit(fn ->
      restore_application_env(:pending_operator_messages_store_path, previous)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    {:ok, pid} = Orchestrator.start_link(name: name, initial_poll?: false)
    assert {:ok, queued_id} = Orchestrator.send_operator_message(name, "45", %{kind: :text, body: "ack must persist"})
    assert {:ok, %{id: ^queued_id}} = OperatorMessages.claim_next_queue_item(name, "45")
    Application.put_env(:aiur, :pending_operator_messages_store_path, Path.join(blocker, "messages.json"))

    assert {:error, {:persistence_failed, _reason}} =
             OperatorMessages.acknowledge_queue_item_delivery(name, queued_id, %{turn_id: "worker-turn"})

    item = :sys.get_state(pid).queue_store.items[queued_id]
    assert item.status == :delivered
    assert item.provider_delivered_at == nil
    assert length(persisted_items(path)) == 1
    GenServer.stop(pid)
  end

  test "full durable queue refuses a next-worker message without changing memory" do
    root = Aiur.TestSupport.tmp_root!("pending-operator-messages-cap")
    path = Path.join(root, "messages.json")
    previous = Application.get_env(:aiur, :pending_operator_messages_store_path)
    Application.put_env(:aiur, :pending_operator_messages_store_path, path)
    name = Module.concat(__MODULE__, FullQueueOrchestrator)

    on_exit(fn ->
      restore_application_env(:pending_operator_messages_store_path, previous)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    full_store =
      Enum.reduce(1..PendingStore.capacity(), AgentQueueStore.new(), fn number, store ->
        {store, _item} =
          AgentQueue.operator_message("45", "stored message #{number}", persist_across_restart?: true)
          |> then(&AgentQueueStore.enqueue(store, &1))

        store
      end)

    assert :ok = PendingStore.save(full_store)
    {:ok, pid} = Orchestrator.start_link(name: name, initial_poll?: false)

    assert {:error, {:queue_full, capacity}} =
             Orchestrator.send_operator_message(name, "45", %{kind: :text, body: "must be rejected"})

    assert capacity == PendingStore.capacity()
    state = :sys.get_state(pid)
    assert length(AgentQueueStore.list_pending(state.queue_store, "45")) == PendingStore.capacity()
    assert length(persisted_items(path)) == PendingStore.capacity()
    GenServer.stop(pid)
  end

  test "oversized legacy queue stays claimable while new sends remain capped" do
    root = Aiur.TestSupport.tmp_root!("pending-operator-messages-legacy-over-cap")
    path = Path.join(root, "messages.json")
    previous = Application.get_env(:aiur, :pending_operator_messages_store_path)
    Application.put_env(:aiur, :pending_operator_messages_store_path, path)
    name = Module.concat(__MODULE__, LegacyOversizedQueueOrchestrator)

    on_exit(fn ->
      restore_application_env(:pending_operator_messages_store_path, previous)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    oversized_store =
      Enum.reduce(1..(PendingStore.capacity() + 1), AgentQueueStore.new(), fn number, store ->
        {store, _item} =
          AgentQueue.operator_message("45", "legacy message #{number}", persist_across_restart?: true)
          |> then(&AgentQueueStore.enqueue(store, &1))

        store
      end)

    assert :ok = PendingStore.save(oversized_store)
    {:ok, pid} = Orchestrator.start_link(name: name, initial_poll?: false)

    assert {:error, {:queue_full, capacity}} =
             Orchestrator.send_operator_message(name, "45", %{kind: :text, body: "must wait"})

    assert capacity == PendingStore.capacity()
    assert {:ok, %{target_issue_identifier: "45"}} = OperatorMessages.claim_next_queue_item(name, "45")
    assert length(persisted_items(path)) == PendingStore.capacity() + 1
    GenServer.stop(pid)
  end

  defp persisted_items(path), do: Jason.decode!(File.read!(path))["items"]

  defp restore_application_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_application_env(key, value), do: Application.put_env(:aiur, key, value)
end
