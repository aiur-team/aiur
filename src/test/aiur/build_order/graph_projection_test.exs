defmodule Aiur.BuildOrder.GraphProjectionTest do
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.{Catalog, ProviderHealth, ProviderResult, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection
  alias Aiur.BuildOrder.GraphProjection.{Failure, Policy, Snapshot}
  alias Aiur.TrackerIdentity

  @repository {"owner", "repo"}
  @now ~U[2026-07-15 12:00:00Z]

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    unless Process.whereis(Aiur.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    end

    :ok
  end

  test "cold start publishes exactly one complete catalog generation and restart invents no stale state" do
    first = identity(1, "I1")
    {:ok, projection} = start_projection()

    assert %Snapshot{generation: :unknown, data: nil, health: %{state: :unavailable}} =
             GraphProjection.catalog(projection)

    reader = await_reader(:catalog)
    finish(reader, {:ok, ProviderResult.complete(catalog([root(first)]))})

    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog} = published}}, 2_000
    assert published.generation == 1
    assert published.data == catalog([root(first)])
    assert published.health.state == :healthy
    refute_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 100

    assert %Snapshot{generation: 1, data: %Catalog{}, health: %{state: :healthy}} =
             GraphProjection.catalog(projection)

    GenServer.stop(projection)
    {:ok, restarted} = start_projection()

    assert %Snapshot{generation: :unknown, data: nil, health: %{state: :unavailable}} =
             GraphProjection.catalog(restarted)

    _reader = await_reader(:catalog)
  end

  test "failed refresh preserves last-known-good content and a later complete result recovers" do
    first = identity(1, "I1")
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, projection} = start_projection(clock: clock)

    reader = await_reader(:catalog)
    first_catalog = catalog([root(first)])
    finish(reader, {:ok, ProviderResult.complete(first_catalog)})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{generation: 1}}}, 2_000

    Agent.update(clock, fn _ -> 60_001 end)
    GraphProjection.refresh_catalog(projection)
    failed_reader = await_reader(:catalog)
    finish(failed_reader, {:error, ProviderResult.failed(:transport)})

    assert_receive {
                     :projection_event,
                     {:graph_projection_health,
                      %Snapshot{
                        generation: 1,
                        data: ^first_catalog,
                        health: %{state: :stale, failure: :transport}
                      }}
                   },
                   2_000

    recovered_catalog = catalog([root(first), root(identity(2, "I2"))])
    GraphProjection.refresh_catalog(projection)
    recovered_reader = await_reader(:catalog)
    finish(recovered_reader, {:ok, ProviderResult.complete(recovered_catalog)})

    assert_receive {
                     :projection_event,
                     {:graph_projection_generation,
                      %Snapshot{
                        generation: 2,
                        data: ^recovered_catalog,
                        health: %{state: :healthy, failure: nil}
                      }}
                   },
                   2_000
  end

  test "selected-root demand coalesces, protects live entries, and evicts released LRU entries" do
    first = identity(1, "I1")
    second = identity(2, "I2")
    {:ok, projection} = start_projection(max_selected_roots: 1)

    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([root(first), root(second)]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 2_000

    assert {:ok, %Snapshot{data: nil}} = GraphProjection.demand(projection, first)
    first_reader = await_reader({:selected, first})

    for _ <- 1..3 do
      assert {:ok, %Snapshot{data: nil}} = GraphProjection.demand(projection, first)
    end

    refute_receive {:reader_started, {:selected, ^first}, _reader}, 100
    assert {:error, %Failure{kind: :capacity}} = GraphProjection.demand(projection, second)

    first_selected = selected(first)
    finish(first_reader, {:ok, ProviderResult.complete(first_selected)})

    assert_receive {
                     :projection_event,
                     {:graph_projection_generation,
                      %Snapshot{
                        scope: {:selected, ^first},
                        data: ^first_selected,
                        generation: first_generation
                      }}
                   },
                   2_000

    assert :ok = GraphProjection.release(projection, first)
    assert {:ok, %Snapshot{data: nil}} = GraphProjection.demand(projection, second)
    second_reader = await_reader({:selected, second})

    assert {:ok, %Snapshot{data: nil, generation: :unknown}} = GraphProjection.selected(projection, first)

    second_selected = selected(second)
    finish(second_reader, {:ok, ProviderResult.complete(second_selected)})

    assert_receive {
                     :projection_event,
                     {:graph_projection_generation,
                      %Snapshot{
                        scope: {:selected, ^second},
                        data: ^second_selected,
                        generation: second_generation
                      }}
                   },
                   2_000

    assert second_generation > first_generation
  end

  test "authority reset fences delayed work and publishes only the new repository" do
    {:ok, authority} = Agent.start_link(fn -> authority(@repository, 1, 4) end)
    {:ok, projection} = start_projection(authority: authority)

    _old_reader = await_reader(:catalog)
    old_state = :sys.get_state(projection)
    [{old_ref, _inflight}] = Map.to_list(old_state.inflight_by_ref)

    new_repository = {"other", "repo"}
    Agent.update(authority, fn _ -> authority(new_repository, 2, 4) end)
    send(projection, {:workflow_config_updated, 2})
    new_reader = await_reader(:catalog)

    old_candidate = catalog([root(identity(1, "I1"))])
    send(projection, {old_ref, {:ok, ProviderResult.complete(old_candidate)}})

    assert %Snapshot{repository: ^new_repository, generation: :unknown, data: nil} =
             GraphProjection.catalog(projection)

    new_identity = identity(3, "I3", new_repository)
    new_catalog = catalog([root(new_identity, new_repository)])
    finish(new_reader, {:ok, ProviderResult.complete(new_catalog)})

    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{} = snapshot}}, 2_000
    assert snapshot.repository == new_repository
    assert snapshot.generation == 1
    assert snapshot.data == new_catalog
  end

  test "caller death releases only its selected-root lease and retains completed data" do
    first = identity(1, "I1")
    parent = self()
    {:ok, projection} = start_projection()

    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([root(first)]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 2_000

    demander =
      spawn(fn ->
        send(parent, {:demand_result, GraphProjection.demand(projection, first)})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:demand_result, {:ok, %Snapshot{data: nil}}}, 2_000
    selected_reader = await_reader({:selected, first})
    selected = selected(first)
    finish(selected_reader, {:ok, ProviderResult.complete(selected)})

    assert_receive {
                     :projection_event,
                     {:graph_projection_generation, %Snapshot{scope: {:selected, ^first}, data: ^selected}}
                   },
                   2_000

    monitor = Process.monitor(demander)
    send(demander, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^demander, :normal}, 2_000
    :sys.get_state(projection)

    key = Policy.root_key(first)
    entry = :sys.get_state(projection).selected[key]
    assert entry.data == selected
    assert entry.demanders == MapSet.new()
    assert entry.timer == nil
  end

  test "timeout clears owned work and reports a bounded cold failure" do
    {:ok, projection} = start_projection()
    _reader = await_reader(:catalog)

    state = :sys.get_state(projection)
    [{ref, %{attempt: attempt}}] = Map.to_list(state.inflight_by_ref)
    send(projection, {:graph_projection_timeout, ref, attempt})

    assert_receive {
                     :projection_event,
                     {:graph_projection_health,
                      %Snapshot{
                        data: nil,
                        generation: :unknown,
                        health: %{state: :unavailable, failure: :timeout}
                      }}
                   },
                   2_000

    assert %{inflight_by_ref: inflight} = :sys.get_state(projection)
    assert inflight == %{}
  end

  defp start_projection(opts \\ []) do
    parent = self()

    task_supervisor =
      start_supervised!(%{
        id: make_ref(),
        start: {Task.Supervisor, :start_link, [[]]}
      })

    authority = Keyword.get(opts, :authority)
    clock = Keyword.get(opts, :clock)
    max_selected_roots = Keyword.get(opts, :max_selected_roots, 4)

    authority_snapshot =
      if authority,
        do: fn -> Agent.get(authority, & &1) end,
        else: fn -> authority(@repository, 1, max_selected_roots) end

    clock_ms = if clock, do: fn -> Agent.get(clock, & &1) end, else: fn -> 0 end

    GraphProjection.start_link(
      name: nil,
      task_supervisor: task_supervisor,
      authority_snapshot: authority_snapshot,
      configuration_subscriber: fn _pid -> :ok end,
      catalog_reader: blocking_reader(parent, :catalog),
      selected_reader: fn identity, _reader_opts -> blocking_read(parent, {:selected, identity}) end,
      now: fn -> @now end,
      clock_ms: clock_ms,
      catalog_refresh_ms: 60_000,
      selected_refresh_ms: 15_000,
      demand_refresh_ms: 5_000,
      refresh_timeout_ms: 30_000,
      max_selected_roots: max_selected_roots,
      max_inflight: 4,
      after_broadcast: fn event -> send(parent, {:projection_event, event}) end
    )
  end

  defp blocking_reader(parent, scope), do: fn _reader_opts -> blocking_read(parent, scope) end

  defp blocking_read(parent, scope) do
    send(parent, {:reader_started, scope, self()})

    receive do
      {:finish, result} -> result
    end
  end

  defp await_reader(scope) do
    assert_receive {:reader_started, ^scope, reader}, 2_000
    reader
  end

  defp finish(reader, result), do: send(reader, {:finish, result})

  defp authority(repository, generation, max_selected_roots) do
    %{
      repository: repository,
      generation: generation,
      root_limit: 100,
      page_budget: 4,
      call_budget: 4,
      options: [
        catalog_refresh_ms: 60_000,
        selected_refresh_ms: 15_000,
        demand_refresh_ms: 5_000,
        refresh_timeout_ms: 30_000,
        max_selected_roots: max_selected_roots,
        max_inflight: 4
      ]
    }
  end

  defp catalog(roots), do: Catalog.new(roots, ProviderHealth.new(1, :healthy, true))

  defp selected(identity, repository \\ @repository) do
    SelectedRoot.new(root(identity, repository), [], ProviderHealth.new(1, :healthy, true))
  end

  defp root(identity, {owner, repository} \\ @repository) do
    RootSummary.new(%{
      identity: identity,
      title: "Build Order #{identity.identifier}",
      url: "https://github.com/#{owner}/#{repository}/issues/#{identity.identifier}",
      state: "OPEN"
    })
  end

  defp identity(number, provider_id, repository \\ @repository) do
    {:ok, identity} =
      TrackerIdentity.from_github(
        %{"node_id" => provider_id, "number" => number},
        repository,
        repository
      )

    identity
  end
end
