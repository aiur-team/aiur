defmodule AiurWeb.OperatorControlCenter.BuildOrderGraph do
  @moduledoc false

  use Phoenix.Component

  alias AiurWeb.StaticAssets

  @edge_states ~w(cleared blocking terminal_unsatisfied unknown cyclic)

  attr(:id, :string, required: true)
  attr(:root_id, :string, required: true)
  attr(:provider_generation, :integer, required: true)
  attr(:dom_generation, :integer, required: true)
  attr(:nodes, :list, default: [])
  attr(:edges, :list, default: [])
  attr(:layout_assets, :map, default: nil)

  @spec build_order_graph(map()) :: Phoenix.LiveView.Rendered.t()
  def build_order_graph(assigns) do
    assigns =
      assigns
      |> assign(:lanes, lane_groups(assigns.nodes))
      |> assign(:edge_rows, edge_rows(assigns.edges))
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
            data-layout-node
            data-layout-node-id={node_id(node)}
            data-layout-lane={node_lane(node)}
            data-layout-phase={node_phase(node)}
          >
            <header data-layout-card-header>
              <p class="bo-layout-card-id">{node_id(node)}</p>
              <h4>{node_title(node)}</h4>
            </header>
            <p :if={node_summary(node)}>{node_summary(node)}</p>
            <p class="bo-layout-card-meta">Phase {node_phase(node)}</p>
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
            <strong>{edge.source}</strong> blocks <strong>{edge.target}</strong>
            <span class="bo-layout-edge-state">{edge_label(edge.state)}</span>
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
      %{index: lane, label: "Lane #{lane + 1}", nodes: Enum.sort_by(lane_nodes, &node_phase/1)}
    end)
  end

  defp edge_rows(edges) do
    edges
    |> Enum.with_index()
    |> Enum.map(fn {edge, index} ->
      %{
        id: string_value(edge, :id, "edge-#{index + 1}"),
        source: string_value(edge, :source, "Unknown source"),
        target: string_value(edge, :target, "Unknown target"),
        state: edge_state(Map.get(edge, :state) || Map.get(edge, "state"))
      }
    end)
  end

  defp node_id(node), do: string_value(node, :id, "Unknown ticket")
  defp node_title(node), do: string_value(node, :title, node_id(node))
  defp node_summary(node), do: optional_string(node, :summary)
  defp node_lane(node), do: non_negative_integer(node, :lane)
  defp node_phase(node), do: non_negative_integer(node, :phase)

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

  defp edge_state(value) when is_atom(value), do: edge_state(Atom.to_string(value))
  defp edge_state(value) when value in @edge_states, do: value
  defp edge_state(_value), do: "unknown"

  defp edge_label(state), do: state |> String.replace("_", " ") |> String.capitalize()
end
