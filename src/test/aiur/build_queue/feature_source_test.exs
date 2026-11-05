defmodule Aiur.BuildQueue.FeatureSourceTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Aiur.BuildQueue.{Hints, Model, MutationCLI, Server}
  alias Aiur.BuildQueue.Sources.Feature
  alias Aiur.Config.Schema

  @empty %{queues: [], items: [], edges: [], intents: [], latches: []}

  defmodule Boundary do
    def load, do: Agent.get(__MODULE__, &{:ok, &1.document})

    def save(document) do
      {:ok, restored} = document |> Model.encode() |> Jason.encode!() |> Jason.decode!() |> Model.decode()
      Agent.update(__MODULE__, &%{&1 | document: restored})
    end

    def open_issue_labels(_age), do: Agent.get(__MODULE__, &{:ok, Map.new(&1.labels, fn {id, labels} -> {id, %{labels: labels}} end), &1.now})
    def issue_closure(id, _age), do: Agent.get(__MODULE__, &Map.get(&1.closures, id, {:error, :not_found}))
    def blocked_by(id), do: Agent.get(__MODULE__, &{:ok, Map.get(&1.dependencies, id, [])})

    def status(ids) do
      Agent.get_and_update(__MODULE__, fn state ->
        holds = Map.new(ids, &{&1, Hints.held?(&1)})
        {state.claims, %{state | probes: state.probes ++ [holds]}}
      end)
    end

    def notify_demand(_ids), do: :ok
    def ensure_labels(_labels), do: :ok

    def add_label(id, label) do
      result = Agent.get(__MODULE__, & &1.marker_result)
      if result == :ok, do: write(id, label, :add), else: result
    end

    def remove_label(id, label), do: write(id, label, :remove)

    def update_issue_state(id, "todo", _opts) do
      result = Agent.get(__MODULE__, & &1.promotion_result)
      if result == :ok, do: write(id, "agent:todo", :add), else: result
    end

    defp write(id, label, action) do
      Agent.update(__MODULE__, fn state ->
        labels = Map.update(state.labels, id, [], &if(action == :add, do: Enum.uniq(&1 ++ [label]), else: List.delete(&1, label)))
        %{state | labels: labels, calls: state.calls ++ [{action, id, label}]}
      end)
    end
  end

  defmodule FeatureRegistry do
    def snapshot(_opts), do: Agent.get(__MODULE__, & &1.snapshot)
  end

  setup do
    labels = Map.new(101..110, &{Integer.to_string(&1), []})

    pid =
      start_supervised!(
        {Agent,
         fn ->
           %{
             document: @empty,
             labels: labels,
             now: 1_000_000,
             claims: Map.new(101..110, &{Integer.to_string(&1), :unclaimed}),
             calls: [],
             probes: [],
             promotion_result: :ok,
             marker_result: :ok,
             dependencies: %{},
             closures: %{}
           }
         end},
        id: Boundary
      )

    Process.register(pid, Boundary)
    registry_pid = start_supervised!({Agent, fn -> %{snapshot: {:ok, registry("combat", [])}} end}, id: FeatureRegistry)
    Process.register(registry_pid, FeatureRegistry)
    :ok
  end

  test "a queued feature picks up a ticket added to the registry later" do
    set_registry({:ok, registry("combat", [101, 102, 103, 104, 105, 106])})
    pid = server()

    assert {:ok, [{"Feature combat", :ok}]} = adopt(pid)
    assert ids() == Enum.map(101..106, &Integer.to_string/1)

    set_registry({:ok, registry("combat", [101, 102, 103, 104, 105, 106, 107], generation: 2)})
    reconcile(pid)

    assert ids() == Enum.map(101..107, &Integer.to_string/1)
    assert {:add, "107", "agent:queued"} in get(:calls)
  end

  test "a list keeps ownership of a ticket that is also in a queued feature" do
    set_registry({:ok, registry("combat", [101, 102])})
    pid = server()

    assert :ok = Aiur.BuildQueue.add(["101"], "list")
    assert {:ok, [{"Feature combat", :ok}, {"#101", {:error, {:already_queued, "list"}}}]} = adopt(pid)

    list = Enum.find(get(:document).queues, &(&1.name == "list"))
    assert Enum.count(get(:document).items, &(&1.issue_id == "101")) == 1
    assert Enum.find(get(:document).items, &(&1.issue_id == "101")).queue_id == list.id
    assert ids() == ["101", "102"]

    feature = Enum.find(Aiur.BuildQueue.show(pid).queues, &(&1.kind == :feature))
    assert feature.elsewhere == [{"101", "list"}]
    assert Enum.map(feature.items, & &1.number) == [102]

    output = capture_io(fn -> assert Aiur.BuildQueueCLI.run(verb: :show, server: pid) == 0 end)
    assert output =~ "#101  owned elsewhere  list"

    reconcile(pid)
    assert Enum.find(Aiur.BuildQueue.show(pid).queues, &(&1.kind == :feature)).elsewhere == [{"101", "list"}]
    assert ids() == ["101", "102"]
  end

  test "removing a registry member unmarks it and an item hold survives sync" do
    set_registry({:ok, registry("combat", [101, 102])})
    pid = server()
    assert {:ok, _results} = adopt(pid)

    assert :ok = GenServer.call(pid, {:hold, "101"})
    assert Enum.find(get(:document).items, &(&1.issue_id == "101")).hold == :operator

    set_registry({:ok, registry("combat", [101], generation: 2)})
    reconcile(pid)

    assert ids() == ["101"]
    assert Enum.find(get(:document).items, &(&1.issue_id == "101")).hold == :operator
    assert {:remove, "102", "agent:queued"} in get(:calls)
  end

  test "a blocked feature member is not promoted until its blocker closes" do
    set_registry({:ok, registry("combat", [101, 102])})
    update(:dependencies, %{"102" => ["101"]})
    pid = server()
    assert {:ok, _results} = adopt(pid)
    reconcile(pid)

    assert {:add, "101", "agent:todo"} in get(:calls)
    refute {:add, "102", "agent:todo"} in get(:calls)

    update(:labels, Map.delete(get(:labels), "101"))
    update(:closures, %{"101" => {:ok, %{open?: false, state_reason: "completed"}}})
    clear_calls()
    reconcile(pid)

    assert {:add, "102", "agent:todo"} in get(:calls)
  end

  test "queue add --feature warns when set order is none and stays quiet when ranked" do
    set_registry({:ok, registry("combat", [101])})
    pid = server()

    stderr = capture_io(:stderr, fn -> assert {:ok, _results} = MutationCLI.execute(verb: :add, feature: "combat", server: pid, settings: settings()) end)
    assert stderr =~ "build_queue.set_order is none"

    :sys.replace_state(pid, &%{&1 | document: @empty})
    stderr = capture_io(:stderr, fn -> assert {:ok, _results} = MutationCLI.execute(verb: :add, feature: "combat", server: pid, settings: settings(%{"set_order" => "ranked"})) end)
    refute stderr =~ "build_queue.set_order is none"
  end

  test "an unavailable registry leaves membership untouched and marks members unknown" do
    set_registry({:ok, registry("combat", [101])})
    pid = server()
    assert {:ok, _results} = adopt(pid)
    reconcile(pid)
    clear_calls()

    set_registry({:error, %{state: :unavailable}})
    reconcile(pid)

    assert ids() == ["101"]
    assert get(:calls) == []
    assert {:ok, %{sources: %{"feature:combat" => {:unavailable, :partial}}}} = GenServer.call(Server, :show)
  end

  test "a registry change asks the server to reconcile promptly" do
    set_registry({:ok, registry("combat", [101])})
    owner = self()

    pid =
      server(
        schedule: fn _server, message, _delay ->
          send(owner, {:scheduled, message})
          make_ref()
        end
      )

    assert_receive {:scheduled, {:reconcile, _token}}, 1_000
    send(pid, {:build_order_features_changed, {:ok, %{slug: "combat"}}})
    assert_receive {:scheduled, {:reconcile, _token}}, 1_000
  end

  test "queue add --feature honors --rank without an explicit name" do
    set_registry({:ok, registry("combat", [101])})
    pid = server()

    assert {:ok, [{"Feature combat", :ok}]} =
             MutationCLI.execute(verb: :add, feature: "combat", rank: 0, server: pid, settings: settings(), error_fun: fn _ -> :ok end)

    assert Enum.find(get(:document).queues, &(&1.kind == :feature)) |> Map.take([:name, :rank]) == %{name: "Feature combat", rank: 0}
  end

  test "a feature slug missing from the registry is refused before any write" do
    set_registry({:ok, registry("combat", [101])})
    pid = server()

    assert {:ok, [{"Feature naval", {:error, :feature_not_found}}]} = MutationCLI.execute(verb: :add, feature: "naval", server: pid, settings: settings(), error_fun: fn _ -> :ok end)
    assert get(:document).queues == []
    assert get(:calls) == []
  end

  test "the source keeps a closed member that is already queued and never adds a closed one" do
    queue = %Model.Queue{id: "q-0000", name: "Feature combat", kind: :feature, feature: "combat", root: nil, held: false, generation: 0, created_at: DateTime.from_unix!(0)}
    existing = %Model.Item{issue_id: "101", queue_id: "q-0000", position: nil, hold: nil, override: nil, promoted_at: nil, added_at: DateTime.from_unix!(0)}
    context = %{items: [existing], source_snapshots: %{"combat" => {:ok, registry("combat", [101, 102, 103])}}, observations: %{"102" => %{}}}

    assert {:ok, [%{issue_id: "101"}, %{issue_id: "102"}], [], :current} = Feature.members(queue, context)
  end

  test "the source is unavailable without a fresh open-issue observation" do
    queue = %Model.Queue{id: "q-0000", name: "Feature combat", kind: :feature, feature: "combat", root: nil, held: false, generation: 0, created_at: DateTime.from_unix!(0)}
    context = %{items: [], source_snapshots: %{"combat" => {:ok, registry("combat", [101])}}, observations: %{}}

    assert {:unavailable, :observation_unavailable} = Feature.members(queue, context)
  end

  defp adopt(pid, settings \\ settings()) do
    MutationCLI.execute(verb: :add, feature: "combat", server: pid, settings: settings, error_fun: fn _ -> :ok end)
  end

  defp registry(slug, numbers, opts \\ []) do
    %{
      features: %{slug => %{slug: slug, epics: [], baseline: :none}},
      owners: Map.new(numbers, &{&1, %{feature: slug, epic: nil, confirmed: true}}),
      also: %{},
      generation: Keyword.get(opts, :generation, 1),
      health: %{state: :healthy}
    }
  end

  defp settings(overrides \\ %{}) do
    {:ok, settings} =
      Schema.parse(%{
        "tracker" => %{"kind" => "github"},
        "build_queue" => Map.merge(%{"enabled" => true, "reconcile_interval_seconds" => 60, "max_writes_per_minute" => 20}, overrides)
      })

    settings
  end

  defp server(opts \\ []) do
    pid =
      start_supervised!(
        {Server,
         settings: {:ok, Keyword.get(opts, :settings, settings())},
         tracker: Boundary,
         store: Boundary,
         claim_probe: Boundary,
         feature_registry: FeatureRegistry,
         clock: fn -> get(:now) end,
         schedule: Keyword.get(opts, :schedule, fn _, _, _ -> make_ref() end),
         exchange: :missing_exchange,
         open_issues_topic: "tracker:open_issues:#{System.unique_integer([:positive])}"}
      )

    reconcile(pid)
    pid
  end

  defp reconcile(pid) do
    GenServer.call(pid, :reconcile_now)
    token = :sys.get_state(pid).pending
    send(pid, {:reconcile, token})
    :sys.get_state(pid, 30_000)
  end

  defp ids, do: get(:document).items |> Enum.map(& &1.issue_id) |> Enum.sort_by(&String.to_integer/1)
  defp set_registry(snapshot), do: Agent.update(FeatureRegistry, &%{&1 | snapshot: snapshot})
  defp get(key), do: Agent.get(Boundary, &Map.fetch!(&1, key))
  defp update(key, value), do: Agent.update(Boundary, &Map.put(&1, key, value))
  defp clear_calls, do: update(:calls, [])
end
