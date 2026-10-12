defmodule AiurWeb.Routes.DashboardPages do
  @moduledoc "Component routes expanded inside AiurWeb.Router."
  use AiurWeb.Kit, :routes

  defmacro static_assets do
    quote do
      scope "/" do
        pipe_through([:dashboard_auth, :dashboard_pages])

        get("/dashboard.css", AiurWeb.StaticAssetController, :dashboard_css)
        get("/ticket-context-dialog-hook.js", AiurWeb.StaticAssetController, :ticket_context_dialog_hook)
        get("/build-order-grid-hook.js", AiurWeb.StaticAssetController, :build_order_grid_hook)
        get("/time-brush-hook.js", AiurWeb.StaticAssetController, :time_brush_hook)
        get("/sortable-table-hook.js", AiurWeb.StaticAssetController, :sortable_table_hook)
        get("/streamdeck-emulator-hook.js", AiurWeb.StaticAssetController, :streamdeck_emulator_hook)
        get("/aiur-dom-svg-layout-adapter.js", AiurWeb.StaticAssetController, :dom_svg_layout_adapter)
        get("/aiur-dom-svg-layout-loader.js", AiurWeb.StaticAssetController, :dom_svg_layout_loader)
        get("/aiur-dom-svg-layout/:module", AiurWeb.StaticAssetController, :dom_svg_layout_module)
        get("/aiur-logo.png", AiurWeb.StaticAssetController, :aiur_logo)
        get("/images/github-mark.svg", AiurWeb.StaticAssetController, :github_mark)
        get("/provider-assets/*provider_asset", AiurWeb.StaticAssetController, :provider_asset)
        get("/vendor/phoenix_html/phoenix_html.js", AiurWeb.StaticAssetController, :phoenix_html_js)
        get("/vendor/phoenix/phoenix.js", AiurWeb.StaticAssetController, :phoenix_js)
        get("/vendor/phoenix_live_view/phoenix_live_view.js", AiurWeb.StaticAssetController, :phoenix_live_view_js)
        get("/vendor/layout/:version/:digest/:asset", AiurWeb.StaticAssetController, :layout_asset)
      end
    end
  end

  defmacro pages do
    quote do
      scope "/" do
        pipe_through([:dashboard_auth, :dashboard_pages, :browser])

        get("/decisions", AiurWeb.CommandsRedirectController, :legacy)
        get("/decisions/:decision_id", AiurWeb.CommandsRedirectController, :legacy)

        live_session :dashboard, on_mount: [AiurWeb.DashboardPagesGate, AiurWeb.FinancialDataAccess] do
          live("/", AiurWeb.DashboardLive, :index)
          live("/chat/:owner/:repository/:identifier", AiurWeb.DashboardLive, :index)
          live("/commands", AiurWeb.DashboardLive, :decisions)
          live("/commands/:decision_id", AiurWeb.DashboardLive, :decision)
          live("/build-orders", AiurWeb.BuildOrderLive, :build_orders)
          live("/build-orders/:root_number", AiurWeb.BuildOrderLive, :build_order)
          live("/build", AiurWeb.BuildLive, :build)
          live("/analytics", AiurWeb.AnalyticsLive, :analytics)
          live("/streamdeck", AiurWeb.StreamdeckLive, :streamdeck)
        end
      end

      scope "/" do
        pipe_through([:dashboard_auth, :dashboard_pages, :secure_document])

        get("/build-order-documents/:owner/:repository/:root_number/:member_number", AiurWeb.PlanningDocumentController, :show)
      end
    end
  end
end
