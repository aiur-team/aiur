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
      <aside class="shell-sidebar" aria-label="Aiur navigation">
        <div class="brand-row">
          <a class="brand-mini" href="/" aria-label="Aiur home">
            <img class="brand-mini-logo" src="/aiur-logo.png" alt="" />
            <span class="brand-wordmark"><b>aiur</b></span>
          </a>
          <div class="brand-tools">
            <button
              id="nav-toggle"
              class="tool-btn tool-btn-icon"
              type="button"
              phx-hook="NavToggle"
              aria-label="Hide or show navigation"
              title="Hide or show navigation"
            >
              <span aria-hidden="true">☰</span>
            </button>
            <button
              id="theme-toggle"
              class="tool-btn tool-btn-icon"
              type="button"
              phx-hook="ThemeToggle"
              aria-label="Toggle color theme"
              title="Toggle color theme"
            >
              <span class="theme-icon" aria-hidden="true">◐</span>
            </button>
          </div>
        </div>
        <.navigation
          routes={@routes}
          current_route={@route}
          class="shell-nav shell-nav-sidebar"
          label="Aiur sidebar routes"
        />
      </aside>

      <div class="shell-main">
        <header class="topbar">
          <div class="route-context">
            <h1 id="route-title">{@route.label}</h1>
            <p :if={@route.description not in [nil, ""]}>{@route.description}</p>
          </div>
          <div class="toolbar">
            <span class="status-badge status-badge-live"><span class="status-badge-dot"></span>Live</span>
            <span class="status-badge status-badge-offline"><span class="status-badge-dot"></span>Offline</span>
            <time class="status-badge mono num" datetime={datetime_value(@now)}>{clock_value(@now)}</time>
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
        label="Aiur mobile routes"
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
