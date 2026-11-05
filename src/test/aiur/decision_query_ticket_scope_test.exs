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
