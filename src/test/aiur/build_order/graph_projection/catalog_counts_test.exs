defmodule Aiur.BuildOrder.GraphProjection.CatalogCountsTest do
  use ExUnit.Case, async: false

  import Aiur.BuildOrder.GraphProjectionTestSupport

  alias Aiur.BuildOrder.Catalog
  alias Aiur.BuildOrder.GraphProjection
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.BuildOrder.ProviderResult
  alias Aiur.BuildOrder.RootSummary

  @repository {"owner", "repo"}

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    unless Process.whereis(Aiur.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    end

    :ok
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
  test "retains a labelled-read budget failure across a cheap success and clears it on recovery" do
    parent = self()
    first = identity(1, "I1")
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    reader = fn reader_opts ->
      send(parent, {:catalog_read, Keyword.get(reader_opts, :member_labels)})
      blocking_read(parent, :catalog)
    end

    {:ok, projection} = start_projection(clock: clock, catalog_reader: reader)

    assert_receive {:catalog_read, true}, 2_000
    finish(await_reader(:catalog), {:error, ProviderResult.failed(:call_budget_exhausted)})
    assert_receive {:projection_event, {:graph_projection_health, %Snapshot{scope: :catalog}}}, 2_000

    # The catalog keeps publishing on the cheap query while the labelled one is
    # in backoff, rather than failing over and over on the expensive one.
    assert_receive {:catalog_read, false}, 3_000
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([counted_root(first)]))})

    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{generation: 1} = fallback}}, 2_000
    assert fallback.data.count_resolution_failure == :budget

    Agent.update(clock, fn _ -> 60_001 end)
    GraphProjection.refresh_catalog(projection)
    assert_receive {:catalog_read, true}, 2_000

    resolved = counted_root(first, epic_count: 2, phase_count: 4)
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([resolved]))})

    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{generation: 2} = recovered}}, 2_000
    assert recovered.data.count_resolution_failure == nil
  end

  test "retains a labelled-read timeout across a cheap success" do
    parent = self()
    first = identity(1, "I1")

    reader = fn reader_opts ->
      send(parent, {:catalog_read, Keyword.get(reader_opts, :member_labels)})
      blocking_read(parent, :catalog)
    end

    {:ok, _projection} = start_projection(catalog_reader: reader)

    assert_receive {:catalog_read, true}, 2_000
    finish(await_reader(:catalog), {:error, ProviderResult.failed({:github, :timeout, %{reason: :timeout}})})
    assert_receive {:projection_event, {:graph_projection_health, %Snapshot{scope: :catalog}}}, 2_000

    assert_receive {:catalog_read, false}, 3_000
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([counted_root(first)]))})

    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{} = fallback}}, 2_000
    assert fallback.data.count_resolution_failure == :timeout
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

    # No error occurred: the read succeeded and simply ran past our own planning
    # page bound. Reporting `:upstream` here blamed GitHub for an Aiur limit.
    assert published.data.count_resolution_failure == :incomplete
  end

  # The branch that actually fires in production — permission, rate limit,
  # schema, transport, quota hold — previously had zero coverage: every test
  # drove a reason hitting one of the two whitelisted clauses, so the
  # `:upstream` catch-all survived any mutation. This drives each class end to
  # end through a failed labelled read and pins the atom the operator is shown.
  for {reason, expected} <- [
        {:call_budget_exhausted, :budget},
        {:page_budget_exhausted, :budget},
        {{:aiur, :locally_held, %{reason: :shared_budget, resource: "graphql"}}, :budget},
        {{:aiur, :locally_held, %{resource: "graphql", remaining: 0, limit: 5000}}, :budget},
        {{:github, :rate_limited, %{status: 403}}, :rate_limited},
        {{:github, :timeout, %{reason: :timeout}}, :timeout},
        {{:github, :timeout, %{reason: :econnrefused}}, :unreachable},
        {:missing_github_token, :permission},
        {{:github, :auth, %{status: 401}}, :permission},
        {:provider_schema, :schema},
        {:invalid_graphql_response, :schema},
        {:pagination_mismatch, :incomplete},
        {:graphql_partial, :incomplete},
        {:catalog_overflow, :incomplete},
        # Nothing we can name. The cell must keep admitting ignorance rather
        # than inventing a cause an operator would act on.
        {:something_unmapped, nil}
      ] do
    test "classifies a labelled-read #{inspect(reason)} as #{inspect(expected)}" do
      reason = unquote(Macro.escape(reason))
      expected = unquote(expected)
      parent = self()
      first = identity(1, "I1")

      reader = fn reader_opts ->
        send(parent, {:catalog_read, Keyword.get(reader_opts, :member_labels)})
        blocking_read(parent, :catalog)
      end

      {:ok, _projection} = start_projection(catalog_reader: reader)

      assert_receive {:catalog_read, true}, 2_000
      finish(await_reader(:catalog), {:error, ProviderResult.failed(reason)})
      assert_receive {:projection_event, {:graph_projection_health, %Snapshot{scope: :catalog}}}, 2_000

      assert_receive {:catalog_read, false}, 3_000
      finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([counted_root(first)]))})

      assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{} = fallback}}, 2_000
      assert fallback.data.count_resolution_failure == expected
    end
  end

  # "Budget exhausted" with no horizon leaves the operator unable to tell a
  # minute from an hour. The hold already carries the reset; it must survive.
  test "carries a budget hold's reset horizon through to the published catalog" do
    parent = self()
    first = identity(1, "I1")
    reset_at = ~U[2026-08-23 15:30:00Z]

    reader = fn reader_opts ->
      send(parent, {:catalog_read, Keyword.get(reader_opts, :member_labels)})
      blocking_read(parent, :catalog)
    end

    {:ok, _projection} = start_projection(catalog_reader: reader)

    assert_receive {:catalog_read, true}, 2_000
    hold = {:aiur, :locally_held, %{reason: :shared_budget, resource: "graphql", reset_at: reset_at}}
    finish(await_reader(:catalog), {:error, ProviderResult.failed(hold)})
    assert_receive {:projection_event, {:graph_projection_health, %Snapshot{scope: :catalog}}}, 2_000

    assert_receive {:catalog_read, false}, 3_000
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([counted_root(first)]))})

    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{} = fallback}}, 2_000
    assert fallback.data.count_resolution_failure == :budget
    assert fallback.data.count_resolution_reset_at == reset_at
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

    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{data: %Catalog{entries: [expired]}}}} when expired.epic_count == nil,
                   3_000

    assert is_nil(expired.phase_count)
  end
end
