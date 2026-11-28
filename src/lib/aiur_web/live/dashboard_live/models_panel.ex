defmodule AiurWeb.DashboardLive.ModelsPanel do
  @moduledoc false
  use Phoenix.Component

  @spec panel(map()) :: Phoenix.LiveView.Rendered.t()
  def panel(assigns) do
    ~H"""
    <section class="control-panel" id="models-panel">
      <header><h2>Models</h2><p>Configured routes in dispatch order. Meter values remain unknown until observed.</p></header>
      <div :if={@models_projection.routes == []} class="empty-state">No model routes are configured.</div>
      <article :for={route <- @models_projection.routes} class="control-card" data-route={route.position}>
        <header><span class="eyebrow">Route {route.position} · {route.source}</span><span class={if route.dispatch.available, do: "status-badge", else: "status-badge status-badge-offline"}>{if route.dispatch.available, do: "Available", else: "Unavailable"}</span></header>
        <h3>{route.backend} · {route.model || "backend default"}</h3>
        <p :if={route.effort}>Effort: {route.effort}</p>
        <p>Account(s): {Enum.map_join(route.accounts, ", ", &"#{&1.name} (#{&1.freshness})")}</p>
        <p :if={route.dispatch.reason}>Dispatch status: {String.replace(route.dispatch.reason, "_", " ")}</p>
        <div class="models-windows">
          <div :for={window <- route.usage.windows}><b>{window.name}</b><span>{usage_percent(window.used_percent)}</span><span>Reset: {reset_time(window.reset_at)}</span><span>Freshness: {window.freshness}</span></div>
        </div>
      </article>
    </section>
    """
  end

  defp usage_percent(value) when is_number(value), do: "#{Float.round(value * 1.0, 1)}% used"
  defp usage_percent(_), do: "Unknown usage"
  defp reset_time(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M UTC")
  defp reset_time(_), do: "Unknown"
end
