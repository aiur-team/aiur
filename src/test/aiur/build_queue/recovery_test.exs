defmodule Aiur.BuildQueue.RecoveryTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.BuildQueue.{Hints, Model, Server, Store}
  alias Aiur.Config.{Paths, Schema}

  defmodule Boundary do
    def open_issue_labels(_age), do: Agent.get(__MODULE__, & &1.snapshot)
    def load, do: Store.load()

    def rebuild(document) do
      if Agent.get(__MODULE__, & &1.save_error?), do: {:error, :disk_full}, else: Store.rebuild(document)
    end

    def status(_ids), do: :unavailable
    def notify_demand(_ids), do: :ok
    def ensure_labels(_labels), do: record(:ensure)
    def add_label(id, _label), do: record({:mark, id})
    def remove_label(id, _label), do: record({:unmark, id})

    def save(document) do
      state = Agent.get_and_update(__MODULE__, fn state -> {state, %{state | saves: state.saves ++ [document]}} end)

      if state.crash? and Enum.any?(document.intents, &(&1.outcome != nil)) do
        send(state.owner, {:outcome_pending, self()})

        receive do
          :continue -> :ok
        end
      end

      if state.save_error?, do: {:error, :disk_full}, else: Store.save(document)
    end

    def update_issue_state(id, "todo", expected_state: :none) do
      Agent.update(__MODULE__, fn state ->
        {:ok, rows, time} = state.snapshot
        rows = Map.update!(rows, id, &%{&1 | labels: &1.labels ++ ["agent:todo"]})
        %{state | calls: state.calls ++ [{:promote, id}], snapshot: {:ok, rows, time}}
      end)
    end

    defp record(call), do: Agent.update(__MODULE__, &%{&1 | calls: &1.calls ++ [call]})
  end

  setup do
    root = Path.join(System.tmp_dir!(), "queue-recovery-#{System.unique_integer([:positive])}")
    previous = Application.fetch_env(:aiur, :decision_state_dir)
    Application.put_env(:aiur, :decision_state_dir, root)
    owner = self()
    agent = start_supervised!({Agent, fn -> %{owner: owner, snapshot: :none, calls: [], saves: [], crash?: false, save_error?: false} end})
    Process.register(agent, Boundary)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :decision_state_dir, value)
        :error -> Application.delete_env(:aiur, :decision_state_dir)
      end

      File.rm_rf!(root)
    end)

    {:ok, directory} = Paths.build_queue_dir()
    %{path: Path.join(directory, "queue.json")}
  end

  test "AC11: kill after promotion returns before saving outcome, restart writes exactly once" do
    :ok = Store.save(document())
    snapshot(%{"1" => ["agent:queued"]})
    update(:crash?, true)
    pid = server()
    send_reconcile(pid)
    {:outcome_pending, ^pid} = receive_barrier({:outcome_pending, _})
    assert calls() == [{:promote, "1"}]
    assert {:ok, %{intents: [%{outcome: nil}]}} = Store.load()
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    receive_barrier({:DOWN, ^ref, :process, ^pid, :killed})
    update(:crash?, false)
    restarted = server()
    reconcile(restarted)
    assert calls() == [{:promote, "1"}]
    assert {:ok, %{intents: [%{outcome: :ok}], items: [%{promoted_at: promoted}]}} = Store.load()
    assert promoted == DateTime.from_unix!(1_000, :millisecond)
    assert {:ok, %{projections: [%{state: :promoted}]}} = GenServer.call(Aiur.BuildQueue.Server, :show)
  end

  test "unfinished intent without todo is recorded not applied and promotes once" do
    :ok = Store.save(document([intent(:promote)]))
    snapshot(%{"1" => ["agent:queued"]})
    pid = server()
    reconcile(pid)
    assert calls() == [{:promote, "1"}]
    assert {:ok, %{intents: [%{outcome: {:error, :not_applied}}, %{outcome: :ok}]}} = Store.load()
  end

  test "no automatic or explicit writes before first fresh observation" do
    :ok = Store.save(document([intent(:promote)]))
    pid = server()
    reconcile(pid)
    assert {:ok, %{status: :running, phase: :awaiting_first_observation, freshness: :unknown}} = GenServer.call(Aiur.BuildQueue.Server, :show)
    assert GenServer.call(pid, {:write, :mark, "1"}) == {:error, :awaiting_first_observation}
    assert calls() == []
    assert {:ok, %{intents: [%{outcome: nil}]}} = Store.load()
    update(:snapshot, {:ok, %{"1" => %{labels: ["agent:queued", "agent:todo"]}}, -1_000_000})
    trigger(pid)
    assert {:ok, %{phase: :awaiting_first_observation, freshness: :unknown}} = GenServer.call(Aiur.BuildQueue.Server, :show)
    assert calls() == []
    update(:snapshot, {:ok, %{"1" => %{labels: ["agent:queued", "agent:todo"]}}, 998})
    trigger(pid)
    assert {:ok, %{phase: :awaiting_first_observation, freshness: :unknown}} = GenServer.call(Aiur.BuildQueue.Server, :show)
    assert {:ok, %{intents: [%{outcome: nil}]}} = Store.load()
    snapshot(%{"1" => ["agent:queued", "agent:todo"]})
    trigger(pid)
    assert {:ok, %{phase: :ready, freshness: :fresh}} = GenServer.call(Aiur.BuildQueue.Server, :show)
    assert {:ok, %{intents: [%{outcome: :ok}]}} = Store.load()
  end

  test "intent recovery save failure keeps writes closed" do
    :ok = Store.save(document([intent(:promote)]))
    snapshot(%{"1" => ["agent:queued"]})
    update(:save_error?, true)
    pid = server()
    reconcile(pid)
    assert Aiur.BuildQueue.status() == :store_unavailable
    assert calls() == []
    [attempted] = Agent.get(Boundary, & &1.saves)
    assert attempted.intents == [%{intent(:promote) | outcome: {:error, :not_applied}}]
    assert {:ok, %{intents: [%{outcome: nil}]}} = Store.load()
  end

  test "marker and withdrawal outcomes follow their own observed label" do
    intents = for action <- [:mark, :unmark, :withdraw], do: intent(action)
    :ok = Store.save(document(intents))
    snapshot(%{"1" => ["agent:queued", "agent:in-progress"]})
    pid = server()
    reconcile(pid)
    assert {:ok, saved} = Store.load()
    assert Enum.map(saved.intents, &{&1.action, &1.outcome}) == [mark: :ok, unmark: {:error, :not_applied}, withdraw: :ok]
    assert calls() == []
  end

  for source <- [:missing, :corrupt] do
    test "recover rebuilds #{source} store as an ordered held marker list", %{path: path} do
      if unquote(source) == :corrupt do
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, "broken queue")
      end

      snapshot(%{"12" => ["agent:queued"], "2" => ["agent:queued", "agent:todo"], "3" => []})
      pid = server()
      assert Aiur.BuildQueue.recover() == :ok
      assert Hints.held?("2") and Hints.held?("12")
      reconcile(pid)
      assert Aiur.BuildQueue.status() == :running
      assert {:ok, saved} = Store.load()
      assert [%{name: "recovered", kind: :list, held: false, root: nil}] = saved.queues
      assert Enum.map(saved.items, &{&1.issue_id, &1.position, &1.hold}) == [{"2", 0, :operator}, {"12", 1, :operator}]
      assert saved.edges == []
      assert saved.intents == []
      assert saved.latches == []
      assert Hints.held?("2") and Hints.held?("12")
      assert calls() == []
      backups = Path.wildcard(path <> ".corrupt-*")
      if unquote(source) == :corrupt, do: assert(Enum.map(backups, &File.read!/1) == ["broken queue"]), else: assert(backups == [])
    end
  end

  test "recover with no markers succeeds with no items" do
    snapshot(%{"3" => []})
    server()
    assert Aiur.BuildQueue.recover() == :ok
    assert {:ok, %{queues: [%{name: "recovered"}], items: [], edges: []}} = Store.load()
  end

  test "unavailable observation does not quarantine corrupt store", %{path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "broken queue")
    server()
    assert Aiur.BuildQueue.recover() == {:error, :observation_unavailable}
    assert File.read!(path) == "broken queue"
    assert Path.wildcard(path <> ".corrupt-*") == []
  end

  test "rebuild persistence failure leaves store unavailable and writes closed" do
    snapshot(%{"1" => ["agent:queued"]})
    update(:save_error?, true)
    pid = server()
    assert Aiur.BuildQueue.recover() == {:error, :disk_full}
    assert Aiur.BuildQueue.status() == :store_unavailable
    assert GenServer.call(pid, {:write, :mark, "1"}) == {:error, :store_unavailable}
    assert calls() == []
  end

  test "recover refuses to replace a healthy queue" do
    :ok = Store.save(document())
    snapshot(%{})
    server()
    assert Aiur.BuildQueue.recover() == {:error, :store_present}
    assert Store.load() == {:ok, document()}
  end

  defp server do
    owner = self()

    child =
      {Server,
       name: Server,
       settings: {:ok, %Schema{build_queue: %Schema.BuildQueue{enabled: true}, tracker: %Schema.Tracker{}, polling: %Schema.Polling{}}},
       tracker: Boundary,
       store: Boundary,
       claim_probe: Boundary,
       clock: fn -> 1_000 end,
       exchange: :absent_recovery_exchange,
       schedule: fn pid, message, _delay ->
         send(owner, {:scheduled, pid, message})
         make_ref()
       end}

    start_supervised!(Supervisor.child_spec(child, restart: :temporary))
  end

  defp reconcile(pid) do
    send_reconcile(pid)
    GenServer.call(pid, :status)
  end

  defp send_reconcile(pid) do
    {:scheduled, ^pid, message} = receive_barrier({:scheduled, ^pid, {:reconcile, _}})
    send(pid, message)
  end

  defp trigger(pid) do
    :ok = Aiur.BuildQueue.reconcile_now()
    reconcile(pid)
  end

  defp update(key, value), do: Agent.update(Boundary, &Map.put(&1, key, value))
  defp calls, do: Agent.get(Boundary, & &1.calls)
  defp snapshot(rows), do: update(:snapshot, {:ok, Map.new(rows, fn {id, labels} -> {id, %{labels: labels}} end), 1_000})
  defp intent(action), do: %Model.Intent{id: Atom.to_string(action), issue_id: "1", action: action, target_labels: ["agent:queued", "agent:todo"], recorded_at_ms: 999, outcome: nil}

  defp document(intents \\ []) do
    time = DateTime.from_unix!(0)
    queue = %Model.Queue{id: "q-ab12", name: "Q", kind: :list, root: nil, held: false, generation: 0, created_at: time}
    item = %Model.Item{issue_id: "1", queue_id: queue.id, position: 0, hold: nil, override: nil, promoted_at: nil, added_at: time}
    %{queues: [queue], items: [item], edges: [], intents: intents, latches: []}
  end
end
