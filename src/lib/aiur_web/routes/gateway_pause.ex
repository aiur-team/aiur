defmodule AiurWeb.Routes.GatewayPause do
  @moduledoc "Gateway and fleet pause writes, expanded inside AiurWeb.Router ahead of the issue catch-all."
  use AiurWeb.Kit, :routes

  defmacro writes do
    quote do
      scope "/" do
        pipe_through(:gateway_write)

        post("/api/v1/gateway/pause", AiurWeb.GatewayPauseController, :pause)
        match(:*, "/api/v1/gateway/pause", AiurWeb.GatewayPauseController, :method_not_allowed)
        post("/api/v1/gateway/resume", AiurWeb.GatewayPauseController, :resume)
        match(:*, "/api/v1/gateway/resume", AiurWeb.GatewayPauseController, :method_not_allowed)
        post("/api/v1/fleet/pause", AiurWeb.GatewayPauseController, :fleet_pause)
        match(:*, "/api/v1/fleet/pause", AiurWeb.GatewayPauseController, :method_not_allowed)
        post("/api/v1/fleet/resume", AiurWeb.GatewayPauseController, :fleet_resume)
        match(:*, "/api/v1/fleet/resume", AiurWeb.GatewayPauseController, :method_not_allowed)
      end
    end
  end
end
