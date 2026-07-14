defmodule Aiur.DecisionQueryTest do
  use ExUnit.Case, async: false

  alias Aiur.{DecisionQuery, DecisionStore}

  @ticket %{identifier: "1088", title: "Retained Decisions", url: "https://example.test/issues/1088"}
  @source %{agent_id: "agent-1088", session_id: "session-private", event_id: nil}

  setup do
    original_override = Application.get_env(:aiur, :decision_state_dir)
    dir = Path.join(System.tmp_dir!(), "aiur-decision-query-#{System.unique_integer([:positive])}")
    Application.put_env(:aiur, :decision_state_dir, dir)

    {:ok, store} = DecisionStore.start_link(name: nil, filesystem_sync_fun: fn -> :ok end)

    on_exit(fn ->
      if Process.alive?(store), do: GenServer.stop(store)

      case original_override do
        nil -> Application.delete_env(:aiur, :decision_state_dir)
        value -> Application.put_env(:aiur, :decision_state_dir, value)
      end

      File.rm_rf!(dir)
    end)

    %{store: store}
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

    assert {:ok, page_two} = DecisionQuery.list(%{"limit" => 1, "cursor" => page_one.pagination.next_cursor}, store: store)
    assert [next] = page_two.decisions
    assert next.decision_id == second.decision_id

    assert {:ok, page_three} = DecisionQuery.list(%{"limit" => 1, "cursor" => page_two.pagination.next_cursor}, store: store)
    assert [oldest] = page_three.decisions
    assert oldest.decision_id == first.decision_id
    assert MapSet.size(MapSet.new([newest.decision_id, next.decision_id, oldest.decision_id])) == 3
  end

  test "query filters search only retained identifiers and tickets, and counts use all retained Decisions", %{store: store} do
    open = request!(store, "open", ~U[2026-07-13 08:00:00Z], blocking: true)
    resolved = request!(store, "resolved", ~U[2026-07-13 08:01:00Z], blocking: true)

    :sys.replace_state(store, fn state ->
      current = Map.fetch!(state.current, resolved.decision_id)
      %{state | current: Map.put(state.current, resolved.decision_id, %{current | decision_status: :resolved})}
    end)

    assert {:ok, %{decisions: [open_row], filters: %{lifecycle: :open}}} =
             DecisionQuery.list(%{"lifecycle" => "open", "ticket" => "1088"}, store: store)

    assert open_row.decision_id == open.decision_id

    search = String.slice(open.decision_id, 0, 12)
    assert {:ok, %{decisions: [search_row]}} = DecisionQuery.list(%{"search" => search}, store: store)
    assert search_row.decision_id == open.decision_id

    assert {:ok, %{open: 1, blocking: 1, scope: %{label: "All retained decisions"}}} = DecisionQuery.counts(store: store)
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
          %{"unknown" => "ignored"},
          %{"limit" => 1, limit: 2}
        ] do
      assert {:error, {:invalid_query, _reason}} = DecisionQuery.list(params, store: store)
    end

    assert {:error, {:invalid_decision_id, :malformed}} = DecisionQuery.get(<<255>>, store: store)
  end

  test "counts distinguish partial retained data from an unavailable store", %{store: store} do
    request!(store, "partial", ~U[2026-07-13 08:00:00Z])

    :sys.replace_state(store, &Map.put(&1, :health, {:corrupt, 1, :invalid_record}))

    assert {:ok, %{open: 1, health: %{status: :partial, partial?: true, reason: :retained_store_partial}}} =
             DecisionQuery.counts(store: store)

    assert {:ok, %{open: nil, blocking: nil, health: %{status: :unavailable, partial?: true}}} =
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

  defp request!(store, source_id, now, attrs \\ []) do
    payload = %{
      "source_id" => source_id,
      "question" => "Should #{source_id} ship?",
      "blocking" => Keyword.get(attrs, :blocking, false),
      "urgency" => "normal",
      "reversibility" => "reversible"
    }

    assert {:ok, %{decision: decision}} =
             DecisionStore.request(payload, [ticket: @ticket, source: @source, now: now], store)

    decision
  end
end
