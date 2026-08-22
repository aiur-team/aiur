defmodule Aiur.DecisionQueryTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Aiur.{DecisionQuery, DecisionStore, DecisionValidation}
  alias Aiur.DecisionQuery.Cursor
  alias Aiur.DecisionStore.RetainedSnapshot

  @ticket %{identifier: "1088", title: "Retained Decisions", url: "https://example.test/issues/1088"}
  @source %{agent_id: "agent-1088", session_id: "session-private", event_id: nil}

  defmodule AtomicSnapshotStore do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, %{decision: Keyword.fetch!(opts, :decision), report: Keyword.fetch!(opts, :report)}}

    @impl true
    def handle_call(
          {:retained_lookup, decision_id},
          _from,
          %{decision: %{decision_id: decision_id} = decision} = state
        ) do
      send(state.report, {:atomic_snapshot, :lookup})
      {:reply, {:ok, %{decision: decision, health: :writable}}, state}
    end

    def handle_call({:retained_lookup, _decision_id}, _from, state) do
      send(state.report, {:atomic_snapshot, :lookup})
      {:reply, {:ok, %{decision: nil, health: :writable}}, state}
    end

    def handle_call({:retained_query, _query}, _from, %{decision: decision} = state) do
      send(state.report, {:atomic_snapshot, :query})

      {:reply,
       {:ok,
        %{
          decisions: [decision],
          has_next?: false,
          total: 1,
          counts: %{open: 1, blocking: if(decision.blocking, do: 1, else: 0), total: 1},
          health: :writable
        }}, state}
    end

    def handle_call(:retained_counts, _from, %{decision: decision} = state) do
      send(state.report, {:atomic_snapshot, :counts})

      {:reply,
       {:ok,
        %{
          counts: %{open: 1, blocking: if(decision.blocking, do: 1, else: 0), total: 1},
          health: :writable
        }}, state}
    end

    def handle_call(request, _from, state) do
      send(state.report, {:split_read_attempted, request})
      {:reply, {:error, :simulated_restart}, state}
    end
  end

  setup do
    original_override = Application.get_env(:aiur, :decision_state_dir)
    dir = Path.join(System.tmp_dir!(), "aiur-decision-query-#{System.pid()}-#{System.unique_integer([:positive])}")
    Application.put_env(:aiur, :decision_state_dir, dir)

    {:ok, store} = DecisionStore.start_link(name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(store)

      case original_override do
        nil -> Application.delete_env(:aiur, :decision_state_dir)
        value -> Application.put_env(:aiur, :decision_state_dir, value)
      end

      File.rm_rf!(dir)
    end)

    %{store: store, dir: dir}
  end

  test "default retained reads target the canonical Aiur DecisionStore" do
    assert DecisionQuery.default_store() == Aiur.DecisionStore

    assert {:error, :not_found} = DecisionQuery.get("dec-default-path-missing")
    assert {:ok, %{decisions: decisions}} = DecisionQuery.list(%{"limit" => 1})
    assert is_list(decisions)
    assert {:ok, %{open: open, blocking: blocking}} = DecisionQuery.counts()
    assert is_integer(open)
    assert is_integer(blocking)
  end

  test "exact lookup reaches an old retained Decision outside the priority overview", %{store: store} do
    oldest = request!(store, "oldest", ~U[2026-07-13 08:00:00Z])

    for index <- 1..50 do
      request!(store, "recent-#{index}", DateTime.add(oldest.created_at, index, :second))
    end

    refute Enum.any?(DecisionStore.recent_decisions(50, store), &(&1.decision_id == oldest.decision_id))

    assert {:ok, %{decision: detail, scope: %{kind: :retained}, health: %{status: :available}}} =
             DecisionQuery.get(oldest.decision_id, store: store)

    assert detail.decision_id == oldest.decision_id
    assert {:error, :not_found} = DecisionQuery.get("dec_missing", store: store)
  end

  test "cursor pages remain stable and non-overlapping when a later Decision is inserted", %{store: store} do
    first = request!(store, "first", ~U[2026-07-13 08:00:00Z])
    second = request!(store, "second", ~U[2026-07-13 08:01:00Z])
    third = request!(store, "third", ~U[2026-07-13 08:02:00Z])

    assert {:ok, page_one} = DecisionQuery.list(%{"limit" => 1}, store: store)
    assert [newest] = page_one.decisions
    assert newest.decision_id == third.decision_id

    _later = request!(store, "later", ~U[2026-07-13 08:03:00Z])

    assert {:ok, page_two} =
             DecisionQuery.list(
               %{"limit" => 1, "cursor" => page_one.pagination.next_cursor},
               store: store
             )

    assert [next] = page_two.decisions
    assert next.decision_id == second.decision_id

    assert {:ok, page_three} =
             DecisionQuery.list(
               %{"limit" => 1, "cursor" => page_two.pagination.next_cursor},
               store: store
             )

    assert [oldest] = page_three.decisions
    assert oldest.decision_id == first.decision_id
    assert MapSet.size(MapSet.new([newest.decision_id, next.decision_id, oldest.decision_id])) == 3
  end

  test "cursor pages preserve first accepted audit order after update and replay", %{store: store, dir: dir} do
    first = request!(store, "stable-first", ~U[2026-07-13 08:00:00Z])
    middle = request!(store, "stable-middle", ~U[2026-07-13 08:01:00Z])
    third = request!(store, "stable-third", ~U[2026-07-13 08:02:00Z])

    assert {:ok, %{decisions: [page_one], pagination: %{next_cursor: cursor}}} =
             DecisionQuery.list(%{"limit" => 1}, store: store)

    assert page_one.decision_id == third.decision_id

    updated = request!(store, "stable-middle", ~U[2026-07-13 08:03:00Z], version: 2)
    assert updated.version == 2

    assert {:ok, %{decisions: [page_two]}} =
             DecisionQuery.list(%{"limit" => 1, "cursor" => cursor}, store: store)

    assert page_two.decision_id == middle.decision_id

    GenServer.stop(store)
    {:ok, replayed} = DecisionStore.start_link(name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(replayed)
    end)

    assert %{ids: ids} = traverse_pages(replayed, 1)
    assert ids == [third.decision_id, middle.decision_id, first.decision_id]
  end

  test "cursor pages retain every equal-timestamp Decision in canonical ID order", %{store: store} do
    created_at = ~U[2026-07-13 08:00:00Z]

    expected_ids =
      [
        request!(store, "same-timestamp-z", created_at),
        request!(store, "same-timestamp-a", created_at),
        request!(store, "same-timestamp-m", created_at)
      ]
      |> Enum.sort_by(& &1.decision_id)
      |> Enum.map(& &1.decision_id)

    assert {:ok, %{decisions: first_page, pagination: %{next_cursor: cursor}}} =
             DecisionQuery.list(%{"limit" => 2}, store: store)

    assert Enum.map(first_page, & &1.decision_id) == Enum.take(expected_ids, 2)

    assert {:ok, %{decisions: second_page, pagination: %{next_cursor: nil}}} =
             DecisionQuery.list(%{"limit" => 2, "cursor" => cursor}, store: store)

    assert Enum.map(second_page, & &1.decision_id) == Enum.drop(expected_ids, 2)
    assert Enum.map(first_page ++ second_page, & &1.decision_id) == expected_ids
  end

  test "cursor helper round trips stable retained ordering keys" do
    cursor = %{created_at: ~U[2026-07-13 08:00:00Z], decision_id: "dec_cursor-round-trip"}

    assert {:ok, ^cursor} = cursor |> Cursor.encode() |> Cursor.parse()
  end

  test "query filters retained identifiers and tickets while counts cover all Decisions", %{
    store: store
  } do
    open = request!(store, "open", ~U[2026-07-13 08:00:00Z], blocking: true)
    deferred = request!(store, "deferred", ~U[2026-07-13 08:00:30Z], blocking: true)
    resolved = request!(store, "resolved", ~U[2026-07-13 08:01:00Z], blocking: true)

    :sys.replace_state(store, fn state ->
      current =
        state.current
        |> Map.update!(deferred.decision_id, &%{&1 | decision_status: :deferred})
        |> Map.update!(resolved.decision_id, &%{&1 | decision_status: :resolved})

      %{state | current: current, retained_index: RetainedSnapshot.build_index(current)}
    end)

    assert {:ok, %{decisions: open_rows, filters: %{lifecycle: :open}}} =
             DecisionQuery.list(%{"lifecycle" => "open", "ticket" => "1088"}, store: store)

    assert MapSet.new(open_rows, & &1.decision_id) == MapSet.new([open.decision_id, deferred.decision_id])

    assert {:ok, %{decisions: [deferred_row], filters: %{lifecycle: :deferred}}} =
             DecisionQuery.list(%{"lifecycle" => "deferred"}, store: store)

    assert deferred_row.decision_id == deferred.decision_id

    search = String.slice(open.decision_id, 0, 12)
    assert {:ok, %{decisions: [search_row]}} = DecisionQuery.list(%{"search" => search}, store: store)
    assert search_row.decision_id == open.decision_id

    assert {:ok, %{pagination: %{total: 1}}} =
             DecisionQuery.list(%{"search" => search}, store: store)

    assert {:ok, %{open: 2, blocking: 2, scope: %{label: "All retained decisions"}}} =
             DecisionQuery.counts(store: store)
  end

  test "filtered continuation pages omit totals unless the full candidate set was scanned", %{store: store} do
    request!(store, "filtered-first", ~U[2026-07-13 08:00:00Z])
    request!(store, "filtered-second", ~U[2026-07-13 08:01:00Z])

    assert {:ok, %{pagination: %{next_cursor: cursor}}} =
             DecisionQuery.list(%{"limit" => 1, "search" => "dec_"}, store: store)

    assert {:ok, %{pagination: %{next_cursor: nil, total: nil}}} =
             DecisionQuery.list(%{"limit" => 1, "search" => "dec_", "cursor" => cursor}, store: store)
  end

  test "invalid retained-query input is rejected without broadening the result", %{store: store} do
    request!(store, "only", ~U[2026-07-13 08:00:00Z])

    for params <- [
          %{"limit" => 0},
          %{"limit" => 101},
          %{"cursor" => "not-a-cursor"},
          %{"lifecycle" => "future"},
          %{"lifecycle" => <<255>>},
          %{"search" => "\n"},
          %{"search" => <<255>>},
          %{"search" => "dec", "ticket" => "1088"},
          %{"unknown" => "ignored"},
          %{"limit" => 1, limit: 2}
        ] do
      assert {:error, {:invalid_query, _reason}} = DecisionQuery.list(params, store: store)
    end

    assert {:error, {:invalid_decision_id, :malformed}} = DecisionQuery.get(<<255>>, store: store)
  end

  test "store-native retained query enforces provider input bounds", %{store: store} do
    valid = %{limit: 1, cursor: nil, lifecycle: nil, search: nil, ticket: nil}
    assert {:ok, %{decisions: []}} = DecisionStore.retained_query(valid, store)

    for params <- [
          %{valid | limit: 101},
          %{valid | search: String.duplicate("a", 201)},
          %{valid | ticket: String.duplicate("a", 201)},
          %{valid | cursor: "not-a-cursor"},
          %{valid | search: "dec", ticket: "1088"}
        ] do
      assert {:error, :invalid_query} = DecisionStore.retained_query(params, store)
    end

    assert Process.alive?(store)
  end

  test "legacy retained pages keep a single current-order snapshot beyond cursor limits", %{store: store} do
    decisions =
      for index <- 0..100 do
        request!(store, "legacy-page-#{index}", DateTime.add(~U[2026-07-13 08:00:00Z], index, :second))
      end
      |> Enum.reverse()

    query = %{
      limit: 25,
      cursor: nil,
      lifecycle: nil,
      search: nil,
      ticket: nil,
      authority: nil,
      blocking: nil,
      kind: nil
    }

    assert {:ok, %{decisions: page, has_next?: false, total: 101, partial?: false, health: :writable}} =
             DecisionStore.retained_legacy_page(query, 0, 200, store)

    assert Enum.map(page, & &1.decision_id) == Enum.map(decisions, & &1.decision_id)
  end

  test "retained snapshots read only the indexed page candidate window", %{store: store} do
    oldest = request!(store, "indexed-oldest", ~U[2026-07-13 08:00:00Z])
    middle = request!(store, "indexed-middle", ~U[2026-07-13 08:01:00Z])
    newest = request!(store, "indexed-newest", ~U[2026-07-13 08:02:00Z])
    index = RetainedSnapshot.build_index(Map.new([oldest, middle, newest], &{&1.decision_id, &1}))

    page_current = Map.new([newest, middle], &{&1.decision_id, &1})
    query = %{limit: 1, cursor: nil, lifecycle: nil, search: nil, ticket: nil}

    assert {:ok, %{decisions: [first], has_next?: true, total: 3}} =
             RetainedSnapshot.query(page_current, index, :writable, query)

    assert first.decision_id == newest.decision_id

    no_match_query = %{query | search: "does-not-exist"}

    assert {:ok, %{decisions: [], has_next?: false, total: 0}} =
             RetainedSnapshot.query(%{}, index, :writable, no_match_query)
  end

  test "fixed search buckets bound nonmatching candidate work without prefix amplification", %{store: store} do
    [template] = generated_decisions([{0, :open}])

    decisions =
      for index <- 1..1_001 do
        %{template | decision_id: "dec_search-#{index}", source_id: "search-#{index}"}
      end

    current = Map.new(decisions, &{&1.decision_id, &1})
    index = RetainedSnapshot.build_index(current)

    assert map_size(index.searches) <= 6

    query = %{limit: 1, cursor: nil, lifecycle: nil, search: "dec_missing", ticket: nil}

    assert {:ok, %{decisions: [], has_next?: true, next_key: next_key, total: nil, partial?: true}} =
             RetainedSnapshot.query(current, index, :writable, query)

    assert is_tuple(next_key)

    :sys.replace_state(store, fn state ->
      %{state | current: current, retained_index: index}
    end)

    assert {:ok,
            %{
              decisions: [],
              partial_results?: true,
              partial_reason: :retained_query_scan_capped,
              pagination: %{
                next_cursor: next_cursor,
                total: nil,
                partial_reason: :retained_query_scan_capped,
                label: label
              }
            }} = DecisionQuery.list(%{"limit" => 1, "search" => "dec_missing"}, store: store)

    assert is_binary(next_cursor)
    assert label =~ "Partial retained Decision page"
  end

  test "capped filtered scans continue to an exact match beyond the candidate limit", %{store: _store} do
    [template] = generated_decisions([{0, :open}])

    matching = %{template | decision_id: "dec_match", source_id: "match"}

    nonmatching =
      for index <- 1..1_000 do
        %{
          template
          | decision_id: "dec_other-#{index}",
            source_id: "other-#{index}",
            created_at: DateTime.add(template.created_at, index, :second)
        }
      end

    current = Map.new([matching | nonmatching], &{&1.decision_id, &1})
    index = RetainedSnapshot.build_index(current)
    query = %{limit: 1, cursor: nil, lifecycle: nil, search: "dec_match", ticket: nil}

    assert {:ok, %{decisions: [], has_next?: true, next_key: {_created_at, "dec_other-1"}, partial?: true}} =
             RetainedSnapshot.query(current, index, :writable, query)

    cursor = %{created_at: DateTime.add(template.created_at, 1, :second), decision_id: "dec_other-1"}

    assert {:ok, %{decisions: [retained], has_next?: false, partial?: false}} =
             RetainedSnapshot.query(current, index, :writable, %{query | cursor: cursor})

    assert retained.decision_id == matching.decision_id
  end

  test "authority, blocking, and kind scans cap no-match reads and resume rare matches" do
    [template] = generated_decisions([{0, :open}])

    for {field, expected, nonmatching_value} <- [
          {:authority, :supervisor_allowed, :human_required},
          {:blocking, true, false},
          {:kind, "product", "architecture"}
        ] do
      nonmatching =
        for index <- 1..1_001 do
          template
          |> Map.put(:decision_id, "dec_#{field}-#{index}")
          |> Map.put(:source_id, "#{field}-#{index}")
          |> Map.put(:created_at, DateTime.add(template.created_at, index, :second))
          |> Map.put(field, nonmatching_value)
        end

      no_match_current = Map.new(nonmatching, &{&1.decision_id, &1})
      no_match_index = RetainedSnapshot.build_index(no_match_current)

      query =
        %{limit: 1, cursor: nil, lifecycle: nil, search: nil, ticket: nil}
        |> Map.put(field, expected)

      assert {:ok,
              %{
                decisions: [],
                has_next?: true,
                next_key: {next_created_at, next_id},
                total: nil,
                partial?: true,
                partial_reason: :retained_query_scan_capped
              }} = RetainedSnapshot.query(no_match_current, no_match_index, :writable, query)

      assert next_id == "dec_#{field}-2"

      matching =
        template
        |> Map.put(:decision_id, "dec_#{field}-match")
        |> Map.put(:source_id, "#{field}-match")
        |> Map.put(field, expected)

      current = Map.new([matching | nonmatching], &{&1.decision_id, &1})
      index = RetainedSnapshot.build_index(current)

      assert {:ok, %{decisions: [], partial?: true}} =
               RetainedSnapshot.query(current, index, :writable, query)

      cursor = %{
        created_at: DateTime.from_unix!(-next_created_at, :microsecond),
        decision_id: next_id
      }

      assert {:ok, %{decisions: [retained], has_next?: false, partial?: false}} =
               RetainedSnapshot.query(current, index, :writable, %{query | cursor: cursor})

      assert retained.decision_id == matching.decision_id
    end
  end

  test "counts distinguish partial retained data from an unavailable store", %{store: store} do
    request!(store, "partial", ~U[2026-07-13 08:00:00Z])

    :sys.replace_state(store, &Map.put(&1, :health, {:corrupt, 1, :invalid_record}))

    assert {:ok, %{open: 1, health: %{status: :partial, partial?: true, reason: :retained_store_partial}}} =
             DecisionQuery.counts(store: store)

    assert {:ok, %{open: nil, blocking: nil, total: nil, health: %{status: :unavailable, partial?: true}}} =
             DecisionQuery.counts(store: make_ref())

    assert {:ok,
            %{
              decisions: [],
              scope: %{kind: :retained},
              health: %{status: :unavailable},
              partial_results?: true,
              pagination: %{total: nil}
            }} = DecisionQuery.list(%{"limit" => 1}, store: make_ref())

    assert {:error, :store_unavailable} = DecisionQuery.get("dec_missing", store: make_ref())
  end

  test "generated retained datasets preserve stable page order, bounds, and exact totals", %{store: store} do
    :rand.seed(:exsplus, {1088, 6, 17})

    Enum.reduce(1..8, [], fn dataset, accumulated ->
      decisions =
        for index <- 1..(2 + :rand.uniform(6)) do
          offset = dataset * 100 + :rand.uniform(4) - 1
          request!(store, "generated-#{dataset}-#{index}", DateTime.add(~U[2026-07-13 08:00:00Z], offset, :second))
        end

      retained = decisions ++ accumulated
      expected = retained |> Enum.sort_by(&audit_key/1) |> Enum.map(& &1.decision_id)

      for limit <- [1, 2, 3, 5] do
        assert %{ids: ids, totals: totals} = traverse_pages(store, limit)
        assert ids == expected
        assert MapSet.size(MapSet.new(ids)) == length(ids)
        assert Enum.uniq(totals) == [length(expected)]
      end

      retained
    end)

    for params <- [
          %{"limit" => -1},
          %{"limit" => "1.0"},
          %{"cursor" => String.duplicate("a", 1_025)},
          %{"search" => String.duplicate("a", 201)},
          %{"ticket" => String.duplicate("a", 201)},
          %{"search" => "\u0000"},
          %{"ticket" => "1088", "search" => "dec"}
        ] do
      assert {:error, {:invalid_query, _reason}} = DecisionQuery.list(params, store: store)
    end
  end

  test "lifecycle pages preserve the same audit ordering and canonical counts", %{store: store} do
    oldest = request!(store, "resolved-oldest", ~U[2026-07-13 08:00:00Z], blocking: true)
    open = request!(store, "open-middle", ~U[2026-07-13 08:01:00Z], blocking: true)
    newest = request!(store, "resolved-newest", ~U[2026-07-13 08:02:00Z])

    :sys.replace_state(store, fn state ->
      current =
        state.current
        |> Map.update!(oldest.decision_id, &%{&1 | decision_status: :resolved})
        |> Map.update!(newest.decision_id, &%{&1 | decision_status: :resolved})

      %{state | current: current, retained_index: RetainedSnapshot.build_index(current)}
    end)

    assert {:ok, %{decisions: [resolved_newest, resolved_oldest], pagination: %{total: 2}}} =
             DecisionQuery.list(%{"lifecycle" => "resolved"}, store: store)

    assert [resolved_newest.decision_id, resolved_oldest.decision_id] == [newest.decision_id, oldest.decision_id]

    assert {:ok, %{decisions: [open_row], pagination: %{total: 1}}} =
             DecisionQuery.list(%{"lifecycle" => "open"}, store: store)

    assert open_row.decision_id == open.decision_id
    assert {:ok, %{open: 1, blocking: 1}} = DecisionQuery.counts(store: store)
  end

  test "replayed corrupt prefixes retain valid details and distinguish missing IDs", %{
    store: store,
    dir: dir
  } do
    decision = request!(store, "replay-prefix", ~U[2026-07-13 08:00:00Z])
    GenServer.stop(store)

    File.write!(Path.join(dir, "decisions.ndjson"), "not json at all\n", [:append])
    {:ok, replayed} = DecisionStore.start_link(name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(replayed)
    end)

    assert {:ok, %{decision: retained, health: %{status: :partial, partial?: true}}} =
             DecisionQuery.get(decision.decision_id, store: replayed)

    assert retained.decision_id == decision.decision_id

    assert {:error, {:indeterminate, %{status: :partial, partial?: true}}} =
             DecisionQuery.get("dec_missing", store: replayed)

    assert {:ok,
            %{
              health: %{status: :partial},
              partial_results?: true,
              partial_reason: :retained_store_partial,
              pagination: %{total: 1, partial_reason: :retained_store_partial, label: label}
            }} = DecisionQuery.list(%{}, store: replayed)

    assert label =~ "retained audit data is corrupt"
  end

  test "atomic retained snapshots avoid a health/read restart race", %{store: store} do
    decision = request!(store, "atomic-snapshot", ~U[2026-07-13 08:00:00Z], blocking: true)
    {:ok, snapshot_store} = AtomicSnapshotStore.start_link(decision: decision, report: self())

    assert {:ok, %{decision: retained}} = DecisionQuery.get(decision.decision_id, store: snapshot_store)
    assert retained.decision_id == decision.decision_id
    assert {:ok, %{decisions: [listed]}} = DecisionQuery.list(%{"limit" => 1}, store: snapshot_store)
    assert listed.decision_id == decision.decision_id

    assert {:ok, %{counts: %{open: 1, blocking: 1, total: 1}, health: :writable}} =
             DecisionStore.retained_counts(snapshot_store)

    assert {:ok, %{open: 1, blocking: 1, total: 1}} = DecisionQuery.counts(store: snapshot_store)

    assert_receive {:atomic_snapshot, :lookup}
    assert_receive {:atomic_snapshot, :query}
    assert_receive {:atomic_snapshot, :counts}
    assert_receive {:atomic_snapshot, :counts}
    refute_receive {:split_read_attempted, _request}
  end

  property "generated retained pages preserve lifecycle audit order without duplicates", %{store: store} do
    statuses = [:open, :decided, :acknowledged, :resolved]

    check all(
            specs <- list_of(tuple({integer(0..4), member_of(statuses)}), min_length: 1, max_length: 30),
            limit <- integer(1..5),
            selected <- integer(0..100),
            max_runs: 10
          ) do
      decisions = generated_decisions(specs)
      current = Map.new(decisions, &{&1.decision_id, &1})
      lifecycle = specs |> Enum.at(rem(selected, length(specs))) |> elem(1)

      :sys.replace_state(store, fn state ->
        %{
          state
          | current: current,
            retained_index: RetainedSnapshot.build_index(current),
            decision_index: :gb_sets.empty()
        }
      end)

      expected =
        decisions
        |> Enum.filter(&(&1.decision_status == lifecycle))
        |> Enum.sort_by(&audit_key/1)
        |> Enum.map(& &1.decision_id)

      actual = traverse_filtered_pages(store, %{"lifecycle" => Atom.to_string(lifecycle)}, limit)

      assert actual == expected
      assert MapSet.size(MapSet.new(actual)) == length(actual)
    end
  end

  property "generated invalid query inputs never broaden a retained-store read", %{store: store} do
    check all(
            oversized <- string(:alphanumeric, min_length: 201, max_length: 240),
            invalid_limit <- one_of([integer(-100..0), integer(101..1_000)]),
            max_runs: 10
          ) do
      for params <- [
            %{"limit" => invalid_limit},
            %{"search" => oversized},
            %{"ticket" => oversized},
            %{"search" => String.slice(oversized, 0, 3), "ticket" => "1088"}
          ] do
        assert {:error, {:invalid_query, _reason}} = DecisionQuery.list(params, store: store)
      end
    end
  end

  property "generated malformed cursors reject before querying the retained store", %{store: store} do
    decision = request!(store, "cursor-boundary", ~U[2026-07-13 08:00:00Z])
    {:ok, boundary_store} = AtomicSnapshotStore.start_link(decision: decision, report: self())

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(boundary_store)
    end)

    check all(cursor <- malformed_cursor(), max_runs: 10) do
      params = %{"cursor" => cursor}

      assert {:error, {:invalid_query, _reason}} = DecisionQuery.list(params, store: boundary_store)
      assert {:error, :invalid_query} = DecisionStore.retained_query(params, store)
      assert Process.alive?(store)
      refute_receive {:atomic_snapshot, :query}
    end
  end

  property "generated direct lookup ignores the priority overview index", %{store: store} do
    check all(
            offsets <- list_of(integer(0..30), min_length: 51, max_length: 70),
            selected <- integer(0..100),
            max_runs: 10
          ) do
      decisions = generated_decisions(Enum.map(offsets, &{&1, :open}))
      current = Map.new(decisions, &{&1.decision_id, &1})
      target = Enum.at(decisions, rem(selected, length(decisions)))

      :sys.replace_state(store, fn state ->
        %{
          state
          | current: current,
            retained_index: RetainedSnapshot.build_index(current),
            decision_index: :gb_sets.empty()
        }
      end)

      assert {:ok, %{decision: retained}} = DecisionQuery.get(target.decision_id, store: store)
      assert retained.decision_id == target.decision_id
    end
  end

  defp request!(store, source_id, now, attrs \\ []) do
    payload = %{
      "source_id" => source_id,
      "question" => "Should #{source_id} ship?",
      "blocking" => Keyword.get(attrs, :blocking, false),
      "urgency" => "normal",
      "reversibility" => "reversible"
    }

    payload =
      case Keyword.get(attrs, :version) do
        nil -> payload
        version -> Map.put(payload, "version", version)
      end

    assert {:ok, %{decision: decision}} =
             DecisionStore.request(payload, [ticket: @ticket, source: @source, now: now], store)

    decision
  end

  defp traverse_pages(store, limit, cursor \\ nil, ids \\ [], totals \\ []) do
    params = if cursor, do: %{"limit" => limit, "cursor" => cursor}, else: %{"limit" => limit}
    assert {:ok, page} = DecisionQuery.list(params, store: store)

    ids = ids ++ Enum.map(page.decisions, & &1.decision_id)
    totals = [page.pagination.total | totals]

    case page.pagination.next_cursor do
      nil -> %{ids: ids, totals: Enum.reverse(totals)}
      next_cursor -> traverse_pages(store, limit, next_cursor, ids, totals)
    end
  end

  defp traverse_filtered_pages(store, filters, limit, cursor \\ nil, ids \\ []) do
    params =
      filters
      |> Map.put("limit", limit)
      |> then(fn params -> if(cursor, do: Map.put(params, "cursor", cursor), else: params) end)

    assert {:ok, page} = DecisionQuery.list(params, store: store)
    ids = ids ++ Enum.map(page.decisions, & &1.decision_id)

    case page.pagination.next_cursor do
      nil -> ids
      next_cursor -> traverse_filtered_pages(store, filters, limit, next_cursor, ids)
    end
  end

  defp generated_decisions(specs) do
    specs
    |> Enum.with_index()
    |> Enum.map(fn {{offset, status}, index} ->
      payload = %{
        "source_id" => "property-#{index}",
        "question" => "Should generated Decision #{index} ship?",
        "blocking" => rem(index, 2) == 0,
        "urgency" => "normal",
        "reversibility" => "reversible"
      }

      assert {:ok, decision} =
               DecisionValidation.normalize(payload,
                 ticket: @ticket,
                 source: @source,
                 now: DateTime.add(~U[2026-07-13 08:00:00Z], offset, :second)
               )

      %{decision | decision_status: status}
    end)
  end

  defp malformed_cursor do
    valid_timestamp = "2026-07-13T08:00:00Z"
    valid_decision_id = "dec_cursor-boundary"

    one_of([
      map(string(:alphanumeric, min_length: 0, max_length: 100), &("!" <> &1)),
      constant(encode_cursor_payload([])),
      constant(encode_cursor_payload(true)),
      constant(encode_cursor_payload("cursor")),
      map(one_of([integer(), boolean(), constant(nil)]), fn created_at ->
        encode_cursor_payload(%{"created_at" => created_at, "decision_id" => valid_decision_id})
      end),
      map(string(:alphanumeric, min_length: 1, max_length: 30), fn created_at ->
        encode_cursor_payload(%{"created_at" => created_at, "decision_id" => valid_decision_id})
      end),
      map(
        one_of([
          integer(),
          boolean(),
          constant(nil),
          constant(""),
          string(:alphanumeric, min_length: 257, max_length: 260)
        ]),
        fn decision_id ->
          encode_cursor_payload(%{"created_at" => valid_timestamp, "decision_id" => decision_id})
        end
      ),
      constant(encode_cursor_payload(%{"created_at" => valid_timestamp})),
      constant(encode_cursor_payload(%{"decision_id" => valid_decision_id}))
    ])
  end

  defp encode_cursor_payload(payload) do
    payload
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp audit_key(decision), do: {-DateTime.to_unix(decision.created_at, :microsecond), decision.decision_id}
end
