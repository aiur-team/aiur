defmodule AiurWeb.OperatorControlCenter.BuildOrderEpicIcon do
  @moduledoc """
  Renders the per-epic (build lane) column icon using inlined Heroicons.

  The Heroicons SVG sources are vendored by the `:heroicons` dependency
  (source only, `compile: false`) and inlined here at compile time — the same
  compile-time inlining pattern the layout adapter JS uses. Each icon draws
  with `currentColor`, so the surrounding CSS `color` controls its hue.
  """

  use Phoenix.Component

  # Epic (build lane) -> Heroicons v2 outline icon name. "adhoc" is the runtime
  # Ad Hoc overlay lane, tracked separately from the planning lanes.
  @lane_icons %{
    "plan-graph" => "share",
    "runtime" => "bolt",
    "dashboard-ui" => "rectangle-group",
    "accounting" => "banknotes",
    "platform" => "server-stack",
    "adhoc" => "sparkles",
    # Additional lanes used by planning packs (e.g. the CropTracker demo).
    "core" => "cube",
    "web" => "window",
    "data" => "circle-stack",
    "api" => "cloud",
    "billing" => "credit-card"
  }

  @generic_icon "squares-2x2"

  # Vendored by the `:heroicons` dep (source only); present at compile time.
  @outline_dir "deps/heroicons/optimized/24/outline"

  @svgs (for name <- Map.values(@lane_icons) ++ [@generic_icon], into: %{} do
           path = Path.join(@outline_dir, "#{name}.svg")
           @external_resource path

           svg =
             path
             |> File.read!()
             |> String.replace(~r/\s+data-slot="icon"/, "")
             |> String.trim()

           {name, svg}
         end)

  @lane_labels %{
    "plan-graph" => "Plan graph",
    "runtime" => "Runtime",
    "dashboard-ui" => "Dashboard UI",
    "accounting" => "Accounting",
    "platform" => "Platform",
    "adhoc" => "Ad Hoc",
    "core" => "Core",
    "web" => "Web",
    "data" => "Data",
    "api" => "API",
    "billing" => "Billing"
  }

  attr(:lane, :any, required: true)
  attr(:class, :any, default: nil)

  @spec build_order_epic_icon(map()) :: Phoenix.LiveView.Rendered.t()
  def build_order_epic_icon(assigns) do
    assigns =
      assigns
      |> assign(:svg, svg_for(assigns.lane))
      |> assign(:label, label(assigns.lane))

    ~H"""
    <span class={["bo-epic-ic", @class]} role="img" aria-label={@label}>
      {Phoenix.HTML.raw(@svg)}
    </span>
    """
  end

  @doc "Human-readable epic label for a build lane."
  @spec label(term()) :: String.t()
  def label(lane) when is_binary(lane) do
    Map.get(@lane_labels, lane) || lane |> String.replace("-", " ") |> capitalize_words()
  end

  def label(_lane), do: "Unassigned"

  @doc "Ordered list of the planning epics (excludes the Ad Hoc overlay lane)."
  @spec planning_lanes() :: [String.t()]
  def planning_lanes, do: ["plan-graph", "runtime", "dashboard-ui", "accounting", "platform"]

  defp svg_for(lane) when is_binary(lane) do
    name = Map.get(@lane_icons, lane, @generic_icon)
    Map.get(@svgs, name, Map.fetch!(@svgs, @generic_icon))
  end

  defp svg_for(_lane), do: Map.fetch!(@svgs, @generic_icon)

  defp capitalize_words(text) do
    text
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
