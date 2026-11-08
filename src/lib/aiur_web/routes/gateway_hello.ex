defmodule AiurWeb.Routes.GatewayHello do
  @moduledoc "Anonymous gateway hello and invite-enrol routes (the enrol secret is the credential), expanded inside AiurWeb.Router with no auth pipeline."
  use AiurWeb.Kit, :routes

  defmacro receiver do
    quote do
      scope "/" do
        get("/api/v1/gateway/hello", AiurWeb.GatewayHelloController, :show)
        match(:*, "/api/v1/gateway/hello", AiurWeb.GatewayHelloController, :method_not_allowed)
        post("/api/v1/gateway/enroll", AiurWeb.GatewayEnrollController, :create, log: false)
      end
    end
  end
end
