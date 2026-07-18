defmodule AiurWeb.OperatorControlCenter.DashboardShell do
  @moduledoc false

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.RouteRegistry

  attr(:route, :map, required: true)
  attr(:routes, :list, required: true)
  attr(:now, :any, required: true)
  attr(:tracker_kind, :string, required: true)
  attr(:agent_kind, :string, required: true)
  slot(:inner_block, required: true)

  @spec dashboard_shell(map()) :: Phoenix.LiveView.Rendered.t()
  def dashboard_shell(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <aside class="shell-sidebar" aria-label="Operator Control Center navigation">
        <a class="brand-mini" href="/" aria-label="Aiur Operator Control Center">
          <img class="brand-mini-logo" src="/aiur-logo.png" alt="" />
          <span class="brand-wordmark"><b>aiur</b> / Operator Control Center</span>
        </a>
        <.navigation
          routes={@routes}
          current_route={@route}
          class="shell-nav shell-nav-sidebar"
          label="Control Center sidebar routes"
        />
      </aside>

      <div class="shell-main">
        <header class="topbar">
          <div class="route-context">
            <p class="route-eyebrow">Operator Control Center</p>
            <h1 id="route-title">{@route.label}</h1>
            <p>{@route.description}</p>
          </div>
          <div class="toolbar">
            <span class="status-badge status-badge-live"><span class="status-badge-dot"></span>Live</span>
            <span class="status-badge status-badge-offline"><span class="status-badge-dot"></span>Offline</span>
            <span class="status-badge"><span class="status-key">ITS</span> {@tracker_kind}</span>
            <span class="status-badge"><span class="status-key">Agent</span> {@agent_kind}</span>
            <time class="status-badge mono num" datetime={datetime_value(@now)}>{clock_value(@now)}</time>
            <button id="theme-toggle" class="tool-btn" type="button" phx-hook="ThemeToggle" aria-label="Toggle color theme">
              <span class="theme-icon" aria-hidden="true">◐</span>Theme
            </button>
          </div>
        </header>

        <div class="shell-content" aria-labelledby="route-title">
          {render_slot(@inner_block)}
        </div>
      </div>

      <.navigation
        routes={@routes}
        current_route={@route}
        class="shell-nav shell-nav-mobile"
        label="Control Center mobile routes"
      />
    </section>
    """
  end

  attr(:routes, :list, required: true)
  attr(:current_route, :map, required: true)
  attr(:class, :string, required: true)
  attr(:label, :string, required: true)

  defp navigation(assigns) do
    ~H"""
    <nav class={@class} aria-label={@label}>
      <%= for route <- @routes do %>
        <.route_item route={route} current_route={@current_route} active={route.id == @current_route.id} />
      <% end %>
    </nav>
    """
  end

  attr(:route, :map, required: true)
  attr(:current_route, :map, required: true)
  attr(:active, :boolean, required: true)

  defp route_item(assigns) do
    assigns =
      assigns
      |> assign(:available, RouteRegistry.available?(assigns.route))
      |> assign(:navigation_mode, RouteRegistry.navigation_mode(assigns.current_route, assigns.route))

    ~H"""
    <.link
      :if={@available and RouteRegistry.live?(@route) and @navigation_mode == :patch}
      patch={@route.path}
      class={["shell-nav-item", @active && "is-active"]}
      aria-current={if @active, do: "page"}
    >
      <span class="shell-nav-icon" aria-hidden="true">{@route.icon}</span>
      <span class="shell-nav-label">{@route.label}</span>
    </.link>
    <.link
      :if={@available and RouteRegistry.live?(@route) and @navigation_mode == :navigate}
      navigate={@route.path}
      class={["shell-nav-item", @active && "is-active"]}
      aria-current={if @active, do: "page"}
    >
      <span class="shell-nav-icon" aria-hidden="true">{@route.icon}</span>
      <span class="shell-nav-label">{@route.label}</span>
    </.link>
    <.link
      :if={@available and RouteRegistry.document?(@route)}
      href={@route.path}
      class="shell-nav-item"
    >
      <span class="shell-nav-icon" aria-hidden="true">{@route.icon}</span>
      <span class="shell-nav-label">{@route.label}</span>
    </.link>
    <span
      :if={!@available}
      class="shell-nav-item is-unavailable"
      aria-label={"#{@route.label} unavailable"}
      aria-disabled="true"
      title={@route.description}
    >
      <span class="shell-nav-icon" aria-hidden="true">{@route.icon}</span>
      <span class="shell-nav-label">{@route.label}</span>
      <span class="shell-nav-state">Unavailable</span>
    </span>
    """
  end

  defp clock_value(%DateTime{} = now), do: Calendar.strftime(now, "%H:%M:%S")
  defp clock_value(_now), do: "--:--:--"
  defp datetime_value(%DateTime{} = now), do: DateTime.to_iso8601(now)
  defp datetime_value(_now), do: nil
end
