defmodule AiurWeb.OperatorControlCenter.BuildOrderEpicIcon do
  @moduledoc """
  Renders the per-epic (build lane) column icon using inlined Heroicons.

  The Heroicons SVG sources are vendored by the `:heroicons` dependency
  (source only, `compile: false`) and inlined here at compile time — the same
  compile-time inlining pattern the layout adapter JS uses. Each icon draws
  with `currentColor`, so the surrounding CSS `color` controls its hue.
  """

  use Phoenix.Component

  # Epic (build lane) -> Heroicons v2 outline icon name.
  @lane_icons %{
    "plan-graph" => "share",
    "runtime" => "bolt",
    "dashboard-ui" => "rectangle-group",
    "accounting" => "banknotes",
    "platform" => "server-stack",
    # Additional lanes used by planning packs (e.g. the CropTracker demo).
    "core" => "cube",
    "web" => "window",
    "data" => "circle-stack",
    "api" => "cloud",
    "billing" => "credit-card"
  }

  @generic_icon "squares-2x2"
  @explicit_icons ["bolt", "cube", "sparkles", "server-stack", "rectangle-group"]

  # Vendored by the `:heroicons` dep (source only); present at compile time.
  @outline_dir "deps/heroicons/optimized/24/outline"

  @svgs (for name <- Map.values(@lane_icons) ++ @explicit_icons ++ [@generic_icon], into: %{} do
           path = Path.join(@outline_dir, "#{name}.svg")
           @external_resource path

           svg =
             path
             |> File.read!()
             |> String.replace(~r/\s+data-slot="icon"/, "")
             |> String.trim()

           {name, svg}
         end)

  # Distinct accent colours per epic, used in the column headings and the epic
  # breakdown list (NOT on the ticket cards, which keep a neutral icon).
  @lane_colors %{
    "plan-graph" => "#8fbcff",
    "runtime" => "#f2cd6b",
    "dashboard-ui" => "#c9a6ff",
    "accounting" => "#6bd6a6",
    "platform" => "#8fbcff",
    "core" => "#c9a6ff",
    "web" => "#6bd6a6",
    "data" => "#f2cd6b",
    "api" => "#7fd4e0",
    "billing" => "#f2836b"
  }

  @generic_color "#9aa0ac"

  @lane_labels %{
    "plan-graph" => "Plan graph",
    "runtime" => "Runtime",
    "dashboard-ui" => "Dashboard UI",
    "accounting" => "Accounting",
    "platform" => "Platform",
    "core" => "Core",
    "web" => "Web",
    "data" => "Data",
    "api" => "API",
    "billing" => "Billing"
  }

  attr(:lane, :any, required: true)
  attr(:class, :any, default: nil)
  attr(:colored, :boolean, default: false)

  @spec build_order_epic_icon(map()) :: Phoenix.LiveView.Rendered.t()
  def build_order_epic_icon(assigns) do
    assigns =
      assigns
      |> assign(:svg, svg_for(assigns.lane))
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
  def label(lane) when is_binary(lane) do
    Map.get(@lane_labels, lane) || lane |> String.replace("-", " ") |> capitalize_words()
  end

  def label(_lane), do: "Unassigned"

  @doc "Ordered list of the built-in planning epics."
  @spec planning_lanes() :: [String.t()]
  def planning_lanes, do: ["plan-graph", "runtime", "dashboard-ui", "accounting", "platform"]

  defp svg_for(lane) when is_binary(lane) do
    name = Map.get(@lane_icons, lane, lane)
    Map.get(@svgs, name, Map.fetch!(@svgs, @generic_icon))
  end

  defp svg_for(_lane), do: Map.fetch!(@svgs, @generic_icon)

  defp capitalize_words(text) do
    text
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
