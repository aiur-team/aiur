defmodule AiurWeb.OperatorControlCenter.RouteRegistryTest do
  use ExUnit.Case, async: true

  alias AiurWeb.OperatorControlCenter.{DecisionPath, RouteRegistry}

  test "declares live and document routes with one active-match policy each" do
    analytics = %{available?: true, path: "/analytics", message: "Open analytics."}

    assert Enum.map(RouteRegistry.routes(analytics), & &1.id) == [
             :units,
             :commands,
             :build_order,
             :analytics
           ]

    assert {:ok, units} = RouteRegistry.route(:units, analytics)

    assert units == %{
             id: :units,
             label: "Units",
             icon: "◫",
             description: "Current Executor activity and durable outcomes.",
             path: "/",
             type: :live,
             owner: :dashboard,
             availability: :available,
             active_actions: [:index]
           }

    assert RouteRegistry.live?(units)
    assert RouteRegistry.available?(units)
    assert RouteRegistry.active?(units, :index)
    refute RouteRegistry.active?(units, :decisions)

    assert {:ok, analytics_route} = RouteRegistry.route(:analytics, analytics)
    assert RouteRegistry.document?(analytics_route)
    assert RouteRegistry.available?(analytics_route)
    assert analytics_route.description == "Open analytics."
    assert analytics_route.active_actions == []
  end

  test "keeps Analytics named but non-navigable when telemetry is unavailable" do
    analytics = %{available?: false, path: nil, message: "Run with debug telemetry first."}

    assert {:ok, route} = RouteRegistry.route(:analytics, analytics)
    refute RouteRegistry.available?(route)
    assert route.path == "/analytics"
    assert route.description == "Run with debug telemetry first."
  end

  test "keeps direct Decision URLs inside the Commands route" do
    assert %{id: :commands} = RouteRegistry.current_route(:decisions)
    assert %{id: :commands} = RouteRegistry.current_route(:decision)
    assert %{id: :units} = RouteRegistry.current_route(:unknown)
  end

  test "uses patches only within one LiveView owner" do
    analytics = %{available?: true}
    {:ok, units} = RouteRegistry.route(:units, analytics)
    {:ok, commands} = RouteRegistry.route(:commands, analytics)
    {:ok, build_order} = RouteRegistry.route(:build_order, analytics)
    {:ok, analytics_route} = RouteRegistry.route(:analytics, analytics)

    assert RouteRegistry.navigation_mode(units, commands) == :patch
    assert RouteRegistry.navigation_mode(build_order, build_order) == :patch
    assert RouteRegistry.navigation_mode(units, build_order) == :navigate
    assert RouteRegistry.navigation_mode(build_order, units) == :navigate
    assert RouteRegistry.navigation_mode(units, analytics_route) == :document
  end

  test "preserves shareable retained-page state without exposing it to non-All filters" do
    assert DecisionPath.inbox(:all, %{search: "AIUR-42", cursor: "opaque"}) ==
             "/decisions?cursor=opaque&search=AIUR-42"

    assert DecisionPath.detail("dec /42", :blocking, %{cursor: "opaque"}) ==
             "/decisions/dec%20%2F42?cursor=opaque&filter=blocking"

    assert DecisionPath.inbox(:all, %{search: "", ignored: "secret"}) == "/decisions"
  end

  test "registers the Build Order catalog and selected actions as one live owner" do
    assert {:ok, build_order} = RouteRegistry.route(:build_order, %{})
    assert build_order.path == "/build-orders"
    assert build_order.availability == :available
    assert build_order.owner == :build_order
    assert build_order.active_actions == [:build_orders, :build_order]
    assert RouteRegistry.available?(build_order)
    assert RouteRegistry.active?(build_order, :build_orders)
    assert RouteRegistry.active?(build_order, :build_order)
  end
end
