defmodule AiurWeb.OperatorControlCenter.BuildOrderSelected do
  @moduledoc "Selected-root state and graph surface for Build Order routes."

  use Phoenix.Component

  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.BuildOrder.SelectedRoot
  alias AiurWeb.BuildOrder.RouteState
  alias AiurWeb.OperatorControlCenter.{BuildOrderBreakdown, BuildOrderGraph, BuildOrderStatus}

  attr(:route_state, :any, required: true)
  attr(:model, :any, default: nil)
  attr(:adhoc, :any, default: nil)
  attr(:now, :any, required: true)

  @spec build_order_selected(map()) :: Phoenix.LiveView.Rendered.t()
  def build_order_selected(assigns) do
    assigns =
      assigns
      |> assign(:status, RouteState.status(assigns.route_state))
      |> assign(:snapshot, RouteState.selected_snapshot(assigns.route_state))

    ~H"""
    <section class="bo-surface" aria-labelledby="build-order-selected-title">
      <.link patch="/build-orders" class="bo-back-link">← All Build Orders</.link>

      <header class="bo-page-header">
        <div>
          <p class="section-eyebrow">Selected planning root</p>
          <h2 id="build-order-selected-title">{selected_title(@status, @snapshot, RouteState.root_identifier(@route_state))}</h2>
          <p>{selected_message(@status)}</p>
        </div>
        <BuildOrderStatus.provider_health snapshot={@snapshot || RouteState.catalog_snapshot(@route_state)} now={@now} />
      </header>

      <div :if={is_nil(@model)} class="bo-state-card" role={state_role(@status)}>
        <h3>{state_title(@status)}</h3>
        <p>{state_message(@status)}</p>
      </div>

      <div :if={not is_nil(@model)} class="bo-selected-summary">
        <p class="mono">Planning generation {display_generation(@snapshot)}</p>
        <p>{model_summary(@model)}</p>
        <div :if={@model.status not in [:ready, :empty]} class="bo-state-card" role={model_state_role(@model)}>
          <h3>{model_state_title(@model)}</h3>
          <p>{model_summary(@model)}</p>
        </div>
        <dl class="bo-summary-grid" aria-label="Build Order graph summary">
          <div><dt>Members</dt><dd>{@model.summary.members}</dd></div>
          <div><dt>Dependencies</dt><dd>{@model.summary.edges}</dd></div>
          <div><dt>External</dt><dd>{@model.summary.external_edges}</dd></div>
          <div><dt>Lanes</dt><dd>{map_size(@model.summary.lanes)}</dd></div>
          <div><dt>Phases</dt><dd>{map_size(@model.summary.phases)}</dd></div>
        </dl>

        <div :if={@model.status == :empty} class="bo-state-card" role="status">
          <h3>Valid empty graph</h3>
          <p>This Build Order currently has no direct members.</p>
        </div>

        <BuildOrderGraph.build_order_graph
          :if={@model.nodes != []}
          id="selected-build-order-graph"
          root_id={RouteState.root_identifier(@route_state)}
          provider_generation={positive_generation(@snapshot)}
          dom_generation={max(RouteState.dom_generation(@route_state), 1)}
          model={@model}
        />

        <BuildOrderBreakdown.build_order_breakdown :if={@model.status != :empty} model={@model} adhoc={@adhoc} />

        <ul :if={@model.diagnostics != []} class="bo-diagnostics" aria-label="Build Order diagnostics">
          <li :for={diagnostic <- @model.diagnostics}>{diagnostic.text}</li>
        </ul>
      </div>
    </section>
    """
  end

  defp selected_title(_status, %Snapshot{data: %SelectedRoot{root: root}}, _identifier), do: root.title
  defp selected_title(_status, _snapshot, identifier) when is_binary(identifier), do: "Build Order ##{identifier}"
  defp selected_title(_status, _snapshot, _identifier), do: "Build Order"

  defp selected_message(:selected), do: "Read-only planning truth joined with cached execution and activity."
  defp selected_message(:selected_stale), do: "Showing last-known-good planning truth while the provider is stale."
  defp selected_message(:selected_invalid), do: "The selected provider data is structurally invalid."
  defp selected_message(:selected_unavailable), do: "The selected provider is unavailable."
  defp selected_message(_status), do: "The selected route remains explicit while its planning scope is resolved."

  defp state_title(:invalid_parameter), do: "Invalid Build Order URL"
  defp state_title(:awaiting_catalog), do: "Loading catalog"
  defp state_title(:catalog_unavailable), do: "Catalog unavailable"
  defp state_title(:catalog_stale), do: "Catalog is stale"
  defp state_title(:not_found), do: "Build Order not found"
  defp state_title(:invalid_catalog), do: "Catalog identity conflict"
  defp state_title(:selected_loading), do: "Loading selected graph"
  defp state_title(:selected_unavailable), do: "Selected graph unavailable"
  defp state_title(:selected_stale), do: "Selected graph is stale"
  defp state_title(:selected_invalid), do: "Selected graph is structurally invalid"
  defp state_title(_status), do: "Build Order unavailable"

  defp state_message(:invalid_parameter), do: "Use one canonical positive GitHub issue number."
  defp state_message(:awaiting_catalog), do: "Waiting for a validated repository catalog before selecting this root."
  defp state_message(:catalog_unavailable), do: "No validated catalog snapshot can resolve this URL yet."
  defp state_message(:catalog_stale), do: "The last-known-good catalog cannot safely confirm this root."
  defp state_message(:not_found), do: "The healthy complete catalog does not contain this root."
  defp state_message(:invalid_catalog), do: "The locator does not resolve to exactly one repository-qualified identity."
  defp state_message(:selected_loading), do: "The exact root is selected; its graph snapshot is loading."
  defp state_message(:selected_unavailable), do: "No validated selected-root snapshot is available."
  defp state_message(:selected_stale), do: "The provider is stale and has no selected-root last-known-good snapshot."
  defp state_message(:selected_invalid), do: "The selected-root provider response failed structural validation."
  defp state_message(_status), do: "Planning data is temporarily unavailable."

  defp state_role(:invalid_parameter), do: "alert"
  defp state_role(:invalid_catalog), do: "alert"
  defp state_role(_status), do: "status"

  defp display_generation(%Snapshot{generation: generation}), do: generation
  defp display_generation(_snapshot), do: "unknown"
  defp positive_generation(%Snapshot{generation: generation}) when is_integer(generation) and generation > 0, do: generation
  defp positive_generation(_snapshot), do: 1

  defp model_summary(%{status: :empty}), do: "This is a valid empty graph."
  defp model_summary(%{status: :provider_stale}), do: "Showing the stale last-known-good planning graph."
  defp model_summary(%{status: :structurally_invalid}), do: "The selected planning graph is structurally invalid."
  defp model_summary(%{status: :provider_unavailable}), do: "The selected planning graph is unavailable."
  defp model_summary(_model), do: "Planning graph ready."

  defp model_state_title(%{status: :provider_stale}), do: "Stale last-known-good graph"
  defp model_state_title(%{status: :structurally_invalid}), do: "Structurally invalid graph"
  defp model_state_title(%{status: :provider_unavailable}), do: "Provider unavailable"
  defp model_state_title(_model), do: "Build Order state"

  defp model_state_role(%{status: :structurally_invalid}), do: "alert"
  defp model_state_role(_model), do: "status"
end
