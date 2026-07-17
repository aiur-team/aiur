defmodule AiurWeb.OperatorControlCenter.BuildOrderGraph do
  @moduledoc false

  use Phoenix.Component

  alias Aiur.BuildOrder.{Diagnostic, Metadata}
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.TicketContextSelection
  alias AiurWeb.BuildOrderViewModel.{Edge, Node}
  alias AiurWeb.OperatorControlCenter.BuildOrderIcon
  alias AiurWeb.StaticAssets

  @edge_states ~w(cleared blocking terminal_unsatisfied unknown cyclic)

  attr(:id, :string, required: true)
  attr(:root_id, :string, required: true)
  attr(:provider_generation, :integer, required: true)
  attr(:dom_generation, :integer, required: true)
  attr(:nodes, :list, default: [])
  attr(:edges, :list, default: [])
  attr(:model, :any, default: nil)
  attr(:layout_assets, :map, default: nil)

  @spec build_order_graph(map()) :: Phoenix.LiveView.Rendered.t()
  def build_order_graph(assigns) do
    {nodes, edges} = graph_content(assigns.model, assigns.nodes, assigns.edges)

    assigns =
      assigns
      |> assign(:lanes, lane_groups(nodes))
      |> assign(:edge_rows, edge_rows(edges))
      |> assign(:layout_assets, assigns.layout_assets || StaticAssets.layout_asset_urls())

    ~H"""
    <section
      id={@id}
      class="bo-layout-root is-layout-fallback"
      phx-hook="DomSvgLayout"
      data-layout-root-id={@root_id}
      data-layout-provider-generation={@provider_generation}
      data-layout-dom-generation={@dom_generation}
      data-layout-client-url={@layout_assets.client}
      data-layout-worker-url={@layout_assets.worker}
      data-layout-engine-url={@layout_assets.engine}
      data-layout-adapter-url="/aiur-dom-svg-layout-adapter.js"
      data-layout-health="fallback"
      aria-labelledby={"#{@id}-title"}
    >
      <header class="bo-layout-heading">
        <h2 id={"#{@id}-title"}>Build order</h2>
        <p data-layout-health-message role="status">Using readable document-flow layout.</p>
      </header>

      <div class="bo-layout-cards" data-layout-cards>
        <section :for={lane <- @lanes} class="bo-layout-lane" data-layout-lane={lane.index} aria-labelledby={"#{@id}-lane-#{lane.index}"}>
          <h3 id={"#{@id}-lane-#{lane.index}"} class="bo-layout-lane-heading">{lane.label}</h3>

          <article
            :for={node <- lane.nodes}
            class="bo-layout-card"
            aria-label={node_accessible_title(node)}
            data-layout-node
            data-layout-node-id={node_id(node)}
            data-layout-lane={node_lane(node)}
            data-layout-phase={node_phase(node)}
          >
            <header data-layout-card-header>
              <div class="bo-layout-card-kicker">
                <p class="bo-layout-card-id">{node_id(node)}</p>
                <span :if={node_status_icon(node)} class="bo-layout-card-status">
                  <BuildOrderIcon.build_order_icon icon={node_status_icon(node)} />
                  <span>{node_status_text(node)}</span>
                </span>
              </div>
              <h4>{node_title(node)}</h4>
            </header>
            <p :if={node_summary(node)}>{node_summary(node)}</p>
            <dl :if={typed_node?(node)} class="bo-layout-card-facts">
              <div>
                <dt>Lane</dt>
                <dd>
                  <BuildOrderIcon.build_order_icon :if={node_lane_icon(node)} icon={node_lane_icon(node)} />
                  {node_lane_label(node)}
                </dd>
              </div>
              <div><dt>Phase</dt><dd>{node_phase_label(node)}</dd></div>
              <div><dt>Lifecycle</dt><dd>{node_lifecycle(node)}</dd></div>
              <div><dt>Readiness</dt><dd>{node_readiness(node)}</dd></div>
              <div><dt>Execution</dt><dd>{node_execution(node)}</dd></div>
              <div><dt>Agent stage</dt><dd>{node_agent_stage(node)}</dd></div>
              <div><dt>Progress</dt><dd>{node_progress(node)}</dd></div>
            </dl>
            <p :if={typed_node?(node)} class="bo-layout-card-provenance mono">{node_provenance(node)}</p>
            <ul :if={node_diagnostics(node) != []} class="bo-layout-card-warnings" aria-label="Metadata warnings">
              <li :for={warning <- node_diagnostics(node)}>{warning}</li>
            </ul>
            <button
              :if={node_navigation_value(@model, node)}
              id={node_origin_id(@model, node)}
              type="button"
              class="bo-card-context-trigger"
              phx-click="open-ticket-context"
              phx-value-member={node_navigation_value(@model, node)}
              aria-label={"Open cached context for #{node_id(node)} #{node_title(node)}"}
            >
              Ticket context
            </button>
            <p :if={!typed_node?(node)} class="bo-layout-card-meta">Phase {node_phase(node)}</p>
          </article>
        </section>
      </div>

      <svg class="bo-layout-edges" data-layout-edges aria-hidden="true" focusable="false"></svg>

      <section class="bo-layout-dependency-summary" aria-labelledby={"#{@id}-dependencies"}>
        <h3 id={"#{@id}-dependencies"}>Dependency summary</h3>
        <p :if={@edge_rows == []}>No dependencies are recorded.</p>
        <ul :if={@edge_rows != []} data-layout-dependency-summary>
          <li
            :for={edge <- @edge_rows}
            data-layout-edge
            data-layout-edge-id={edge.id}
            data-layout-edge-source={edge.source}
            data-layout-edge-target={edge.target}
            data-layout-edge-state={edge.state}
          >
            <span :if={edge.text}>{edge.text}</span>
            <span :if={is_nil(edge.text)}><strong>{edge.source}</strong> {edge_relation(edge.state)} <strong>{edge.target}</strong></span>
            <span class="bo-layout-edge-state">{edge_label(edge.state)}</span>
            <span class="bo-layout-edge-kind">{edge_kind_label(edge.kind)}</span>
            <ul :if={edge.diagnostics != []} class="bo-layout-card-warnings" aria-label="Dependency diagnostics">
              <li :for={diagnostic <- edge.diagnostics}>{diagnostic}</li>
            </ul>
          </li>
        </ul>
      </section>
    </section>
    """
  end

  defp lane_groups(nodes) do
    nodes
    |> Enum.group_by(&node_lane/1)
    |> Enum.sort_by(fn {lane, _nodes} -> lane end)
    |> Enum.map(fn {lane, lane_nodes} ->
      %{index: lane, label: lane_label(lane, lane_nodes), nodes: Enum.sort_by(lane_nodes, &node_phase/1)}
    end)
  end

  defp graph_content(%AiurWeb.BuildOrderViewModel{} = model, _nodes, _edges),
    do: {model.nodes, model.edges}

  defp graph_content(_model, nodes, edges), do: {nodes, edges}

  defp edge_rows(edges) do
    edges
    |> Enum.with_index()
    |> Enum.map(fn
      {%Edge{} = edge, index} ->
        %{
          id: safe_text(edge.id, "edge-#{index + 1}"),
          source: endpoint_identifier(edge.source, edge.source_key, "Unknown source"),
          target: endpoint_identifier(edge.target, edge.target_key, "Unknown target"),
          state: edge_state(edge.state),
          kind: edge.kind,
          text: safe_optional_text(edge.text),
          diagnostics: diagnostic_texts(edge.diagnostics)
        }

      {edge, index} ->
        %{
          id: string_value(edge, :id, "edge-#{index + 1}"),
          source: string_value(edge, :source, "Unknown source"),
          target: string_value(edge, :target, "Unknown target"),
          state: edge_state(Map.get(edge, :state) || Map.get(edge, "state")),
          kind: :unknown,
          text: nil,
          diagnostics: []
        }
    end)
  end

  defp node_id(%Node{card: %{identifier: identifier}}), do: safe_text(identifier, "Unknown ticket")
  defp node_id(node), do: string_value(node, :id, "Unknown ticket")
  defp node_title(%Node{title: title}), do: safe_text(title, "Unknown ticket")
  defp node_title(node), do: string_value(node, :title, node_id(node))
  defp node_summary(%Node{}), do: nil
  defp node_summary(node), do: optional_string(node, :summary)
  defp node_lane(%Node{card: %{lane: lane}}), do: lane_index(lane)
  defp node_lane(node), do: non_negative_integer(node, :lane)
  defp node_phase(%Node{card: %{phase: phase}}) when is_integer(phase) and phase > 0, do: phase
  defp node_phase(%Node{}), do: 0
  defp node_phase(node), do: non_negative_integer(node, :phase)

  defp typed_node?(%Node{}), do: true
  defp typed_node?(_node), do: false

  defp node_lane_icon(%Node{lane_icon: icon}), do: icon
  defp node_lane_icon(_node), do: nil
  defp node_status_icon(%Node{status_icon: icon}), do: icon
  defp node_status_icon(_node), do: nil
  defp node_status_text(%Node{card: %{status_text: text}}), do: safe_text(text, "Status unavailable")
  defp node_status_text(_node), do: nil

  defp node_lane_label(%Node{card: %{lane: lane}}) when is_binary(lane),
    do: lane |> String.replace("-", " ") |> String.capitalize()

  defp node_lane_label(%Node{}), do: "Unassigned"
  defp node_lane_label(node), do: "Lane #{node_lane(node) + 1}"

  defp node_phase_label(%Node{card: %{phase: phase}}) when is_integer(phase) and phase > 0,
    do: "Phase #{phase}"

  defp node_phase_label(%Node{}), do: "Unphased"

  defp node_lifecycle(%Node{card: %{lifecycle: %{state: state, state_reason: reason}}}) do
    [label(state), reason_label(reason)] |> Enum.reject(&is_nil/1) |> Enum.join(" — ")
  end

  defp node_lifecycle(%Node{}), do: "Lifecycle unavailable"
  defp node_readiness(%Node{readiness: readiness}), do: label(readiness)
  defp node_execution(%Node{card: %{execution_state: state}}), do: label(state)

  defp node_agent_stage(%Node{card: %{agent_stage: stage}})
       when stage in [:brainstorm, :plan, :work, :review],
       do: label(stage)

  defp node_agent_stage(%Node{}), do: "Agent stage unavailable"

  defp node_progress(%Node{card: %{progress: percent}})
       when is_integer(percent) and percent in 0..100,
       do: "#{percent}%"

  defp node_progress(%Node{}), do: "Progress unavailable"

  defp node_provenance(%Node{provenance: provenance}) do
    planning = Map.get(provenance, :planning_generation, :unknown)
    activity = Map.get(provenance, :activity_generation, :unknown)
    "planning gen #{planning} · activity gen #{activity}"
  end

  defp node_diagnostics(%Node{diagnostics: diagnostics}) do
    Enum.flat_map(diagnostics, fn
      %Diagnostic{text: text} when is_binary(text) -> [text]
      _diagnostic -> []
    end)
  end

  defp node_diagnostics(_node), do: []

  defp diagnostic_texts(diagnostics) when is_list(diagnostics) do
    Enum.flat_map(diagnostics, fn
      %Diagnostic{text: text} when is_binary(text) -> [text]
      _diagnostic -> []
    end)
  end

  defp diagnostic_texts(_diagnostics), do: []

  defp node_navigation_value(%AiurWeb.BuildOrderViewModel{} = model, %Node{identity: %TrackerIdentity{} = identity}) do
    if TrackerIdentity.joinable?(identity), do: TicketContextSelection.navigation_value(model, identity)
  end

  defp node_navigation_value(_model, _node), do: nil

  defp node_origin_id(%AiurWeb.BuildOrderViewModel{} = model, %Node{identity: identity}),
    do: TicketContextSelection.origin_id(model, identity)

  defp node_origin_id(_model, _node), do: nil

  defp node_accessible_title(%Node{} = node) do
    [
      node_id(node),
      node_title(node),
      node_status_text(node),
      node_lane_label(node),
      node_phase_label(node),
      node_agent_stage(node),
      node_progress(node)
    ]
    |> Enum.join(" · ")
  end

  defp node_accessible_title(node), do: "#{node_id(node)} · #{node_title(node)}"

  defp lane_label(_lane, [%Node{} = node | _nodes]), do: node_lane_label(node)
  defp lane_label(lane, _nodes), do: "Lane #{lane + 1}"

  defp lane_index(lane) when is_binary(lane),
    do: Enum.find_index(Metadata.lanes(), &(&1 == lane)) || length(Metadata.lanes())

  defp lane_index(_lane), do: length(Metadata.lanes())

  defp string_value(map, key, fallback) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_binary(value) and byte_size(value) > 0 -> value
      value when is_integer(value) -> Integer.to_string(value)
      _value -> fallback
    end
  end

  defp optional_string(map, key) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_binary(value) and byte_size(value) > 0 -> value
      _value -> nil
    end
  end

  defp non_negative_integer(map, key) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_integer(value) and value >= 0 -> value
      _value -> 0
    end
  end

  defp endpoint_identifier(%TrackerIdentity{identifier: identifier}, _key, _fallback)
       when is_binary(identifier),
       do: identifier

  defp endpoint_identifier(_identity, key, fallback), do: safe_text(key, fallback)

  defp safe_text(value, _fallback) when is_binary(value) and byte_size(value) in 1..160, do: value
  defp safe_text(value, _fallback) when is_integer(value), do: Integer.to_string(value)
  defp safe_text(_value, fallback), do: fallback
  defp safe_optional_text(value) when is_binary(value) and byte_size(value) in 1..512, do: value
  defp safe_optional_text(_value), do: nil

  defp edge_state(value) when is_atom(value), do: edge_state(Atom.to_string(value))
  defp edge_state(value) when value in @edge_states, do: value
  defp edge_state(_value), do: "unknown"

  defp edge_label(state), do: state |> String.replace("_", " ") |> String.capitalize()

  defp edge_kind_label(:native), do: "Native dependency"
  defp edge_kind_label(:external), do: "External reference"
  defp edge_kind_label(_kind), do: "Dependency kind unavailable"

  defp edge_relation("cleared"), do: "is clear of"
  defp edge_relation("blocking"), do: "blocks"
  defp edge_relation("terminal_unsatisfied"), do: "leaves terminally unsatisfied"
  defp edge_relation("unknown"), do: "has an unknown dependency relation to"
  defp edge_relation("cyclic"), do: "is cyclic with"

  defp label(value) when is_atom(value), do: value |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  defp label(_value), do: "Unavailable"
  defp reason_label(reason) when reason in [nil, :none, :unknown], do: nil
  defp reason_label(reason), do: label(reason)
end
