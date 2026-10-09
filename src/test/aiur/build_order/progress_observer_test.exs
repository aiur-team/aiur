defmodule Aiur.BuildOrder.ProgressObserverTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.BuildOrder.{Catalog, GraphProjection, ProgressObserver, ProviderHealth, RootSummary}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.{BuildProgress, TrackerIdentity}
  alias Aiur.Events.Exchange

  defmodule Projection do
    use GenServer
    def init(snapshot), do: {:ok, snapshot}
    def handle_call(:catalog, _from, snapshot), do: {:reply, snapshot, snapshot}
    def handle_call({:replace, snapshot}, _from, _old), do: {:reply, :ok, snapshot}
    def handle_call(:catalog_topic, _from, %{repository: :unknown} = snapshot), do: {:reply, {:error, %Aiur.BuildOrder.GraphProjection.Failure{kind: :configuration}}, snapshot}
    def handle_call(:catalog_topic, _from, snapshot), do: {:reply, {:ok, GraphProjection.catalog_topic(snapshot.repository)}, snapshot}
  end

  setup do
    dir = Aiur.TestSupport.tmp_root!("progress-observer")
    File.mkdir_p!(dir)
    id = System.unique_integer([:positive])
    :ok = Exchange.subscribe("system.build_order.#{id}.progress")
    :ok = BuildProgress.subscribe()
    on_exit(fn -> File.rm_rf!(dir) end)
    %{path: Path.join(dir, "latches.json"), id: id, scope: {:build_order, id}}
  end

  test "initial catalog and subscribed generations preserve rounded 2/3 progress", context do
    {_observer, store, snapshot} = start_observer(context, 50)
    assert [%{percent: 50, generation: 1, resolution: :resolved, resolved: 3, total: 3, observed_at: observed_at}] = BuildProgress.facts(context.scope, store)
    assert observed_at == snapshot.health.observed_at
    assert_received {:event, %{milestone: 50}}
    scope = context.scope
    assert_received {:build_progress_changed, %{scope: ^scope, percent: 50}}
    [fact] = BuildProgress.facts(context.scope, store)
    :ok = BuildProgress.put_fact(%{fact | scope: {:queue, "other-latch"}}, store)
    snapshot = percent(snapshot, 67)
    Phoenix.PubSub.broadcast!(Aiur.PubSub, GraphProjection.catalog_topic(snapshot.repository), {:graph_projection_generation, snapshot})
    scope = context.scope
    receive_barrier({:build_progress_changed, %{scope: ^scope}})
    assert [%{percent: 67}] = BuildProgress.facts(context.scope, store)
  end

  test "unusable health marks facts stale and suppresses milestones", context do
    {observer, store, snapshot} = start_observer(context, 20)

    for {health, complete?} <- [healthy: false, stale: true, unavailable: true, structurally_invalid: true] do
      send(observer, {:graph_projection_health, %{percent(snapshot, 100) | health: ProviderHealth.new(1, health, complete?)}})
      :sys.get_state(observer)
      assert [%{percent: 100, freshness: :stale}] = BuildProgress.facts(context.scope, store)
    end

    refute_received {:event, %{topic: _}}
    send(observer, {:graph_projection_health, percent(snapshot, 100)})
    :sys.get_state(observer)
    assert_received {:event, %{milestone: 100, generation: 1}}
  end

  test "completion then resolved zero persists generation 2 across both restarts", context do
    {observer, store, snapshot} = start_observer(context, 100)
    assert_received {:event, %{milestone: 100, generation: 1}}
    send(observer, {:graph_projection_generation, percent(snapshot, 0)})
    :sys.get_state(observer)
    assert [%{generation: 2, percent: 0}] = BuildProgress.facts(context.scope, store)
    GenServer.stop(observer)
    GenServer.stop(store)
    {restarted, store, snapshot} = start_observer(context, 0)
    assert [%{generation: 2}] = BuildProgress.facts(context.scope, store)
    send(restarted, {:graph_projection_generation, percent(snapshot, 50)})
    :sys.get_state(restarted)
    assert_received {:event, %{milestone: 50, generation: 2}}
  end

  test "partial and unknown regressions do not reopen a completed generation", context do
    {observer, store, snapshot} = start_observer(context, 100)
    assert_received {:event, %{milestone: 100}}

    for resolution <- [:partial, :unknown, :unresolved] do
      [root] = snapshot.data.entries
      root = %{root | progress: if(resolution == :unresolved, do: nil, else: 50), progress_resolution: resolution}
      send(observer, {:graph_projection_generation, %{snapshot | data: %{snapshot.data | entries: [root]}}})
      :sys.get_state(observer)
      assert [%{generation: 1, resolution: ^resolution}] = BuildProgress.facts(context.scope, store)
    end

    refute_received {:event, %{topic: _}}
  end

  # Future regression guard for absent catalog data; not new-behavior coverage.
  test "future guard: empty snapshots and invalid identities produce no facts", context do
    {observer, store, snapshot} = start_observer(context, nil, entries: [])
    send(observer, {:graph_projection_health, %{snapshot | data: nil}})
    send(observer, {:graph_projection_generation, %{snapshot | data: %Catalog{entries: [%RootSummary{}]}}})
    :sys.get_state(observer)
    assert BuildProgress.facts(:all, store) == []
    refute_received {:event, %{topic: _}}
  end

  test "unconfigured projection waits for reset then subscribes to its new catalog", context do
    snapshot = snapshot(context.id, 50, [])
    {:ok, store} = BuildProgress.start_link(name: nil, state_file: context.path)
    {:ok, projection} = GenServer.start_link(Projection, %{snapshot | repository: :unknown})
    {:ok, observer} = ProgressObserver.start_link(name: nil, projection: projection, progress: store)
    assert BuildProgress.facts(:all, store) == []
    :ok = GenServer.call(projection, {:replace, snapshot})
    send(observer, {:graph_projection_reset, 2})
    :sys.get_state(observer)
    assert [%{percent: 50}] = BuildProgress.facts(context.scope, store)
    snapshot = percent(snapshot, 75)
    Phoenix.PubSub.broadcast!(Aiur.PubSub, GraphProjection.catalog_topic(snapshot.repository), {:graph_projection_generation, snapshot})
    scope = context.scope
    receive_barrier({:build_progress_changed, %{scope: ^scope, percent: 75}})
    assert [%{percent: 75}] = BuildProgress.facts(context.scope, store)
    on_exit(fn -> Enum.each([observer, projection, store], &Aiur.TestSupport.safe_stop/1) end)
  end

  test "invalid observer facts are rejected without changing the store", context do
    {_observer, store, _snapshot} = start_observer(context, 100)
    assert {:error, :invalid_fact} = BuildProgress.put_build_order_fact(%{scope: context.scope}, store)
    assert [%{percent: 100}] = BuildProgress.facts(context.scope, store)
  end

  test "recording supervises observer after projection and BuildProgress" do
    children = fn recording? ->
      Aiur.Application.child_specs(interactive_cli?: false, headless?: true, dashboard?: false, recording?: recording?)
      |> Enum.map(fn
        {mod, _} -> mod
        %{id: id} -> id
        mod -> mod
      end)
    end

    modules = children.(true)
    observer = Enum.find_index(modules, &(&1 == ProgressObserver))
    assert Enum.find_index(modules, &(&1 == GraphProjection)) < observer
    assert Enum.find_index(modules, &(&1 == BuildProgress)) < observer
    refute ProgressObserver in children.(false)
  end

  defp start_observer(context, value, opts \\ []) do
    snapshot = snapshot(context.id, value, opts)
    {:ok, store} = BuildProgress.start_link(name: nil, state_file: context.path)
    {:ok, projection} = GenServer.start_link(Projection, snapshot)
    {:ok, observer} = ProgressObserver.start_link(name: nil, projection: projection, progress: store)
    on_exit(fn -> Enum.each([observer, projection, store], &Aiur.TestSupport.safe_stop/1) end)
    {observer, store, snapshot}
  end

  defp snapshot(id, value, opts) do
    health = ProviderHealth.new(1, :healthy, true, observed_at: ~U[2026-10-09 12:00:00Z])
    repository = {"observer", Integer.to_string(id)}
    {:ok, identity} = TrackerIdentity.from_github(%{"number" => id, "node_id" => "R#{id}"}, repository, repository)
    root = %RootSummary{identity: identity, progress: value, progress_resolution: :resolved, member_count: 3, progress_resolved_count: 3}
    %Snapshot{scope: :catalog, repository: {"observer", Integer.to_string(id)}, generation: 1, health: health, data: %Catalog{entries: Keyword.get(opts, :entries, [root]), provider: health}}
  end

  defp percent(snapshot, value) do
    [root] = snapshot.data.entries
    %{snapshot | data: %{snapshot.data | entries: [%{root | progress: value}]}}
  end
end
