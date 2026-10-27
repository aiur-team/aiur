defmodule Aiur.Orchestrator.HeldReadsTest do
  use ExUnit.Case, async: true
  alias Aiur.{AgentQueue, AgentQueueStore}
  alias Aiur.Listener.{ModeStore, Receipt}
  alias Aiur.Orchestrator.{LifecycleFence, State}
  alias Aiur.Orchestrator.OperatorMessages.HeldReads

  setup do
    dir = Aiur.TestSupport.tmp_root!("held-reads")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    %{opts: [dir: dir, repo_name: "read-test"]}
  end

  test "oldest first consuming read persists cursor, read receipt, and emits a batch", %{opts: opts} do
    :ok = Aiur.AgentPubSub.subscribe_agent("held-42")
    {store, first} = enqueue(AgentQueueStore.new(), "first")
    {store, second} = enqueue(store, "second")
    state = %State{queue_store: store}
    assert {:reply, {:ok, %{messages: messages, remaining: 0}}, next} = HeldReads.handle_call(state, "held-42", 50, opts)
    assert messages == [message(first, "first"), message(second, "second")]

    for id <- [first.id, second.id] do
      item = AgentQueueStore.get(next.queue_store, id)
      assert item.status == :consumed
      assert %DateTime{} = item.read_at
      assert Receipt.from_snapshot(item).receipt == :read
    end

    assert ModeStore.get("held-42", opts).last_read_sequence == second.sequence
    assert {:ok, record} = ModeStore.put("held-42", :sync, 0, %{actor: :human}, opts)
    assert record.last_read_sequence == second.sequence
    assert ModeStore.get("held-42", opts).last_read_sequence == second.sequence
    assert {:reply, {:ok, %{messages: [], remaining: 0}}, ^next} = HeldReads.handle_call(next, "held-42", 50, opts)
    assert_received {:transcript_event, event}
    assert event.payload.operator_message.status == :read
    assert event.payload.operator_message.request_ids == [first.id, second.id]
    assert_received {:transcript_event, %{role: :system, payload: %{listener: %{unread_count: 0, oldest_unread_at: nil}}}}
    refute_received {:transcript_event, %{payload: %{listener: _}}}
  end

  test "only held operator messages from this ticket are consumed", %{opts: opts} do
    {store, normal} = AgentQueueStore.enqueue(AgentQueueStore.new(), AgentQueue.operator_message("held-42", "sync", listener_mode: :sync))
    {store, other} = AgentQueueStore.enqueue(store, AgentQueue.operator_message("other", "private", listener_mode: :async))
    {store, held} = enqueue(store, "held")
    assert {:reply, {:ok, %{messages: [result], remaining: 0}}, next} = HeldReads.handle_call(%State{queue_store: store}, "held-42", 50, opts)
    assert result == message(held, "held")
    assert AgentQueueStore.get(next.queue_store, normal.id).status == :pending
    assert AgentQueueStore.get(next.queue_store, other.id).status == :pending
  end

  test "count limit and UTF-8 byte budget leave the remaining messages unread", %{opts: opts} do
    store = Enum.reduce(1..51, AgentQueueStore.new(), fn n, store -> elem(enqueue(store, to_string(n)), 0) end)
    assert {:reply, {:ok, %{messages: messages, remaining: 1}}, next} = HeldReads.handle_call(%State{queue_store: store}, "held-42", 50, opts)
    assert length(messages) == 50
    assert {:reply, {:ok, %{messages: [%{text: "51"}], remaining: 0}}, _} = HeldReads.handle_call(next, "held-42", 1, opts)
    {store, _} = enqueue(AgentQueueStore.new(), String.duplicate("x", 65_535))
    {store, clipped} = enqueue(store, "éé")
    {store, unread} = enqueue(store, "later")
    assert {:reply, {:ok, %{messages: [first, last], remaining: 1}}, next} = HeldReads.handle_call(%State{queue_store: store}, "held-42", 50, opts)
    assert byte_size(first.text) == 65_535
    assert last == Map.put(message(clipped, ""), :truncated, true)
    assert String.valid?(last.text)
    assert AgentQueueStore.get(next.queue_store, clipped.id).status == :consumed
    assert AgentQueueStore.get(next.queue_store, unread.id).status == :pending
  end

  test "cursor write failure leaves the queue unread", %{opts: opts} do
    file = Path.join(opts[:dir], "file")
    File.mkdir_p!(opts[:dir])
    File.write!(file, "not a directory")
    {store, _} = enqueue(AgentQueueStore.new(), "retain me")
    state = %State{queue_store: store}
    assert {:reply, {:error, {:write_failed, _}}, ^state} = HeldReads.handle_call(state, "held-42", 50, Keyword.put(opts, :dir, file))
  end

  test "partial reads acknowledge only read lifecycle fences", %{opts: opts} do
    {store, first} = enqueue(AgentQueueStore.new(), "first")
    {store, second} = enqueue(store, "second")
    issue = %Aiur.Issue{id: "issue-42", identifier: "held-42", state: "in-progress"}
    state = %State{queue_store: store, running: %{issue.id => %{identifier: issue.identifier, issue: issue}}}
    state = Enum.reduce([first, second], state, &LifecycleFence.protect_queued_item(&2, issue.identifier, &1))
    assert LifecycleFence.handoff_blocked?(state, issue)
    assert {:reply, {:ok, %{remaining: 1}}, next} = HeldReads.handle_call(state, issue.identifier, 1, opts)
    refute LifecycleFence.protected_item?(next, first)
    assert LifecycleFence.protected_item?(next, second)
    assert {:reply, {:ok, %{remaining: 0}}, next} = HeldReads.handle_call(next, issue.identifier, 1, opts)
    refute LifecycleFence.handoff_blocked?(next, issue)
  end

  test "expired serialized request never consumes messages", %{opts: opts} do
    {store, item} = enqueue(AgentQueueStore.new(), "not read")
    state = %State{queue_store: store}
    expired = System.monotonic_time(:millisecond) - 1
    # The test server uses the production Orchestrator router and serialized state.
    assert {:reply, {:error, :read_timeout}, ^state} = HeldReads.handle_call(state, "held-42", 50, Keyword.put(opts, :deadline, expired))
    empty = %State{}
    {:ok, server} = GenServer.start_link(__MODULE__.Server, empty)
    assert {:error, :read_timeout} = GenServer.call(server, {:read_held_messages, "held-42", 50, expired})
    assert :sys.get_state(server) == empty
    assert AgentQueueStore.get(state.queue_store, item.id).read_at == nil
    assert {:ok, %{messages: [], remaining: 0}} = HeldReads.read(server, "empty", 50)
    GenServer.stop(server)
    refute File.exists?(ModeStore.path_for("held-42", opts))
  end

  defmodule Server do
    use GenServer
    def init(state), do: {:ok, state}
    def handle_call(request, from, state), do: Aiur.Orchestrator.handle_call(request, from, state)
  end

  defp enqueue(store, text), do: AgentQueueStore.enqueue(store, AgentQueue.operator_message("held-42", text, listener_mode: :async))
  defp message(item, text), do: %{id: item.id, text: text, from: "operator", accepted_at: DateTime.to_iso8601(item.inserted_at)}
end
