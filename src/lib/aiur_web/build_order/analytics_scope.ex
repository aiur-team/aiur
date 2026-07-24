defmodule AiurWeb.BuildOrder.AnalyticsScope do
  @moduledoc """
  Pure derivation of the selected Build Order's telemetry scope from route state.

  Membership authority is the same one `AiurWeb.BuildOrder.UsageScope` uses: the
  current complete GitHub member set, never labels, prose, phase/lane, or visible
  nodes. Because membership is re-derived live, a ticket that joins the Build
  Order later retroactively contributes the telemetry it already wrote, and a
  removed ticket drops out on the next complete membership generation.

  The join key is the member's display identifier. Run telemetry records a bare
  ticket-number string (`Aiur.RunTelemetry.Lifecycle` reads it off the
  `ticket.<n>.*` topic; the sampler writes actor `"ticket:<n>"`), so it carries no
  repository qualification. Aiur runs against one configured repository, so the
  join is sound — but a member whose identity is not joinable is counted as
  rejected rather than coerced into a bare-number key, which is what keeps this
  honest if the telemetry stream ever spans repositories.

  Decision values mirror `UsageScope` so the analytics pane can render the same
  degraded states as the rest of the Build Order page.
  """

  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.BuildOrder.SelectedRoot
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.RouteState

  @typedoc "Content-free membership key: the sorted member number set plus the authority epoch."
  @type membership_key :: {[String.t()], term()}

  @typedoc "The resolved telemetry scope for one Build Order."
  @type scope :: %{tickets: MapSet.t(String.t()), total: non_neg_integer(), rejected: non_neg_integer()}

  @type decision ::
          :none
          | :pending
          | {:invalid, RouteState.status()}
          | {:unavailable, atom()}
          | :empty_build
          | {:unscopable, non_neg_integer()}
          | {:ready, scope(), membership_key(), :ready | :stale}

  @invalid_statuses [:invalid_parameter, :not_found, :invalid_catalog, :selected_invalid]
  @pending_statuses [:awaiting_catalog, :selected_loading]
  @unavailable_statuses [:catalog_unavailable, :selected_unavailable]

  @doc """
  Derives the current scope-level decision from the validated route state.

  Total over `RouteState.status/1`. A `:ready` decision carries the member ticket
  set, its membership key, and the graph health so a stale (last-known-good)
  member set can be annotated rather than confused with an empty build.
  """
  @spec decide(RouteState.t()) :: decision()
  def decide(%RouteState{} = route_state) do
    case RouteState.status(route_state) do
      :catalog -> :none
      status when status in @invalid_statuses -> {:invalid, status}
      status when status in @pending_statuses -> :pending
      status when status in @unavailable_statuses -> {:unavailable, status}
      # A stale catalog is a usable stale member graph only once a selected root
      # has resolved; otherwise the membership itself is unavailable.
      :catalog_stale -> from_members(route_state, :stale, {:unavailable, :catalog_stale})
      :selected_stale -> from_members(route_state, :stale)
      :selected -> from_members(route_state, :ready)
    end
  end

  defp from_members(route_state, graph_health, no_root \\ :pending) do
    case selected_root(route_state) do
      %SelectedRoot{members: members} -> scope_decision(members, route_state, graph_health)
      _none -> no_root
    end
  end

  defp scope_decision([], _route_state, _graph_health), do: :empty_build

  defp scope_decision(members, route_state, graph_health) do
    numbers = member_numbers(members)
    rejected = length(members) - length(numbers)

    if numbers == [] do
      {:unscopable, rejected}
    else
      scope = %{tickets: MapSet.new(numbers), total: length(members), rejected: rejected}
      {:ready, scope, {Enum.sort(numbers), authority_epoch(route_state)}, graph_health}
    end
  end

  defp selected_root(route_state) do
    case {RouteState.selected_identity(route_state), RouteState.selected_snapshot(route_state)} do
      {%TrackerIdentity{}, %Snapshot{data: %SelectedRoot{} = selected}} -> selected
      _no_selected_root -> nil
    end
  end

  defp member_numbers(members) do
    Enum.flat_map(members, &member_number/1)
  end

  defp member_number(%{identity: %TrackerIdentity{identifier: identifier} = identity}) when is_binary(identifier),
    do: if(TrackerIdentity.joinable?(identity), do: [identifier], else: [])

  defp member_number(_member), do: []

  defp authority_epoch(route_state) do
    case RouteState.selected_snapshot(route_state) do
      %Snapshot{authority_epoch: epoch} -> epoch
      _no_snapshot -> :unknown
    end
  end
end
