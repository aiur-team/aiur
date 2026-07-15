defmodule AiurWeb.OperatorControlCenter.RouteRegistryTest do
  use ExUnit.Case, async: true

  alias AiurWeb.OperatorControlCenter.RouteRegistry

  test "declares live and document routes with one active-match policy each" do
    assert Enum.map(RouteRegistry.routes(), & &1.id) == [:units, :commands, :build_order, :analytics]

    assert {:ok, units} = RouteRegistry.route(:units)
    assert units == %{id: :units, label: "Units", icon: "◫", description: "Current Executor activity and durable outcomes.", path: "/", type: :live, availability: :available, active_actions: [:index]}
    assert RouteRegistry.live?(units)
    assert RouteRegistry.available?(units)
    assert RouteRegistry.active?(units, :index)
    refute RouteRegistry.active?(units, :decisions)

    assert {:ok, analytics} = RouteRegistry.route(:analytics)
    assert RouteRegistry.document?(analytics)
    assert RouteRegistry.available?(analytics)
    assert analytics.active_actions == []
  end

  test "keeps direct Decision URLs inside the Commands route" do
    assert %{id: :commands} = RouteRegistry.current_route(:decisions)
    assert %{id: :commands} = RouteRegistry.current_route(:decision)
    assert %{id: :units} = RouteRegistry.current_route(:unknown)
  end

  test "makes the future Build Order destination named but non-navigable" do
    assert {:ok, build_order} = RouteRegistry.route(:build_order)
    assert build_order.path == "/build-orders"
    assert build_order.availability == :unavailable
    refute RouteRegistry.available?(build_order)
    refute RouteRegistry.active?(build_order, :index)
  end
end
