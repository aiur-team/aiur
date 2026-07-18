defmodule AiurWeb.OperatorControlCenter.BuildOrderGraph do
  @moduledoc false

  use Phoenix.Component

  alias Aiur.BuildOrder.{DependencyChain, Diagnostic, Metadata}
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
      |> assign(:chains, dependency_chains(assigns.model, nodes))
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

      <div class="bo-graph-controls" role="group" aria-label="Graph view controls" data-graph-controls>
        <button type="button" class="bo-graph-control" data-graph-zoom="out" aria-label="Zoom graph out">&minus;</button>
        <span class="bo-graph-zoom-level" data-graph-zoom-level aria-hidden="true">100%</span>
        <button type="button" class="bo-graph-control" data-graph-zoom="in" aria-label="Zoom graph in">+</button>
        <button type="button" class="bo-graph-control" data-graph-zoom="fit" aria-label="Fit graph to view">Fit</button>
        <button type="button" class="bo-graph-control" data-graph-zoom="reset" aria-label="Reset graph zoom and pan">Reset</button>
        <details class="bo-graph-help" id={"#{@id}-graph-help"}>
          <summary class="bo-graph-control">Keyboard help</summary>
          <ul>
            <li>Tab or arrow keys move between build-order cards.</li>
            <li>Focus or hover a card to highlight its dependency chain.</li>
            <li>Space pins a card selection; Escape clears it.</li>
            <li>Enter opens the focused card's ticket context.</li>
            <li>On the canvas, arrow keys pan and <kbd>+</kbd>/<kbd>-</kbd>/<kbd>0</kbd> zoom.</li>
            <li>Hold Ctrl (or &#8984;) while scrolling to zoom the graph.</li>
          </ul>
        </details>
      </div>

      <ul class="bo-graph-legend" aria-label="Dependency edge legend">
        <li><span class="bo-graph-legend-line is-cleared" aria-hidden="true"></span>Cleared</li>
        <li><span class="bo-graph-legend-line is-blocking" aria-hidden="true"></span>Blocking</li>
      </ul>

      <p class="sr-only" aria-live="polite" aria-atomic="true" data-graph-announce></p>

      <div
        class="bo-layout-viewport"
        data-graph-viewport
        tabindex="0"
        role="group"
        aria-label="Build order graph canvas"
        aria-describedby={"#{@id}-graph-help"}
      >
        <div class="bo-layout-canvas" data-graph-content>
          <div class="bo-layout-cards" data-layout-cards>
            <section :for={lane <- @lanes} class="bo-layout-lane" data-layout-lane={lane.index} aria-labelledby={"#{@id}-lane-#{lane.index}"}>
              <h3 id={"#{@id}-lane-#{lane.index}"} class="bo-layout-lane-heading">{lane.label}</h3>

              <article
                :for={node <- lane.nodes}
                class="bo-layout-card"
                aria-label={node_accessible_title(node)}
                tabindex="0"
                data-layout-node
                data-graph-node={node_id(node)}
                data-graph-upstream={chain_tokens(@chains, node, :upstream)}
                data-graph-downstream={chain_tokens(@chains, node, :downstream)}
                data-layout-node-id={node_id(node)}
                data-layout-lane={node_lane(node)}
                data-layout-phase={node_phase(node)}
              >
            <header data-layout-card-header>
              <div class="bo-layout-card-kicker">
                <span class="bo-layout-card-idline">
                  <span class="bo-layout-card-id">{node_id(node)}</span>
                  <span :if={node_complexity(node)} class="bo-cx" title={"Complexity #{node_complexity(node)} of 5"}>Cx:{node_complexity(node)}</span>
                </span>
                <span :if={node_status_icon(node)} class="bo-layout-card-status">
                  <BuildOrderIcon.build_order_icon icon={node_status_icon(node)} />
                  <span>{node_status_text(node)}</span>
                </span>
              </div>
              <h4>{node_title(node)}</h4>
            </header>
            <p :if={node_summary(node)}>{node_summary(node)}</p>
            <p :if={typed_node?(node) && node_meta_line(node)} class="bo-layout-card-meta-line">{node_meta_line(node)}</p>
            <div :if={typed_node?(node)} class="bo-layout-card-progress">
              <span class="bo-bar" aria-hidden="true"><i style={node_progress_style(node)}></i></span>
              <span class="bo-layout-card-pct">{node_progress(node)}</span>
            </div>
            <ul :if={node_diagnostics(node) != []} class="bo-layout-card-warnings" aria-label="Metadata warnings">
              <li :for={warning <- node_diagnostics(node)}>{warning}</li>
            </ul>
                <button
                  :if={node_navigation_value(@model, node)}
                  id={node_origin_id(@model, node)}
                  type="button"
                  class="bo-card-context-trigger"
                  data-graph-context
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
        </div>
      </div>

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

  defp dependency_chains(%AiurWeb.BuildOrderViewModel{} = model, nodes) do
    closures = DependencyChain.closures(model.adjacency, model.reverse_adjacency)
    id_by_key = Map.new(nodes, fn node -> {node_key(node), node_id(node)} end)

    Map.new(nodes, fn node ->
      closure = Map.get(closures, node_key(node), %{upstream: [], downstream: []})

      {node_id(node),
       %{
         upstream: chain_identifiers(closure.upstream, id_by_key),
         downstream: chain_identifiers(closure.downstream, id_by_key)
       }}
    end)
  end

  defp dependency_chains(_model, _nodes), do: %{}

  defp chain_identifiers(keys, id_by_key) do
    keys
    |> Enum.map(&Map.get(id_by_key, &1))
    |> Enum.filter(&valid_token?/1)
  end

  defp chain_tokens(chains, node, direction) do
    case Map.get(chains, node_id(node)) do
      %{^direction => ids} when ids != [] -> Enum.join(ids, " ")
      _chain -> nil
    end
  end

  defp valid_token?(value), do: is_binary(value) and value != "" and not String.contains?(value, " ")

  defp node_key(%Node{key: key}), do: key
  defp node_key(node), do: node_id(node)

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

  defp node_complexity(%Node{plan: %{complexity: complexity}}) when complexity in 1..5, do: complexity
  defp node_complexity(_node), do: nil

  defp node_meta_line(%Node{} = node) do
    case Enum.reject([node_meta_phase(node), node_meta_stage(node)], &is_nil/1) do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defp node_meta_phase(%Node{card: %{phase: phase}}) when is_integer(phase) and phase > 0,
    do: "Phase #{phase}"

  defp node_meta_phase(%Node{}), do: nil

  defp node_meta_stage(%Node{card: %{agent_stage: stage}})
       when stage in [:brainstorm, :plan, :work, :review],
       do: label(stage)

  defp node_meta_stage(%Node{}), do: nil

  defp node_progress_style(%Node{card: %{progress: percent}})
       when is_integer(percent) and percent in 0..100,
       do: "width:#{percent}%"

  defp node_progress_style(%Node{}), do: "width:0%"

  defp node_agent_stage(%Node{card: %{agent_stage: stage}})
       when stage in [:brainstorm, :plan, :work, :review],
       do: label(stage)

  defp node_agent_stage(%Node{}), do: "Agent stage unavailable"

  defp node_progress(%Node{card: %{progress: percent}})
       when is_integer(percent) and percent in 0..100,
       do: "#{percent}%"

  defp node_progress(%Node{}), do: "Progress unavailable"

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
end
