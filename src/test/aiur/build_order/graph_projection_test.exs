defmodule Aiur.BuildOrder.GraphProjectionTest do
  use ExUnit.Case, async: false

  import Aiur.BuildOrder.GraphProjectionTestSupport

  alias Aiur.BuildOrder.Catalog
  alias Aiur.BuildOrder.GraphProjection
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.BuildOrder.ProviderResult

  @repository {"owner", "repo"}

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

    assert %Snapshot{
             authority_epoch: first_authority_epoch,
             generation: :unknown,
             data: nil,
             health: %{state: :unavailable}
           } = GraphProjection.catalog(projection)

    assert is_integer(first_authority_epoch) and first_authority_epoch > 0
    assert_receive {:projection_event, {:graph_projection_reset, ^first_authority_epoch}}, 2_000

    reader = await_reader(:catalog)
    finish(reader, {:ok, ProviderResult.complete(catalog([root(first)]))})

    assert_receive {
                     :projection_event,
                     {:graph_projection_generation, %Snapshot{scope: :catalog, authority_epoch: ^first_authority_epoch} = published}
                   },
                   2_000

    assert published.generation == 1
    assert published.data == catalog([root(first)])
    assert published.health.state == :healthy
    refute_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 100

    assert %Snapshot{generation: 1, data: %Catalog{}, health: %{state: :healthy}} =
             GraphProjection.catalog(projection)

    GenServer.stop(projection)
    {:ok, restarted} = start_projection()

    assert %Snapshot{
             authority_epoch: restarted_authority_epoch,
             generation: :unknown,
             data: nil,
             health: %{state: :unavailable}
           } = GraphProjection.catalog(restarted)

    assert restarted_authority_epoch > first_authority_epoch

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

  # The event-sourced catalog re-converges from GitHub on daemon boot — the
  # rare reconciliation that repairs whatever the dropped-delivery path could
  # not, rather than the old every-60s poll (#2313).
  test "boot starts the rare GraphQL reconciliation and serves a snapshot immediately" do
    parent = self()
    first = identity(1, "I1")

    {:ok, _projection} =
      start_projection(
        reconciliation_fun: fn reader_opts ->
          send(parent, {:reconciled, reader_opts})
        end
      )

    # The reconciliation is spawned on boot with the catalog's reader options.
    assert_receive {:reconciled, reconciled_opts}, 2_000
    assert Keyword.get(reconciled_opts, :repository) == @repository

    # Boot also requests the catalog from the store projection so the page has
    # a snapshot before the reconciliation's store writes land.
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([root(first)]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{generation: 1}}}, 2_000

    # The reconciliation task completes and clears its inflight marker; no
    # second reconciliation is owed until delivery mode degrades again.
    refute_receive {:reconciled, _}, 100
  end

  # The dropped-delivery path: a degraded repo's event stream cannot be trusted
  # to converge on its own, so the projection re-fetches the graph from GitHub.
  # Triggered by the delivery-mode transition, not by a clock (#2313).
  test "a degraded delivery mode reconciles the active repo from GitHub" do
    parent = self()
    first = identity(1, "I1")

    {:ok, projection} =
      start_projection(
        reconciliation_fun: fn reader_opts ->
          send(parent, {:reconciled, reader_opts})
        end
      )

    # Drain boot's reconciliation and the first catalog read.
    assert_receive {:reconciled, _}, 2_000
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([root(first)]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{generation: 1}}}, 2_000

    # The active repo degrades: deliveries are being dropped, so reconcile.
    send(projection, {:webhook_mode_changed, %{repo: "owner/repo", state: :degraded}})
    assert_receive {:reconciled, _}, 2_000

    # Another repo's degradation is not this projection's business.
    send(projection, {:webhook_mode_changed, %{repo: "someone/else", state: :degraded}})
    refute_receive {:reconciled, _}, 200
  end

  # The catalog is event-sourced from `Aiur.BuildOrder.CatalogStore`, which is
  # fed by `sub_issues` / `issue_dependencies` deliveries. A repo with no
  # webhooks configured feeds it nothing at all after boot, so a store-only
  # rebuild republishes the boot-time world for ever: a root whose sub-issues
  # exist on GitHub reported `member_count: 0` until the daemon restarted
  # (#2538). So the explicit refresh buys the re-converge from GitHub too.
  test "an explicit catalog refresh re-converges from GitHub, not only from the store" do
    parent = self()
    first = identity(1, "I1")

    {:ok, projection} = start_projection(reconciliation_fun: blocking_reconciliation(parent))

    # Boot's re-converge is inflight and stays that way until released.
    assert_receive {:reconciled, _boot_opts, boot_task}, 2_000
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([root(first)]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{generation: 1}}}, 2_000

    # A refresh while one is running coalesces onto it — the budget rule the
    # boot and degraded paths already keep — while still rebuilding from the
    # store.
    :ok = GraphProjection.refresh_catalog(projection)
    refute_receive {:reconciled, _coalesced_opts, _coalesced_task}, 200
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([root(first)]))})

    finish(boot_task, :ok)
    await_reconciliation_idle(projection)

    # With nothing inflight, the operator's refresh buys the GraphQL read that
    # a store-only rebuild can never make.
    :ok = GraphProjection.refresh_catalog(projection)
    assert_receive {:reconciled, refresh_opts, refresh_task}, 2_000
    assert Keyword.get(refresh_opts, :repository) == @repository

    finish(refresh_task, :ok)
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([root(first)]))})
  end
end
