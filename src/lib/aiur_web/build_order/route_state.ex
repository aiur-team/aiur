defmodule AiurWeb.BuildOrder.RouteState do
  @moduledoc """
  Owns canonical Build Order URL selection and projection generation checks.

  The issue number in the URL is only a locator. A selected projection is not
  activated until that locator resolves to exactly one repository-qualified,
  opaque tracker identity from the catalog (including a stale last-known-good
  catalog).
  """

  alias Aiur.BuildOrder.{Bounded, Catalog, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.TrackerIdentity

  @type status ::
          :catalog
          | :invalid_parameter
          | :awaiting_catalog
          | :catalog_unavailable
          | :catalog_stale
          | :not_found
          | :invalid_catalog
          | :selected_loading
          | :selected_unavailable
          | :selected_stale
          | :selected_invalid
          | :selected

  @type effect :: {:activate, TrackerIdentity.t()} | {:deactivate, TrackerIdentity.t()}

  @type t :: %__MODULE__{
          request_epoch: term(),
          revision: non_neg_integer(),
          route: :catalog | :selected,
          requested_identifier: String.t() | nil,
          catalog_snapshot: Snapshot.t() | nil,
          selected_identity: TrackerIdentity.t() | nil,
          selected_snapshot: Snapshot.t() | nil,
          status: status(),
          dom_generation: non_neg_integer()
        }

  @enforce_keys [:request_epoch]
  defstruct request_epoch: nil,
            revision: 0,
            route: :catalog,
            requested_identifier: nil,
            catalog_snapshot: nil,
            selected_identity: nil,
            selected_snapshot: nil,
            status: :catalog,
            dom_generation: 0

  @spec new(term()) :: t()
  def new(request_epoch), do: %__MODULE__{request_epoch: request_epoch}

  @spec parse_root(term()) :: {:ok, String.t()} | :error
  def parse_root(value), do: Bounded.github_issue_identifier(value)

  @spec navigate(t(), term()) :: {t(), [effect()]}
  def navigate(%__MODULE__{} = state, nil), do: navigate_catalog(state)

  def navigate(%__MODULE__{} = state, raw_identifier) do
    case parse_root(raw_identifier) do
      {:ok, identifier} -> navigate_selected(state, identifier)
      :error -> navigate_invalid(state)
    end
  end

  @spec put_catalog(t(), term()) :: {t(), [effect()]}
  def put_catalog(%__MODULE__{} = state, %Snapshot{scope: :catalog} = snapshot) do
    case catalog_update(state.catalog_snapshot, snapshot) do
      {:ok, snapshot} -> state |> Map.put(:catalog_snapshot, snapshot) |> resolve_selected()
      :ignored -> {state, []}
    end
  end

  def put_catalog(%__MODULE__{} = state, _snapshot), do: {state, []}

  @spec put_selected(t(), term()) :: {t(), :generation | :health | :ignored}
  def put_selected(%__MODULE__{} = state, %Snapshot{} = snapshot) do
    with true <- selected_snapshot_for_state?(snapshot, state),
         {:ok, update_kind, snapshot} <- selected_update(state.selected_snapshot, snapshot) do
      dom_generation =
        if update_kind == :generation and not is_nil(snapshot.data),
          do: state.dom_generation + 1,
          else: state.dom_generation

      state = %{
        state
        | selected_snapshot: snapshot,
          status: selected_status(snapshot),
          dom_generation: dom_generation
      }

      {state, update_kind}
    else
      _ -> {state, :ignored}
    end
  end

  def put_selected(%__MODULE__{} = state, _snapshot), do: {state, :ignored}

  @doc "Marks an exact selected scope unavailable when its initial demand cannot be served."
  @spec demand_failed(t(), term()) :: t()
  def demand_failed(
        %__MODULE__{selected_identity: %TrackerIdentity{} = selected, selected_snapshot: nil} = state,
        %TrackerIdentity{} = identity
      ) do
    if same_identity?(selected, identity), do: %{state | status: :selected_unavailable}, else: state
  end

  def demand_failed(%__MODULE__{} = state, _identity), do: state

  @spec reset(t()) :: {t(), [effect()]}
  def reset(%__MODULE__{} = state) do
    effects = deactivate_effect(state.selected_identity)

    status =
      case state.route do
        :catalog -> :catalog
        :selected when is_binary(state.requested_identifier) -> :awaiting_catalog
        :selected -> :invalid_parameter
      end

    {%{
       state
       | revision: state.revision + 1,
         catalog_snapshot: nil,
         selected_identity: nil,
         selected_snapshot: nil,
         status: status,
         dom_generation: 0
     }, effects}
  end

  @spec async_token(t(), term()) :: tuple()
  def async_token(%__MODULE__{} = state, kind) do
    {
      state.request_epoch,
      state.revision,
      identity_key(state.selected_identity),
      snapshot_generation(state.selected_snapshot),
      kind
    }
  end

  @spec current_async?(t(), term(), term()) :: boolean()
  def current_async?(%__MODULE__{} = state, token, kind), do: token == async_token(state, kind)

  @spec status(t()) :: status()
  def status(%__MODULE__{status: status}), do: status

  @spec route(t()) :: :catalog | :selected
  def route(%__MODULE__{route: route}), do: route

  @spec root_identifier(t()) :: String.t() | nil
  def root_identifier(%__MODULE__{requested_identifier: identifier}), do: identifier

  @spec catalog_snapshot(t()) :: Snapshot.t() | nil
  def catalog_snapshot(%__MODULE__{catalog_snapshot: snapshot}), do: snapshot

  @spec selected_identity(t()) :: TrackerIdentity.t() | nil
  def selected_identity(%__MODULE__{selected_identity: identity}), do: identity

  @spec selected_snapshot(t()) :: Snapshot.t() | nil
  def selected_snapshot(%__MODULE__{selected_snapshot: snapshot}), do: snapshot

  @spec dom_generation(t()) :: non_neg_integer()
  def dom_generation(%__MODULE__{dom_generation: generation}), do: generation

  defp navigate_catalog(state) do
    effects = deactivate_effect(state.selected_identity)

    {%{
       state
       | revision: changed_revision(state, state.route != :catalog),
         route: :catalog,
         requested_identifier: nil,
         selected_identity: nil,
         selected_snapshot: nil,
         status: :catalog,
         dom_generation: 0
     }, effects}
  end

  defp navigate_invalid(state) do
    effects = deactivate_effect(state.selected_identity)

    {%{
       state
       | revision: state.revision + 1,
         route: :selected,
         requested_identifier: nil,
         selected_identity: nil,
         selected_snapshot: nil,
         status: :invalid_parameter,
         dom_generation: 0
     }, effects}
  end

  defp navigate_selected(state, identifier) do
    changed? = state.route != :selected or state.requested_identifier != identifier

    if changed? do
      deactivation = deactivate_effect(state.selected_identity)

      state = %{
        state
        | revision: state.revision + 1,
          route: :selected,
          requested_identifier: identifier,
          selected_identity: nil,
          selected_snapshot: nil,
          status: :awaiting_catalog,
          dom_generation: 0
      }

      {state, activation} = resolve_selected(state)
      {state, deactivation ++ activation}
    else
      resolve_selected(state)
    end
  end

  defp resolve_selected(%__MODULE__{route: :catalog} = state), do: {state, []}

  defp resolve_selected(%__MODULE__{requested_identifier: nil} = state) do
    transition_selection(state, nil, :invalid_parameter)
  end

  defp resolve_selected(%__MODULE__{} = state) do
    case catalog_match(state.catalog_snapshot, state.requested_identifier) do
      {:ok, identity} -> transition_selection(state, identity, selected_status(state.selected_snapshot))
      {:error, status} -> transition_selection(state, nil, status)
    end
  end

  defp catalog_match(nil, _identifier), do: {:error, :awaiting_catalog}

  defp catalog_match(%Snapshot{data: %Catalog{entries: entries}} = snapshot, identifier) do
    # Match by identifier across every published catalog entry. Each entry is an
    # already-trusted, repository-qualified identity, so we do not additionally
    # require it to match the snapshot's declared repository — that lets a single
    # catalog span repositories (e.g. multiple planning packs) while ambiguous
    # identifiers across repositories are still rejected as invalid below.
    matches =
      Enum.filter(entries, fn
        %RootSummary{identity: %TrackerIdentity{} = identity} ->
          TrackerIdentity.joinable?(identity) and identity.identifier == identifier

        _entry ->
          false
      end)

    case matches do
      [%RootSummary{identity: identity}] -> {:ok, identity}
      [] -> {:error, missing_catalog_status(snapshot.health)}
      _duplicates -> {:error, :invalid_catalog}
    end
  end

  defp catalog_match(%Snapshot{health: health}, _identifier),
    do: {:error, missing_catalog_status(health)}

  defp missing_catalog_status(%ProviderHealth{} = health) do
    cond do
      ProviderHealth.usable?(health) -> :not_found
      health.state == :stale -> :catalog_stale
      health.state == :structurally_invalid -> :invalid_catalog
      true -> :catalog_unavailable
    end
  end

  defp missing_catalog_status(_health), do: :catalog_unavailable

  defp transition_selection(state, identity, status) do
    old_identity = state.selected_identity

    effects =
      if same_identity?(old_identity, identity) do
        []
      else
        deactivate_effect(old_identity) ++ activate_effect(identity)
      end

    selected_snapshot = if same_identity?(old_identity, identity), do: state.selected_snapshot, else: nil
    dom_generation = if same_identity?(old_identity, identity), do: state.dom_generation, else: 0

    {%{
       state
       | selected_identity: identity,
         selected_snapshot: selected_snapshot,
         status: status,
         dom_generation: dom_generation
     }, effects}
  end

  defp catalog_update(nil, %Snapshot{} = snapshot), do: {:ok, snapshot}

  defp catalog_update(%Snapshot{} = current, %Snapshot{} = incoming) do
    cond do
      not same_repository?(current.repository, incoming.repository) -> {:ok, incoming}
      newer_generation?(incoming.generation, current.generation) -> {:ok, incoming}
      same_generation?(incoming.generation, current.generation) -> {:ok, %{current | health: incoming.health}}
      true -> :ignored
    end
  end

  defp selected_update(nil, %Snapshot{} = snapshot), do: {:ok, :generation, snapshot}

  defp selected_update(%Snapshot{} = current, %Snapshot{} = incoming) do
    cond do
      newer_generation?(incoming.generation, current.generation) ->
        {:ok, :generation, incoming}

      same_generation?(incoming.generation, current.generation) ->
        {:ok, :health, %{current | health: incoming.health}}

      true ->
        :ignored
    end
  end

  defp selected_snapshot_for_state?(%Snapshot{scope: {:selected, identity}, repository: repository}, state) do
    same_identity?(identity, state.selected_identity) and same_repository?(identity, repository)
  end

  defp selected_snapshot_for_state?(_snapshot, _state), do: false

  # Availability outranks structure: an unfetched graph is unknown, not malformed,
  # and routing it to `:selected_invalid` tells every downstream region (usage,
  # analytics, breakdown) to blame the operator's Build Order for an outage.
  defp selected_status(%Snapshot{data: %SelectedRoot{} = selected, health: %ProviderHealth{} = health}) do
    case SelectedRoot.availability(selected, health) do
      :structurally_invalid -> :selected_invalid
      :provider_stale -> :selected_stale
      :provider_unavailable -> :selected_unavailable
      nil -> if SelectedRoot.structurally_valid?(selected), do: :selected, else: :selected_invalid
    end
  end

  defp selected_status(%Snapshot{data: nil, health: %ProviderHealth{state: :stale}}), do: :selected_stale

  defp selected_status(%Snapshot{data: nil, health: %ProviderHealth{state: :structurally_invalid}}),
    do: :selected_invalid

  # An unfetched graph whose provider has not yet recorded a failure is still
  # loading, not unavailable: the initial demand returns a nil-data snapshot
  # while the async fetch is in flight, and erroring here is the flicker the
  # shimmer replaces. A recorded failure is the only honest "unavailable".
  defp selected_status(%Snapshot{data: nil, health: %ProviderHealth{state: :unavailable, failure: nil}}),
    do: :selected_loading

  defp selected_status(%Snapshot{data: nil, health: %ProviderHealth{state: :unavailable}}),
    do: :selected_unavailable

  defp selected_status(%Snapshot{data: nil}), do: :selected_loading
  defp selected_status(%Snapshot{data: _data}), do: :selected_invalid
  defp selected_status(_snapshot), do: :selected_loading

  defp newer_generation?(incoming, current) when is_integer(incoming) and is_integer(current), do: incoming > current
  defp newer_generation?(incoming, _current) when is_integer(incoming), do: true
  defp newer_generation?(_incoming, _current), do: false

  defp same_generation?(generation, generation), do: true
  defp same_generation?(_left, _right), do: false

  defp same_repository?(%TrackerIdentity{owner: owner, repository: repository}, {other_owner, other_repository}),
    do: same_repository?({owner, repository}, {other_owner, other_repository})

  defp same_repository?({owner, repository}, {other_owner, other_repository})
       when is_binary(owner) and is_binary(repository) and is_binary(other_owner) and is_binary(other_repository),
       do: String.downcase(owner) == String.downcase(other_owner) and String.downcase(repository) == String.downcase(other_repository)

  defp same_repository?(_left, _right), do: false

  defp same_identity?(nil, nil), do: true

  defp same_identity?(%TrackerIdentity{} = left, %TrackerIdentity{} = right),
    do: identity_key(left) == identity_key(right) and not is_nil(identity_key(left))

  defp same_identity?(_left, _right), do: false

  defp identity_key(%TrackerIdentity{} = identity), do: TrackerIdentity.github_key(identity)
  defp identity_key(_identity), do: nil

  defp snapshot_generation(%Snapshot{generation: generation}), do: generation
  defp snapshot_generation(_snapshot), do: :unknown

  defp deactivate_effect(%TrackerIdentity{} = identity), do: [{:deactivate, identity}]
  defp deactivate_effect(_identity), do: []
  defp activate_effect(%TrackerIdentity{} = identity), do: [{:activate, identity}]
  defp activate_effect(_identity), do: []

  defp changed_revision(state, true), do: state.revision + 1
  defp changed_revision(state, false), do: state.revision
end
