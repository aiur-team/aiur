defmodule Aiur.DecisionQueryLifecycleTest do
  use ExUnit.Case, async: false

  use ExUnitProperties

  alias Aiur.{DecisionQuery, DecisionStore, DecisionValidation}

  alias Aiur.DecisionStore.RetainedSnapshot

  @ticket %{identifier: "1088", title: "Retained Decisions", url: "https://example.test/issues/1088"}

  @source %{agent_id: "agent-1088", session_id: "session-private", event_id: nil}

  setup do
    original_override = Application.get_env(:aiur, :decision_state_dir)
    dir = Aiur.TestSupport.tmp_root!("aiur-decision-query")
    Application.put_env(:aiur, :decision_state_dir, dir)

    {:ok, store} = DecisionStore.start_link(name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(store)

      case original_override do
        nil -> Application.delete_env(:aiur, :decision_state_dir)
        value -> Application.put_env(:aiur, :decision_state_dir, value)
      end

      Aiur.TestCleanup.rm_rf!(dir)
    end)

    %{store: store, dir: dir}
  end

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

    assert_receive {:atomic_snapshot, :lookup}, 1000
    assert_receive {:atomic_snapshot, :query}, 1000
    assert_receive {:atomic_snapshot, :counts}, 1000
    assert_receive {:atomic_snapshot, :counts}, 1000
    refute_receive {:split_read_attempted, _request}, 100
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
      refute_receive {:atomic_snapshot, :query}, 100
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
