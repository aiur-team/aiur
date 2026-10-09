defmodule Aiur.BuildQueue.ServerTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.BuildQueue.{Hints, Model, Server}
  alias Aiur.Config.Schema
  alias Aiur.Events.Exchange

  defmodule Boundary do
    def open_issue_labels(_age), do: Agent.get(__MODULE__, & &1.snapshot)
    def load, do: Agent.get(__MODULE__, & &1.document)
    def status(_ids), do: :unavailable
    def save(document), do: Agent.update(__MODULE__, &%{&1 | document: {:ok, document}})
    def update_issue_state(id, "todo", expected_state: :none), do: call({:promote, id})
    def notify_demand(ids), do: call({:demand, ids})
    def ensure_labels(labels), do: call({:ensure, labels})
    def add_label(id, label), do: call({:mark, id, label})
    def remove_label(id, label), do: call({:unmark, id, label})

    defp call(call) do
      Agent.get_and_update(__MODULE__, fn state -> {state.result, %{state | calls: state.calls ++ [{call, state.document}]}} end)
    end
  end

  setup do
    pid = start_supervised!({Agent, fn -> %{calls: [], result: :ok, now: 1_000, snapshot: :none, document: {:ok, %{queues: [], items: [], edges: [], intents: [], latches: []}}} end})
    Process.register(pid, Boundary)
    :ok
  end

  test "unsupported tracker has no table or timers" do
    update(:snapshot, {:error, :unsupported})
    pid = server()
    assert GenServer.call(pid, :status) == :unsupported_tracker
    assert :ets.whereis(Hints.table_name()) == :undefined
    assert :ok = GenServer.call(pid, :reconcile_now)
    refute_received {:scheduled, ^pid, _, _}
  end

  test "disabled server remains inert" do
    pid = server(settings: {:ok, settings(false)})
    assert GenServer.call(pid, :status) == :disabled
    assert :ets.whereis(Hints.table_name()) == :undefined
    refute_received {:scheduled, ^pid, _, _}
  end

  test "store failure leaves neutral protected hints and no timers" do
    update(:document, {:error, :corrupt})
    pid = server()
    assert GenServer.call(pid, :status) == :store_unavailable
    assert :ets.info(Hints.table_name(), :owner) == pid
    assert :ets.info(Hints.table_name(), :protection) == :protected
    assert Hints.sort_key("1") == {0, 0}
    refute Hints.held?("1")
    refute_received {:scheduled, ^pid, _, _}
  end

  test "two real open-issue signals coalesce into one reconciliation" do
    pid = server()
    boot(pid)
    assert :ok = Phoenix.PubSub.subscribe(Aiur.PubSub, "build_queue:changed")
    Phoenix.PubSub.broadcast(Aiur.PubSub, "tracker:open_issues", {:open_issues_recorded, 1})
    {^pid, message, 2_000} = scheduled()
    send(pid, {:open_issues_recorded, 2})
    GenServer.call(pid, :status)
    refute_received {:scheduled, ^pid, {:reconcile, _}, _}
    send(pid, message)
    assert {:ok, %{reconciles: 2}} = GenServer.call(pid, :show)
    assert_received {:build_queue_changed, :running}
  end

  test "Exchange bindings schedule every required topic" do
    exchange = start_supervised!({Exchange, name: nil})
    pid = server(exchange: exchange)
    boot(pid)

    for topic <- ["ticket.7.pr.merged", "ticket.7.issue.label.added.agent.todo", "ticket.7.agent.attention.error-store", "ticket.7.dependency.merged_blocker_reconciled"] do
      assert Exchange.publish(topic, %{topic: topic}, exchange) == 1
      {^pid, message, 2_000} = scheduled()
      send(pid, message)
      GenServer.call(pid, :status)
    end

    assert {:ok, %{reconciles: 5}} = GenServer.call(pid, :show)
    assert Exchange.publish("ticket.7.branch.push", %{}, exchange) == 0
  end

  test "fallback tick rebinds a missing Exchange and plans from changed snapshots" do
    fixture()
    update(:snapshot, :none)
    pid = server(exchange: :queue_test_exchange)
    assert_received {:scheduled, ^pid, :tick, 60_000}
    assert_received {:scheduled, ^pid, initial, 2_000}
    send(pid, initial)
    assert {:ok, %{actions: []}} = GenServer.call(pid, :show)
    exchange = start_supervised!({Exchange, name: :queue_test_exchange})
    snapshot(["1", "2", "3"])
    send(pid, :tick)
    assert GenServer.call(pid, :status) == :running
    assert_received {:scheduled, ^pid, :tick, 60_000}
    {^pid, reconcile, 2_000} = scheduled()
    send(pid, reconcile)
    assert {:ok, %{actions: actions}} = GenServer.call(pid, :show)
    assert {:promote, "1"} in actions
    assert Exchange.publish("ticket.1.pr.merged", %{}, exchange) == 1
    {^pid, next, 2_000} = scheduled()
    snapshot(["1", "2", "3"], ["agent:queued", "agent:in-progress"])
    send(pid, next)
    assert {:ok, %{actions: []}} = GenServer.call(pid, :show)
  end

  test "writes ordering and holds, removes rows and owns table lifetime" do
    fixture()
    snapshot(["1", "2", "3"])
    pid = server(name: Server)
    boot(pid)
    assert Aiur.BuildQueue.status() == :running
    assert {:ok, %{status: :running}} = Aiur.BuildQueue.show(pid)
    assert Hints.sort_key("1") == {-1, 0}
    assert Hints.sort_key("2") == {0, 1}
    assert Hints.held?("2")
    assert :ets.info(Hints.table_name(), :read_concurrency)
    assert_raise ArgumentError, fn -> :ets.insert(Hints.table_name(), {"bad", {0, 0}, false}) end
    snapshot(["1", "2", "3"], ["agent:queued", "agent:parked"])
    assert :ok = Aiur.BuildQueue.reconcile_now()
    {^pid, parked, 2_000} = scheduled()
    send(pid, parked)
    GenServer.call(pid, :status)
    assert Hints.held?("1")
    update(:snapshot, :none)
    assert :ok = Aiur.BuildQueue.reconcile_now()
    {^pid, unknown, 2_000} = scheduled()
    send(pid, unknown)
    GenServer.call(pid, :status)
    assert Hints.held?("1")
    assert Hints.held?("2")
    snapshot(["1", "2", "3"], [])
    assert :ok = Aiur.BuildQueue.reconcile_now()
    {^pid, message, 2_000} = scheduled()
    send(pid, message)
    GenServer.call(pid, :status)
    assert :ets.tab2list(Hints.table_name()) == []
    GenServer.stop(pid)
    assert :ets.whereis(Hints.table_name()) == :undefined
    refute Hints.held?("2")
  end

  test "cold unknown snapshot preserves persisted item and queue holds" do
    fixture()

    Agent.update(Boundary, fn boundary ->
      {:ok, doc} = boundary.document
      queues = Enum.map(doc.queues, &%{&1 | held: true})
      %{boundary | document: {:ok, %{doc | queues: queues}}}
    end)

    pid = server()
    boot(pid)
    assert Hints.held?("1")
    assert Hints.held?("2")
  end

  test "unavailable claims retain withdrawal holds without withdrawing" do
    fixture()

    Agent.update(Boundary, fn boundary ->
      {:ok, doc} = boundary.document
      items = Enum.map(doc.items, fn item -> if item.issue_id == "3", do: %{item | promoted_at: ~U[2026-10-08 00:00:00Z]}, else: item end)
      %{boundary | document: {:ok, %{doc | items: items}}}
    end)

    snapshot(["1", "2", "3"], ["agent:queued", "agent:todo"])
    pid = server()
    boot(pid)
    assert {:ok, %{actions: actions}} = GenServer.call(pid, :show)
    assert {:begin_withdraw, "3"} in actions
    assert Hints.held?("3")
    send(pid, :tick)
    GenServer.call(pid, :status)
    assert_received {:scheduled, ^pid, :tick, 60_000}
    {^pid, message, 2_000} = scheduled()
    send(pid, message)
    assert {:ok, %{actions: next}} = GenServer.call(pid, :show)
    refute {:withdraw, "3"} in next
    assert Hints.held?("3")
  end

  test "server persists promotions and notifies demand; budget pause recovers on tick" do
    fixture()
    snapshot(["1", "2", "3"])
    update(:result, {:error, {:github, :local_hold, %{}}})
    pid = server()
    assert_received {:scheduled, ^pid, :tick, 60_000}
    assert_received {:scheduled, ^pid, initial, 2_000}
    send(pid, initial)
    assert GenServer.call(pid, :status) == :writes_paused
    [{call, {:ok, saved}}] = Agent.get(Boundary, & &1.calls)
    assert call == {:promote, "1"}
    assert [%{outcome: nil, issue_id: "1"}] = saved.intents
    update(:result, :ok)
    send(pid, :tick)
    GenServer.call(pid, :status)
    assert_received {:scheduled, ^pid, :tick, 60_000}
    {^pid, next, 2_000} = scheduled()
    send(pid, next)
    assert GenServer.call(pid, :status) == :running
    {:ok, persisted} = Agent.get(Boundary, & &1.document)
    assert Enum.find(persisted.items, &(&1.issue_id == "1")).promoted_at == DateTime.from_unix!(2_000, :millisecond)
    assert Enum.map(Agent.get(Boundary, & &1.calls), &elem(&1, 0)) == [{:promote, "1"}, {:promote, "1"}, {:demand, ["1"]}]
  end

  test "server executes marker actions and returns budget errors" do
    pid = server()
    boot(pid)
    assert GenServer.call(pid, {:write, :mark, "1"}) == :ok
    assert GenServer.call(pid, {:write, :unmark, "1"}) == :ok
    assert Enum.map(Agent.get(Boundary, & &1.calls), &elem(&1, 0)) == [{:ensure, ["agent:queued"]}, {:mark, "1", "agent:queued"}, {:unmark, "1", "agent:queued"}]
    update(:result, {:error, {:github, :local_hold, %{}}})
    assert GenServer.call(pid, {:write, :mark, "2"}) == {:error, {:github, :local_hold, %{}}}
    assert GenServer.call(pid, :status) == :writes_paused
    count = Agent.get(Boundary, &length(&1.calls))
    update(:result, :ok)
    assert GenServer.call(pid, {:write, :mark, "3"}) == {:error, :writes_paused}
    assert GenServer.call(pid, {:write, :unmark, "1"}) == {:error, :writes_paused}
    assert Agent.get(Boundary, &length(&1.calls)) == count
    assert GenServer.call(pid, :status) == :writes_paused
  end

  defp server(opts \\ []) do
    owner = self()

    defaults = [
      name: nil,
      settings: {:ok, settings(true)},
      tracker: Boundary,
      store: Boundary,
      claim_probe: Boundary,
      clock: fn -> Agent.get(Boundary, & &1.now) end,
      exchange: :absent_queue_exchange,
      schedule: fn pid, message, delay ->
        send(owner, {:scheduled, pid, message, delay})
        make_ref()
      end
    ]

    start_supervised!({Server, Keyword.merge(defaults, opts)})
  end

  defp settings(enabled), do: %Schema{build_queue: %Schema.BuildQueue{enabled: enabled}, tracker: %Schema.Tracker{}, polling: %Schema.Polling{}}
  defp update(key, value), do: Agent.update(Boundary, &Map.put(&1, key, value))

  defp scheduled do
    receive_barrier({:scheduled, pid, message, delay})
    {pid, message, delay}
  end

  defp boot(pid) do
    assert_received {:scheduled, ^pid, :tick, 60_000}
    assert_received {:scheduled, ^pid, message, 2_000}
    send(pid, message)
    assert GenServer.call(pid, :status) == :running
  end

  defp snapshot(ids, labels \\ ["agent:queued"]) do
    Agent.update(Boundary, fn state ->
      now = state.now + 1_000
      %{state | now: now, snapshot: {:ok, Map.new(ids, &{&1, %{labels: labels, updated_at: nil}}), now}}
    end)
  end

  defp fixture do
    queue = %Model.Queue{id: "q", name: "Q", kind: :build_order, root: 1, held: false, generation: 0, created_at: ~U[2026-10-08 00:00:00Z]}

    items =
      for id <- ["1", "2", "3"],
          do: %Model.Item{issue_id: id, queue_id: "q", position: if(id == "2", do: 1), hold: if(id == "2", do: :operator), override: nil, promoted_at: nil, added_at: queue.created_at}

    edge = %Model.Edge{prerequisite: "1", dependent: "3", source: :native}
    update(:document, {:ok, %{queues: [queue], items: items, edges: [edge], intents: [], latches: []}})
  end
end
