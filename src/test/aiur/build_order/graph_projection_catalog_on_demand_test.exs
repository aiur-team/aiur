defmodule Aiur.BuildOrder.GraphProjectionCatalogOnDemandTest do
  # The `planning: 0` on-demand catalog guarantees from #2309/#2399, pinned
  # under the event-sourced model (#2313).
  #
  # `graph_projection_catalog_demand_test.exs` (deleted) pinned the demand-
  # gating half of #2312 and, in its last three tests, these on-demand *cadence*
  # guarantees. The demand-registration assertions are gone by design — #2313
  # makes the catalog always active (`active_scope?(:catalog) == true`) and
  # rebuilds it from the store, so there is no demand-gated read left to pin.
  # But the on-demand guarantees are independent of demand-gating and must
  # survive the deletion, so they are re-pinned here against the new model:
  #
  #   * an on-demand catalog arms no successor timer after a read completes
  #     (`schedule_after_completion/3`), nor is it re-armed by a message
  #     (`no_schedule?/3`'s `catalog_on_demand?` guard);
  #   * a failed on-demand read keeps its retry state but arms no timer
  #     (`successor_allowed?/2`);
  #   * an on-demand catalog never turns a selected root's staleness bound into
  #     zero — the bound is delivery latency (#2313), not the `0` cadence.
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.{Catalog, ProviderHealth, ProviderResult, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.TrackerIdentity

  @repository {"demand-owner", "repo"}
  @now ~U[2026-07-15 12:00:00Z]
  @delivery_staleness_ms 300_000

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    unless Process.whereis(Aiur.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    end

    :ok
  end

  # #2309/#2399, new model: an on-demand catalog (`planning: 0`) buys the boot
  # read but arms no successor timer on completion (`schedule_after_completion/3`
  # for the catalog returns state unchanged), and an unrelated message must not
  # re-arm it (`no_schedule?/3`'s `catalog_on_demand?` guard).
  test "an on-demand catalog arms no successor timer after a completed read and is not re-armed by a message" do
    authority = supervised_agent(authority(catalog_refresh_ms: 0))

    {:ok, projection} =
      start_projection(
        catalog_refresh_ms: 0,
        authority_snapshot: fn -> Agent.get(authority, & &1) end
      )

    reader = await_reader(:catalog)
    finish(reader, {:ok, ProviderResult.complete(catalog([root(identity(1, "I1"))]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 2_000

    assert catalog_entry(projection).timer == nil

    # A validated configuration-generation change with the same authority
    # fingerprint takes the in-place reconcile path, which runs
    # `reschedule_active_scopes/1`. Trace the guard's result because catalog
    # success scheduling is independently suppressed under the event-sourced
    # model; the timer assertion alone cannot distinguish removal of this
    # on-demand branch.
    :erlang.trace_pattern({GraphProjection, :no_schedule?, 3}, [{:_, [], [{:return_trace}]}], [:local])
    :erlang.trace(projection, true, [:call])

    on_exit(fn ->
      :erlang.trace_pattern({GraphProjection, :no_schedule?, 3}, false, [:local])
    end)

    Agent.update(authority, &%{&1 | generation: 2})
    assert %Snapshot{data: %Catalog{}} = GraphProjection.catalog(projection)

    assert_receive {:trace, ^projection, :return_from, {GraphProjection, :no_schedule?, 3}, true}

    :erlang.trace(projection, false, [:call])
    :erlang.trace_pattern({GraphProjection, :no_schedule?, 3}, false, [:local])

    assert :sys.get_state(projection).active_configuration_generation == 2
    assert catalog_entry(projection).timer == nil
  end

  # #2309/#2399 mutant 2/3, new model: `successor_allowed?/2` is what stops an
  # on-demand catalog from re-arming a timer after a FAILED read. The failed read
  # keeps its retry state (the next demand or reconcile may re-read), but it must
  # not schedule — a timer is exactly the cadence `planning: 0` removes.
  test "a failed on-demand catalog read keeps its retry state but arms no successor timer" do
    {:ok, projection} = start_projection(catalog_refresh_ms: 0)

    reader = await_reader(:catalog)
    finish(reader, {:error, :transport})

    # Synchronous barrier: the catalog call queues behind the reader-result
    # message, so once it answers the failure handler has run.
    GraphProjection.catalog(projection)

    state = :sys.get_state(projection)
    # The failed read kept a retry deadline...
    assert state.catalog.health.next_retry_at != nil
    assert state.catalog.health.retry_count == 1
    # ...but, on-demand, armed no successor timer.
    assert state.catalog.timer == nil
  end

  # #2309/#2399 mutant 6, re-based by #2313: a selected root's staleness bound
  # is delivery latency, never the raw catalog cadence. An on-demand catalog is
  # `0`, so deriving the bound from it would give a just-read root a zero-width
  # window and brand it "stale" the instant it rendered — on-demand means *no
  # timer*, not zero-width staleness. This drives the production snapshot path
  # (`selected/2` → `Policy.snapshot` with `selected_staleness_ms/1`) and fails
  # if the bound regresses to the catalog cadence.
  test "an on-demand catalog keeps a selected root's staleness bound at delivery latency, not zero" do
    first = identity(1, "I1")
    clock = supervised_agent(0)

    {:ok, projection} =
      start_projection(
        catalog_refresh_ms: 0,
        delivery_staleness_ms: @delivery_staleness_ms,
        clock_ms: fn -> Agent.get(clock, & &1) end
      )

    # Demand creates the entry; refresh dispatches the one read.
    assert {:ok, %Snapshot{data: nil}} = GraphProjection.demand(projection, first)
    GraphProjection.refresh(projection, first)
    reader = await_reader({:selected, first})
    finish(reader, {:ok, ProviderResult.complete(selected(first))})

    # Wait for the completion to be processed (the `after_broadcast` event
    # confirms it) before taking a snapshot.
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: {:selected, ^first}}}}, 2_000

    # Pin both sides of the exact delivery-latency boundary. The on-demand
    # catalog fallback is shorter, so substituting `catalog_bound_ms(state)`
    # would make the first assertion stale too early.
    Agent.update(clock, fn _ -> @delivery_staleness_ms - 1 end)
    assert {:ok, %Snapshot{data: %SelectedRoot{}, health: health}} = GraphProjection.selected(projection, first)
    assert health.state == :healthy

    Agent.update(clock, fn _ -> @delivery_staleness_ms end)
    assert {:ok, %Snapshot{data: %SelectedRoot{}, health: health}} = GraphProjection.selected(projection, first)
    assert health.state == :stale
  end

  defp start_projection(opts) do
    parent = self()

    task_supervisor =
      start_supervised!(%{
        id: make_ref(),
        start: {Task.Supervisor, :start_link, [[]]}
      })

    GraphProjection.start_link(
      name: nil,
      task_supervisor: task_supervisor,
      authority_snapshot: Keyword.get(opts, :authority_snapshot, fn -> authority(opts) end),
      configuration_subscriber: fn _pid -> :ok end,
      reconciliation_fun: fn _opts -> :ok end,
      catalog_reader: fn _reader_opts -> blocking_read(parent, :catalog) end,
      selected_reader: fn identity, _reader_opts -> blocking_read(parent, {:selected, identity}) end,
      now: fn -> @now end,
      clock_ms: Keyword.get(opts, :clock_ms, fn -> 0 end),
      catalog_refresh_ms: Keyword.get(opts, :catalog_refresh_ms, 60_000),
      delivery_staleness_ms: Keyword.get(opts, :delivery_staleness_ms, @delivery_staleness_ms),
      refresh_timeout_ms: 30_000,
      max_selected_roots: 4,
      max_inflight: 4,
      after_broadcast: fn event -> send(parent, {:projection_event, event}) end
    )
  end

  defp authority(opts) do
    %{
      repository: @repository,
      generation: Keyword.get(opts, :generation, 1),
      root_limit: 100,
      page_budget: 4,
      call_budget: 4,
      options: [
        catalog_refresh_ms: Keyword.get(opts, :catalog_refresh_ms, 60_000),
        delivery_staleness_ms: Keyword.get(opts, :delivery_staleness_ms, @delivery_staleness_ms),
        refresh_timeout_ms: 30_000,
        max_selected_roots: 4,
        max_inflight: 4
      ]
    }
  end

  defp catalog_entry(projection) do
    projection |> :sys.get_state() |> Map.fetch!(:catalog)
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

  defp supervised_agent(initial) do
    start_supervised!(%{id: make_ref(), start: {Agent, :start_link, [fn -> initial end]}})
  end

  defp catalog(roots), do: Catalog.new(roots, ProviderHealth.new(1, :healthy, true))

  defp selected(identity) do
    SelectedRoot.new(root(identity), [], ProviderHealth.new(1, :healthy, true))
  end

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
