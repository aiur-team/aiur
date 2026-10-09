Code.require_file("../../support/build_queue_planner_fixture.exs", __DIR__)

defmodule Aiur.BuildQueue.AttentionCausesTest do
  use ExUnit.Case, async: false
  alias Aiur.BuildQueue.Model.Edge
  alias Aiur.BuildQueue.{PlannerFixture, Server, Store}
  alias Aiur.Config.Schema
  alias Aiur.Events.Exchange

  defmodule Boundary do
    def open_issue_labels(_age), do: Agent.get(__MODULE__, fn s -> if s.available, do: {:ok, s.labels, s.now}, else: {:error, :offline} end)
    def status(ids), do: Map.new(ids, &{&1, :unclaimed})
    def issue_closure(_id, _age), do: Agent.get(__MODULE__, &{:ok, %{open?: false, state_reason: &1.close_reason}})
    def ticket_pull_request(_id), do: {:ok, nil}
    def blocked_by(_id), do: {:ok, []}
    def notify_demand(_ids), do: :ok
    def ensure_labels(_labels), do: :ok
    def add_label(_id, _label), do: Agent.get(__MODULE__, & &1.write_result)
    def remove_label(_id, _label), do: :ok
    def update_issue_state(_id, "todo", expected_state: :none), do: :ok
  end

  setup do
    previous = Application.fetch_env(:aiur, :decision_state_dir)
    root = Aiur.TestSupport.tmp_root!("queue-causes")
    Application.put_env(:aiur, :decision_state_dir, root)
    patterns = ["ticket.*.queue.attention.#", "system.queue.attention.#"]
    owner = self()
    for pattern <- patterns, do: Exchange.subscribe(pattern)

    on_exit(fn ->
      for pattern <- patterns, do: GenServer.call(Exchange, {:unsubscribe, pattern, owner})

      case previous do
        {:ok, value} -> Application.put_env(:aiur, :decision_state_dir, value)
        :error -> Application.delete_env(:aiur, :decision_state_dir)
      end

      File.rm_rf!(root)
    end)

    labels = Map.new(["11", "12"], &{&1, %{labels: ["agent:queued"]}}) |> Map.put("10", %{labels: ["agent:error"]})
    pid = start_supervised!({Agent, fn -> %{now: 10_000, available: true, labels: labels, write_result: :ok, close_reason: "completed"} end})
    Process.register(pid, Boundary)
    queue = %{hd(PlannerFixture.input().queues) | id: "q-abcd", held: true}
    items = for id <- ["11", "12"], do: %{PlannerFixture.item(id) | queue_id: queue.id}
    edges = for id <- ["11", "12"], do: %Edge{prerequisite: "10", dependent: id, source: :native}
    {:ok, doc} = Store.load()
    :ok = Store.save(%{doc | queues: [queue], items: items, edges: edges})
    {:ok, root: root}
  end

  test "AC3: one alert names both dependents, restart does not re-fire, clearing resolves" do
    pid = server()
    reconcile(pid)
    topic = "ticket.10.queue.attention.prerequisite_failed"
    assert_received {:event, %{topic: ^topic, prerequisite: "10", cause: :agent_error, blocked: ["11", "12"]}}
    refute_received {:event, %{topic: ^topic}}
    stop_supervised!(Server)
    pid = server()
    reconcile(pid)
    refute_received {:event, %{topic: ^topic}}
    labels("10", [])
    reconcile(pid)
    resolved = topic <> ".resolved"
    assert_received {:event, %{topic: ^resolved}}
    assert {:ok, %{latches: []}} = Store.load()
  end

  test "direct dependents precede transitive dependents; changed blocked set does not re-fire" do
    {:ok, doc} = Store.load()
    edges = [%Edge{prerequisite: "10", dependent: "12", source: :native}, %Edge{prerequisite: "12", dependent: "11", source: :native}]
    :ok = Store.save(%{doc | edges: edges})
    pid = server()
    reconcile(pid)
    topic = "ticket.10.queue.attention.prerequisite_failed"
    assert_received {:event, %{topic: ^topic, blocked: ["12", "11"]}}
    labels("11", [])
    reconcile(pid)
    refute_received {:event, %{topic: ^topic}}
  end

  test "unknown evidence retains the latch; changing prerequisite cause emits again" do
    pid = server()
    reconcile(pid)
    topic = "ticket.10.queue.attention.prerequisite_failed"
    assert_received {:event, %{topic: ^topic, cause: :agent_error}}
    change(available: false)
    reconcile(pid)
    resolved = topic <> ".resolved"
    refute_received {:event, %{topic: ^resolved}}
    Agent.update(Boundary, &%{&1 | available: true, close_reason: "not_planned", labels: Map.delete(&1.labels, "10")})
    reconcile(pid)
    assert_received {:event, %{topic: ^topic, cause: :not_planned}}
    assert_received {:event, %{topic: ^resolved}}
    assert {:ok, %{latches: [%{key: {{:prerequisite_failed, :not_planned}, "10"}}]}} = Store.load()
  end

  test "claimed dependency change opens and becoming ready resolves" do
    {:ok, doc} = Store.load()
    :ok = Store.save(%{doc | items: Enum.map(doc.items, &%{&1 | promoted_at: ~U[2026-10-08 00:00:00Z]})})
    labels("11", ["agent:queued", "agent:in-progress"])
    pid = server()
    reconcile(pid)
    topic = "ticket.11.queue.attention.dependency_changed_after_start"
    assert_received {:event, %{topic: ^topic, prerequisite: "10"}}
    Agent.update(Boundary, &%{&1 | labels: Map.delete(&1.labels, "10")})
    reconcile(pid)
    resolved = topic <> ".resolved"
    assert_received {:event, %{topic: ^resolved}}
  end

  test "inputs unavailable waits twice the age, stays latched, then resolves" do
    pid = server()
    reconcile(pid)
    topic = "system.queue.attention.inputs_unavailable"
    change(available: false)
    reconcile(pid)
    change(now: 11_000)
    reconcile(pid)
    refute_received {:event, %{topic: ^topic}}
    change(now: 12_000)
    reconcile(pid)
    assert_received {:event, %{topic: ^topic, freshness: :unknown}}
    change(now: 13_000)
    reconcile(pid)
    refute_received {:event, %{topic: ^topic}}
    change(available: true)
    reconcile(pid)
    resolved = topic <> ".resolved"
    assert_received {:event, %{topic: ^resolved}}
  end

  test "store unavailable fires once per boot and recovering resolves", %{root: root} do
    path = Path.join([root, "build-queue", "queue.json"])
    File.write!(path, "broken")
    pid = server()
    assert GenServer.call(pid, :status) == :store_unavailable
    topic = "system.queue.attention.store_unavailable"
    assert_received {:event, %{topic: ^topic}}
    GenServer.call(pid, :reconcile_now)
    refute_received {:event, %{topic: ^topic}}
    stop_supervised!(Server)
    pid = server()
    assert GenServer.call(pid, :status) == :store_unavailable
    assert_received {:event, %{topic: ^topic}}
    assert File.read!(path) == "broken"
    assert GenServer.call(pid, :recover) == :ok
    resolved = topic <> ".resolved"
    assert_received {:event, %{topic: ^resolved}}
  end

  test "runtime store failure alerts and a repaired store loads without rebuilding", %{root: root} do
    pid = server()
    reconcile(pid)
    path = Path.join([root, "build-queue", "queue.json"])
    bytes = File.read!(path)
    File.rm!(path)
    File.mkdir!(path)
    assert {:error, _} = GenServer.call(pid, {:write, :mark, "11"})
    topic = "system.queue.attention.store_unavailable"
    assert_received {:event, %{topic: ^topic}}
    File.rmdir!(path)
    File.write!(path, bytes)
    assert GenServer.call(pid, :recover) == :ok
    reconcile(pid)
    resolved = topic <> ".resolved"
    assert_received {:event, %{topic: ^resolved}}
    {:ok, document} = Store.load()
    assert Enum.map(document.items, & &1.issue_id) == ["11", "12"]
    assert document.queues |> hd() |> Map.fetch!(:name) == "queue"
  end

  test "a cold unavailable listing still opens after the grace" do
    change(available: false)
    pid = server()
    reconcile(pid)
    change(now: 12_000)
    reconcile(pid)
    topic = "system.queue.attention.inputs_unavailable"
    assert_received {:event, %{topic: ^topic}}
    assert :sys.get_state(pid).phase == :awaiting_first_observation
  end

  test "a recovered input between outages resets the grace" do
    pid = server()
    reconcile(pid)
    change(available: false)
    reconcile(pid)
    change(now: 11_999, available: true)
    reconcile(pid)
    change(now: 12_000, available: false)
    reconcile(pid)
    change(now: 13_999)
    reconcile(pid)
    topic = "system.queue.attention.inputs_unavailable"
    refute_received {:event, %{topic: ^topic}}
    change(now: 14_000)
    reconcile(pid)
    assert_received {:event, %{topic: ^topic}}
  end

  test "five write failures emit once and the next successful write resolves" do
    pid = server()
    reconcile(pid)
    topic = "ticket.11.queue.attention.write_failed"
    change(write_result: {:error, :offline})
    assert GenServer.call(pid, {:write, :mark, "11"}) == {:error, :offline}
    refute_received {:event, %{topic: ^topic}}
    assert GenServer.call(pid, {:write, :mark, "11"}) == {:error, :offline}
    assert_received {:event, %{topic: ^topic, ticket: "11"}}
    assert GenServer.call(pid, {:write, :mark, "11"}) == {:error, :offline}
    refute_received {:event, %{topic: ^topic}}
    change(write_result: :ok)
    assert GenServer.call(pid, {:write, :mark, "11"}) == :ok
    resolved = topic <> ".resolved"
    assert_received {:event, %{topic: ^resolved}}
    {:ok, doc} = Store.load()
    refute Enum.any?(doc.latches, &(&1.key == {:write_failed, "11"}))
  end

  defp server do
    owner = self()
    settings = %Schema{build_queue: %Schema.BuildQueue{enabled: true, observation_max_age_seconds: 1}, tracker: %Schema.Tracker{}, polling: %Schema.Polling{}}

    pid =
      start_supervised!(
        {Server,
         name: nil,
         tracker: Boundary,
         claim_probe: Boundary,
         settings: {:ok, settings},
         sleep: fn _ -> :ok end,
         clock: fn -> Agent.get(Boundary, & &1.now) end,
         schedule: fn server, message, _ -> send(owner, {:scheduled, server, message}) end}
      )

    :sys.get_state(pid)
    pid
  end

  defp reconcile(pid) do
    GenServer.call(pid, :reconcile_now)
    assert_received {:scheduled, ^pid, {:reconcile, _} = message}
    send(pid, message)
    GenServer.call(pid, :show)
  end

  defp change(changes), do: Agent.update(Boundary, &Enum.into(changes, &1))
  defp labels(id, labels), do: Agent.update(Boundary, &%{&1 | labels: Map.put(&1.labels, id, %{labels: labels})})
end
