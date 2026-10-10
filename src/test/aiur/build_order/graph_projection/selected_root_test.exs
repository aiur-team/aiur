defmodule Aiur.BuildOrder.GraphProjection.SelectedRootTest do
  use ExUnit.Case, async: false

  import Aiur.BuildOrder.GraphProjectionTestSupport

  alias Aiur.BuildOrder.Catalog
  alias Aiur.BuildOrder.GraphProjection
  alias Aiur.BuildOrder.GraphProjection.Failure
  alias Aiur.BuildOrder.GraphProjection.Policy
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.BuildOrder.ProviderResult

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    unless Process.whereis(Aiur.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    end

    :ok
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

  # A lost update, and the reason the marker is captured at dispatch rather than
  # at completion.
  #
  # A read starts while the catalog says D1. The catalog then moves to D2, so the
  # root is due — but a read is already inflight and the request is declined. That
  # read finally lands carrying D1-era data. If it stamps the marker held *now*,
  # it stamps D2: the root is recorded as current at a state it has never held,
  # and because nothing else moves the marker it is never read again.
  #
  # Two things have to be true to avoid that: the completion stamps D1, and the
  # request declined mid-flight is queued rather than dropped.
  test "a catalog change during an inflight read is not lost when the read lands" do
    first = identity(1, "I1")
    {:ok, projection} = start_projection()

    open = normalized_root(1, ["OPEN", "OPEN", "OPEN"])
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([open]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 2_000

    assert {:ok, %Snapshot{data: nil}} = GraphProjection.demand(projection, first)

    # A read is dispatched against the D1 catalog, and deliberately left running.
    GraphProjection.refresh_catalog(projection)
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([open]))})
    stale_reader = await_reader({:selected, first})

    # The world moves underneath it: a member closes.
    closed = normalized_root(1, ["CLOSED", "OPEN", "OPEN"])
    GraphProjection.refresh_catalog(projection)
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([closed]))})

    # The inflight read cannot answer the new question, so no second reader starts
    # yet — but the request must not have been thrown away either.
    refute_receive {:reader_started, {:selected, ^first}, _reader}, 200

    # The D1-era read lands. Its data is D1-era, so it must be recorded as D1 and
    # the queued D2 request must now run.
    finish(stale_reader, {:ok, ProviderResult.complete(selected(first))})

    assert {:selected, ^first} = await_selected_scope(first)

    # And the stamp itself, which is the half the queue would otherwise paper
    # over: the landed read holds D1-era data, so it must be recorded at D1. A D2
    # stamp here is the lost update — it claims the root is current at a state it
    # has never held, and the moment anything drops the queued read (a failure, a
    # restart, an eviction) nothing is left that would ever re-read it.
    recorded = :sys.get_state(projection).selected_fingerprints[Policy.root_key(first)]
    assert recorded == Catalog.root_fingerprint(catalog([open]), first)
    refute recorded == Catalog.root_fingerprint(catalog([closed]), first)
  end

  # Deleting the viewer cadences leaves a question the cadence used to answer:
  # what reads a selected root at all? The answer must be a writer, and the only
  # daemon-owned writer left is the catalog reconciliation. If nothing triggered a
  # selected read the page would simply never show a graph, which is not
  # "need-driven" — it is broken — so this pins the whole trigger, including that
  # it does not repeat and does not fire for a root nobody is watching.
  test "the catalog cycle buys a watched cold root once, then only when it moves" do
    first = identity(1, "I1")
    second = identity(2, "I2")
    {:ok, projection} = start_projection()

    unmoved = [counted_root(first), counted_root(second)]
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog(unmoved))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 2_000

    # `first` is watched. `second` is selected and then released, so an entry
    # for it survives with nothing to show and nobody watching — the case where
    # "is anyone watching?" is the only thing stopping the read.
    assert {:ok, %Snapshot{data: nil}} = GraphProjection.demand(projection, first)
    assert {:ok, %Snapshot{data: nil}} = GraphProjection.demand(projection, second)
    assert :ok = GraphProjection.release(projection, second)
    refute_receive {:reader_started, {:selected, ^first}, _reader}, 100

    # The next catalog reconciliation notices that a watched root has nothing.
    GraphProjection.refresh_catalog(projection)
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog(unmoved))})

    finish(await_reader({:selected, first}), {:ok, ProviderResult.complete(selected(first))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: {:selected, ^first}}}}, 2_000

    # The unwatched root is never read: the cost has to be caused by something.
    refute_receive {:reader_started, {:selected, ^second}, _reader}, 100

    # A catalog cycle that reports the same root, unmoved, buys nothing more —
    # otherwise the deleted cadence is simply back, keyed off the catalog timer.
    GraphProjection.refresh_catalog(projection)
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog(unmoved))})
    refute_receive {:reader_started, {:selected, ^first}, _reader}, 300

    # A catalog cycle that reports the root *moved* buys exactly one read.
    moved = [%{counted_root(first) | member_count: 4}, counted_root(second)]
    GraphProjection.refresh_catalog(projection)
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog(moved))})

    assert {:selected, ^first} = await_selected_scope(first)
    refute_receive {:reader_started, {:selected, ^second}, _reader}, 100
  end

  # The other way a deleted cadence can come back: not as a setting, but as a
  # successor timer armed when a read finishes. That is where
  # `graph_selected_refresh_ms` actually lived — every completed selected read
  # queued the next one — so deleting the setting without deleting the
  # rescheduling would move the cost rather than remove it.
  test "a completed selected read arms no successor for the watcher" do
    first = identity(1, "I1")
    {:ok, projection} = start_projection()

    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([root(first)]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 2_000

    assert {:ok, %Snapshot{data: nil}} = GraphProjection.demand(projection, first)
    :ok = GraphProjection.refresh(projection, first)
    finish(await_reader({:selected, first}), {:ok, ProviderResult.complete(selected(first))})

    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: {:selected, ^first}}}}, 2_000

    # The watcher is still there and still watching, which is exactly the state
    # that used to guarantee a successor read.
    entry = :sys.get_state(projection).selected[Policy.root_key(first)]
    assert MapSet.size(entry.demanders) == 1
    assert entry.timer == nil

    # And no second reader starts, however long the page stays open.
    refute_receive {:reader_started, {:selected, ^first}, _reader}, 300
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

  # #2608, the one-shot caller. `aiur build-orders <root> --json` registers
  # demand from an RPC process that is gone before the read it bought lands.
  # The read must still run to completion and be kept, so the next caller is
  # served the reconciled graph rather than buying the same read again.
  test "a read bought by a demander that has already exited is kept for the next caller" do
    first = identity(1, "I1")
    {:ok, projection} = start_projection()

    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([normalized_root(1, ["OPEN", "OPEN", "OPEN"])]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 2_000

    assert {:ok, _} = GraphProjection.demand(projection, first)
    :ok = GraphProjection.refresh(projection, first)
    finish(await_reader({:selected, first}), {:ok, ProviderResult.complete(selected(first))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: {:selected, ^first}, generation: held}}}, 2_000
    :ok = GraphProjection.release(projection, first)

    # A member closes while nobody watches; the catalog tracks it.
    GraphProjection.refresh_catalog(projection)
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([normalized_root(1, ["CLOSED", "OPEN", "OPEN"])]))})
    refute_receive {:reader_started, {:selected, ^first}, _reader}, 300

    # A short-lived caller demands the root and exits before the read lands.
    caller = Task.async(fn -> GraphProjection.demand(projection, first) end)
    assert {:ok, %Snapshot{generation: ^held}} = Task.await(caller)
    reader = await_reader({:selected, first})
    finish(reader, {:ok, ProviderResult.complete(selected(first))})

    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: {:selected, ^first}, generation: fresh}}}, 2_000
    assert fresh > held
    assert {:ok, %Snapshot{generation: ^fresh}} = GraphProjection.selected(projection, first)

    # The graph now matches the catalog, so the next caller buys nothing.
    caller = Task.async(fn -> GraphProjection.demand(projection, first) end)
    assert {:ok, %Snapshot{generation: ^fresh}} = Task.await(caller)
    refute_receive {:reader_started, {:selected, ^first}, _reader}, 300
  end

  # #2608, freeze half — the failure that made the six hours *permanent* rather
  # than merely slow.
  #
  # A poll-only daemon boots with an empty catalog store, so the first catalog
  # generation knows no roots at all. A selected read dispatched in that window
  # corresponds to no catalog observation and records a `nil` marker. When the
  # reconciliation's deposits finally land and the root appears, the comparison
  # `{current, nil}` used to answer "not moved" — and since nothing else ever
  # moves a recorded marker, the root could never become due again. Only an
  # explicit `refresh/2` would ever re-read it.
  test "a root read before the catalog knew it becomes due once the catalog learns it" do
    first = identity(1, "I1")
    {:ok, projection} = start_projection()

    # Boot: the store is empty, so the catalog carries no roots.
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 2_000

    assert {:ok, _} = GraphProjection.demand(projection, first)

    # A read lands in that window, so it corresponds to no catalog observation.
    :ok = GraphProjection.refresh(projection, first)
    finish(await_reader({:selected, first}), {:ok, ProviderResult.complete(selected(first))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: {:selected, ^first}}}}, 2_000
    refute :sys.get_state(projection).selected_fingerprints[Policy.root_key(first)]

    # The reconciliation's deposits land and the catalog learns the root.
    GraphProjection.refresh_catalog(projection)
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([normalized_root(1, ["OPEN", "OPEN", "OPEN"])]))})

    # The root is due: one read, after which a real marker is stamped.
    assert {:selected, ^first} = await_selected_scope(first)
  end

  # #2608, the returning-watcher case. A catalog move only re-reads roots that
  # are watched *at that moment* — `request_scope/2` declines a root nobody has
  # open, and nothing re-raises the request when a watcher comes back. So a page
  # opened on a root the catalog had already superseded rendered the held graph
  # and never asked for a better one. Arriving demand buys exactly one read, and
  # only when the catalog itself says the root has moved.
  test "demand on a root the catalog has superseded buys one read, and an unmoved root buys none" do
    first = identity(1, "I1")
    {:ok, projection} = start_projection()

    open = normalized_root(1, ["OPEN", "OPEN", "OPEN"])
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([open]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 2_000

    assert {:ok, _} = GraphProjection.demand(projection, first)
    :ok = GraphProjection.refresh(projection, first)
    finish(await_reader({:selected, first}), {:ok, ProviderResult.complete(selected(first))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: {:selected, ^first}}}}, 2_000

    # Re-opening the page on an unmoved root buys nothing: demand is still
    # bookkeeping, not a cadence.
    :ok = GraphProjection.release(projection, first)
    assert {:ok, _} = GraphProjection.demand(projection, first)
    refute_receive {:reader_started, {:selected, ^first}, _reader}, 300

    # The page closes, and a member closes while nobody is watching. The catalog
    # tracks it; the held graph cannot, because no watcher is registered.
    :ok = GraphProjection.release(projection, first)
    closed = normalized_root(1, ["CLOSED", "OPEN", "OPEN"])
    GraphProjection.refresh_catalog(projection)
    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([closed]))})
    refute_receive {:reader_started, {:selected, ^first}, _reader}, 300

    # The operator opens the page again. The catalog says this graph is
    # superseded, so demand buys the one read that reconciles it.
    assert {:ok, _} = GraphProjection.demand(projection, first)
    assert {:selected, ^first} = await_selected_scope(first)
  end

  # An explicit refresh is an operator saying "read this now", so the answer has
  # to be a read. It was not: a root whose snapshot was healthy, complete and
  # stamped with the catalog marker still in force was "not due", and a root
  # whose page had gone was "not watched" — so a detail page kept reporting 0
  # members and 0 dependencies for membership written after the last read
  # (#2538).
  test "an explicit selected refresh re-reads a held root that is current and unwatched" do
    first = identity(1, "I1")
    second = identity(2, "I2")
    {:ok, projection} = start_projection()

    finish(await_reader(:catalog), {:ok, ProviderResult.complete(catalog([root(first)]))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: :catalog}}}, 2_000

    assert {:ok, %Snapshot{data: nil}} = GraphProjection.demand(projection, first)
    :ok = GraphProjection.refresh(projection, first)
    finish(await_reader({:selected, first}), {:ok, ProviderResult.complete(selected(first))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: {:selected, ^first}}}}, 2_000

    # The state in which nothing is due: complete data, healthy, no read
    # running and no successor armed.
    entry = :sys.get_state(projection).selected[Policy.root_key(first)]
    assert entry.health.state == :healthy
    assert entry.data == selected(first)
    assert entry.inflight == nil
    assert entry.timer == nil

    :ok = GraphProjection.refresh(projection, first)
    finish(await_reader({:selected, first}), {:ok, ProviderResult.complete(selected(first))})
    assert_receive {:projection_event, {:graph_projection_generation, %Snapshot{scope: {:selected, ^first}}}}, 2_000

    # Losing the watcher does not make the request unanswerable: the entry is
    # still held, so it is still read.
    assert :ok = GraphProjection.release(projection, first)
    :ok = GraphProjection.refresh(projection, first)
    _unwatched_reader = await_reader({:selected, first})

    # What a refresh still cannot do is create a root the projection is not
    # holding, which is what stops a caller buying a read for anything at all.
    :ok = GraphProjection.refresh(projection, second)
    refute_receive {:reader_started, {:selected, ^second}, _reader}, 200
  end
end
