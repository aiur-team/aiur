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

  # The catalog's per-member `labels` connection resolves each root's epic and
  # wave counts but costs ~26 GraphQL points per page against a 5,000/hour
  # budget, versus ~1 without it (#1766). So it is bought on its own slow
  # cadence: promptly on the first read so the page resolves, then only once per
  # `catalog_labels_refresh_ms` — never on every catalog poll.
  test "buys the catalog's per-member labels on the first read but not on the next poll" do
    parent = self()
    first = identity(1, "I1")
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    reader = fn reader_opts ->
      send(parent, {:catalog_read, Keyword.get(reader_opts, :member_labels)})
      blocking_read(parent, :catalog)
    end

    {:ok, projection} = start_projection(clock: clock, catalog_reader: reader)

    assert_receive {:catalog_read, true}, 2_000
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([root(first)]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog, generation: 1}}}, 2_000

    Agent.update(clock, fn _ -> 60_001 end)
    GraphProjection.refresh_catalog(projection)
    assert_receive {:catalog_read, false}, 2_000
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([root(first)]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog, generation: 2}}}, 2_000

    # One millisecond short of the cadence is still the cheap variant.
    Agent.update(clock, fn _ -> 599_999 end)
    GraphProjection.refresh_catalog(projection)
    assert_receive {:catalog_read, false}, 2_000
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([root(first)]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog, generation: 3}}}, 2_000

    # Exactly on the cadence, the counts are re-read rather than trusted forever,
    # so a root whose membership changed stops carrying a stale number.
    Agent.update(clock, fn _ -> 600_000 end)
    GraphProjection.refresh_catalog(projection)
    assert_receive {:catalog_read, true}, 2_000
  end

  # A new authority discards the catalog and every count it carried, so the first
  # read under it must buy the labels again — otherwise the page would sit on
  # "Unresolved" for a whole cadence after each configuration change.
  test "buys the catalog's per-member labels again after an authority change" do
    parent = self()
    first = identity(1, "I1")
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, authority} = Agent.start_link(fn -> authority(@repository, 1, 4) end)

    reader = fn reader_opts ->
      send(parent, {:catalog_read, Keyword.get(reader_opts, :member_labels)})
      blocking_read(parent, :catalog)
    end

    {:ok, projection} = start_projection(clock: clock, authority: authority, catalog_reader: reader)

    assert_receive {:catalog_read, true}, 2_000
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([root(first)]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{generation: 1}}}, 2_000

    Agent.update(clock, fn _ -> 60_001 end)
    GraphProjection.refresh_catalog(projection)
    assert_receive {:catalog_read, false}, 2_000
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([root(first)]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{generation: 2}}}, 2_000

    # Point the projection at a different repository.
    Agent.update(authority, fn _ -> authority({"owner", "other-repo"}, 2, 4) end)
    send(projection, {:workflow_config_updated, 2})

    assert_receive {:catalog_read, true}, 2_000
  end

  # The counts the labelled read bought must survive the cheap polls in between,
  # or the page would flap back to "Unresolved" every catalog refresh.
  test "publishes carried-forward catalog counts after a poll that could not resolve them" do
    parent = self()
    first = identity(1, "I1")
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    reader = fn _reader_opts -> blocking_read(parent, :catalog) end
    {:ok, projection} = start_projection(clock: clock, catalog_reader: reader)

    labelled = counted_root(first, epic_count: 2, phase_count: 4)
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([labelled]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{generation: 1}}}, 2_000

    Agent.update(clock, fn _ -> 60_001 end)
    GraphProjection.refresh_catalog(projection)
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([counted_root(first)]))})

    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{generation: 2} = published}}, 2_000
    assert [%RootSummary{epic_count: 2, phase_count: 4}] = published.data.entries
    assert %Snapshot{data: %Catalog{entries: [%RootSummary{epic_count: 2}]}} = GraphProjection.catalog(projection)
  end

  # A labelled read that fails deterministically — a timeout on the much larger
  # response, a node-limit rejection, point exhaustion — must not make every
  # catalog poll buy the 26-point query. That is the budget burn #1766 is about,
  # and it would also leave the catalog publishing nothing at all. So the retry
  # after a failed labelled read is the cheap variant, and the labelled read
  # comes back once its backoff elapses rather than being abandoned.
  test "backs off a failed labelled catalog read instead of retrying it on every poll" do
    parent = self()
    first = identity(1, "I1")
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    reader = fn reader_opts ->
      send(parent, {:catalog_read, Keyword.get(reader_opts, :member_labels)})
      blocking_read(parent, :catalog)
    end

    {:ok, projection} = start_projection(clock: clock, catalog_reader: reader)

    assert_receive {:catalog_read, true}, 2_000
    finish(await_reader(:catalog), {:error, ProviderResult.failed(:transport)})
    assert_receive {:projection_event, {:graph_projection_health, %Snapshot{scope: :catalog}}}, 2_000

    # The catalog keeps publishing on the cheap query while the labelled one is
    # in backoff, rather than failing over and over on the expensive one.
    assert_receive {:catalog_read, false}, 3_000
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([root(first)]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{generation: 1}}}, 2_000

    Agent.update(clock, fn _ -> 60_001 end)
    GraphProjection.refresh_catalog(projection)
    assert_receive {:catalog_read, true}, 2_000
  end

  # A labelled read is authoritative. If it read the member labels and still
  # could not resolve the counts, the honest answer is "Unresolved", not the
  # number from before — otherwise one stale count would survive every expensive
  # refresh that existed to correct it.
  test "does not carry counts forward across a labelled catalog read" do
    parent = self()
    first = identity(1, "I1")
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    reader = fn _reader_opts -> blocking_read(parent, :catalog) end
    {:ok, projection} = start_projection(clock: clock, catalog_reader: reader)

    resolved = counted_root(first, epic_count: 2, phase_count: 4)
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([resolved]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{generation: 1}}}, 2_000

    # The next labelled read is due, and it comes back unable to resolve.
    Agent.update(clock, fn _ -> 600_001 end)
    GraphProjection.refresh_catalog(projection)
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([counted_root(first)]))})

    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{generation: 2} = published}}, 2_000
    assert [%RootSummary{epic_count: nil, phase_count: nil}] = published.data.entries
  end

  # Carrying bridges the gap between labelled reads; it is not a substitute for
  # them. Once the labelled cadence has been failing for longer than the grace
  # window, the columns fall back to "Unresolved" rather than publishing a number
  # of unbounded age.
  test "stops carrying catalog counts once the labelled read has been failing too long" do
    parent = self()
    first = identity(1, "I1")
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    # Labelled reads fail from here on; the cheap ones keep succeeding, so the
    # only thing ageing is the last count we actually resolved.
    reader = fn reader_opts ->
      if Keyword.get(reader_opts, :member_labels) do
        send(parent, :labelled_attempt)
        {:error, ProviderResult.failed(:transport)}
      else
        {:ok, ProviderResult.complete(catalog([counted_root(first)]))}
      end
    end

    {:ok, projection} =
      start_projection(
        clock: clock,
        catalog_reader: fn _reader_opts -> blocking_read(parent, :catalog) end
      )

    resolved = counted_root(first, epic_count: 2, phase_count: 4)
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([resolved]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{generation: 1}}}, 2_000

    # Swap in the failing-labelled reader for the rest of the run.
    :sys.replace_state(projection, fn state -> %{state | catalog_reader: reader} end)

    # Inside the grace window, a cheap poll still carries the resolved counts.
    Agent.update(clock, fn _ -> 60_001 end)
    GraphProjection.refresh_catalog(projection)
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{generation: 2} = carried}}, 2_000
    assert [%RootSummary{epic_count: 2, phase_count: 4}] = carried.data.entries

    # The labelled read is due and fails; the cheap retry still carries.
    Agent.update(clock, fn _ -> 600_002 end)
    GraphProjection.refresh_catalog(projection)
    assert_receive :labelled_attempt, 2_000

    # Past the grace window with no successful labelled read, the counts are no
    # longer a number we can stand behind.
    Agent.update(clock, fn _ -> 1_200_003 end)
    GraphProjection.refresh_catalog(projection)

    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{data: %Catalog{entries: [expired]}}}}
                   when expired.epic_count == nil,
                   3_000

    assert is_nil(expired.phase_count)
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

  # Acceptance criterion 1: opening the Build Order page costs zero, cold cache
  # included. "Cold" is the case that used to be guaranteed to spend — a selected
  # entry with no `last_success_ms` was due by definition, so the first person to
  # look at a root paid for it. Asserted by counting reader starts, because the
  # reader is the only witness that cannot be fooled: latency and health state
  # both look the same whether or not a request went out.
  test "opening a cold root, repeatedly, starts no reader at all" do
    first = identity(1, "I1")
    {:ok, projection} = start_projection()

    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([root(first)]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 2_000

    # Mount, re-mount, reconnect — every one of these is a `demand/2`.
    for _ <- 1..5 do
      assert {:ok, %Snapshot{data: nil}} = GraphProjection.demand(projection, first)
    end

    # Holding the page open is `selected/2`, which also must not spend.
    assert {:ok, %Snapshot{data: nil}} = GraphProjection.selected(projection, first)

    refute_receive {:reader_started, {:selected, ^first}, _reader}, 200

    # And nothing was armed to spend later on the viewer's behalf either: a timer
    # here would just be the same cost deferred by one interval.
    entry = :sys.get_state(projection).selected[Policy.root_key(first)]
    assert entry.timer == nil
  end

  test "selected-root demand coalesces, protects live entries, and evicts released LRU entries" do
    first = identity(1, "I1")
    second = identity(2, "I2")
    {:ok, projection} = start_projection(max_selected_roots: 1)

    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([root(first), root(second)]))})

    assert_receive {
                     :projection_event,
                     {:graph_projection_generation, %Snapshot{scope: :catalog, authority_epoch: authority_epoch}}
                   },
                   2_000

    # Demand registers the watcher and buys nothing, so no reader starts for it.
    assert {:ok, %Snapshot{data: nil}} = GraphProjection.demand(projection, first)
    refute_receive {:reader_started, {:selected, ^first}, _reader}, 100

    # The explicit need is what spends, and repeated needs still coalesce onto
    # the one inflight read.
    :ok = GraphProjection.refresh(projection, first)
    first_reader = await_reader({:selected, first})

    for _ <- 1..3 do
      :ok = GraphProjection.refresh(projection, first)
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
                        authority_epoch: ^authority_epoch,
                        data: ^first_selected,
                        generation: first_generation
                      }}
                   },
                   2_000

    assert :ok = GraphProjection.release(projection, first)
    assert {:ok, %Snapshot{data: nil}} = GraphProjection.demand(projection, second)
    :ok = GraphProjection.refresh(projection, second)
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
    :ok = GraphProjection.refresh(projection, first)
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
      catalog_reader: Keyword.get(opts, :catalog_reader, blocking_reader(parent, :catalog)),
      selected_reader: fn identity, _reader_opts -> blocking_read(parent, {:selected, identity}) end,
      now: fn -> @now end,
      clock_ms: clock_ms,
      catalog_refresh_ms: 60_000,
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

  # A root carrying the fingerprint the carry-forward rule matches on: identity,
  # member count, and update timestamp.
  defp counted_root(identity, opts \\ []) do
    identity
    |> root()
    |> Map.merge(%{
      member_count: 3,
      updated_at: ~U[2026-07-15 11:00:00Z],
      epic_count: Keyword.get(opts, :epic_count),
      phase_count: Keyword.get(opts, :phase_count)
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
