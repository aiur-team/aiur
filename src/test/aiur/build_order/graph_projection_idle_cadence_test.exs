defmodule Aiur.BuildOrder.GraphProjectionIdleCadenceTest do
  # The catalog is event-sourced (#2325): it has no sweep cadence at all. These
  # tests pin the two halves of that contract — a completed read arms no
  # successor timer, and a root labelled after boot reaches the page through the
  # store change stream rather than a clock. Both were, before #2325, the
  # "idle cadence" sweep's job (#2118).
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.{Catalog, ProviderHealth, ProviderResult, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.GitHub.ResourceStore
  alias Aiur.TrackerIdentity

  @repository {"owner", "repo"}
  @now ~U[2026-07-15 12:00:00Z]
  @idle_refresh_ms 600_000

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    unless Process.whereis(Aiur.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    end

    if Process.whereis(ResourceStore) == nil do
      Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
    end

    :ok
  end

  setup do
    ResourceStore.reset()
    :ok
  end

  test "a completed catalog read arms no successor sweep" do
    {:ok, projection} = start_projection()

    reader = await_reader(:catalog)
    finish(reader, {:ok, ProviderResult.complete(catalog([root(identity(1, "I1"))]))})

    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 2_000

    # The event stream is the refresh, so the completed read arms nothing. A
    # projection still running a cadence would have armed a timer here.
    entry = catalog_entry(projection)
    assert is_nil(entry.timer)
    refute_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 150
  end

  test "a root labelled after boot reaches the page through the store event stream" do
    first = identity(1, "I1")
    newly_labelled = identity(2, "I2")

    {:ok, projection} = start_projection()

    reader = await_reader(:catalog)
    finish(reader, {:ok, ProviderResult.complete(catalog([root(first)]))})

    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog} = published}}, 2_000

    assert Enum.map(published.data.entries, & &1.identity) == [first]

    # Somebody adds the build-order label to a second root. The deposit wakes the
    # projection through the store change stream — no sweep, no timer, no GitHub
    # read.
    deposit_issue(2, "I2", ["build-order"], "open", "I2")

    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog} = refreshed}}, 2_000

    assert Enum.map(refreshed.data.entries, & &1.identity) == [first, newly_labelled]

    # And the page reads the same thing a subscriber was told.
    assert %Snapshot{data: %Catalog{entries: roots}} = GraphProjection.catalog(projection)
    assert Enum.map(roots, & &1.identity) == [first, newly_labelled]
  end

  # Acceptance #2325: adding a sub-issue outside Aiur is reflected on the page.
  # The `sub_issues` delivery is deposited, and the projection reconciles the
  # parent root's membership from the store — the delivery test, with no fetch.
  test "a sub-issue added outside Aiur raises the root's member count through the store stream" do
    first = identity(1, "I1")
    {:ok, _projection} = start_projection()

    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([root(first)]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 2_000

    # The root's own issue is deposited, so the projection can derive its
    # membership from the store; the member edge arrives separately.
    deposit_issue(1, "I1", ["build-order"], "open", "I1")
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 2_000

    deposit_sub_issue("IS_member", 1)

    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog} = refreshed}}, 2_000
    assert Enum.at(refreshed.data.entries, 0).member_count == 1
  end

  # Acceptance #2325: a blocked-by relationship added outside Aiur is likewise
  # reflected. The edge lives on the selected-root graph, so the deposit re-reads
  # the held root rather than changing the catalog itself.
  test "a dependency added outside Aiur re-reads the held selected root it touches" do
    first = identity(1, "I1")
    {:ok, projection} = start_projection()

    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([root(first)]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 2_000

    # Hold the page open on the root and let the cold read land.
    assert {:ok, %Snapshot{}} = GraphProjection.demand(projection, first)
    GraphProjection.refresh_catalog(projection)
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([root(first)]))})
    finish(await_reader({:selected, first}), {:ok, ProviderResult.complete(selected(first))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: {:selected, ^first}}}}, 2_000

    refute_receive {:reader_started, {:selected, ^first}, _reader}, 100

    # A blocked-by edge is created outside Aiur; the deposit wakes the projection
    # and the held root is re-read because its edge moved.
    deposit_dependency("DI_1", 1)
    finish(await_reader({:selected, first}), {:ok, ProviderResult.complete(selected(first))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: {:selected, ^first}}}}, 2_000
  end

  defp catalog_entry(projection) do
    projection |> :sys.get_state() |> Map.fetch!(:catalog)
  end

  defp deposit_issue(number, title, labels, state, node_id) do
    body = %{
      "number" => number,
      "node_id" => node_id,
      "title" => title,
      "state" => state,
      "html_url" => "https://github.com/owner/repo/issues/#{number}",
      "labels" => Enum.map(labels, &%{"name" => &1}),
      "created_at" => "2026-07-15T10:00:00Z",
      "updated_at" => "2026-07-15T10:00:00Z",
      "repository_url" => "https://api.github.com/repos/owner/repo"
    }

    ResourceStore.put_resource(ResourceStore.key(:issue, "owner", "repo", number), body,
      source: :webhook,
      version: "2026-07-15T10:00:00Z"
    )
  end

  defp deposit_sub_issue(node_id, parent_number) do
    edge = %{
      "node_id" => node_id,
      "number" => 100,
      "state" => "open",
      "parent" => %{"node_id" => "IS_#{parent_number}", "number" => parent_number}
    }

    ResourceStore.put_resource(ResourceStore.key(:sub_issues, "owner", "repo", node_id), edge,
      source: :webhook,
      version: "2026-07-15T10:00:00Z"
    )
  end

  defp deposit_dependency(relationship_id, dependant_number) do
    dependency = %{
      "dependency_id" => relationship_id,
      "dependency" => %{"number" => 99, "node_id" => "IS_99", "title" => "a blocker", "state" => "open"},
      "dependant" => %{"number" => dependant_number, "node_id" => "IS_#{dependant_number}", "state" => "open"}
    }

    ResourceStore.put_resource(ResourceStore.key(:issue_dependencies, "owner", "repo", relationship_id), dependency,
      source: :webhook,
      version: "2026-07-15T10:00:00Z"
    )
  end

  defp start_projection do
    parent = self()
    task_supervisor = start_supervised!({Task.Supervisor, name: nil})

    {:ok, projection} =
      GraphProjection.start_link(
        name: nil,
        task_supervisor: task_supervisor,
        authority_snapshot: fn -> authority() end,
        configuration_subscriber: fn _pid -> :ok end,
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

    # The catalog is demand-gated since #2312: these tests exercise its cadence,
    # so register the test process as the viewer a page would be.
    GraphProjection.subscribe_catalog(projection)

    {:ok, projection}
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

  defp identity(number, provider_id) do
    {:ok, identity} =
      TrackerIdentity.from_github(%{"node_id" => provider_id, "number" => number}, @repository, @repository)

    identity
  end
end
