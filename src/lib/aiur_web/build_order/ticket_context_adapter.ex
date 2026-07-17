defmodule AiurWeb.BuildOrder.TicketContextAdapter.Relationship do
  @moduledoc false

  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrderViewModel.Edge

  @type t :: %__MODULE__{
          direction: :blocked_by | :blocking,
          edge: Edge.t(),
          endpoint: TrackerIdentity.t() | nil,
          label: String.t(),
          readiness: Aiur.BuildOrder.Readiness.t(),
          selectable?: boolean(),
          navigation_value: String.t() | nil,
          outbound_url: String.t() | nil
        }

  @enforce_keys [:direction, :edge, :label, :readiness, :selectable?]
  defstruct [:direction, :edge, :endpoint, :label, :readiness, :navigation_value, :outbound_url, selectable?: false]
end

defmodule AiurWeb.BuildOrder.TicketContextAdapter.View do
  @moduledoc false

  alias Aiur.BuildOrder.Diagnostic
  alias AiurWeb.BuildOrder.TicketContextAdapter.Relationship
  alias AiurWeb.BuildOrder.TicketContextPresenter.View, as: BaseView
  alias AiurWeb.BuildOrderViewModel.Node

  @type status :: :available | :unavailable
  @type reason :: :identity_mismatch | :selection_unavailable | :stale_scope | nil

  @type t :: %__MODULE__{
          status: status(),
          reason: reason(),
          base: BaseView.t(),
          selected: Node.t() | nil,
          blocked_by: [Relationship.t()],
          blocking: [Relationship.t()],
          diagnostics: [Diagnostic.t()]
        }

  @enforce_keys [:status, :base]
  defstruct [:reason, :base, :selected, status: :unavailable, blocked_by: [], blocking: [], diagnostics: []]
end

