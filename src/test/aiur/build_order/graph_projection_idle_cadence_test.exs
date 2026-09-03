defmodule Aiur.BuildOrder.GraphProjectionIdleCadenceTest do
  # The other half of #2118's acceptance. Widening the catalog cadence is only a
  # saving if the catalog still does its job at the wider cadence: a catalog
  # that never refreshes costs nothing and shows nothing.
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.{Catalog, ProviderHealth, ProviderResult, RootSummary}
  alias Aiur.BuildOrder.GraphProjection
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.TrackerIdentity

  @repository {"owner", "repo"}
  @now ~U[2026-07-15 12:00:00Z]

  # The shipped idle cadence: polling.interval_seconds 120 * idle_widen_factor 5.
  @idle_refresh_ms 600_000

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    unless Process.whereis(Aiur.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    end

    :ok
  end

  test "the catalog no longer arms a periodic sweep after a completion" do
    {:ok, projection} = start_projection()

    reader = await_reader(:catalog)
    finish(reader, {:ok, ProviderResult.complete(catalog([root(identity(1, "I1"))]))})

    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 2_000

    # The catalog is event-sourced from the store (#2313): a completion rebuilds
    # it once and arms nothing, so an open page never re-reads on a clock.
    entry = catalog_entry(projection)
    assert entry.timer == nil
  end

  test "a root labelled while the fleet was idle reaches the page on a store change, not a sweep" do
    first = identity(1, "I1")
    newly_labelled = identity(2, "I2")

    {:ok, projection} = start_projection()

    reader = await_reader(:catalog)
    finish(reader, {:ok, ProviderResult.complete(catalog([root(first)]))})

    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog} = published}}, 2_000

    assert Enum.map(published.data.entries, & &1.identity) == [first]

    # Somebody adds the build-order label to a second root. In the old design a
    # periodic sweep noticed on its own clock; now the store's change event is
    # the trigger, and there is no sweep to wait for.
    send(
      projection,
      {:github_resource_changed,
       %{
         key: nil,
         resource_type: :issue_labels,
         owner: "owner",
         repo: "repo",
         id: "2",
         source: :webhook,
         version: nil,
         etag: nil,
         data?: true,
         data_version: nil,
         recorded_at_ms: 1,
         cleared: false
       }}
    )

    next_reader = await_reader(:catalog)
    finish(next_reader, {:ok, ProviderResult.complete(catalog([root(first), root(newly_labelled)]))})

    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog} = refreshed}}, 2_000

    assert Enum.map(refreshed.data.entries, & &1.identity) == [first, newly_labelled]

    # And the page reads the same thing a subscriber was told.
    assert %Snapshot{data: %Catalog{entries: roots}} = GraphProjection.catalog(projection)
    assert Enum.map(roots, & &1.identity) == [first, newly_labelled]
  end

  defp catalog_entry(projection) do
    projection |> :sys.get_state() |> Map.fetch!(:catalog)
  end

  defp start_projection do
    parent = self()
    task_supervisor = start_supervised!({Task.Supervisor, name: nil})

    GraphProjection.start_link(
      name: nil,
      task_supervisor: task_supervisor,
      authority_snapshot: fn -> authority() end,
      configuration_subscriber: fn _pid -> :ok end,
      reconciliation_fun: fn _opts -> :ok end,
      catalog_reader: fn _reader_opts -> blocking_read(parent, :catalog) end,
      selected_reader: fn identity, _reader_opts -> blocking_read(parent, {:selected, identity}) end,
      now: fn -> @now end,
      clock_ms: fn -> 0 end,
      catalog_refresh_ms: @idle_refresh_ms,
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
        catalog_refresh_ms: @idle_refresh_ms,
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

  defp root(identity, {owner, repository} \\ @repository) do
    RootSummary.new(%{
      identity: identity,
      title: "Build Order #{identity.identifier}",
      url: "https://github.com/#{owner}/#{repository}/issues/#{identity.identifier}",
      state: "OPEN"
    })
  end

  defp identity(number, provider_id) do
    {:ok, identity} =
      TrackerIdentity.from_github(%{"node_id" => provider_id, "number" => number}, @repository, @repository)

    identity
  end
end
