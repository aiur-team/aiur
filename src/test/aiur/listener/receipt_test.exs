defmodule Aiur.Listener.ReceiptTest do
  use ExUnit.Case, async: false

  alias Aiur.{AgentQueue, AgentQueueStore, Listener}
  alias Aiur.Listener.Receipt
  alias Aiur.Orchestrator.{Calls, State}
  alias Aiur.Orchestrator.OperatorMessages.Snapshot

  defmodule QueueServer do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    def handle_call(message, from, state), do: Calls.handle_call(message, from, state)
  end

  test "pending pull item maps to held_async and preserves listener mode" do
    {_store, item} = enqueue(listener_mode: :async)
    assert %{receipt: :held_async, queue_status: :pending, listener_mode: :async} = Receipt.from_snapshot(item)
  end

  test "pending legacy and sync items map to accepted" do
    for opts <- [[], [listener_mode: :sync]] do
      {_store, item} = enqueue(opts)
      assert %{receipt: :accepted, queue_status: :pending} = Receipt.from_snapshot(item)
      assert Receipt.from_snapshot(item).listener_mode == Keyword.get(opts, :listener_mode)
    end
  end

  test "claimed and consumed items without provider confirmation remain accepted" do
    {store, item} = enqueue(listener_mode: :sync)
    {store, claimed} = AgentQueueStore.claim_next_deliverable(store, "repo#44")
    assert claimed.id == item.id
    assert %{receipt: :accepted, queue_status: :delivered} = Receipt.from_snapshot(claimed)
    {_store, consumed} = AgentQueueStore.mark_consumed(store, item.id)
    assert %{receipt: :accepted, queue_status: :consumed} = Receipt.from_snapshot(consumed)
  end

  test "provider-confirmed lifecycle is harness_queued through the real snapshot route" do
    {store, item} = enqueue(listener_mode: :sync)
    {store, _claimed} = AgentQueueStore.claim_next_deliverable(store, "repo#44")
    {store, _confirmed} = AgentQueueStore.mark_provider_delivered(store, item.id, %{})
    server = start_supervised!({QueueServer, %State{queue_store: store}})
    assert {:ok, confirmed} = Snapshot.read(server, item.id, 5_000)
    assert %{receipt: :harness_queued, queue_status: :delivered, listener_mode: :sync} = Receipt.from_snapshot(confirmed)
    {store, _consumed} = AgentQueueStore.mark_consumed(store, item.id)
    :sys.replace_state(server, fn _ -> %State{queue_store: store} end)
    assert {:ok, consumed} = Snapshot.read(server, item.id, 5_000)
    assert %{receipt: :harness_queued, queue_status: :consumed} = Receipt.from_snapshot(consumed)
  end

  test "failed and superseded items preserve their causes even after provider confirmation" do
    {_store, item} = enqueue([])

    for {status, reason} <- [failed: :provider_rejected, superseded: :superseded] do
      snapshot = %{item | status: status, failure_reason: :provider_rejected, provider_delivered_at: DateTime.utc_now()}
      assert %{receipt: :failed, failure_reason: ^reason, queue_status: ^status} = Receipt.from_snapshot(snapshot)
    end
  end

  test "missing item id maps to unknown even when another item has a known status" do
    {store, _item} = enqueue(listener_mode: :sync)
    server = start_supervised!({QueueServer, %State{queue_store: store}})
    assert {:ok, nil} = Snapshot.read(server, 4_242, 5_000)
    assert %{receipt: :unknown, queue_status: :unknown, listener_mode: nil} = Receipt.from_snapshot(nil)
  end

  test "snapshot timeout maps to outcome_unknown and unavailable remains an error" do
    server = start_supervised!({QueueServer, %State{queue_store: AgentQueueStore.new()}})
    :sys.suspend(server)

    try do
      assert {:error, {:outcome_unknown, :timeout}} = Snapshot.read(server, 1, 0)
    after
      :sys.resume(server)
    end

    GenServer.stop(server)
    assert {:error, :unavailable} = Snapshot.read(server, 1, 5_000)
  end

  test "receipt carries the time of observation" do
    {_store, item} = enqueue([])
    before_read = DateTime.utc_now()
    receipt = Receipt.from_snapshot(item)
    after_read = DateTime.utc_now()
    assert %DateTime{} = receipt.observed_at
    assert DateTime.compare(receipt.observed_at, before_read) in [:eq, :gt]
    assert DateTime.compare(receipt.observed_at, after_read) in [:eq, :lt]
  end

  test "send outcomes distinguish acceptance, failure and uncertainty" do
    assert Listener.receipt_for_send_result({:ok, 1}) == :accepted
    assert Listener.receipt_for_send_result({:error, :unavailable}) == :failed
    assert Listener.receipt_for_send_result({:error, {:outcome_unknown, %{message_id: "retry-id"}}}) == :outcome_unknown
  end

  test "public receipt reads the queue and propagates uncertain and unavailable reads" do
    {store, item} = enqueue(listener_mode: :sync)
    server = start_supervised!({QueueServer, %State{queue_store: store}})
    original = Process.whereis(Aiur.Orchestrator)
    if original, do: Process.unregister(Aiur.Orchestrator)
    Process.register(server, Aiur.Orchestrator)

    on_exit(fn ->
      if Process.whereis(Aiur.Orchestrator) == server, do: Process.unregister(Aiur.Orchestrator)
      if original && Process.alive?(original), do: Process.register(original, Aiur.Orchestrator)
    end)

    assert {:ok, %{receipt: :accepted, queue_status: :pending, listener_mode: :sync}} = Listener.receipt(item.id)
    assert {:ok, %{receipt: :unknown, queue_status: :unknown, listener_mode: nil}} = Listener.receipt(4_242)
    :sys.suspend(server)

    try do
      assert {:error, {:outcome_unknown, :timeout}} = Listener.receipt(item.id, 0)
    after
      :sys.resume(server)
    end

    Process.unregister(Aiur.Orchestrator)
    assert {:error, :unavailable} = Listener.receipt(item.id)
  end

  defp enqueue(opts) do
    attrs = AgentQueue.operator_message("repo#44", "ship it", opts)
    AgentQueueStore.enqueue(AgentQueueStore.new(), attrs)
  end
end
