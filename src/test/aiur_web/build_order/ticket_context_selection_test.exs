defmodule AiurWeb.BuildOrder.TicketContextSelectionTest do
  use ExUnit.Case, async: true

  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.TicketContextSelection, as: Selection
  alias AiurWeb.BuildOrderViewModel
  alias AiurWeb.BuildOrderViewModel.Node

  test "opens, replaces in both directions, walks back, and closes with one root-qualified origin" do
    graph = model(100, 7, [1, 2, 3])
    events = Selection.event_names()

    assert events == %{
             replace: "build-order-context-replace",
             back: "build-order-context-back",
             close: "build-order-context-close"
           }

    state = Selection.open(Selection.new(), graph, navigation(graph, 2))
    origin = Selection.origin_id(graph, identity(2))

    assert state.status == :open
    assert state.selected == identity(2)
    assert state.history == []
    assert state.origin_id == origin
    assert String.starts_with?(origin, "build-order-card-")
    assert state.focus_revision == 1
    assert is_binary(state.request_token)

    first_token = state.request_token
    state = Selection.replace(state, graph, navigation(graph, 1))
    assert state.selected == identity(1)
    assert state.history == [identity(2)]
    assert state.origin_id == origin
    assert state.focus_revision == 2
    refute state.request_token == first_token

    state = Selection.replace(state, graph, navigation(graph, 3))
    assert state.selected == identity(3)
    assert state.history == [identity(1), identity(2)]

    state = Selection.back(state, graph)
    assert state.selected == identity(1)
    assert state.history == [identity(2)]
    assert state.origin_id == origin
    assert state.focus_revision == 4

    state = Selection.back(state, graph)
    assert state.selected == identity(2)
    assert state.history == []
    assert Selection.back(state, graph) == state

    closed = Selection.close(state)
    assert closed.status == :closed
    assert closed.selected == nil
    assert closed.history == []
    assert closed.origin_id == nil
    assert closed.request_token == nil
    assert Selection.close(closed) == closed
  end

  test "reconciles only a surviving exact member on a same-root generation" do
    original = model(100, 7, [1, 2, 3])

    state =
      Selection.new()
      |> Selection.open(original, navigation(original, 2))
      |> Selection.replace(original, navigation(original, 1))
      |> Selection.replace(original, navigation(original, 3))

    prior_token = state.request_token
    prior_focus = state.focus_revision
    next = model(100, 8, [2, 3, 4])
    reconciled = Selection.reconcile(state, next)

    assert reconciled.status == :open
    assert reconciled.selected == identity(3)
    assert reconciled.history == [identity(2)]
    assert reconciled.generation == 8
    assert reconciled.focus_revision == prior_focus
    refute reconciled.request_token == prior_token
    assert Selection.reconcile(reconciled, next) == reconciled

    removed = Selection.reconcile(reconciled, model(100, 9, [1, 2]))
    assert removed.status == :closed
    assert removed.selected == nil
  end

  test "root, generation, repository, and duplicate-member mismatches fail closed" do
    graph = model(100, 7, [1, 2])
    original_navigation = navigation(graph, 2)
    state = Selection.open(Selection.new(), graph, original_navigation)

    same_numbers_new_root = model(200, 8, [1, 2])
    assert Selection.reconcile(state, same_numbers_new_root).status == :closed
    refute navigation(same_numbers_new_root, 2) == original_navigation
    assert Selection.open(Selection.new(), same_numbers_new_root, original_navigation) == Selection.new()

    stale_generation = model(100, 8, [1, 2])
    refute navigation(stale_generation, 2) == original_navigation
    assert Selection.open(Selection.new(), stale_generation, original_navigation) == Selection.new()
    assert Selection.replace(state, stale_generation, navigation(stale_generation, 1)) == state

    foreign = identity(9, owner: "other", repository: "repo", provider_id: "FOREIGN")
    refute Selection.navigation_value(graph, foreign)
    refute Selection.origin_id(graph, foreign)
    assert Selection.open(Selection.new(), graph, "2") == Selection.new()
    assert Selection.open(Selection.new(), graph, "member-not-present") == Selection.new()

    duplicate = %{graph | nodes: [member_node(2), member_node(2)]}
    duplicate_value = Selection.navigation_value(graph, identity(2))
    assert Selection.open(Selection.new(), duplicate, duplicate_value) == Selection.new()

    malformed_node = %{member_node(2) | key: TrackerIdentity.github_key(identity(1))}
    malformed = %{graph | nodes: [malformed_node]}
    refute Selection.navigation_value(malformed, identity(2))
    assert Selection.open(Selection.new(), malformed, duplicate_value) == Selection.new()

    invalid_generation = %{graph | generations: %{planning: :unknown, activity: 1}}
    assert Selection.open(Selection.new(), invalid_generation, navigation(graph, 2)) == Selection.new()

    mismatched_generation = put_in(graph.root.generation, 6)
    refute Selection.navigation_value(mismatched_generation, identity(2))
    assert Selection.open(Selection.new(), mismatched_generation, original_navigation) == Selection.new()
  end

  test "rejects delayed completions after every token-changing transition and reconnect" do
    graph = model(100, 7, [1, 2])
    opened = Selection.open(Selection.new(), graph, navigation(graph, 1))
    open_token = opened.request_token

    assert Selection.current_completion?(opened, open_token, identity(1))
    refute Selection.current_completion?(opened, open_token, identity(2))
    refute Selection.current_completion?(opened, "request-forged", identity(1))

    replaced = Selection.replace(opened, graph, navigation(graph, 2))
    refute Selection.current_completion?(replaced, open_token, identity(1))
    assert Selection.current_completion?(replaced, replaced.request_token, identity(2))

    backed = Selection.back(replaced, graph)
    refute Selection.current_completion?(backed, replaced.request_token, identity(2))

    reconciled = Selection.reconcile(backed, model(100, 8, [1, 2]))
    refute Selection.current_completion?(reconciled, backed.request_token, identity(1))

    reconnected = Selection.reconnect(reconciled)
    assert reconnected.status == :closed
    refute Selection.current_completion?(reconnected, reconciled.request_token, identity(1))
    assert Selection.reconnect(reconnected) == reconnected

    current_graph = model(100, 8, [1, 2])
    reopened = Selection.open(reconnected, current_graph, navigation(current_graph, 1))
    assert reopened.status == :open
    assert reopened.selected == identity(1)
    refute reopened.request_token == reconciled.request_token
  end

  test "caps replacement history to the graph member bound" do
    graph = model(100, 7, [1, 2])
    state = Selection.open(Selection.new(), graph, navigation(graph, 1))

    state =
      Enum.reduce(1..240, state, fn index, current ->
        target = if rem(index, 2) == 0, do: 1, else: 2
        Selection.replace(current, graph, navigation(graph, target))
      end)

    assert length(state.history) == Selection.max_history()
    assert Selection.max_history() == 100
    assert Enum.all?(state.history, &(&1 in [identity(1), identity(2)]))
  end

  defp model(root_number, generation, members) do
    root = identity(root_number)

    %BuildOrderViewModel{
      status: :ready,
      root: %{identity: root, generation: generation},
      nodes: Enum.map(members, &member_node/1),
      generations: %{planning: generation, activity: 1}
    }
  end

  defp member_node(number) do
    identity = identity(number)

    %Node{
      key: TrackerIdentity.github_key(identity),
      identity: identity,
      title: "Ticket #{number}",
      plan: %{},
      execution: %{},
      activity: %{},
      readiness: :ready,
      lane_icon: nil,
      status_icon: nil,
      health: %{},
      observed_at: %{},
      provenance: %{},
      card: %{}
    }
  end

  defp navigation(graph, number), do: Selection.navigation_value(graph, identity(number))

  defp identity(number, overrides \\ []) do
    struct!(
      TrackerIdentity,
      Keyword.merge(
        [
          status: :joinable,
          kind: :github,
          owner: "owner",
          repository: "repo",
          provider_id: "ISSUE-#{number}",
          identifier: to_string(number),
          reason: nil
        ],
        overrides
      )
    )
  end
end
