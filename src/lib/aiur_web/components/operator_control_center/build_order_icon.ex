defmodule AiurWeb.OperatorControlCenter.BuildOrderIcon do
  @moduledoc false

  use Phoenix.Component

  alias Aiur.BuildOrder.Icon

  @icons %{
    lane_plan_graph: "◇",
    lane_runtime: "▶",
    lane_dashboard_ui: "▣",
    lane_accounting: "∑",
    lane_platform: "⬡",
    lane_generic: "◫",
    status_ready: "✓",
    status_blocking: "■",
    status_terminal_unsatisfied: "⊘",
    status_unknown: "?",
    status_cyclic: "↻",
    status_generic: "·",
    status_completed: "◆",
    status_not_planned: "—",
    status_paused: "Ⅱ",
    status_retrying: "↺",
    status_waiting: "◷",
    status_working: "●"
  }

  attr(:icon, :any, required: true)
  attr(:class, :any, default: nil)

  @spec build_order_icon(map()) :: Phoenix.LiveView.Rendered.t()
  def build_order_icon(assigns) do
    {key, text, glyph} = normalize(assigns.icon)

    assigns =
      assigns
      |> assign(:key, key)
      |> assign(:text, text)
      |> assign(:glyph, glyph)

    ~H"""
    <span
      class={["bo-icon", @class]}
      role="img"
      aria-label={@text}
      data-icon-key={@key}
    >
      <span class="bo-icon-glyph" aria-hidden="true">{@glyph}</span>
    </span>
    """
  end

  defp normalize(%Icon{key: key, text: text}) when is_map_key(@icons, key) and is_binary(text),
    do: {key, text, Map.fetch!(@icons, key)}

  defp normalize(_icon), do: {:generic, "Status unavailable", "·"}
end
