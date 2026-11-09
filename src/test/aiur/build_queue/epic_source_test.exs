defmodule Aiur.BuildQueue.EpicSourceTest do
  use ExUnit.Case, async: false
  alias Aiur.BuildOrder.{GraphProjection, GraphProjection.Snapshot, Lifecycle, Member, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.BuildQueue.{Model, MutationCLI, Server}
  alias Aiur.BuildQueue.Sources.Epic
  alias Aiur.Config.Schema
  alias Aiur.TrackerIdentity

  @empty %{queues: [], items: [], edges: [], intents: [], latches: []}

  defmodule Boundary do
    def load, do: Agent.get(__MODULE__, &{:ok, &1.document})

    def save(document) do
      {:ok, restored} = document |> Model.encode() |> Jason.encode!() |> Jason.decode!() |> Model.decode()
      Agent.update(__MODULE__, &%{&1 | document: restored})
    end

    def open_issue_labels(_age), do: Agent.get(__MODULE__, &{:ok, Map.new(&1.labels, fn {id, labels} -> {id, %{labels: labels}} end), &1.now})
    def issue_closure(_id, _age), do: {:error, :not_found}
    def blocked_by(_id), do: {:ok, []}

    def status(ids), do: Map.new(ids, &{&1, :unclaimed})

    def notify_demand(_ids), do: :ok
    def ensure_labels(_labels), do: :ok
    def add_label(id, label), do: write(id, label, :add)
    def remove_label(id, label), do: write(id, label, :remove)
    def update_issue_state(id, "todo", _opts), do: write(id, "agent:todo", :add)

    defp write(id, label, action) do
      Agent.update(__MODULE__, fn state ->
        labels = Map.update(state.labels, id, [], &if(action == :add, do: Enum.uniq(&1 ++ [label]), else: List.delete(&1, label)))
        %{state | labels: labels}
      end)
    end
  end

  defmodule Projection do
    use GenServer
    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot)
    @impl true
    def init(snapshot), do: {:ok, snapshot}
    @impl true
    def handle_call(:catalog, _, snapshot), do: {:reply, %{data: %{entries: [snapshot.data.root]}}, snapshot}
    def handle_call({:selected_topic, identity}, _, snapshot), do: {:reply, {:ok, GraphProjection.selected_topic(identity)}, snapshot}
    def handle_call({verb, _}, _, snapshot) when verb in [:demand, :selected], do: {:reply, {:ok, snapshot}, snapshot}
    def handle_call({:release, _}, _, snapshot), do: {:reply, :ok, snapshot}
    @impl true
    def handle_cast({:refresh_selected, _}, snapshot), do: {:noreply, snapshot}
  end

  defmodule Registry do
    def snapshot(_opts), do: Agent.get(__MODULE__, & &1.snapshot)
  end

  setup do
    labels = Map.new(101..110, &{Integer.to_string(&1), []})
    pid = start_supervised!({Agent, fn -> %{document: @empty, labels: labels, now: 1_000_000} end}, id: Boundary)
    Process.register(pid, Boundary)
    registry = start_supervised!({Agent, fn -> %{snapshot: {:ok, registry([101, 102], [103, 104], 99)}} end}, id: Registry)
    Process.register(registry, Registry)
    :ok
  end

  test "an epic is the union of its features and its root's open sub-issues, without duplicates" do
    queue = %Model.Queue{id: "q-0000", name: "Epic world", kind: :epic, epic: "world", root: nil, held: false, generation: 0, created_at: DateTime.from_unix!(0)}
    {:ok, registry} = Registry.snapshot([])
    {:ok, watched} = Epic.watch("world", registry: Registry, projection: projection([102, 108]))

    context = %{items: [], source_snapshots: %{{:epic, "world"} => {:ok, watched}}, observations: Map.new(101..110, &{Integer.to_string(&1), %{}})}

    assert {:ok, items, _edges, :current} = Epic.members(queue, context)
    assert Enum.map(items, & &1.issue_id) == ["101", "102", "103", "104", "108"]
    assert registry.epics |> hd() |> Map.fetch!(:features) == ["combat", "naval"]
  end

  test "an epic with a root stays unavailable while the root projection is unavailable" do
    assert {:unavailable, _reason} = Epic.watch("world", registry: Registry, projection: :no_such_projection)
  end

  test "a feature queued on its own keeps its tickets when its epic is queued, in either order" do
    pid = server()
    assert {:ok, [{"Feature combat", :ok}]} = add(pid, feature: "combat")
    assert {:ok, [{"Epic world", :ok} | _]} = add(pid, epic: "world")

    assert owners() == %{"101" => "Feature combat", "102" => "Feature combat", "103" => "Epic world", "104" => "Epic world", "108" => "Epic world"}
    reconcile(pid)
    assert owners()["101"] == "Feature combat"

    :sys.replace_state(pid, &%{&1 | document: @empty})
    assert {:ok, [{"Epic world", :ok} | _]} = add(pid, epic: "world")
    assert owners()["101"] == "Epic world"
    assert {:ok, _} = add(pid, feature: "combat")
    assert owners()["101"] == "Feature combat"
    assert owners()["103"] == "Epic world"
    reconcile(pid)
    assert owners()["102"] == "Feature combat"
  end

  test "a list keeps a ticket over a queued epic" do
    pid = server()
    assert :ok = Aiur.BuildQueue.add(["101"], "list")
    assert {:ok, [{"Epic world", :ok} | _]} = add(pid, epic: "world")
    assert owners()["101"] == "list"
  end

  test "a ticket filed into an epic's feature later joins without another command" do
    pid = server()
    assert {:ok, _} = add(pid, epic: "world")
    refute Map.has_key?(owners(), "105")

    Agent.update(Registry, &%{&1 | snapshot: {:ok, registry([101, 102], [103, 104, 105], 99)}})
    reconcile(pid)
    assert owners()["105"] == "Epic world"
  end

  test "--build-order adopts the root's epic when there is one and a plain Build Order entry otherwise" do
    pid = server()
    assert {:ok, [{"Build Order #99", :ok} | _]} = MutationCLI.execute(verb: :add, build_order: 99, server: pid, settings: settings(), error_fun: fn _ -> :ok end)
    assert [%{kind: :epic, epic: "world"}] = get(:document).queues
    assert Map.keys(owners()) |> Enum.sort() == ["101", "102", "103", "104", "108"]

    :sys.replace_state(pid, &%{&1 | document: @empty})
    Agent.update(Registry, &%{&1 | snapshot: {:ok, Map.put(registry([101], [], nil), :epics, [])}})
    assert {:ok, [{"Build Order #99", :ok} | _]} = MutationCLI.execute(verb: :add, build_order: 99, server: pid, settings: settings(), error_fun: fn _ -> :ok end)
    assert [%{kind: :build_order, root: 99}] = get(:document).queues
    assert Map.keys(owners()) |> Enum.sort() == ["102", "108"]
  end

  test "an unknown epic slug is refused before any write" do
    pid = server()
    assert {:ok, [{"Epic nope", {:error, :epic_not_found}}]} = add(pid, epic: "nope")
    assert get(:document).queues == []
  end

  defp add(pid, opts), do: MutationCLI.execute([verb: :add, server: pid, settings: settings(), error_fun: fn _ -> :ok end] ++ opts)

  defp owners do
    document = get(:document)
    names = Map.new(document.queues, &{&1.id, &1.name})
    for item <- document.items, into: %{}, do: {item.issue_id, if(item.position, do: "list", else: Map.fetch!(names, item.queue_id))}
  end

  defp registry(combat, naval, root) do
    owners = Map.new(combat, &{&1, %{feature: "combat", epic: nil, confirmed: true}}) |> Map.merge(Map.new(naval, &{&1, %{feature: "naval", epic: nil, confirmed: true}}))

    %{
      features: %{"combat" => %{slug: "combat", epics: [], baseline: :none}, "naval" => %{slug: "naval", epics: [], baseline: :none}},
      owners: owners,
      also: %{},
      epics: [%{slug: "world", root: root, features: ["combat", "naval"]}],
      generation: 1,
      health: %{state: :healthy}
    }
  end

  defp identity(number) do
    {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => "I_#{number}", "number" => number}, {"owner", "repo"}, {"owner", "repo"})
    identity
  end

  defp member(number),
    do: Member.new(%{identity: identity(number), title: "Member", url: "https://github.com/owner/repo/issues/#{number}", lifecycle: %Lifecycle{state: :open, state_reason: :none}, dependencies: []})

  defp root_snapshot(numbers) do
    health = ProviderHealth.new(1, :healthy, true)
    root = RootSummary.new(%{identity: identity(99), title: "Build Order", url: "https://github.com/owner/repo/issues/99", lifecycle: %Lifecycle{state: :open, state_reason: :none}})
    %Snapshot{scope: {:selected, identity(99)}, repository: {"owner", "repo"}, generation: 1, health: health, data: SelectedRoot.new(root, Enum.map(numbers, &member/1), health)}
  end

  defp projection(numbers), do: start_supervised!({Projection, root_snapshot(numbers)}, id: make_ref())

  defp settings do
    {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "github"}, "build_queue" => %{"enabled" => true, "reconcile_interval_seconds" => 60, "max_writes_per_minute" => 20}})
    settings
  end

  defp server do
    start_supervised!(
      {Server,
       settings: {:ok, settings()},
       tracker: Boundary,
       store: Boundary,
       claim_probe: Boundary,
       feature_registry: Registry,
       build_order_projection: projection([102, 108]),
       clock: fn -> get(:now) end,
       schedule: fn _, _, _ -> make_ref() end,
       exchange: :missing_exchange,
       open_issues_topic: "tracker:open_issues:#{System.unique_integer([:positive])}"}
    )
    |> tap(&reconcile/1)
  end

  defp reconcile(pid) do
    GenServer.call(pid, :reconcile_now)
    token = :sys.get_state(pid).pending
    send(pid, {:reconcile, token})
    :sys.get_state(pid, 30_000)
  end

  defp get(key), do: Agent.get(Boundary, &Map.fetch!(&1, key))
end
