defmodule AiurWeb.OperatorControlCenter.RouteRegistryTest do
  use ExUnit.Case, async: true

  alias AiurWeb.OperatorControlCenter.{DecisionPath, RouteRegistry}

  test "declares live routes with one active-match policy each" do
    analytics = %{available?: true, path: "/analytics", message: "Open analytics."}

    assert Enum.map(RouteRegistry.routes(analytics), & &1.id) == [
             :units,
             :commands,
             :build_order,
             :analytics,
             :streamdeck
           ]

    assert {:ok, units} = RouteRegistry.route(:units, analytics)

    assert units == %{
             id: :units,
             label: "Units",
             icon: "◫",
             description: "",
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
    assert RouteRegistry.live?(analytics_route)
    assert RouteRegistry.available?(analytics_route)
    assert analytics_route.description == "Live run utilization."
    assert analytics_route.active_actions == [:analytics]
  end

  test "keeps Analytics always navigable so the live page owns its empty state" do
    analytics = %{available?: false, path: nil, message: "ignored now"}

    assert {:ok, route} = RouteRegistry.route(:analytics, analytics)
    assert RouteRegistry.available?(route)
    assert RouteRegistry.live?(route)
    assert route.path == "/analytics"
    assert route.owner == :analytics
    assert route.description == "Live run utilization."
  end

  test "keeps direct Decision URLs inside the Commands route" do
    assert {:ok, %{path: "/commands"}} = RouteRegistry.route(:commands, %{})
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
    assert RouteRegistry.navigation_mode(units, analytics_route) == :navigate
  end

  test "preserves shareable retained-page state without exposing it to non-All filters" do
    assert DecisionPath.inbox(:all, %{search: "AIUR-42", cursor: "opaque"}) ==
             "/commands?cursor=opaque&search=AIUR-42"

    assert DecisionPath.detail("dec /42", :blocking, %{cursor: "opaque"}) ==
             "/commands/dec%20%2F42?cursor=opaque&filter=blocking"

    assert DecisionPath.inbox(:all, %{search: "", ignored: "secret"}) == "/commands"
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

  test "registers Streamdeck+ as an always-available LiveView" do
    assert {:ok, streamdeck} = RouteRegistry.route(:streamdeck, %{})
    assert streamdeck.label == "Streamdeck+"
    assert streamdeck.description == "Stream Deck + control surface"
    assert streamdeck.path == "/streamdeck"
    assert streamdeck.owner == :streamdeck
    assert streamdeck.active_actions == [:streamdeck]
    assert RouteRegistry.available?(streamdeck)
    assert RouteRegistry.live?(streamdeck)
  end
end
