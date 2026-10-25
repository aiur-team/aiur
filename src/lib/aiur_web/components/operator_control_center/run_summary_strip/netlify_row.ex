defmodule AiurWeb.OperatorControlCenter.RunSummaryStrip.NetlifyRow do
  use Phoenix.Component

  attr(:usage, :map, default: nil)

  def netlify_api_row(assigns) do
    usage = assigns.usage || %{}
    fields = Map.get(usage, :fields, Map.get(usage, "fields", %{}))
    credits = Map.get(fields, :credits, Map.get(fields, "credits", %{}))
    remaining = Map.get(credits, :estimated_remaining, Map.get(credits, "estimated_remaining"))
    runway = Map.get(credits, :runway_days, Map.get(credits, "runway_days"))
    state = Map.get(usage, :state, Map.get(usage, "state"))
    age = Map.get(usage, :age_ms, Map.get(usage, "age_ms"))
    sites = Map.get(fields, :sites, Map.get(fields, "sites", []))
    account = Map.get(fields, :account, Map.get(fields, "account", %{}))
    exceeded = Map.get(account, :usages_exceeded, Map.get(account, "usages_exceeded", false))

    assigns =
      assigns
      |> assign(:ready?, state in [:ready, "ready"])
      |> assign(:remaining, remaining)
      |> assign(:runway, runway)
      |> assign(:age, age)
      |> assign(:sites, sites)
      |> assign(:account, account)
      |> assign(:exceeded, exceeded)

    ~H"""
    <div class="rs-api rs-netlify rs-provider-row" data-testid="netlify-usage-card">
      <div class="rs-head"><span class="rs-limit-label">Netlify</span></div>
      <div class="rs-provider-body">
        <span :if={@ready? && is_number(@remaining)} class="rs-limit-meta">
          Estimated credits: {Float.round(@remaining * 1.0, 1)} · runway {format_runway(@runway)} · observed {format_age(@age)} ago
        </span>
        <span :if={not @ready? || not is_number(@remaining)} class="rs-limit-meta">Estimated credits: unavailable</span>
        <span :if={is_map(@account)} class="rs-limit-meta">{length(@sites)} sites · {if(@exceeded, do: "usage exceeded", else: "within usage limits")}</span>
      </div>
    </div>
    """
  end

  defp format_runway(days) when is_number(days), do: "#{Float.round(days * 1.0, 1)} days"
  defp format_runway(_), do: "unknown"
  defp format_age(ms) when is_integer(ms), do: "#{div(ms, 1_000)}s"
  defp format_age(_), do: "unknown age"
end
