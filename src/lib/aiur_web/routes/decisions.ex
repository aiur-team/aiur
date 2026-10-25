defmodule AiurWeb.Routes.Decisions do
  @moduledoc "Component routes expanded inside AiurWeb.Router."
  use AiurWeb.Kit, :routes

  defmacro mutations do
    quote do
      # Supervisor Decision mutations retain the dashboard's existing write
      # defenses in addition to their dedicated machine credential. Keep these
      # specific routes before `/api/v1/:issue_identifier` so `decisions` cannot
      # be interpreted as an issue identifier.
      scope "/" do
        pipe_through([:supervisor_auth, :api_write, :require_writable])

        post("/api/v1/decisions/:decision_id/enrich", AiurWeb.DecisionApiController, :enrich)
        post("/api/v1/decisions/:decision_id/decide", AiurWeb.DecisionApiController, :decide)
        post("/api/v1/decisions/:decision_id/revise", AiurWeb.DecisionApiController, :revise)
      end
    end
  end

  defmacro reads do
    quote do
      # Read operations require the same supervisor identity but remain available
      # while the dashboard is observe-only and need no browser mutation headers.
      scope "/" do
        pipe_through(:supervisor_auth)

        get("/api/v1/decisions", AiurWeb.DecisionApiController, :index)
        get("/api/v1/decisions/:decision_id", AiurWeb.DecisionApiController, :show)
      end
    end
  end

  defmacro method_catches do
    quote do
      # Authenticated method/shape catches keep unsupported Decision requests from
      # falling through into the dashboard Basic-Auth issue API.
      scope "/" do
        pipe_through(:supervisor_auth)

        match(:*, "/api/v1/decisions", AiurWeb.DecisionApiController, :method_not_allowed)
        match(:*, "/api/v1/decisions/:decision_id/enrich", AiurWeb.DecisionApiController, :method_not_allowed)
        match(:*, "/api/v1/decisions/:decision_id/decide", AiurWeb.DecisionApiController, :method_not_allowed)
        match(:*, "/api/v1/decisions/:decision_id/revise", AiurWeb.DecisionApiController, :method_not_allowed)
        match(:*, "/api/v1/decisions/:decision_id", AiurWeb.DecisionApiController, :method_not_allowed)
        match(:*, "/api/v1/decisions/:decision_id/*path", AiurWeb.DecisionApiController, :not_found)
      end
    end
  end
end
