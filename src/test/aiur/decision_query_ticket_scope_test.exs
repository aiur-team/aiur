defmodule Aiur.DecisionQueryTicketScopeTest do
  use ExUnit.Case, async: false

  alias Aiur.{DecisionQuery, DecisionStore}

  @source %{agent_id: "agent-1", session_id: "session-1", event_id: nil}
  @now ~U[2026-11-05 12:00:00Z]

  setup_all do: :ok = Aiur.TestSupport.ensure_runtime_children_running()

  setup do
    original_override = Application.get_env(:aiur, :decision_state_dir)
    dir = Aiur.TestSupport.tmp_root!("aiur-query-ticket-scope")
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

    %{store: store}
  end

  test "list_scoped returns only the allowed tickets and scoped counts", %{store: store} do
    _allowed = request!(store, "42", "allowed")
    _other = request!(store, "99", "hidden")

    assert {:ok, page} = DecisionQuery.list_scoped(%{}, MapSet.new(["42"]), store: store)

    assert [decision] = page.decisions
    assert decision.ticket.identifier == "42"
    assert page.pagination.total == 1

    # Fleet-wide counts are withheld from a scoped read.
    assert page.counts.total == nil
  end

  test "an empty ticket set can see nothing", %{store: store} do
    _allowed = request!(store, "42", "allowed")

    assert {:ok, page} = DecisionQuery.list_scoped(%{}, MapSet.new(), store: store)
    assert page.decisions == []
    assert page.pagination.total == 0
  end

  test "an out-of-scope ticket filter is empty instead of revealing the Command", %{store: store} do
    _allowed = request!(store, "42", "allowed")
    other = request!(store, "99", "hidden")

    assert {:ok, page} = DecisionQuery.list_scoped(%{"ticket" => "99"}, MapSet.new(["42"]), store: store)
    assert page.decisions == []
    assert page.pagination.total == 0

    # The unscoped query still returns it: only the scope hides it.
    assert {:ok, unscoped} = DecisionQuery.list(%{"ticket" => "99"}, store: store)
    assert [found] = unscoped.decisions
    assert found.decision_id == other.decision_id
  end

  test "the scope follows lifecycle filters and cursors", %{store: store} do
    _allowed = request!(store, "42", "allowed")
    _other = request!(store, "99", "hidden")

    assert {:ok, page} = DecisionQuery.list_scoped(%{"lifecycle" => "open", "limit" => "1"}, MapSet.new(["42"]), store: store)
    assert [decision] = page.decisions
    assert decision.ticket.identifier == "42"
    assert page.pagination.next_cursor == nil
  end

  test "ticket identifiers match case-insensitively like the rest of the query", %{store: store} do
    _allowed = request!(store, "GAME-7", "allowed")

    assert {:ok, page} = DecisionQuery.list_scoped(%{}, ["game-7"], store: store)
    assert [decision] = page.decisions
    assert decision.ticket.identifier == "GAME-7"
  end

  test "list filters by a label scope and hides unlabelled Commands", %{store: store} do
    labelled = request!(store, "42", "labelled")
    _unlabelled = request!(store, "99", "unlabelled")

    labels_fun = fn -> {:ok, %{"42" => %{labels: ["game:chess"]}, "99" => %{labels: ["game:checkers"]}}, 0} end

    assert {:ok, page} = DecisionQuery.list(%{"labels" => "game:chess"}, store: store, labels_fun: labels_fun)

    assert [decision] = page.decisions
    assert decision.decision_id == labelled.decision_id
    assert decision.ticket.identifier == "42"
    assert page.pagination.total == 1
    assert page.filters.labels == ["game:chess"]
    assert page.counts.total == nil
    Aiur.TestSupport.refute_leak(page, "unlabelled")
  end

  test "an out-of-label ticket filter is empty instead of revealing the Command", %{store: store} do
    _labelled = request!(store, "42", "labelled")
    _other = request!(store, "99", "unlabelled")

    labels_fun = fn -> {:ok, %{"42" => %{labels: ["game:chess"]}, "99" => %{labels: ["game:checkers"]}}, 0} end

    assert {:ok, page} = DecisionQuery.list(%{"labels" => ["game:chess"], "ticket" => "99"}, store: store, labels_fun: labels_fun)
    assert page.decisions == []
    assert page.pagination.total == 0
  end

  test "a label scope with no usable observation sees nothing", %{store: store} do
    _labelled = request!(store, "42", "labelled")

    assert {:ok, page} = DecisionQuery.list(%{"labels" => "game:chess"}, store: store, labels_fun: fn -> :none end)
    assert page.decisions == []
    assert page.pagination.total == 0

    assert {:ok, page} =
             DecisionQuery.list_scoped(%{"labels" => "game:chess"}, MapSet.new(), store: store, labels_fun: fn -> {:error, :unsupported} end)

    assert page.decisions == []
    assert page.pagination.total == 0
  end

  test "list_scoped narrows explicit tickets with the request label scope and never widens them", %{store: store} do
    explicit = request!(store, "7", "explicit")
    labelled = request!(store, "42", "labelled")
    _outside = request!(store, "99", "outside")

    labels_fun = fn -> {:ok, %{"42" => %{labels: ["game:chess"]}, "99" => %{labels: ["game:other"]}}, 0} end

    assert {:ok, page} =
             DecisionQuery.list_scoped(%{"labels" => "game:chess"}, MapSet.new(["7", "42"]), store: store, labels_fun: labels_fun)

    assert Enum.map(page.decisions, & &1.decision_id) == [labelled.decision_id]
    refute Enum.any?(page.decisions, &(&1.decision_id == explicit.decision_id))
    assert page.counts.total == nil

    # A request label outside the explicit set cannot pull its ticket in.
    assert {:ok, outside_page} =
             DecisionQuery.list_scoped(%{"labels" => "game:other"}, MapSet.new(["7", "42"]), store: store, labels_fun: labels_fun)

    assert outside_page.decisions == []
    assert outside_page.pagination.total == 0
  end

  test "a malformed label is rejected" do
    assert {:error, {:invalid_query, {:labels, _}}} = DecisionQuery.list(%{"labels" => "game chess"})
    assert {:error, {:invalid_query, {:labels, _}}} = DecisionQuery.list(%{"labels" => "nocolon"})
  end

  defp request!(store, ticket, source_id) do
    payload = %{
      "source_id" => source_id,
      "question" => "What should we do about #{source_id}?",
      "blocking" => true,
      "kind" => "architecture",
      "authority" => "supervisor_allowed",
      "reversibility" => "reversible"
    }

    ticket_map = %{identifier: ticket, title: "Ticket #{ticket}", url: "https://example.test/issues/#{ticket}"}

    assert {:ok, %{decision: decision}} =
             DecisionStore.request(payload, [ticket: ticket_map, source: @source, now: @now], store)

    decision
  end
end
