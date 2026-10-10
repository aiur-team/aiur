defmodule Aiur.BuildQueue.UnauthorizedTest do
  use ExUnit.Case, async: false
  alias Aiur.BuildQueue.{Model, Server}
  alias Aiur.Config.Schema
  alias Aiur.Events.Exchange

  @topic "ticket.1.queue.attention.promoted_unauthorized"

  defmodule Boundary do
    @empty %{queues: [], items: [], edges: [], intents: [], latches: []}

    def load do
      with {:ok, persisted} <- Aiur.JsonStore.read(path(), Model.encode(@empty)),
           {:ok, document} <- Model.decode(persisted) do
        {:ok, document}
      else
        {:error, reason} -> {:error, {:read_failed, reason}}
      end
    end

    def save(document), do: Aiur.JsonStore.write!(path(), Model.encode(document))
    defp path, do: Agent.get(__MODULE__, & &1.path)

    def open_issue_labels(_age), do: {:ok, %{"1" => %{labels: ~w(agent:queued agent:todo)}}, 10_000}

    def status(ids) do
      Agent.get_and_update(__MODULE__, fn state -> {state.claims, %{state | batches: state.batches ++ [ids]}} end)
    end
  end

  setup do
    previous = Application.fetch_env(:aiur, :decision_state_dir)
    root = Aiur.TestSupport.tmp_root!("queue-unauthorized")

    on_exit(fn ->
      File.rm_rf!(root)
      refute File.exists?(root)
    end)

    boundary = start_supervised!({Agent, fn -> %{claims: %{"1" => {:declined, :unauthorized}}, batches: [], path: Path.join([root, "build-queue", "queue.json"])} end})
    Process.register(boundary, Boundary)
    {:ok, document} = Boundary.load()
    time = DateTime.from_unix!(9_000, :millisecond)
    queue = %Model.Queue{id: "q-abcd", name: "Queue", kind: :list, root: nil, held: false, generation: 0, created_at: time}
    item = %Model.Item{issue_id: "1", queue_id: queue.id, position: 0, hold: nil, override: nil, promoted_at: time, added_at: time}
    :ok = Boundary.save(%{document | queues: [queue], items: [item]})
    :ok = Exchange.subscribe(@topic <> ".#")
    owner = self()

    pid =
      start_supervised!(
        {Server,
         name: nil,
         tracker: Boundary,
         store: Boundary,
         claim_probe: Boundary,
         clock: fn -> 10_000 end,
         settings: {:ok, %Schema{build_queue: %Schema.BuildQueue{enabled: true}, tracker: %Schema.Tracker{}, polling: %Schema.Polling{}}},
         schedule: fn server, message, _delay ->
           send(owner, {:scheduled, server, message})
           make_ref()
         end}
      )

    assert_received {:scheduled, ^pid, :tick}
    {:ok, pid: pid, root: root, previous: previous}
  end

  test "fixture leaves the application state directory unchanged", %{root: root, previous: previous} do
    assert Application.fetch_env(:aiur, :decision_state_dir) == previous
    assert File.regular?(Path.join([root, "build-queue", "queue.json"]))
  end

  test "promoted IDs are probed and unauthorized decline emits once durably", %{pid: pid} do
    assert %{state: :promoted_unauthorized, reason: :unauthorized} = reconcile(pid)
    assert_received {:event, %{topic: @topic, ticket: "1"}}
    assert Agent.get(Boundary, & &1.batches) == [["1"]]
    assert {:ok, %{latches: [%{key: {:promoted_unauthorized, "1"}, emitted?: true}]}} = Boundary.load()
    assert %{state: :promoted_unauthorized} = reconcile(pid)
    refute_received {:event, %{topic: @topic}}
  end

  test "unavailable probe preserves known unauthorized state without resolving", %{pid: pid} do
    assert %{state: :promoted_unauthorized} = reconcile(pid)
    assert_received {:event, %{topic: @topic}}

    for value <- [:unavailable, %{}, %{"1" => :unavailable}] do
      claims(value)
      assert %{state: :promoted_unauthorized} = reconcile(pid)
      assert {:ok, %{latches: [%{key: {:promoted_unauthorized, "1"}, emitted?: true}]}} = Boundary.load()
      resolved = @topic <> ".resolved"
      refute_received {:event, %{topic: @topic}}
      refute_received {:event, %{topic: ^resolved}}
    end
  end

  test "cleared decline resolves once and claiming also clears attention", %{pid: pid} do
    for {claim, state} <- [{:unclaimed, :promoted}, {:claimed, :claimed}, {{:declined, :worker_capacity}, :promoted}] do
      claims(%{"1" => {:declined, :unauthorized}})
      assert %{state: :promoted_unauthorized} = reconcile(pid)
      assert_received {:event, %{topic: @topic}}
      claims(%{"1" => claim})
      assert %{state: ^state} = reconcile(pid)
      resolved = @topic <> ".resolved"
      assert_received {:event, %{topic: ^resolved}}
      assert {:ok, %{latches: []}} = Boundary.load()
      assert %{state: ^state} = reconcile(pid)
      refute_received {:event, %{topic: ^resolved}}
    end
  end

  test "failed attention publication retries on the next reconcile", %{pid: pid} do
    generator = Process.whereis(Aiur.Events.IdGenerator)
    Process.unregister(Aiur.Events.IdGenerator)

    try do
      assert %{state: :promoted_unauthorized} = reconcile(pid)
      assert {:ok, %{latches: [%{emitted?: false}]}} = Boundary.load()
      refute_received {:event, %{topic: @topic}}
    after
      Process.register(generator, Aiur.Events.IdGenerator)
    end

    assert %{state: :promoted_unauthorized} = reconcile(pid)
    assert_received {:event, %{topic: @topic}}
    assert {:ok, %{latches: [%{emitted?: true}]}} = Boundary.load()
    claims(%{"1" => :unclaimed})
    Process.unregister(Aiur.Events.IdGenerator)

    try do
      assert %{state: :promoted} = reconcile(pid)
      assert {:ok, %{latches: [%{emitted?: true}]}} = Boundary.load()
    after
      Process.register(generator, Aiur.Events.IdGenerator)
    end

    assert %{state: :promoted} = reconcile(pid)
    resolved = @topic <> ".resolved"
    assert_received {:event, %{topic: ^resolved}}
    assert {:ok, %{latches: []}} = Boundary.load()
  end

  test "store reload failure stops writes and preserves corrupt evidence", %{pid: pid, root: root} do
    path = Path.join([root, "build-queue", "queue.json"])
    File.write!(path, "broken")
    assert %{state: :promoted_unauthorized} = reconcile(pid)
    assert GenServer.call(pid, :status) == :store_unavailable
    assert File.read!(path) == "broken"
    refute_received {:event, %{topic: @topic}}
  end

  # Future guard for the existing reason match; mutation to any decline must fail.
  test "other declines and initially unavailable probes never alert", %{pid: pid} do
    for value <- [%{"1" => {:declined, :worker_capacity}}, :unavailable, %{}] do
      claims(value)
      assert %{state: :promoted} = reconcile(pid)
      assert {:ok, %{latches: []}} = Boundary.load()
      refute_received {:event, %{topic: @topic}}
    end
  end

  defp claims(value), do: Agent.update(Boundary, &%{&1 | claims: value})

  defp reconcile(pid) do
    :ok = GenServer.call(pid, :reconcile_now)
    assert_received {:scheduled, ^pid, {:reconcile, _} = message}
    send(pid, message)
    assert {:ok, %{projections: [projection]}} = GenServer.call(pid, :show)
    projection
  end
end
