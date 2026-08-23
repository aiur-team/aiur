defmodule Aiur.BuildOrder.GraphProjectionCatalogDemandTest do
  # The demand-gating half of #2312, reconciled with the event-sourced catalog
  # (#2325). The catalog is the most expensive single GraphQL query in the
  # system and its only consumers are web pages, so a headless run must buy none
  # of it. These tests pin that gating — with no Build Order page open the
  # catalog starts no read and arms nothing — and that a viewer's mount read is
  # a one-shot, not a cadence: the store change stream is the refresh, so the
  # completed read arms no successor timer even while the page stays open.
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.{Catalog, ProviderHealth, ProviderResult, RootSummary}
  alias Aiur.BuildOrder.GraphProjection
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.TrackerIdentity

  @repository {"demand-owner", "repo"}
  @now ~U[2026-07-15 12:00:00Z]

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    unless Process.whereis(Aiur.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    end

    :ok
  end

  test "with no viewer the catalog starts no read, arms no timer, and a one-shot read stays a one-shot" do
    {:ok, projection} = start_projection()

    # Boot reconciles, but with no demander the catalog is not active.
    refute_receive {:reader_started, :catalog, _reader}, 200
    state = :sys.get_state(projection)
    assert MapSet.size(state.catalog.demanders) == 0
    assert state.catalog.timer == nil

    # A one-shot `catalog/0` (the analytics page / CLI) serves the stored
    # snapshot without registering demand and without buying a read.
    assert %Snapshot{data: nil, generation: :unknown} = GraphProjection.catalog(projection)
    refute_receive {:reader_started, :catalog, _reader}, 200

    state = :sys.get_state(projection)
    assert MapSet.size(state.catalog.demanders) == 0
    assert state.catalog.timer == nil
  end

  test "registering a viewer buys one refresh on mount but arms no cadence" do
    parent = self()
    {:ok, projection} = start_projection()

    subscriber =
      spawn(fn ->
        GraphProjection.subscribe_catalog(projection)
        send(parent, {:subscribed, self()})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:subscribed, ^subscriber}, 2_000

    reader = await_reader(:catalog)
    finish(reader, {:ok, ProviderResult.complete(catalog([root(identity(1, "I1"))]))})

    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 2_000

    state = :sys.get_state(projection)
    assert MapSet.size(state.catalog.demanders) == 1
    # The catalog is event-sourced (#2325): the store change stream is the
    # refresh, so even with a page open the mount read arms no successor cadence.
    assert state.catalog.timer == nil

    monitor = Process.monitor(subscriber)
    send(subscriber, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^subscriber, :normal}, 2_000
  end

  # Acceptance criterion: closing the last session leaves nothing armed to spend
  # later. A test covers demander count reaching zero and no timer surviving.
  test "closing the last session takes demander count to zero and leaves nothing armed" do
    parent = self()
    {:ok, projection} = start_projection()

    subscriber =
      spawn(fn ->
        GraphProjection.subscribe_catalog(projection)
        send(parent, {:subscribed, self()})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:subscribed, ^subscriber}, 2_000

    reader = await_reader(:catalog)
    finish(reader, {:ok, ProviderResult.complete(catalog([root(identity(1, "I1"))]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 2_000

    monitor = Process.monitor(subscriber)
    send(subscriber, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^subscriber, :normal}, 2_000

    state = :sys.get_state(projection)
    assert MapSet.size(state.catalog.demanders) == 0
    assert state.catalog.timer == nil

    # Nothing is armed to spend later, and even an explicit nudge buys nothing
    # with nobody watching.
    refute_receive {:reader_started, :catalog, _reader}, 200
    GraphProjection.refresh_catalog(projection)
    refute_receive {:reader_started, :catalog, _reader}, 200
  end

  # If the last viewer leaves while a read is inflight, the completion must not
  # re-arm the cadence for nobody — that would be the deleted unconditional
  # timer back again.
  test "a read completing after the last viewer leaves arms no successor" do
    parent = self()
    {:ok, projection} = start_projection()

    subscriber =
      spawn(fn ->
        GraphProjection.subscribe_catalog(projection)
        send(parent, {:subscribed, self()})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:subscribed, ^subscriber}, 2_000
    reader = await_reader(:catalog)

    monitor = Process.monitor(subscriber)
    send(subscriber, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^subscriber, :normal}, 2_000
    assert MapSet.size(:sys.get_state(projection).catalog.demanders) == 0

    finish(reader, {:ok, ProviderResult.complete(catalog([root(identity(1, "I1"))]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 2_000

    assert :sys.get_state(projection).catalog.timer == nil
    refute_receive {:reader_started, :catalog, _reader}, 200
  end

  defp start_projection do
    parent = self()

    task_supervisor =
      start_supervised!(%{
        id: make_ref(),
        start: {Task.Supervisor, :start_link, [[]]}
      })

    GraphProjection.start_link(
      name: nil,
      task_supervisor: task_supervisor,
      authority_snapshot: fn -> authority() end,
      configuration_subscriber: fn _pid -> :ok end,
      catalog_reader: fn _reader_opts -> blocking_read(parent, :catalog) end,
      selected_reader: fn identity, _reader_opts -> blocking_read(parent, {:selected, identity}) end,
      now: fn -> @now end,
      clock_ms: fn -> 0 end,
      catalog_refresh_ms: 60_000,
      refresh_timeout_ms: 30_000,
      max_selected_roots: 4,
      max_inflight: 4,
      after_broadcast: fn event -> send(parent, {:projection_event, event}) end
    )
  end

  defp authority do
    %{
      repository: @repository,
      generation: 1,
      root_limit: 100,
      page_budget: 4,
      call_budget: 4,
      options: [
        catalog_refresh_ms: 60_000,
        refresh_timeout_ms: 30_000,
        max_selected_roots: 4,
        max_inflight: 4
      ]
    }
  end

  defp blocking_read(parent, scope) do
    send(parent, {:reader_started, scope, self()})
    receive do: ({:finish, result} -> result)
  end

  defp await_reader(scope) do
    assert_receive {:reader_started, ^scope, reader}, 2_000
    reader
  end

  defp finish(reader, result), do: send(reader, {:finish, result})

  defp catalog(roots), do: Catalog.new(roots, ProviderHealth.new(1, :healthy, true))

  defp root(identity) do
    {owner, repository} = @repository

    RootSummary.new(%{
      identity: identity,
      title: "Build Order #{identity.identifier}",
      url: "https://github.com/#{owner}/#{repository}/issues/#{identity.identifier}",
      state: "OPEN"
    })
  end

  defp identity(number, provider_id) do
    {:ok, identity} =
      TrackerIdentity.from_github(
        %{"node_id" => provider_id, "number" => number},
        @repository,
        @repository
      )

    identity
  end
end
