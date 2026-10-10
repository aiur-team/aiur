defmodule Aiur.BuildOrder.GraphProjection.ResourceChangeTest do
  use ExUnit.Case, async: false

  import Aiur.BuildOrder.GraphProjectionTestSupport

  alias Aiur.BuildOrder.GraphProjection
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.BuildOrder.ProviderResult

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    unless Process.whereis(Aiur.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    end

    :ok
  end

  # The regression this whole trigger exists to avoid, and the one a marker built
  # only from the *root* issue silently reintroduces.
  #
  # GitHub does not bump a parent issue's `updatedAt` when a sub-issue closes, and
  # closing does not change `member_count`. So a member finishing — the single
  # change a Build Order page exists to show — leaves an `{identity, member_count,
  # updated_at}` marker byte-identical, and the graph is never re-read. Under the
  # deleted 15s cadence it appeared within 15 seconds; with that marker it never
  # appears at all.
  #
  # The roots here are built by the real `Normalizer.root/2` from raw GraphQL
  # nodes rather than by a fixture with a hand-set digest, so the test cannot pass
  # by agreeing with itself about what the marker contains.
  test "a member closing re-reads the graph even though the root is untouched" do
    first = identity(1, "I1")
    {:ok, projection} = start_projection()

    open = normalized_root(1, ["OPEN", "OPEN", "OPEN"])
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([open]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 2_000

    assert {:ok, %Snapshot{data: nil}} = GraphProjection.demand(projection, first)

    # The cold read, so what follows is a *change* rather than a first fill.
    GraphProjection.refresh_catalog(projection)
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([open]))})
    finish(await_reader({:selected, first}), {:ok, ProviderResult.complete(selected(first))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: {:selected, ^first}}}}, 2_000

    # Nothing has changed yet, so nothing is bought.
    GraphProjection.refresh_catalog(projection)
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([open]))})
    refute_receive {:reader_started, {:selected, ^first}, _reader}, 300

    # One member closes. The root issue itself is untouched: same `updatedAt`,
    # same `member_count`, same title, same labels.
    closed = normalized_root(1, ["CLOSED", "OPEN", "OPEN"])
    assert closed.updated_at == open.updated_at
    assert closed.member_count == open.member_count

    GraphProjection.refresh_catalog(projection)
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([closed]))})

    assert {:selected, ^first} = await_selected_scope(first)
  end

  # A dependency edge set outside Aiur must reflect on the page: the store
  # change re-reads exactly the watched roots the edge touches, and nothing
  # else (#2313).
  test "a dependency-edge change re-reads the selected root it touches and no other" do
    first = identity(1, "I1")
    second = identity(2, "I2")

    {:ok, projection} = start_projection()
    _reader = await_reader(:catalog)

    assert {:ok, _} = GraphProjection.demand(projection, first)
    assert {:ok, _} = GraphProjection.demand(projection, second)

    # An edge "1:7" touches root 1 (the blocked issue). The projection should
    # re-read root 1's selected scope from the store projection...
    send(
      projection,
      {:github_resource_changed,
       %{
         key: nil,
         resource_type: :issue_dependency,
         owner: "owner",
         repo: "repo",
         id: "1:7",
         source: :webhook,
         version: nil,
         etag: nil,
         data?: true,
         data_version: nil,
         recorded_at_ms: 1,
         cleared: false
       }}
    )

    assert {:selected, ^first} = await_selected_scope(first)
    # ...and leave root 2, which the edge does not touch, alone.
    refute_receive {:reader_started, {:selected, ^second}, _reader}, 200
  end

  # #2608, cost half. A member close is observed as an `:issue` store change;
  # that change rebuilds the catalog from the store, the rebuild moves the
  # root's lifecycle digest, and the moved marker buys the re-read. The member's
  # own change must not buy a second read on top: dispatched against the old
  # marker, it could not coalesce with the catalog's, so a close cost two
  # GraphQL reads.
  test "a member close costs exactly one selected read" do
    first = identity(1, "I1")
    seed_sub_issues([{1, 17}])
    {:ok, projection} = start_projection()
    read_root_at(projection, first, normalized_root(1, ["OPEN", "OPEN", "OPEN"]))

    send(projection, {:github_resource_changed, issue_change(:issue, "17")})

    closed = catalog([normalized_root(1, ["CLOSED", "OPEN", "OPEN"])])
    assert count_selected_reads(first, closed) == 1
  end

  # A comment, a title or body edit, or an ETag rotation deposits the issue
  # again without moving its lifecycle. The rebuild finds the digest unchanged,
  # and nothing buys a read.
  test "a member change that moves no lifecycle costs no selected read" do
    first = identity(1, "I1")
    seed_sub_issues([{1, 17}])
    {:ok, projection} = start_projection()
    open = normalized_root(1, ["OPEN", "OPEN", "OPEN"])
    read_root_at(projection, first, open)

    send(projection, {:github_resource_changed, issue_change(:issue, "17")})

    assert count_selected_reads(first, catalog([open])) == 0
  end

  # Labels are rendered by the graph but not digested by the marker, so a
  # member's label change reads the root itself — once per debounce window,
  # however many labels move in it. A fleet relabelling forty tickets in a
  # minute used to cost a read per label event.
  test "a burst of label changes inside the debounce window costs one selected read" do
    first = identity(1, "I1")
    seed_sub_issues([{1, 17}, {1, 18}])
    {:ok, projection} = start_projection(member_debounce_ms: 2_000)
    open = normalized_root(1, ["OPEN", "OPEN", "OPEN"])
    read_root_at(projection, first, open)

    reads =
      Enum.reduce(1..10, 0, fn n, reads ->
        send(projection, {:github_resource_changed, issue_change(:issue_labels, Integer.to_string(17 + rem(n, 2)))})
        reads + count_selected_reads(first, catalog([open]), 20)
      end)

    assert reads + count_selected_reads(first, catalog([open]), 2_500) == 1
  end

  # The debounced read respects failure backoff: a root whose last read failed
  # is left to its own retry timer instead of being read again on every label.
  test "a label change does not read a root that is backing off a failed read" do
    first = identity(1, "I1")
    seed_sub_issues([{1, 17}])
    {:ok, projection} = start_projection()
    open = normalized_root(1, ["OPEN", "OPEN", "OPEN"])
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([open]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 2_000

    assert {:ok, _} = GraphProjection.demand(projection, first)
    :ok = GraphProjection.refresh(projection, first)
    finish(await_reader({:selected, first}), {:error, :rate_limited})
    assert_receive {:projection_event, {:graph_projection_health, %Snapshot{scope: {:selected, ^first}, health: %{next_retry_at: %DateTime{}}}}}, 2_000

    send(projection, {:github_resource_changed, issue_change(:issue_labels, "17")})

    assert count_selected_reads(first, catalog([open])) == 0
  end

  # The same for a label transition, the other member-state change the ticket
  # names, which arrives under its own resource type.
  test "a member's label transition re-reads the selected root it belongs to" do
    first = identity(1, "I1")

    {:ok, projection} = start_projection()
    _reader = await_reader(:catalog)

    assert {:ok, _} = GraphProjection.demand(projection, first)

    send(projection, {:github_resource_changed, issue_change(:issue_labels, "1")})

    assert {:selected, ^first} = await_selected_scope(first)
  end

  # The shape the Khala daemon reported: the issue that changes is not the
  # root but one of its sub-issues (#17 and #52 under root #1). The only link
  # between them is the `:sub_issue` edge the reconciliation deposited, so the
  # member's store change must resolve its root through that edge — and must
  # not wake a root it is no member of.
  test "a sub-issue's label change re-reads the root it belongs to through the stored edge, and no other" do
    first = identity(1, "I1")
    second = identity(2, "I2")
    seed_sub_issues([{1, 17}, {2, 30}])

    {:ok, projection} = start_projection()
    _reader = await_reader(:catalog)

    assert {:ok, _} = GraphProjection.demand(projection, first)
    assert {:ok, _} = GraphProjection.demand(projection, second)

    send(projection, {:github_resource_changed, issue_change(:issue_labels, "17")})

    assert {:selected, ^first} = await_selected_scope(first)
    refute_receive {:reader_started, {:selected, ^second}, _reader}, 200
  end
end
