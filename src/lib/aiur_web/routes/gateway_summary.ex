defmodule AiurWeb.Routes.GatewaySummary do
  @moduledoc "Gateway summary route, expanded inside AiurWeb.Router ahead of the issue catch-all."
  use AiurWeb.Kit, :routes

  defmacro reads do
    quote do
      scope "/" do
        pipe_through(:gateway_summary)

        get("/api/v1/gateway/summary", AiurWeb.GatewaySummaryController, :show)
        match(:*, "/api/v1/gateway/summary", AiurWeb.GatewaySummaryController, :method_not_allowed)
      end
    end
  end
end
