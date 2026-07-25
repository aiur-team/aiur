defmodule AiurWeb.OperatorControlCenter.BuildOrderGraph do
  @moduledoc """
  Spatial Build Order graph: epic **columns** × execution-wave **rows** of small
  ticket cards, with dependency edges drawn between cards by the `BuildOrderGrid`
  client hook. Layout is a CSS grid (no server- or worker-computed geometry); the
  hook only measures rendered card boxes to route edges and owns zoom/pan/fit.
  """

  use Phoenix.Component

  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.TicketContextSelection
  alias AiurWeb.OperatorControlCenter.{BuildOrderEpicIcon, BuildOrderGridModel}

  attr(:id, :string, required: true)
  attr(:root_id, :string, required: true)
  attr(:provider_generation, :integer, required: true)
  attr(:dom_generation, :integer, required: true)
  attr(:model, :any, default: nil)
  attr(:adhoc, :any, default: nil)

  @spec build_order_graph(map()) :: Phoenix.LiveView.Rendered.t()
  def build_order_graph(assigns) do
    grid = BuildOrderGridModel.build(assigns.model, assigns.adhoc)

    cells = Enum.group_by(grid.cards, &{&1.lane, &1.phase})

    assigns =
      assigns
      |> assign(:columns, grid.columns)
      |> assign(:waves, grid.waves)
      |> assign(:edges, grid.edges)
      |> assign(:cells, cells)
      |> assign(:columns_style, columns_style(grid.columns, cells))
      |> assign(:core_waves, Enum.filter(grid.waves, & &1.core?))
      |> assign(:planning?, grid.planning?)

    ~H"""
    <section
      id={@id}
      class="bo-grid-root"
      phx-hook="BuildOrderGrid"
      data-bo-grid
      data-bo-grid-key={"#{@root_id}:#{@provider_generation}"}
      aria-labelledby={"#{@id}-title"}
    >
      <h3 id={"#{@id}-title"} class="sr-only">Build order graph</h3>

      <div :if={@core_waves != [] and not @planning?} class="bo-waves-head" aria-label="Wave completion">

        <div class="bo-waves-strip">
          <div :for={wave <- @core_waves} class="bo-wave-seg">
            <div class="bo-wave-seg-top">
              <span class="bo-wave-seg-label">{wave.label}</span>
              <span class="bo-wave-seg-pct">{wave.pct}%</span>
            </div>
            <span class="bo-wave-seg-meter" aria-hidden="true"><i style={wave_meter_style(wave.pct)}></i></span>
          </div>
        </div>
      </div>

      <div class="bo-grid-toolbar">
        <ul :if={@planning?} class="bo-grid-legend" aria-label="Graph legend">
          <li><span class="bo-legend-swatch is-planned" aria-hidden="true"></span>planned</li>
          <li><span class="bo-legend-line is-planned" aria-hidden="true"></span>dependency</li>
        </ul>
        <ul :if={not @planning?} class="bo-grid-legend" aria-label="Graph legend">
          <li><span class="bo-legend-swatch is-working" aria-hidden="true"></span>agent live</li>
          <li><span class="bo-legend-swatch is-merged" aria-hidden="true"></span>merged</li>
          <li><span class="bo-legend-line is-cleared" aria-hidden="true"></span>cleared</li>
          <li><span class="bo-legend-line is-blocking" aria-hidden="true"></span>blocking</li>
        </ul>
        <div class="bo-grid-zoom" role="group" aria-label="Zoom controls">
          <button type="button" class="bo-grid-zbtn" data-bo-zoom="out" aria-label="Zoom out">&minus;</button>
          <span class="bo-grid-zval" data-bo-zoom-level aria-live="off">100%</span>
          <button type="button" class="bo-grid-zbtn" data-bo-zoom="in" aria-label="Zoom in">+</button>
          <button type="button" class="bo-grid-zbtn" data-bo-zoom="fit" aria-label="Fit graph to view">Fit</button>
        </div>
      </div>

      <p class="sr-only" aria-live="polite" aria-atomic="true" data-bo-grid-announce></p>

      <div class="bo-grid-viewport" data-bo-grid-viewport tabindex="0" role="group" aria-label="Build order graph canvas">
        <div class="bo-grid-scale" data-bo-grid-scale>
          <div class="bo-grid-stage" data-bo-grid-stage role="grid" aria-labelledby={"#{@id}-title"}>
            <div class="bo-grid-lanes" style={@columns_style} role="row">
              <div class="bo-grid-corner" role="columnheader" aria-hidden="true"></div>
              <div :for={col <- @columns} class="bo-epic" role="columnheader">
                <BuildOrderEpicIcon.build_order_epic_icon lane={col.lane} class="bo-epic-icon" colored />
                <span class="bo-epic-label">{col.label}</span>
                <span class="bo-epic-count">{col.count}</span>
              </div>
            </div>

            <div class="bo-grid-body" data-bo-grid-body role="rowgroup">
              <svg class="bo-grid-edges" data-bo-grid-edges aria-hidden="true" focusable="false"></svg>
              <div :for={wave <- @waves} class="bo-grid-wave-row" style={@columns_style} role="row">
                <div class="bo-wave" role="rowheader">
                  <span class="bo-wave-n">{wave.label}</span>
                  <span class="bo-wave-note">{wave.count} tkt</span>
                </div>
                <div :for={col <- @columns} class="bo-cell" role="gridcell">
                  <.build_order_card
                    :for={card <- Map.get(@cells, {col.lane, wave.phase}, [])}
                    card={card}
                    model={@model}
                  />
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <ul class="sr-only" data-bo-grid-edge-data aria-hidden="true">
        <li
          :for={edge <- @edges}
          data-bo-edge-source={edge.source}
          data-bo-edge-target={edge.target}
          data-bo-edge-state={edge.state}
        ></li>
      </ul>
    </section>
    """
  end

  attr(:card, :map, required: true)
  attr(:model, :any, default: nil)

  defp build_order_card(assigns) do
    assigns =
      assigns
      |> assign(:nav_value, nav_value(assigns.model, assigns.card))
      |> assign(:origin_id, origin_id(assigns.model, assigns.card))

    ~H"""
    <div
      class={["bo-node", "is-#{@card.state}", @nav_value && "is-openable"]}
      id={@origin_id}
      data-bo-card={@card.id}
      data-bo-state={@card.state}
      aria-label={card_aria(@card, @nav_value)}
      tabindex="0"
      role={@nav_value && "button"}
      phx-click={@nav_value && "open-ticket-context"}
      phx-value-member={@nav_value}
    >
      <div class="bo-node-top">
        <BuildOrderEpicIcon.build_order_epic_icon lane={@card.lane} class="bo-node-ic" />
        <span class="bo-node-id">{@card.id}</span>
        <span
          class="bo-node-blocks"
          data-bo-pin
          title={blocks_title(@card.blocks)}
          aria-hidden="true"
        ><span class="bo-node-blocks-fill" style={blocks_style(@card.blocks)}>{@card.blocks}</span></span>
      </div>
      <div class="bo-node-title">{@card.title}</div>
      <div class="bo-node-status">
        <span :if={@card.has_progress} class="bo-node-pct">{@card.progress}%</span>
        <span :if={@card.complexity} class="bo-node-cx">Cx {@card.complexity}</span>
        <span class="bo-node-word">{@card.status_word}</span>
      </div>
      <span class="bo-node-bar" aria-hidden="true"><i style={"width:#{@card.progress || 0}%"}></i></span>
    </div>
    """
  end

  # --- helpers ----------------------------------------------------------------

  @card_w 108
  @card_gap 6

  # Each epic column is only as wide as its busiest cell needs: the max number of
  # tickets any single (epic, wave) cell holds, clamped to a cap that shrinks as
  # the number of epics grows (fewer columns → allow up to 3 cards across). A
  # 1-max column is just one card wide, killing the wasted space. The leading
  # 52px track is the sticky wave-label gutter.
  defp columns_style(columns, cells) do
    cap = column_cap(length(columns))

    widths =
      Enum.map_join(columns, " ", fn %{lane: lane} ->
        span = columns |> column_occupancy(cells, lane) |> min(cap) |> max(1)
        "#{span * @card_w + (span - 1) * @card_gap}px"
      end)

    "grid-template-columns: 52px #{widths};"
  end

  defp column_occupancy(_columns, cells, lane) do
    cells
    |> Enum.filter(fn {{cell_lane, _phase}, _cards} -> cell_lane == lane end)
    |> Enum.map(fn {_key, cards} -> length(cards) end)
    |> case do
      [] -> 1
      counts -> Enum.max(counts)
    end
  end

  defp column_cap(epic_count) when epic_count <= 4, do: 3
  defp column_cap(epic_count) when epic_count <= 7, do: 2
  defp column_cap(_epic_count), do: 1

  # Hue ramps red (0%) → green (100%): pct*1.2 maps 100 → 120° (green).
  defp wave_meter_style(pct) when is_integer(pct),
    do: "width:#{pct}%; background:hsl(#{round(pct * 1.2)} 68% 46%)"

  defp wave_meter_style(_pct), do: "width:0%"

  # "Blocks" tag colour ramps green (blocks nothing) → red (blocks many): each
  # blocked ticket shifts the hue 20° toward red, clamped at 0° (red).
  defp blocks_style(blocks) when is_integer(blocks) do
    hue = max(0, 120 - blocks * 20)
    "color: hsl(#{hue} 78% 64%); border-color: hsl(#{hue} 60% 50% / 0.55); background: hsl(#{hue} 55% 45% / 0.16)"
  end

  defp blocks_style(_blocks), do: nil

  defp blocks_title(1), do: "Blocks 1 ticket"
  defp blocks_title(blocks) when is_integer(blocks), do: "Blocks #{blocks} tickets"
  defp blocks_title(_blocks), do: "Blocks no tickets"

  defp nav_value(%AiurWeb.BuildOrderViewModel{} = model, %{identity: %TrackerIdentity{} = identity}) do
    if TrackerIdentity.joinable?(identity),
      do: TicketContextSelection.navigation_value(model, identity)
  end

  defp nav_value(_model, _card), do: nil

  defp origin_id(%AiurWeb.BuildOrderViewModel{} = model, %{identity: %TrackerIdentity{} = identity}),
    do: TicketContextSelection.origin_id(model, identity)

  defp origin_id(_model, _card), do: nil

  defp card_aria(card, nav_value) do
    prefix = if nav_value, do: ["Open ticket context:"], else: []

    (prefix ++ [card.id, card.title, "#{card.progress}%", card.status_word, blocks_title(card.blocks)])
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end
end
