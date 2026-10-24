defmodule AiurWeb.RouterTableTest do
  use ExUnit.Case, async: true

  defmodule DecisionRouter do
    use Phoenix.Router
    alias AiurWeb.Routes.Decisions
    require Decisions

    pipeline :supervisor_auth do
    end

    pipeline :api_write do
    end

    pipeline :require_writable do
    end

    Decisions.mutations()
    Decisions.reads()
    Decisions.method_catches()
  end

  # Characterization of the pre-split router; deliberately passes on main.
  @expected [
    {:post, "/api/v1/github/webhook", AiurWeb.GithubWebhookController, :create, [:github_webhook], false},
    {:get, "/auth/login", AiurWeb.DashboardAuthController, :login, [:auth_session], :debug},
    {:get, "/auth/google", AiurWeb.DashboardAuthController, :google, [:auth_session], :debug},
    {:get, "/auth/google/callback", AiurWeb.DashboardAuthController, :google_callback, [:auth_session], :debug},
    {:post, "/auth/logout", AiurWeb.DashboardAuthController, :logout, [:auth_post], :debug},
    {:post, "/auth/passkeys/authentication/challenge", AiurWeb.DashboardAuthController, :authentication_challenge, [:auth_post], :debug},
    {:post, "/auth/passkeys/authentication/finish", AiurWeb.DashboardAuthController, :authentication_finish, [:auth_post], :debug},
    {:post, "/auth/passkeys/registration/challenge", AiurWeb.DashboardAuthController, :registration_challenge, [:auth_post], :debug},
    {:post, "/auth/passkeys/registration/finish", AiurWeb.DashboardAuthController, :registration_finish, [:auth_post], :debug},
    {:post, "/api/v1/decisions/:decision_id/enrich", AiurWeb.DecisionApiController, :enrich, [:supervisor_auth, :api_write, :require_writable], :debug},
    {:post, "/api/v1/decisions/:decision_id/decide", AiurWeb.DecisionApiController, :decide, [:supervisor_auth, :api_write, :require_writable], :debug},
    {:post, "/api/v1/decisions/:decision_id/revise", AiurWeb.DecisionApiController, :revise, [:supervisor_auth, :api_write, :require_writable], :debug},
    {:get, "/api/v1/decisions", AiurWeb.DecisionApiController, :index, [:supervisor_auth], :debug},
    {:get, "/api/v1/decisions/:decision_id", AiurWeb.DecisionApiController, :show, [:supervisor_auth], :debug},
    {:*, "/api/v1/decisions", AiurWeb.DecisionApiController, :method_not_allowed, [:supervisor_auth], :debug},
    {:*, "/api/v1/decisions/:decision_id/enrich", AiurWeb.DecisionApiController, :method_not_allowed, [:supervisor_auth], :debug},
    {:*, "/api/v1/decisions/:decision_id/decide", AiurWeb.DecisionApiController, :method_not_allowed, [:supervisor_auth], :debug},
    {:*, "/api/v1/decisions/:decision_id/revise", AiurWeb.DecisionApiController, :method_not_allowed, [:supervisor_auth], :debug},
    {:*, "/api/v1/decisions/:decision_id", AiurWeb.DecisionApiController, :method_not_allowed, [:supervisor_auth], :debug},
    {:*, "/api/v1/decisions/:decision_id/*path", AiurWeb.DecisionApiController, :not_found, [:supervisor_auth], :debug},
    {:get, "/dashboard.css", AiurWeb.StaticAssetController, :dashboard_css, [:browser_dashboard_auth, :dashboard_pages], :debug},
    {:get, "/ticket-context-dialog-hook.js", AiurWeb.StaticAssetController, :ticket_context_dialog_hook, [:browser_dashboard_auth, :dashboard_pages], :debug},
    {:get, "/build-order-grid-hook.js", AiurWeb.StaticAssetController, :build_order_grid_hook, [:browser_dashboard_auth, :dashboard_pages], :debug},
    {:get, "/time-brush-hook.js", AiurWeb.StaticAssetController, :time_brush_hook, [:browser_dashboard_auth, :dashboard_pages], :debug},
    {:get, "/sortable-table-hook.js", AiurWeb.StaticAssetController, :sortable_table_hook, [:browser_dashboard_auth, :dashboard_pages], :debug},
    {:get, "/streamdeck-emulator-hook.js", AiurWeb.StaticAssetController, :streamdeck_emulator_hook, [:browser_dashboard_auth, :dashboard_pages], :debug},
    {:get, "/streamdeck-emulator-knob.js", AiurWeb.StaticAssetController, :streamdeck_emulator_knob, [:browser_dashboard_auth, :dashboard_pages], :debug},
    {:get, "/aiur-dom-svg-layout-adapter.js", AiurWeb.StaticAssetController, :dom_svg_layout_adapter, [:browser_dashboard_auth, :dashboard_pages], :debug},
    {:get, "/aiur-dom-svg-layout-loader.js", AiurWeb.StaticAssetController, :dom_svg_layout_loader, [:browser_dashboard_auth, :dashboard_pages], :debug},
    {:get, "/aiur-dom-svg-layout/:module", AiurWeb.StaticAssetController, :dom_svg_layout_module, [:browser_dashboard_auth, :dashboard_pages], :debug},
    {:get, "/aiur-logo.png", AiurWeb.StaticAssetController, :aiur_logo, [:browser_dashboard_auth, :dashboard_pages], :debug},
    {:get, "/images/github-mark.svg", AiurWeb.StaticAssetController, :github_mark, [:browser_dashboard_auth, :dashboard_pages], :debug},
    {:get, "/provider-assets/*provider_asset", AiurWeb.StaticAssetController, :provider_asset, [:browser_dashboard_auth, :dashboard_pages], :debug},
    {:get, "/vendor/phoenix_html/phoenix_html.js", AiurWeb.StaticAssetController, :phoenix_html_js, [:browser_dashboard_auth, :dashboard_pages], :debug},
    {:get, "/vendor/phoenix/phoenix.js", AiurWeb.StaticAssetController, :phoenix_js, [:browser_dashboard_auth, :dashboard_pages], :debug},
    {:get, "/vendor/phoenix_live_view/phoenix_live_view.js", AiurWeb.StaticAssetController, :phoenix_live_view_js, [:browser_dashboard_auth, :dashboard_pages], :debug},
    {:get, "/vendor/layout/:version/:digest/:asset", AiurWeb.StaticAssetController, :layout_asset, [:browser_dashboard_auth, :dashboard_pages], :debug},
    {:get, "/chat/:owner/:repository/:identifier", AiurWeb.ChatRedirectController, :show, [:browser_dashboard_auth, :dashboard_pages, :browser], :debug},
    {:get, "/decisions", AiurWeb.CommandsRedirectController, :legacy, [:browser_dashboard_auth, :dashboard_pages, :browser], :debug},
    {:get, "/decisions/:decision_id", AiurWeb.CommandsRedirectController, :legacy, [:browser_dashboard_auth, :dashboard_pages, :browser], :debug},
    {:get, "/", Phoenix.LiveView.Plug, :build, [:browser_dashboard_auth, :dashboard_pages, :browser], :debug},
    {:get, "/units", Phoenix.LiveView.Plug, :index, [:browser_dashboard_auth, :dashboard_pages, :browser], :debug},
    {:get, "/commands", Phoenix.LiveView.Plug, :decisions, [:browser_dashboard_auth, :dashboard_pages, :browser], :debug},
    {:get, "/commands/:decision_id", Phoenix.LiveView.Plug, :decision, [:browser_dashboard_auth, :dashboard_pages, :browser], :debug},
    {:get, "/build-orders", Phoenix.LiveView.Plug, :build_orders, [:browser_dashboard_auth, :dashboard_pages, :browser], :debug},
    {:get, "/build-orders/:root_number", Phoenix.LiveView.Plug, :build_order, [:browser_dashboard_auth, :dashboard_pages, :browser], :debug},
    {:get, "/build", Phoenix.LiveView.Plug, :build, [:browser_dashboard_auth, :dashboard_pages, :browser], :debug},
    {:get, "/analytics", Phoenix.LiveView.Plug, :analytics, [:browser_dashboard_auth, :dashboard_pages, :browser], :debug},
    {:get, "/post-deploy", Phoenix.LiveView.Plug, :index, [:browser_dashboard_auth, :dashboard_pages, :browser], :debug},
    {:get, "/streamdeck", Phoenix.LiveView.Plug, :streamdeck, [:browser_dashboard_auth, :dashboard_pages, :browser], :debug},
    {:get, "/build-order-documents/:owner/:repository/:root_number/:member_number", AiurWeb.PlanningDocumentController, :show, [:browser_dashboard_auth, :dashboard_pages, :secure_document], :debug},
    {:get, "/experiments", Phoenix.LiveView.Plug, :experiments, [:browser_dashboard_auth, :dashboard_pages, :browser], :debug},
    {:get, "/experiments/:id", Phoenix.LiveView.Plug, :experiment, [:browser_dashboard_auth, :dashboard_pages, :browser], :debug},
    {:post, "/api/v1/refresh", AiurWeb.ObservabilityApiController, :refresh, [:dashboard_auth, :api_write, :require_writable], :debug},
    {:*, "/api/v1/refresh", AiurWeb.ObservabilityApiController, :method_not_allowed, [:dashboard_auth, :api_write, :require_writable], :debug},
    {:post, "/api/v1/:issue_identifier/messages", AiurWeb.ObservabilityApiController, :send_message, [:dashboard_auth, :api_write, :require_writable], :debug},
    {:*, "/api/v1/:issue_identifier/messages", AiurWeb.ObservabilityApiController, :method_not_allowed, [:dashboard_auth, :api_write, :require_writable], :debug},
    {:post, "/api/v1/:issue_identifier/pause", AiurWeb.ObservabilityApiController, :pause, [:dashboard_auth, :api_write, :require_writable], :debug},
    {:*, "/api/v1/:issue_identifier/pause", AiurWeb.ObservabilityApiController, :method_not_allowed, [:dashboard_auth, :api_write, :require_writable], :debug},
    {:post, "/api/v1/:issue_identifier/resume", AiurWeb.ObservabilityApiController, :resume, [:dashboard_auth, :api_write, :require_writable], :debug},
    {:*, "/api/v1/:issue_identifier/resume", AiurWeb.ObservabilityApiController, :method_not_allowed, [:dashboard_auth, :api_write, :require_writable], :debug},
    {:post, "/api/v1/pane/interrupt", AiurWeb.ObservabilityApiController, :pane_interrupt, [:dashboard_auth, :api_write], :debug},
    {:*, "/api/v1/pane/interrupt", AiurWeb.ObservabilityApiController, :method_not_allowed, [:dashboard_auth, :api_write], :debug},
    {:post, "/api/v1/pane/hide", AiurWeb.ObservabilityApiController, :pane_hide, [:dashboard_auth, :api_write], :debug},
    {:*, "/api/v1/pane/hide", AiurWeb.ObservabilityApiController, :method_not_allowed, [:dashboard_auth, :api_write], :debug},
    {:post, "/api/v1/:issue_identifier/claude-hook", AiurWeb.ObservabilityApiController, :claude_hook, [:dashboard_auth, :api_write], :debug},
    {:*, "/api/v1/:issue_identifier/claude-hook", AiurWeb.ObservabilityApiController, :method_not_allowed, [:dashboard_auth, :api_write], :debug},
    {:post, "/api/v1/streamdeck/token", AiurWeb.StreamdeckSessionController, :create, [:dashboard_auth_required], :debug},
    {:get, "/api/v1/capabilities", AiurWeb.CapabilitiesController, :show, [:dashboard_auth], :debug},
    {:*, "/api/v1/capabilities", AiurWeb.CapabilitiesController, :method_not_allowed, [:dashboard_auth], :debug},
    {:get, "/api/v1/:issue_identifier/usage", AiurWeb.Api.UsageController, :show, [:dashboard_auth], :debug},
    {:*, "/api/v1/:issue_identifier/usage", AiurWeb.Api.UsageController, :method_not_allowed, [:dashboard_auth], :debug},
    {:get, "/api/v1/:issue_identifier/progress", AiurWeb.Api.UsageProgressController, :show, [:dashboard_auth], :debug},
    {:*, "/api/v1/:issue_identifier/progress", AiurWeb.Api.UsageProgressController, :method_not_allowed, [:dashboard_auth], :debug},
    {:get, "/api/v1/usage/accounts", AiurWeb.UsageAccountsApiController, :show, [:dashboard_auth], :debug},
    {:*, "/api/v1/usage/accounts", AiurWeb.UsageAccountsApiController, :method_not_allowed, [:dashboard_auth], :debug},
    {:get, "/api/v1/state", AiurWeb.ObservabilityApiController, :state, [:dashboard_auth], :debug},
    {:get, "/api/v1/streamdeck/grid", AiurWeb.ObservabilityApiController, :streamdeck_grid, [:dashboard_auth], :debug},
    {:get, "/api/v1/:issue_identifier/events", AiurWeb.ObservabilityApiController, :events, [:dashboard_auth], :debug},
    {:*, "/api/v1/:issue_identifier/events", AiurWeb.ObservabilityApiController, :method_not_allowed, [:dashboard_auth], :debug},
    {:get, "/api/v1/:issue_identifier", AiurWeb.ObservabilityApiController, :issue, [:dashboard_auth], :debug},
    {:*, "/", AiurWeb.ObservabilityApiController, :method_not_allowed, [:dashboard_auth], :debug},
    {:*, "/api/v1/state", AiurWeb.ObservabilityApiController, :method_not_allowed, [:dashboard_auth], :debug},
    {:*, "/api/v1/streamdeck/grid", AiurWeb.ObservabilityApiController, :method_not_allowed, [:dashboard_auth], :debug},
    {:*, "/api/v1/:issue_identifier", AiurWeb.ObservabilityApiController, :method_not_allowed, [:dashboard_auth], :debug},
    {:*, "/*path", AiurWeb.ObservabilityApiController, :not_found, [:dashboard_auth], :debug}
  ]

  test "compiled route table and matched pipelines retain pre-split behavior" do
    actual = Enum.map(AiurWeb.Router.__routes__(), &project/1)
    assert actual == @expected
  end

  test "webhook is first, catch-all is last, and Decision catches precede issue reads" do
    routes = AiurWeb.Router.__routes__()
    assert hd(routes).plug == AiurWeb.GithubWebhookController
    assert List.last(routes).path == "/*path"
    issue_index = Enum.find_index(routes, &(&1.verb == :get and &1.path == "/api/v1/:issue_identifier"))
    decisions = routes |> Enum.with_index() |> Enum.filter(fn {route, _} -> route.plug == AiurWeb.DecisionApiController end)
    assert length(decisions) == 11
    assert Enum.all?(decisions, fn {_, index} -> index < issue_index end)
  end

  test "Decision component routes expand independently of the application router" do
    expected = Enum.filter(@expected, fn {_, _, plug, _, _, _} -> plug == AiurWeb.DecisionApiController end)
    assert Enum.map(DecisionRouter.__routes__(), &project(&1, DecisionRouter)) == expected
  end

  defp project(route, router \\ AiurWeb.Router) do
    # __routes__/0 omits pipelines in Phoenix 1.8; match each route with a concrete path.
    path = Regex.replace(~r/[:*][^\/]+/, route.path, "fixture")
    method = if route.verb == :*, do: "AIUR_TEST", else: route.verb |> Atom.to_string() |> String.upcase()
    info = Phoenix.Router.route_info(router, method, path, "localhost")
    assert info.route == route.path
    {route.verb, route.path, route.plug, route.plug_opts, info.pipe_through, route.metadata[:log]}
  end
end
