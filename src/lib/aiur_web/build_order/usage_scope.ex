defmodule AiurWeb.BuildOrder.UsageScope do
  @moduledoc """
  Pure derivation of the selected Build Order's `this build` usage scope and a
  generation-safe membership key from BO-012 route state and the BO-003 selected
  member graph.

  Membership authority is the current complete GitHub member set (never labels,
  prose, phase/lane, visible nodes, or issue-number adjacency); each member
  contributes its repository-qualified `Aiur.TrackerIdentity`. The scope is the
  exact current member set, so retained usage recorded before a ticket joined is
  included and a removed/non-member ticket is excluded on the next complete
  membership generation — both fall out of matching cells by repository-qualified
  ticket key, with no joined-at cutoff.

  `this build` (`:explicit_ticket_set`) and `this run` (`:this_run`) can never
  share a cache key because the scope `kind` is part of `Scope.public/1`, which is
  half of the membership key.

  The membership key is deliberately built from the member *identity set* plus the
  authority epoch, not from `Snapshot.generation`: the graph projection advances
  `generation` on every successful poll regardless of whether membership changed,
  so keying on it would churn the cache and defeat coalescing. The repository-
  qualified ticket keys inside `Scope.public/1` already discriminate every member
  add/remove exactly. The accounting (usage-aggregate) generation is folded in by
  the caller at fetch time.
  """

  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.BuildOrder.SelectedRoot
  alias Aiur.TrackerIdentity
  alias Aiur.Usage.GroupedScopes.Scope
  alias AiurWeb.BuildOrder.RouteState

  @typedoc "Content-free membership key: `{Scope.public/1, authority_epoch}`."
  @type membership_key :: {map(), term()}

  @typedoc "The scope-level decision for the selected Build Order usage region."
  @type decision ::
          :none
          | :pending
          | {:invalid, RouteState.status()}
          | {:unavailable, atom()}
          | :empty_build
          | {:unscopable, non_neg_integer()}
          | {:ready, Scope.t(), membership_key(), :ready | :stale}

  @doc """
  Derive the current scope-level decision from the validated route state.

  Total over `RouteState.status/1`; a `:ready`/`:stale` decision carries the
  explicit-ticket-set scope, its membership key, and the graph health so the
  caller can annotate a stale (last-known-good) member set without confusing it
  with zero.
  """
  @spec decide(RouteState.t()) :: decision()
  def decide(%RouteState{} = route_state) do
    case RouteState.status(route_state) do
      :catalog -> :none
      :invalid_parameter -> {:invalid, :invalid_parameter}
      :not_found -> {:invalid, :not_found}
      :invalid_catalog -> {:invalid, :invalid_catalog}
      :selected_invalid -> {:invalid, :selected_invalid}
      :awaiting_catalog -> :pending
      :selected_loading -> :pending
      :catalog_unavailable -> {:unavailable, :catalog_unavailable}
      :selected_unavailable -> {:unavailable, :selected_unavailable}
      # A stale catalog is a usable stale member graph only once a selected root
      # has resolved; otherwise the membership itself is unavailable.
      :catalog_stale -> from_members(route_state, :stale, {:unavailable, :catalog_stale})
      :selected_stale -> from_members(route_state, :stale)
      :selected -> from_members(route_state, :ready)
      other -> {:invalid, other}
    end
  end

  defp from_members(route_state, graph_health, no_root \\ :pending) do
    case selected_root(route_state) do
      %SelectedRoot{members: members} ->
        identities = member_identities(members)
        {:ok, scope} = Scope.explicit_ticket_set(identities)

        cond do
          members == [] -> :empty_build
          not Scope.selectable?(scope) -> {:unscopable, scope.rejected_tickets}
          true -> {:ready, scope, membership_key(scope, route_state), graph_health}
        end

      _none ->
        no_root
    end
  end

  defp selected_root(route_state) do
    case {RouteState.selected_identity(route_state), RouteState.selected_snapshot(route_state)} do
      {%TrackerIdentity{}, %Snapshot{data: %SelectedRoot{} = selected}} -> selected
      _no_selected_root -> nil
    end
  end

  # Every member contributes its opaque repository-qualified identity; a member
  # with a missing identity is dropped here and surfaces as a rejected ticket via
  # `Scope.explicit_ticket_set/1`, never coerced into a bare-number key.
  defp member_identities(members) do
    Enum.flat_map(members, fn member ->
      case member.identity do
        %TrackerIdentity{} = identity -> [identity]
        _no_identity -> []
      end
    end)
  end

  defp membership_key(scope, route_state) do
    {Scope.public(scope), authority_epoch(route_state)}
  end

  defp authority_epoch(route_state) do
    case RouteState.selected_snapshot(route_state) do
      %Snapshot{authority_epoch: epoch} -> epoch
      _no_snapshot -> :unknown
    end
  end
end
