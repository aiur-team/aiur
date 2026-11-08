defmodule AiurWeb.Routes.GatewayHello do
  @moduledoc "Anonymous gateway hello route, expanded inside AiurWeb.Router with no auth pipeline."
  use AiurWeb.Kit, :routes

  defmacro receiver do
    quote do
      scope "/" do
        get("/api/v1/gateway/hello", AiurWeb.GatewayHelloController, :show)
        match(:*, "/api/v1/gateway/hello", AiurWeb.GatewayHelloController, :method_not_allowed)
      end
    end
  end
end
