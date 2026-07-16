defmodule AiurWeb.OperatorControlCenter.RouteRegistry do
  @moduledoc false

  @routes [
    %{
      id: :units,
      label: "Units",
      icon: "◫",
      description: "Current Executor activity and durable outcomes.",
      path: "/",
      type: :live,
      availability: :available,
      active_actions: [:index]
    },
    %{
      id: :commands,
      label: "Commands",
      icon: "⌘",
      description: "Recorded Commands that need review or follow-up.",
      path: "/decisions",
      type: :live,
      availability: :available,
      active_actions: [:decisions, :decision]
    },
    %{
      id: :build_order,
      label: "Build Order",
      icon: "◌",
      description: "Build Order is unavailable until its route is registered.",
      path: "/build-orders",
      type: :live,
      availability: :unavailable,
      active_actions: []
    },
    %{
      id: :analytics,
      label: "Analytics",
      icon: "↗",
      description: "Telemetry analytics are unavailable.",
      path: "/analytics",
      type: :document,
      availability: :unavailable,
      active_actions: []
    }
  ]

  @spec routes(map()) :: [map()]
  def routes(analytics) when is_map(analytics) do
    Enum.map(@routes, &resolve_runtime_availability(&1, analytics))
  end

  @spec route(atom(), map()) :: {:ok, map()} | :error
  def route(id, analytics) when is_atom(id) and is_map(analytics) do
    case Enum.find(routes(analytics), &(&1.id == id)) do
      nil -> :error
      route -> {:ok, route}
    end
  end

  @spec current_route(atom() | nil) :: map()
  def current_route(action) do
    Enum.find(@routes, &active?(&1, action)) || hd(@routes)
  end

  @spec active?(map(), atom() | nil) :: boolean()
  def active?(route, action) when is_map(route), do: action in route.active_actions

  @spec available?(map()) :: boolean()
  def available?(route) when is_map(route), do: route.availability == :available

  @spec live?(map()) :: boolean()
  def live?(route) when is_map(route), do: route.type == :live

  @spec document?(map()) :: boolean()
  def document?(route) when is_map(route), do: route.type == :document

  defp resolve_runtime_availability(%{id: :analytics} = route, analytics) do
    route
    |> Map.put(:availability, analytics_availability(analytics))
    |> Map.put(:description, Map.get(analytics, :message) || route.description)
  end

  defp resolve_runtime_availability(route, _analytics), do: route

  defp analytics_availability(%{available?: true}), do: :available
  defp analytics_availability(_analytics), do: :unavailable
end
