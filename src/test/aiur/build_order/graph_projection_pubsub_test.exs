defmodule Aiur.BuildOrder.GraphProjectionPubSubTest.BarrierServer do
  use GenServer

  def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

  @impl true
  def init(parent), do: {:ok, parent}

  @impl true
  def handle_call(request, from, parent) do
    send(parent, {:topic_lookup, self(), request, from})
    {:noreply, parent}
  end
end

defmodule Aiur.BuildOrder.GraphProjectionPubSubTest do
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.{Catalog, ProviderHealth, ProviderResult, RootSummary}
  alias Aiur.BuildOrder.GraphProjection
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.TrackerIdentity

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    unless Process.whereis(Aiur.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    end

    :ok
  end

  test "catalog and selected subscriptions cannot miss a reset during topic lookup" do
    repository = repository()
    identity = identity(1, "I1", repository)

    for {request, subscribe} <- [
          {:catalog_topic, &GraphProjection.subscribe_catalog/1},
          {{:selected_topic, identity}, &GraphProjection.subscribe_selected(&1, identity)}
        ] do
      server = barrier_server()
      subscriber = forwarding_subscriber(self(), fn -> subscribe.(server) end)

      assert_receive {:topic_lookup, ^server, ^request, from}, 2_000
      generation = System.unique_integer([:positive])

      Phoenix.PubSub.broadcast(
        Aiur.PubSub,
        GraphProjection.reset_topic(),
        {:graph_projection_reset, generation}
      )

      GenServer.reply(from, topic_reply(request, repository))

      assert_receive {:subscribed, ^subscriber, :ok}, 2_000
      assert_receive {:subscriber_event, ^subscriber, {:graph_projection_reset, ^generation}}, 2_000
      Process.exit(subscriber, :kill)
    end
  end

  test "a failed second subscription preserves the caller's existing reset subscription" do
    repository = repository()
    invalid_identity = identity(99, "INVALID", {"another-owner", "another-repo"})
    {:ok, projection} = start_projection(repository)
    parent = self()

    subscriber =
      spawn(fn ->
        catalog_result = GraphProjection.subscribe_catalog(projection)
        selected_result = GraphProjection.subscribe_selected(projection, invalid_identity)
        send(parent, {:subscription_results, self(), catalog_result, selected_result})
        forward_events(parent)
      end)

    assert_receive {
                     :subscription_results,
                     ^subscriber,
                     :ok,
                     {:error, %GraphProjection.Failure{kind: :invalid_root}}
                   },
                   2_000

    generation = System.unique_integer([:positive])

    Phoenix.PubSub.broadcast(
      Aiur.PubSub,
      GraphProjection.reset_topic(),
      {:graph_projection_reset, generation}
    )

    assert_receive {:subscriber_event, ^subscriber, {:graph_projection_reset, ^generation}}, 2_000
    Process.exit(subscriber, :kill)
  end

  test "subscriber churn neither starts selected work nor disrupts catalog publication" do
    repository = repository()
    identity = identity(1, "I1", repository)
    {:ok, projection} = start_projection(repository)

    # The catalog is demand-gated since #2312: the catalog subscriber is the
    # viewer, and subscribing is what starts the (single, coalesced) catalog
    # read — so subscribe before awaiting the reader it triggers.
    catalog_subscriber = forwarding_subscriber(self(), fn -> GraphProjection.subscribe_catalog(projection) end)

    assert_receive {:subscribed, ^catalog_subscriber, :ok}, 2_000
    catalog_reader = await_reader(:catalog)

    selected_subscriber =
      forwarding_subscriber(self(), fn -> GraphProjection.subscribe_selected(projection, identity) end)

    assert_receive {:subscribed, ^selected_subscriber, :ok}, 2_000
    refute_receive {:reader_started, {:selected, ^identity}, _reader}

    monitor = Process.monitor(selected_subscriber)
    Process.exit(selected_subscriber, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^selected_subscriber, :killed}, 2_000

    expected = catalog([root(identity, repository)])
    finish(catalog_reader, {:ok, ProviderResult.complete(expected)})

    assert_receive {
                     :subscriber_event,
                     ^catalog_subscriber,
                     {:graph_projection_generation, %Snapshot{data: ^expected, generation: 1}}
                   },
                   2_000

    refute_receive {
      :subscriber_event,
      ^catalog_subscriber,
      {:graph_projection_generation, %Snapshot{scope: :catalog}}
    }

    assert Process.alive?(projection)
    Process.exit(catalog_subscriber, :kill)
  end

  test "failed partial candidates publish health only and preserve the complete generation" do
    repository = repository()
    first = identity(1, "I1", repository)
    second = identity(2, "I2", repository)
    {:ok, projection} = start_projection(repository)
    assert :ok = GraphProjection.subscribe_catalog(projection)

    initial = catalog([root(first, repository)])
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(initial)})

    assert_receive {:graph_projection_generation, %Snapshot{data: ^initial, generation: 1}}, 2_000

    GraphProjection.refresh_catalog(projection)
    partial = catalog([root(first, repository), root(second, repository)])

    finish(
      await_reader(:catalog),
      {:error, ProviderResult.failed(:graphql_partial, candidate: partial)}
    )

    assert_receive {
                     :graph_projection_health,
                     %Snapshot{
                       data: ^initial,
                       generation: 1,
                       # A partial GraphQL answer keeps its own name rather than
                       # being laundered into a generic outage (#1777).
                       health: %{state: :stale, failure: :graphql_partial}
                     }
                   },
                   2_000

    refute_receive {:graph_projection_generation, %Snapshot{}}
    assert %Snapshot{data: ^initial, generation: 1} = GraphProjection.catalog(projection)
  end

  defp barrier_server do
    start_supervised!(%{
      id: make_ref(),
      start: {Aiur.BuildOrder.GraphProjectionPubSubTest.BarrierServer, :start_link, [self()]}
    })
  end

  defp start_projection(repository) do
    parent = self()

    task_supervisor =
      start_supervised!(%{id: make_ref(), start: {Task.Supervisor, :start_link, [[]]}})

    start_supervised(%{
      id: make_ref(),
      start:
        {GraphProjection, :start_link,
         [
           [
             name: nil,
             task_supervisor: task_supervisor,
             authority_snapshot: fn -> authority(repository) end,
             configuration_subscriber: fn _pid -> :ok end,
             catalog_reader: blocking_reader(parent, :catalog),
             selected_reader: fn identity, _opts -> blocking_read(parent, {:selected, identity}) end,
             now: fn -> ~U[2026-07-15 12:00:00Z] end,
             clock_ms: fn -> 0 end
           ]
         ]}
    })
  end

  defp forwarding_subscriber(parent, subscribe) do
    spawn(fn ->
      result = subscribe.()
      send(parent, {:subscribed, self(), result})
      forward_events(parent)
    end)
  end

  defp forward_events(parent) do
    receive do
      message ->
        send(parent, {:subscriber_event, self(), message})
        forward_events(parent)
    end
  end

  defp topic_reply(:catalog_topic, repository), do: {:ok, GraphProjection.catalog_topic(repository)}
  defp topic_reply({:selected_topic, identity}, _repository), do: {:ok, GraphProjection.selected_topic(identity)}

  defp blocking_reader(parent, scope), do: fn _opts -> blocking_read(parent, scope) end

  defp blocking_read(parent, scope) do
    send(parent, {:reader_started, scope, self()})
    receive do: ({:finish, result} -> result)
  end

  defp await_reader(scope) do
    assert_receive {:reader_started, ^scope, reader}, 2_000
    reader
  end

  defp finish(reader, result), do: send(reader, {:finish, result})

  defp authority(repository) do
    %{
      repository: repository,
      generation: 1,
      root_limit: 100,
      page_budget: 4,
      call_budget: 4,
      options: [catalog_refresh_ms: 60_000]
    }
  end

  defp repository do
    {"pubsub-owner", "repo-#{System.unique_integer([:positive])}"}
  end

  defp catalog(roots), do: Catalog.new(roots, ProviderHealth.new(1, :healthy, true))

  defp root(identity, {owner, repository}) do
    RootSummary.new(%{
      identity: identity,
      title: "Build Order #{identity.identifier}",
      url: "https://github.com/#{owner}/#{repository}/issues/#{identity.identifier}",
      state: "OPEN"
    })
  end

  defp identity(number, provider_id, repository) do
    {:ok, identity} =
      TrackerIdentity.from_github(
        %{"node_id" => provider_id, "number" => number},
        repository,
        repository
      )

    identity
  end
end
