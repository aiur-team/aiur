defmodule AiurWeb.OperatorControlCenter.BuildOrderEpicIcon do
  @moduledoc """
  Renders the per-epic (build lane) column icon using inlined Heroicons.

  The Heroicons SVG sources are vendored by the `:heroicons` dependency
  (source only, `compile: false`) and inlined here at compile time — the same
  compile-time inlining pattern the layout adapter JS uses. Each icon draws
  with `currentColor`, so the surrounding CSS `color` controls its hue.
  """

  use Phoenix.Component

  # Distinct accent colours per epic, used in the column headings and the epic
  # breakdown list (NOT on the ticket cards, which keep a neutral icon).
  @lane_colors %{
    "plan-graph" => "#8fbcff",
    "runtime" => "#f2cd6b",
    "dashboard-ui" => "#c9a6ff",
    "accounting" => "#6bd6a6",
    "platform" => "#8fbcff",
    "adhoc" => "#f0a0c0",
    "core" => "#c9a6ff",
    "web" => "#6bd6a6",
    "data" => "#f2cd6b",
    "api" => "#7fd4e0",
    "billing" => "#f2836b"
  }

  @generic_color "#9aa0ac"

  attr(:lane, :any, required: true)
  attr(:class, :any, default: nil)
  attr(:colored, :boolean, default: false)

  @spec build_order_epic_icon(map()) :: Phoenix.LiveView.Rendered.t()
  def build_order_epic_icon(assigns) do
    assigns =
      assigns
      |> assign(:svg, svg(assigns.lane))
      |> assign(:label, label(assigns.lane))
      |> assign(:style, assigns.colored && "color: #{color(assigns.lane)}")

    ~H"""
    <span class={["bo-epic-ic", @class]} style={@style} role="img" aria-label={@label}>
      {Phoenix.HTML.raw(@svg)}
    </span>
    """
  end

  @doc "Distinct accent colour for a build lane's epic icon."
  @spec color(term()) :: String.t()
  def color(lane) when is_binary(lane), do: Map.get(@lane_colors, lane, @generic_color)
  def color(_lane), do: @generic_color

  @doc "Human-readable epic label for a build lane."
  @spec label(term()) :: String.t()
  defdelegate label(lane), to: Aiur.BuildOrder.Metadata, as: :lane_label

  @doc "Ordered list of the planning epics (excludes the Ad Hoc overlay lane)."
  @spec planning_lanes() :: [String.t()]
  def planning_lanes, do: ["plan-graph", "runtime", "dashboard-ui", "accounting", "platform"]

  @doc "Trusted inlined SVG, shared with the Stream Deck renderer."
  @spec svg(term()) :: String.t()
  defdelegate svg(lane), to: AiurWeb.EpicIcon
end