defmodule AiurWeb.BuildOrder.TicketContextAdapter do
  @moduledoc """
  Pure, read-only composition of BO-007 relationship truth and BO-018 context.

  Inputs are normalized in-memory values. This module performs no provider,
  process, filesystem, log, or clock lookup and never changes edge semantics.
  """

  alias Aiur.BuildOrder.Bounded
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.TicketContextAdapter.{Relationship, View}
  alias AiurWeb.BuildOrder.TicketContextPresenter
  alias AiurWeb.BuildOrder.TicketContextSelection
  alias AiurWeb.BuildOrderPresenter
  alias AiurWeb.BuildOrderViewModel
  alias AiurWeb.BuildOrderViewModel.{Capability, Edge, Node, Relationships}

  @capability_keys [:issue, :pull_request, :chat, :commands]

  @spec present(BuildOrderViewModel.t(), term(), term(), term()) :: View.t()
  def present(model, selected_identity, base_context, capabilities \\ %{})

  def present(%BuildOrderViewModel{} = model, selected_identity, base_context, capabilities) do
    base = TicketContextPresenter.normalize_view(base_context)

    if current_scope?(model) do
      model
      |> BuildOrderPresenter.relationships(selected_identity, capabilities)
      |> compose(model, base)
    else
      unavailable(:stale_scope)
    end
  end

  def present(_model, _selected_identity, _base_context, _capabilities), do: unavailable(:stale_scope)

  defp compose(%Relationships{status: :selected, selected: %Node{} = selected} = relationships, model, base) do
    cond do
      exact_node(model, selected.identity) != selected ->
        unavailable(:selection_unavailable)

      not selected_repository?(model, selected.identity) ->
        unavailable(:selection_unavailable)

      not same_identity?(selected.identity, base.identity) ->
        unavailable(:identity_mismatch)

      true ->
        %View{
          status: :available,
          reason: nil,
          base: bind_capabilities(base, relationships.capabilities, selected.identity),
          selected: selected,
          blocked_by: relationship_rows(relationships.blocked_by, :blocked_by, model),
          blocking: relationship_rows(relationships.blocking, :blocking, model),
          diagnostics: relationships.diagnostics
        }
    end
  end

  defp compose(_relationships, _model, _base), do: unavailable(:selection_unavailable)

  defp relationship_rows(edges, direction, model) do
    Enum.map(edges, &relationship(&1, direction, model))
  end

  defp relationship(%Edge{} = edge, direction, model) do
    endpoint = endpoint(edge, direction)
    endpoint_node = exact_node(model, endpoint)
    navigation_value = selectable_navigation(edge, endpoint_node, model)
    affected = exact_node(model, edge.target)

    %Relationship{
      direction: direction,
      edge: edge,
      endpoint: endpoint,
      label: endpoint_label(endpoint_node, endpoint, edge),
      readiness: readiness(affected),
      selectable?: is_binary(navigation_value),
      navigation_value: navigation_value,
      outbound_url: outbound_url(edge, endpoint)
    }
  end

  defp endpoint(%Edge{source: source}, :blocked_by), do: source
  defp endpoint(%Edge{target: target}, :blocking), do: target

  defp exact_node(model, identity) do
    case TrackerIdentity.github_key(identity) do
      nil ->
        nil

      key ->
        case Enum.filter(model.nodes, &exact_node?(&1, key)) do
          [%Node{} = node] -> node
          _nodes -> nil
        end
    end
  end

  defp exact_node?(%Node{key: key, identity: identity}, key),
    do: TrackerIdentity.github_key(identity) == key

  defp exact_node?(_node, _key), do: false

  defp selectable_navigation(%Edge{kind: :native}, %Node{identity: identity}, model),
    do: TicketContextSelection.navigation_value(model, identity)

  defp selectable_navigation(_edge, _node, _model), do: nil

  defp endpoint_label(%Node{title: title}, _identity, _edge), do: title
  defp endpoint_label(_node, %TrackerIdentity{identifier: identifier}, _edge) when is_binary(identifier), do: "Ticket #{identifier}"
  defp endpoint_label(_node, _identity, %Edge{text: text}) when is_binary(text), do: text
  defp endpoint_label(_node, _identity, _edge), do: "Unavailable endpoint"

  defp readiness(%Node{readiness: readiness}), do: readiness
  defp readiness(_node), do: :unknown

  defp outbound_url(%Edge{kind: :external, url: url}, %TrackerIdentity{} = identity) do
    case Bounded.github_issue_url_for(url, identity) do
      {:ok, safe} -> safe
      :error -> nil
    end
  end

  defp outbound_url(_edge, _identity), do: nil

  defp bind_capabilities(base, capabilities, selected_identity) do
    inputs = Enum.map(@capability_keys, &capability_input(&1, Map.get(capabilities, &1), selected_identity))
    TicketContextPresenter.normalize_view(%{base | capabilities: inputs})
  end

  defp capability_input(key, %Capability{} = capability, selected_identity) do
    {kind, variant} = capability_kind(key)
    reason = capability_reason(key, capability, selected_identity)

    %{
      kind: kind,
      variant: variant,
      number: capability.number,
      href: capability.destination,
      available?: is_nil(reason),
      reason: reason
    }
  end

  defp capability_input(key, _capability, _selected_identity) do
    {kind, variant} = capability_kind(key)
    %{kind: kind, variant: variant, available?: false, reason: :missing}
  end

  defp capability_kind(:issue), do: {:github, :issue}
  defp capability_kind(:pull_request), do: {:github, :pull_request}
  defp capability_kind(:chat), do: {:chat, nil}
  defp capability_kind(:commands), do: {:commands, nil}

  defp capability_reason(
         _key,
         %Capability{available?: available?, reason: reason},
         _selected_identity
       )
       when available? != true,
       do: reason

  defp capability_reason(key, %Capability{} = capability, selected_identity) do
    if same_identity?(capability.identity, selected_identity) do
      capability_state_reason(key, capability)
    else
      :identity_mismatch
    end
  end

  defp capability_state_reason(:chat, %Capability{active?: active?}) when active? != true,
    do: :inactive

  defp capability_state_reason(:chat, %Capability{readable?: readable?}) when readable? != true,
    do: :unreadable

  defp capability_state_reason(:commands, %Capability{readable?: readable?})
       when readable? != true,
       do: :unreadable

  defp capability_state_reason(_key, _capability), do: nil

  defp current_scope?(%BuildOrderViewModel{
         root: %{identity: %TrackerIdentity{} = root, generation: generation},
         generations: %{planning: generation}
       })
       when is_integer(generation) and generation > 0,
       do: TrackerIdentity.joinable?(root)

  defp current_scope?(_model), do: false

  defp selected_repository?(
         %BuildOrderViewModel{root: %{identity: %TrackerIdentity{} = root}},
         %TrackerIdentity{} = selected
       ),
       do: Bounded.same_repository?(root, selected)

  defp selected_repository?(_model, _selected), do: false

  defp same_identity?(left, right) do
    case {TrackerIdentity.github_key(left), TrackerIdentity.github_key(right)} do
      {nil, _right} -> false
      {key, key} -> true
      _different -> false
    end
  end

  defp unavailable(reason) do
    %View{status: :unavailable, reason: reason, base: TicketContextPresenter.normalize_view(nil)}
  end
end
