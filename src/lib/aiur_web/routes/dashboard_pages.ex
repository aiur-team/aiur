defmodule AiurWeb.Routes.DashboardPages do
  @moduledoc "Component routes expanded inside AiurWeb.Router."
  use AiurWeb.Kit, :routes

  defmacro static_assets do
    quote do
      scope "/" do
        pipe_through([:browser_dashboard_auth, :dashboard_pages])

        get("/dashboard.css", AiurWeb.StaticAssetController, :dashboard_css)
        get("/ticket-context-dialog-hook.js", AiurWeb.StaticAssetController, :ticket_context_dialog_hook)
        get("/time-brush-hook.js", AiurWeb.StaticAssetController, :time_brush_hook)
        get("/decision-questions-validation.js", AiurWeb.StaticAssetController, :decision_questions_validation)
        get("/sortable-table-hook.js", AiurWeb.StaticAssetController, :sortable_table_hook)
        get("/streamdeck-emulator-hook.js", AiurWeb.StaticAssetController, :streamdeck_emulator_hook)
        get("/streamdeck-emulator-knob.js", AiurWeb.StaticAssetController, :streamdeck_emulator_knob)
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
        pipe_through([:browser_dashboard_auth, :dashboard_pages, :browser])

        get("/chat/:owner/:repository/:identifier", AiurWeb.ChatRedirectController, :show)
        get("/units", AiurWeb.UnitsRedirectController, :legacy)
        get("/decisions", AiurWeb.CommandsRedirectController, :legacy)
        get("/decisions/:decision_id", AiurWeb.CommandsRedirectController, :legacy)
        get("/build-orders", AiurWeb.BuildOrderRedirectController, :catalog)
        get("/build-orders/:root_number", AiurWeb.BuildOrderRedirectController, :root)

        live_session :dashboard, session: {AiurWeb.Conversation.Access, :session, []}, on_mount: [AiurWeb.DashboardPagesGate, AiurWeb.FinancialDataAccess] do
          live("/", AiurWeb.BuildLive, :build)
          live("/executor", AiurWeb.ExecutorLive, :executor)
          live("/conversations/:conversation_id", AiurWeb.ConversationLive, :show)
          live("/commands", AiurWeb.DashboardLive, :decisions)
          live("/commands/:decision_id", AiurWeb.DashboardLive, :decision)
          live("/voice", AiurWeb.DashboardLive, :voice)
          live("/build", AiurWeb.BuildLive, :build)
          live("/analytics", AiurWeb.AnalyticsLive, :analytics)
          live("/instances", AiurWeb.InstanceRosterLive, :instances)
          live("/post-deploy", AiurWeb.PostDeployLive, :index)
          live("/streamdeck", AiurWeb.StreamdeckLive, :streamdeck)
        end
      end

      scope "/" do
        pipe_through([:browser_dashboard_auth, :dashboard_pages, :secure_document])

        get("/build-order-documents/:owner/:repository/:root_number/:member_number", AiurWeb.PlanningDocumentController, :show)
      end
    end
  end
end
