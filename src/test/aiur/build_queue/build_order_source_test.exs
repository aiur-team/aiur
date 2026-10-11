defmodule Aiur.BuildQueue.BuildOrderSourceTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Aiur.BuildOrder.{Dependency, GraphProjection, GraphProjection.Snapshot, Lifecycle, Member, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.BuildQueue.{Hints, ListMutations, Model, MutationCLI, Server}
  alias Aiur.BuildQueue.Sources.BuildOrder
  alias Aiur.Config.Schema
  alias Aiur.Events.Exchange
  alias Aiur.TrackerIdentity

  @empty %{queues: [], items: [], edges: [], intents: [], latches: []}

  defmodule Boundary do
    def load, do: Agent.get(__MODULE__, &{:ok, &1.document})

    def save(document) do
      {:ok, restored} = document |> Model.encode() |> Jason.encode!() |> Jason.decode!() |> Model.decode()
      Agent.update(__MODULE__, &%{&1 | document: restored})
    end

    def open_issue_labels(_age), do: Agent.get(__MODULE__, &{:ok, Map.new(&1.labels, fn {id, labels} -> {id, %{labels: labels}} end), &1.now})
    def issue_closure(_id, _age), do: {:error, :unavailable}
    def blocked_by(_id), do: {:ok, []}

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
        labels = Map.update!(state.labels, id, &if(action == :add, do: Enum.uniq(&1 ++ [label]), else: List.delete(&1, label)))
        %{state | labels: labels, calls: state.calls ++ [{action, id, label}]}
      end)
    end
  end

  defmodule Projection do
    use GenServer
    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot)
    @impl true
    def init(snapshot), do: {:ok, %{snapshot: snapshot, refreshes: 0, releases: 0, release_result: :ok, timeout?: false}}
    @impl true
    def handle_call(:catalog, _, %{timeout?: true} = state) do
      Agent.update(Boundary, &%{&1 | catalog_calls: &1.catalog_calls + 1})
      {:noreply, state}
    end

    def handle_call(:catalog, _, state), do: {:reply, %{data: %{entries: [state.snapshot.data.root]}}, state}
    def handle_call({:selected_topic, identity}, _, state), do: {:reply, {:ok, GraphProjection.selected_topic(identity)}, state}
    def handle_call({verb, _}, _, state) when verb in [:demand, :selected], do: {:reply, {:ok, state.snapshot}, state}
    def handle_call({:release, _}, _, state), do: {:reply, state.release_result, %{state | releases: state.releases + 1}}
    def handle_call({:replace, snapshot}, _, state), do: {:reply, :ok, %{state | snapshot: snapshot}}
    @impl true
    def handle_cast({:refresh_selected, _}, state), do: {:noreply, %{state | refreshes: state.refreshes + 1}}
  end

  setup do
    labels = Map.new(["1", "2", "3", "4"], &{&1, []})

    pid =
      start_supervised!(
        {Agent,
         fn ->
           %{
             document: @empty,
             labels: labels,
             now: 1_000_000,
             claims: %{"1" => :unclaimed, "2" => :unclaimed, "3" => :claimed, "4" => :unclaimed},
             calls: [],
             probes: [],
             promotion_result: :ok,
             marker_result: :ok,
             catalog_calls: 0
           }
         end},
        id: Boundary
      )

    Process.register(pid, Boundary)
    :ok
  end

  test "native edges map from actual dependency records and closed prerequisites remain edges" do
    queue = queue()
    closed = %{member(1) | lifecycle: %Lifecycle{state: :closed, state_reason: :completed}}
    snapshot = snapshot([closed, member(2, [dependency(1, 2)])])
    assert {:ok, items, edges, :current} = BuildOrder.members(queue, %{items: [], source_snapshots: %{99 => {:ok, snapshot}}})
    assert Enum.map(items, &{&1.issue_id, &1.position}) == [{"2", nil}]
    assert Enum.map(edges, &{&1.prerequisite, &1.dependent, &1.source}) == [{"1", "2", :build_order}]
  end

  test "mutation CLI adopts a named root and reports the owner of refused members" do
    projection = start_supervised!({Projection, snapshot([member(1), member(2)])})
    pid = server(projection)
    assert :ok = Aiur.BuildQueue.add(["1"], "paseo")

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert Aiur.BuildQueueCLI.run(verb: :add, build_order: 99, queue: "roadmap", server: pid) == 1
      end)

    assert output =~ "Build Order #99: ok"
    assert output =~ "#1: already in queue paseo"
    assert Enum.find(get(:document).queues, &(&1.root == 99)).name == "roadmap"
    assert Enum.find(get(:document).items, &(&1.issue_id == "2")).queue_id == Enum.find(get(:document).queues, &(&1.name == "roadmap")).id
    assert {:ok, [{"Build Order #99", {:error, :already_adopted}}]} = MutationCLI.execute(verb: :add, build_order: 99, server: pid)
  end

  test "start-on adoption persists through codec and queue set follows config" do
    projection = start_supervised!({Projection, snapshot([member(1)])})
    pid = server(projection)
    assert {:ok, [{"Build Order #99", :ok}]} = MutationCLI.execute(verb: :add, build_order: 99, queue: "optimistic", start_on: "pr_opened", server: pid)
    assert hd(get(:document).queues).start_trigger == :pr_opened
    assert {:error, :invalid_start_trigger} = GenServer.call(pid, {:mutate, {:adopt, 100, nil, :soon}})
    assert hd(Aiur.BuildQueue.show(pid).queues).start_trigger == :pr_opened
    assert {:ok, [{"optimistic", :ok}]} = MutationCLI.execute(verb: :set, queue: "optimistic", start_on: "default", server: pid)
    assert hd(get(:document).queues).start_trigger == nil
    generation = hd(get(:document).queues).generation
    reconcile(pid)
    assert hd(get(:document).queues).generation == generation
    assert hd(Aiur.BuildQueue.show(pid).queues).start_trigger == :pr_merged
  end

  test "generated Build Order queue names cannot collide with an existing list" do
    projection = start_supervised!({Projection, snapshot([member(2)])})
    pid = server(projection)
    assert :ok = Aiur.BuildQueue.add(["1"], "Build Order #99")
    assert {:ok, [{"Build Order #99", {:error, :queue_exists}}]} = MutationCLI.execute(verb: :add, build_order: 99, server: pid)
    assert [%{name: "Build Order #99", kind: :list}] = get(:document).queues
  end

  test "stale real ProviderHealth yields unavailable, unknown items and zero tracker writes" do
    projection = start_supervised!({Projection, snapshot([member(1)])})
    pid = server(projection)
    assert {:ok, []} = Aiur.BuildQueue.adopt(99)
    reconcile(pid)
    clear_calls()
    stale = snapshot([member(1)], ProviderHealth.new(2, :stale, true))
    assert {:unavailable, :stale} = BuildOrder.members(queue(), %{items: [], source_snapshots: %{99 => {:ok, stale}}})
    GenServer.call(projection, {:replace, stale})
    deliver_projection(pid, :graph_projection_health, stale)
    assert get(:calls) == []
    assert {:ok, %{sources: %{"build_order:99" => {:unavailable, :stale}}, projections: [%{state: :unknown, verdict: {:unknown, [:stale]}}]}} = GenServer.call(Server, :show)
  end

  test "external edge makes its dependent unknown and never promotes it" do
    external = %{dependency(1, 2) | kind: :external}
    projection = start_supervised!({Projection, snapshot([member(2, [external])])})
    pid = server(projection)
    assert {:ok, []} = Aiur.BuildQueue.adopt(99)
    reconcile(pid)
    assert {:ok, %{projections: [%{issue_id: "2", state: :unknown, verdict: {:unknown, [:external_edge]}}]}} = GenServer.call(Server, :show)
    refute {:add, "2", "agent:todo"} in get(:calls)
  end

  test "outgoing external dependency does not poison a local member with the same ticket number" do
    {:ok, foreign} = TrackerIdentity.from_github(%{"node_id" => "I_foreign", "number" => 2}, {"foreign", "repo"}, {"foreign", "repo"})
    outgoing = %Dependency{kind: :external, source_connection: :blocking, blocker_identity: identity(1), blocked_identity: foreign}
    projection = start_supervised!({Projection, snapshot([member(1, [outgoing]), member(2)])})
    pid = server(projection)
    assert {:ok, []} = Aiur.BuildQueue.adopt(99)
    reconcile(pid)
    assert {:add, "2", "agent:todo"} in get(:calls)
    assert {:ok, %{projections: projections}} = GenServer.call(Server, :show)
    assert Enum.find(projections, &(&1.issue_id == "2")).verdict == :ready
  end

  test "budget-paused promotion cannot retry after the graph becomes stale" do
    update(:promotion_result, {:error, {:github, :rate_limited, nil}})
    projection = start_supervised!({Projection, snapshot([member(1)])})
    pid = server(projection)
    assert {:ok, []} = Aiur.BuildQueue.adopt(99)
    reconcile(pid)
    assert :sys.get_state(pid).status == :writes_paused
    clear_calls()
    update(:promotion_result, :ok)
    stale = snapshot([member(1)], ProviderHealth.new(2, :stale, true))
    GenServer.call(projection, {:replace, stale})
    deliver_projection(pid, :graph_projection_health, stale)
    assert get(:calls) == []
    assert {:ok, %{sources: %{"build_order:99" => {:unavailable, :stale}}, projections: [%{state: :unknown}]}} = GenServer.call(Server, :show)
  end

  test "OQ-7 adoption withdraws blocked unclaimed todo after holding dispatch, leaving claimed todo alone" do
    update(:labels, %{"1" => [], "2" => ["agent:todo"], "3" => ["agent:todo"], "4" => []})
    projection = start_supervised!({Projection, snapshot([member(1), member(2, [dependency(1, 2)]), member(3, [dependency(1, 3)])])})
    pid = server(projection)
    assert {:ok, []} = Aiur.BuildQueue.adopt(99)
    reconcile(pid)
    assert Enum.filter(get(:calls), &match?({:remove, _, "agent:todo"}, &1)) == [{:remove, "2", "agent:todo"}]
    assert Enum.any?(get(:probes), &(&1["2"] == true))
    assert "agent:todo" in get(:labels)["3"]
    assert "agent:queued" in get(:labels)["2"]
  end

  test "ownership refusals retain list membership, generations add members and unadopt removes markers" do
    projection = start_supervised!({Projection, snapshot([member(1), member(2)])})
    pid = server(projection)
    assert :ok = Aiur.BuildQueue.add(["1"], "list")
    assert {:ok, [{"1", :already_queued}]} = Aiur.BuildQueue.adopt(99)
    assert Enum.count(get(:document).items, &(&1.issue_id == "1")) == 1
    reconcile(pid)
    changed = snapshot([member(1), member(2), member(4)])
    GenServer.call(projection, {:replace, changed})
    deliver_projection(pid, :graph_projection_generation, changed)
    assert Enum.sort(Enum.map(get(:document).items, & &1.issue_id)) == ["1", "2", "4"]
    assert {:ok, []} = Aiur.BuildQueue.unadopt(99)
    assert Enum.map(get(:document).items, & &1.issue_id) == ["1"]
    assert {:remove, "4", "agent:queued"} in get(:calls)
    assert :sys.get_state(projection).releases == 1
  end

  test "a member leaving the Build Order is dequeued with a removed event" do
    owner = self()
    :ok = Exchange.subscribe("ticket.2.queue.removed")
    on_exit(fn -> GenServer.call(Exchange, {:unsubscribe, "ticket.2.queue.removed", owner}) end)
    projection = start_supervised!({Projection, snapshot([member(1), member(2)])})
    pid = server(projection)
    assert {:ok, []} = Aiur.BuildQueue.adopt(99)
    reconcile(pid)
    changed = snapshot([member(1)])
    GenServer.call(projection, {:replace, changed})
    deliver_projection(pid, :graph_projection_generation, changed)
    assert Enum.map(get(:document).items, & &1.issue_id) == ["1"]
    assert {:remove, "2", "agent:queued"} in get(:calls)
    assert_receive {:event, %{topic: "ticket.2.queue.removed"}}, 1_000
  end

  test "generated queue ids stay lowercase hex" do
    queues = Enum.map(0..9, &%{queue() | id: "q-000#{&1}"})
    assert {:ok, "q-000a"} = ListMutations.queue_id(%{@empty | queues: queues})
  end

  test "missing projection isolates list promotion and hints coalesce per interval" do
    pid = server(:missing_build_order_projection)
    assert {:error, :projection_down} = Aiur.BuildQueue.adopt(99)
    assert :ok = Aiur.BuildQueue.add(["1"], "list")
    reconcile(pid)
    assert {:add, "1", "agent:todo"} in get(:calls)
    assert %{build_queue: %{build_order_source: false}} = Aiur.BuildQueue.show()
  end

  test "member hints refresh at most once per reconciliation interval" do
    projection = start_supervised!({Projection, snapshot([member(1)])})
    pid = server(projection)
    assert {:ok, []} = Aiur.BuildQueue.adopt(99)
    send(pid, {:open_issues_recorded, nil})
    send(pid, {:open_issues_recorded, nil})
    :sys.get_state(pid)
    assert :sys.get_state(projection).refreshes == 1
    update(:now, 1_061_000)
    send(pid, {:open_issues_recorded, nil})
    :sys.get_state(pid)
    assert :sys.get_state(projection).refreshes == 2
  end

  test "cold adoption persists interest, requests a read and imports the healthy generation" do
    cold = %{snapshot([member(1)]) | data: %{snapshot([member(1)]).data | provider: ProviderHealth.new(:unknown, :unavailable, false)}, health: ProviderHealth.new(:unknown, :unavailable, false)}
    projection = start_supervised!({Projection, cold})
    pid = server(projection)
    assert {:ok, []} = Aiur.BuildQueue.adopt(99)
    assert get(:document).items == []
    assert get(:calls) == []
    assert :sys.get_state(projection).refreshes == 1
    reconcile(pid)
    healthy = snapshot([member(1)])
    GenServer.call(projection, {:replace, healthy})
    deliver_projection(pid, :graph_projection_generation, healthy)
    assert Enum.map(get(:document).items, & &1.issue_id) == ["1"]
    assert {:add, "1", "agent:todo"} in get(:calls)
  end

  test "restart restores membership and a projection outage prevents writes while a list advances" do
    projection = start_supervised!({Projection, snapshot([member(2, [dependency(1, 2)])])})
    pid = server(projection)
    assert {:ok, []} = Aiur.BuildQueue.adopt(99)
    assert :ok = Aiur.BuildQueue.add(["4"], "list")
    reconcile(pid)
    :ok = stop_supervised(Server)
    clear_calls()
    update(:labels, Map.put(get(:labels), "4", ["agent:queued"]))

    Agent.update(Boundary, fn state ->
      items = Enum.map(state.document.items, &%{&1 | promoted_at: nil})
      %{state | document: %{state.document | items: items}}
    end)

    pid = server(:missing_build_order_projection)
    reconcile(pid)
    assert {:ok, %{sources: %{"build_order:99" => {:unavailable, :projection_down}}, projections: projections}} = GenServer.call(Server, :show)
    assert Enum.find(projections, &(&1.issue_id == "2")).state == :unknown
    assert {:add, "4", "agent:todo"} in get(:calls)
    refute {:add, "2", "agent:todo"} in get(:calls)
  end

  test "partial evidence and a closed root stop writes without discarding membership" do
    projection = start_supervised!({Projection, snapshot([member(1)])})
    pid = server(projection)
    assert {:ok, []} = Aiur.BuildQueue.adopt(99)
    reconcile(pid)
    clear_calls()
    partial = snapshot([member(1)], ProviderHealth.new(2, :healthy, false))
    GenServer.call(projection, {:replace, partial})
    reconcile(pid)
    assert {:ok, %{sources: %{"build_order:99" => {:unavailable, :partial}}}} = GenServer.call(Server, :show)
    assert get(:calls) == []
    closed = snapshot([member(1)])
    closed = %{closed | data: %{closed.data | root: %{closed.data.root | lifecycle: %Lifecycle{state: :closed, state_reason: :completed}}}}
    GenServer.call(projection, {:replace, closed})
    reconcile(pid)
    assert {:ok, %{sources: %{"build_order:99" => {:unavailable, :completed}}}} = GenServer.call(Server, :show)
    assert get(:calls) == []
    assert length(get(:document).items) == 1
  end

  test "root limit and invalid roots are refused before any projection or tracker writes" do
    pid = server(:missing_build_order_projection)
    assert {:error, :invalid_root} = Aiur.BuildQueue.adopt(0)
    queues = Enum.map(1..32, &%{queue() | id: "q-" <> String.pad_leading(Integer.to_string(&1, 16), 4, "0"), root: &1})
    :sys.replace_state(pid, &%{&1 | document: %{@empty | queues: queues}})
    assert {:error, :too_many_roots} = Aiur.BuildQueue.adopt(99)
    assert get(:calls) == []
  end

  test "paced adoption markers retain membership until a later reconciliation writes them" do
    projection = start_supervised!({Projection, snapshot([member(1), member(2)])})
    pid = server(projection, 1)
    assert {:error, {:marker_write_failed, failures}} = Aiur.BuildQueue.adopt(99)
    assert failures != []

    for _ <- 1..5 do
      reconcile(pid)
      assert Enum.sort(Enum.map(get(:document).items, & &1.issue_id)) == ["1", "2"]
      assert {:ok, %{projections: projections}} = GenServer.call(Server, :show)
      assert Enum.all?(projections, &(&1.reason == :marker_pending))
    end

    update(:now, 1_061_000)
    reconcile(pid)
    assert Enum.any?(get(:calls), &match?({:add, _, "agent:queued"}, &1))
    assert length(get(:document).items) == 2
  end

  test "adoption retries rate-limited markers after the writer resumes" do
    update(:marker_result, {:error, {:github, :rate_limited, nil}})
    projection = start_supervised!({Projection, snapshot([member(1)])})
    pid = server(projection)
    assert {:error, {:marker_write_failed, _}} = Aiur.BuildQueue.adopt(99)
    reconcile(pid)
    assert :sys.get_state(pid).status == :writes_paused
    assert Enum.map(get(:document).items, & &1.issue_id) == ["1"]
    update(:marker_result, :ok)
    reconcile(pid)
    assert :sys.get_state(pid).status == :running
    assert {:add, "1", "agent:queued"} in get(:calls)
    assert {:add, "1", "agent:todo"} in get(:calls)
  end

  test "projection reset schedules a reconcile and reads the new health before writes" do
    projection = start_supervised!({Projection, snapshot([member(1)])})
    pid = server(projection)
    assert {:ok, []} = Aiur.BuildQueue.adopt(99)
    reconcile(pid)
    clear_calls()
    GenServer.call(projection, {:replace, snapshot([member(1)], ProviderHealth.new(2, :stale, true))})
    send(pid, {:graph_projection_reset, 2})
    token = :sys.get_state(pid).pending
    assert is_reference(token)
    send(pid, {:reconcile, token})
    assert :sys.get_state(pid).projections |> hd() |> Map.fetch!(:state) == :unknown
    assert get(:calls) == []
  end

  test "unadoption logs a failed projection release and keeps its durable membership removal" do
    projection = start_supervised!({Projection, snapshot([member(1)])})
    server(projection)
    assert {:ok, []} = Aiur.BuildQueue.adopt(99)
    :sys.replace_state(projection, &%{&1 | release_result: {:error, :unavailable}})
    log = capture_log(fn -> assert {:ok, []} = Aiur.BuildQueue.unadopt(99) end)
    assert log =~ "projection release failed root=99 reason=:unavailable"
    assert get(:document).queues == []
    assert get(:document).items == []
    assert {:remove, "1", "agent:queued"} in get(:calls)
  end

  test "automatic refresh respects a real provider retry deadline" do
    health = ProviderHealth.new(1, :stale, true, next_retry_at: DateTime.from_unix!(1_100_000, :millisecond))
    projection = start_supervised!({Projection, snapshot([member(1)], health)})
    pid = server(projection)
    assert {:ok, []} = Aiur.BuildQueue.adopt(99)
    send(pid, {:open_issues_recorded, nil})
    :sys.get_state(pid)
    assert :sys.get_state(projection).refreshes == 0
    update(:now, 1_101_000)
    send(pid, {:open_issues_recorded, nil})
    :sys.get_state(pid)
    assert :sys.get_state(projection).refreshes == 1
  end

  test "an unresponsive projection is tried once per cycle while an independent list promotes" do
    queues = [%{queue() | root: 99}, %{queue() | id: "q-0001", root: 100}]
    {:ok, document, _} = ListMutations.add(%{@empty | queues: queues}, ["4"], [queue: "list"], DateTime.from_unix!(0))
    update(:document, document)
    update(:labels, Map.put(get(:labels), "4", ["agent:queued"]))
    projection = start_supervised!({Projection, snapshot([member(1)])})
    :sys.replace_state(projection, &%{&1 | timeout?: true})
    server(projection)
    assert {:add, "4", "agent:todo"} in get(:calls)
    # A snapshot recorded elsewhere on the shared topic must not reach this server and re-try the projection.
    Phoenix.PubSub.broadcast(Aiur.PubSub, "tracker:open_issues", {:open_issues_recorded, nil})
    assert {:ok, %{sources: sources}} = GenServer.call(Server, :show)
    assert sources == %{"build_order:99" => {:unavailable, :projection_unavailable}, "build_order:100" => {:unavailable, :projection_unavailable}}
    assert get(:catalog_calls) == 1
  end

  defp queue, do: %Model.Queue{id: "q-0000", name: "Build Order", kind: :build_order, root: 99, held: false, generation: 0, created_at: DateTime.from_unix!(0)}

  defp identity(number) do
    {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => "I_#{number}", "number" => number}, {"owner", "repo"}, {"owner", "repo"})
    identity
  end

  defp member(number, dependencies \\ []),
    do:
      Member.new(%{
        identity: identity(number),
        title: "Member",
        url: "https://github.com/owner/repo/issues/#{number}",
        lifecycle: %Lifecycle{state: :open, state_reason: :none},
        dependencies: dependencies
      })

  defp dependency(blocker, blocked), do: Dependency.new(identity(blocked), identity(blocker), "https://github.com/owner/repo/issues/#{blocker}")

  defp snapshot(members, health \\ ProviderHealth.new(1, :healthy, true)) do
    root = RootSummary.new(%{identity: identity(99), title: "Build Order", url: "https://github.com/owner/repo/issues/99", lifecycle: %Lifecycle{state: :open, state_reason: :none}})
    selected = SelectedRoot.new(root, members, health)
    %Snapshot{scope: {:selected, identity(99)}, repository: {"owner", "repo"}, generation: health.generation, health: health, data: selected}
  end

  defp server(projection, max_writes \\ 20) do
    {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "github"}, "build_queue" => %{"enabled" => true, "reconcile_interval_seconds" => 60, "max_writes_per_minute" => max_writes}})

    pid =
      start_supervised!(
        {Server,
         settings: {:ok, settings},
         tracker: Boundary,
         store: Boundary,
         claim_probe: Boundary,
         build_order_projection: projection,
         clock: fn -> get(:now) end,
         schedule: fn _, _, _ -> make_ref() end,
         sleep: fn _ -> :ok end,
         exchange: :missing_exchange,
         open_issues_topic: "tracker:open_issues:#{System.unique_integer([:positive])}"}
      )

    reconcile(pid)
    pid
  end

  defp deliver_projection(pid, kind, snapshot) do
    {:selected, identity} = snapshot.scope
    Phoenix.PubSub.broadcast(Aiur.PubSub, GraphProjection.selected_topic(identity), {kind, snapshot})
    token = :sys.get_state(pid).pending
    assert is_reference(token)
    send(pid, {:reconcile, token})
    :sys.get_state(pid)
  end

  defp reconcile(pid) do
    GenServer.call(pid, :reconcile_now)
    token = :sys.get_state(pid).pending
    send(pid, {:reconcile, token})
    :sys.get_state(pid, 30_000)
  end

  defp get(key), do: Agent.get(Boundary, &Map.fetch!(&1, key))
  defp update(key, value), do: Agent.update(Boundary, &Map.put(&1, key, value))
  defp clear_calls, do: update(:calls, [])
end
