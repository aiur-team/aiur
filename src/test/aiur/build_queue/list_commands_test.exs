defmodule Aiur.BuildQueue.ListCommandsTest do
  use ExUnit.Case, async: false
  alias Aiur.BuildQueue.{ListCommands, Server}
  alias Aiur.Config.Schema

  @empty %{queues: [], items: [], edges: [], intents: [], latches: []}

  defmodule Boundary do
    alias Aiur.BuildQueue.Model
    def load, do: Agent.get(__MODULE__, & &1.document)
    def open_issue_labels(_age), do: Agent.get(__MODULE__, & &1.snapshot)
    def status(_ids), do: :unavailable
    def notify_demand(_ids), do: :ok

    def save(document) do
      Agent.get_and_update(__MODULE__, fn state ->
        case state.save_result do
          :ok ->
            {:ok, restored} = document |> Model.encode() |> Jason.encode!() |> Jason.decode!() |> Model.decode()
            {:ok, %{state | document: {:ok, restored}, saves: state.saves ++ [restored]}}

          error ->
            {error, state}
        end
      end)
    end

    def ensure_labels(labels), do: record({:ensure, labels})
    def add_label(id, label), do: record({:mark, id, label})
    def remove_label(id, label), do: record({:unmark, id, label})

    defp record(call) do
      Agent.get_and_update(__MODULE__, fn state ->
        {:ok, document} = state.document
        {_, labels, time} = state.snapshot
        failing? = elem(call, 0) in [:mark, :unmark] and state.marker_failures > 0
        result = if failing?, do: {:error, :transient}, else: :ok

        labels =
          case {result, call} do
            {:ok, {:mark, id, label}} -> Map.update!(labels, id, &%{&1 | labels: Enum.uniq(&1.labels ++ [label])})
            {:ok, {:unmark, id, label}} -> Map.update!(labels, id, &%{&1 | labels: List.delete(&1.labels, label)})
            _ -> labels
          end

        state = %{state | calls: state.calls ++ [{call, document}], snapshot: {:ok, labels, time}, marker_failures: if(failing?, do: state.marker_failures - 1, else: state.marker_failures)}
        {result, state}
      end)
    end
  end

  defmodule TimeoutBoundary do
    use GenServer
    def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: Server)
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    def handle_call({:mutate, _}, _from, state), do: {:stop, :timeout, state}
  end

  setup do
    labels = Map.new(["1", "2", "3", "9"], &{&1, %{labels: []}})
    pid = start_supervised!({Agent, fn -> %{document: {:ok, @empty}, snapshot: {:ok, labels, 1_000}, saves: [], calls: [], save_result: :ok, marker_failures: 0, now: 1_000} end})
    Process.register(pid, Boundary)
    :ok
  end

  test "facade adds and removes through durable membership and real marker writer" do
    server()
    assert :ok = Aiur.BuildQueue.add(["1", "2"], "paseo", after: "9")
    assert Enum.map(document().items, & &1.issue_id) == ["1", "2"]
    assert Enum.map(document().edges, &{&1.prerequisite, &1.dependent}) == [{"9", "1"}, {"9", "2"}]
    calls = Agent.get(Boundary, & &1.calls)
    assert Enum.map(calls, &elem(&1, 0)) == [{:ensure, ["agent:queued"]}, {:mark, "1", "agent:queued"}, {:mark, "2", "agent:queued"}]
    {_, before_mark} = Enum.at(calls, 1)
    assert Enum.map(before_mark.items, & &1.issue_id) == ["1", "2"]
    assert Enum.any?(before_mark.intents, &(&1.issue_id == "1" and &1.action == :mark and &1.outcome == nil))
    assert :ok = Aiur.BuildQueue.reorder("2", 0)
    assert Enum.map(document().items, &{&1.issue_id, &1.position}) == [{"2", 0}, {"1", 1}]
    assert :ok = Aiur.BuildQueue.add_edge("3", "2")
    assert Enum.any?(document().edges, &(&1.prerequisite == "3" and &1.dependent == "2" and &1.source == :list))
    assert :ok = Aiur.BuildQueue.remove("1")
    assert Enum.map(document().items, &{&1.issue_id, &1.position}) == [{"2", 0}]
    assert {{:unmark, "1", "agent:queued"}, before_unmark} = List.last(Agent.get(Boundary, & &1.calls))
    refute Enum.any?(before_unmark.items, &(&1.issue_id == "1"))
    assert ListCommands.pending(document()) == []
  end

  test "operator removal publishes a removed hint naming the operator as cause" do
    :ok = Aiur.Events.Exchange.subscribe("ticket.1.queue.removed")
    server()
    assert :ok = Aiur.BuildQueue.add(["1"], "paseo")
    assert :ok = Aiur.BuildQueue.remove("1")
    Aiur.Events.Exchange.bindings_for(self())
    assert_received {:event, %{"ticket" => "1", "cause" => "operator", topic: "ticket.1.queue.removed"}}
  end

  test "ownership and self edge refusals save nothing and write nothing" do
    server()
    assert :ok = Aiur.BuildQueue.add(["1"], "paseo")
    previous = Agent.get(Boundary, & &1)
    assert {:error, {:already_queued, "paseo"}} = Aiur.BuildQueue.add(["2", "1"], "other")
    assert {:error, :self_edge} = Aiur.BuildQueue.add(["2"], "paseo", after: "2")
    assert {:error, :self_edge} = Aiur.BuildQueue.add_edge("1", "1")
    assert Agent.get(Boundary, & &1) == previous
  end

  test "closed, missing and stale snapshots refuse the entire add without saving" do
    server()
    update(:snapshot, {:ok, %{"1" => %{labels: []}}, 1_000})
    assert {:error, :closed} = Aiur.BuildQueue.add(["1", "2"], "paseo")
    update(:snapshot, :none)
    assert {:error, :inputs_unavailable} = Aiur.BuildQueue.add(["1"], "paseo")
    update(:snapshot, {:ok, %{"1" => %{labels: []}}, 100_000})
    assert {:error, :inputs_unavailable} = Aiur.BuildQueue.add(["1"], "paseo")
    update(:now, 1_000_000)
    update(:snapshot, {:ok, %{"1" => %{labels: []}}, 1_000})
    assert {:error, :inputs_unavailable} = Aiur.BuildQueue.add(["1"], "paseo")
    assert document() == @empty
    assert Agent.get(Boundary, & &1.saves) == []
    assert Agent.get(Boundary, & &1.calls) == []
  end

  test "store save failure disables all mutations without label writes" do
    server()
    update(:save_result, {:error, :disk_full})
    assert {:error, :store_unavailable} = Aiur.BuildQueue.add(["1"], "paseo")
    assert {:error, :store_unavailable} = Aiur.BuildQueue.reorder("1", 0)
    assert {:error, :store_unavailable} = Aiur.BuildQueue.remove("1")
    assert {:error, :store_unavailable} = Aiur.BuildQueue.add_edge("1", "2")
    assert document() == @empty
    assert Agent.get(Boundary, & &1.calls) == []
  end

  test "paced markers survive restart and are retried without repeating successful marks" do
    pid = server(2)
    assert {:error, {:marker_write_failed, [{:mark, "2", {:error, :paced}}]}} = Aiur.BuildQueue.add(["1", "2"], "paseo", after: "9")
    assert ListCommands.pending(document()) == [{:mark, "2"}]
    assert :ok = stop_supervised(Server)
    refute Process.alive?(pid)
    server(2)
    assert ListCommands.pending(document()) == []
    markers = Agent.get(Boundary, &Enum.map(&1.calls, fn {call, _} -> call end))
    assert Enum.count(markers, &(&1 == {:mark, "1", "agent:queued"})) == 1
    assert Enum.count(markers, &(&1 == {:mark, "2", "agent:queued"})) == 1
  end

  test "successful marker retry returns success after an intermediate failure" do
    server()
    update(:marker_failures, 1)
    assert :ok = Aiur.BuildQueue.add(["1"], "paseo")
    assert ListCommands.pending(document()) == []
    calls = Agent.get(Boundary, &Enum.map(&1.calls, fn {call, _} -> call end))
    assert Enum.count(calls, &(&1 == {:mark, "1", "agent:queued"})) == 2
  end

  @tag capture_log: true
  test "facade returns unknown when the mutation call exits with timeout" do
    start_supervised!({TimeoutBoundary, []}, restart: :temporary)
    assert {:error, :outcome_unknown} = Aiur.BuildQueue.add(["1"], "paseo")
  end

  test "mutations wait for recovery's first observation and touch nothing" do
    start(20)
    assert {:error, :awaiting_first_observation} = Aiur.BuildQueue.add(["1"], "paseo")
    assert Agent.get(Boundary, & &1.saves) == []
    assert Agent.get(Boundary, & &1.calls) == []
  end

  test "paced unmark survives removal and restart" do
    server(2)
    assert :ok = Aiur.BuildQueue.add(["1"], "paseo")
    assert {:error, {:marker_write_failed, [{:unmark, "1", {:error, :paced}}]}} = Aiur.BuildQueue.remove("1")
    assert document().items == []
    assert ListCommands.pending(document()) == [{:unmark, "1"}]
    stop_supervised(Server)
    server(2)
    assert ListCommands.pending(document()) == []
    assert {:ok, labels, _} = Agent.get(Boundary, & &1.snapshot)
    assert labels["1"].labels == []
  end

  defp server(max_writes \\ 20) do
    pid = start(max_writes)
    assert_received {:scheduled, ^pid, {:reconcile, token}}
    send(pid, {:reconcile, token})
    assert GenServer.call(pid, :status) == :running
    pid
  end

  defp start(max_writes) do
    owner = self()
    settings = %Schema{build_queue: %Schema.BuildQueue{enabled: true, max_writes_per_minute: max_writes}, tracker: %Schema.Tracker{}, polling: %Schema.Polling{}}

    pid =
      start_supervised!(
        {Server,
         name: Server,
         settings: {:ok, settings},
         tracker: Boundary,
         store: Boundary,
         claim_probe: Boundary,
         clock: fn -> Agent.get(Boundary, & &1.now) end,
         sleep: fn _ -> :ok end,
         schedule: fn target, message, _ ->
           send(owner, {:scheduled, target, message})
           make_ref()
         end,
         exchange: :missing_queue_exchange}
      )

    pid
  end

  defp update(key, value), do: Agent.update(Boundary, &Map.put(&1, key, value))

  defp document,
    do:
      Agent.get(Boundary, fn state ->
        {:ok, document} = state.document
        document
      end)
end
