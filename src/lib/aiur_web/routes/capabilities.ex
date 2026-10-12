defmodule AiurWeb.Routes.Capabilities do
  @moduledoc "Component routes expanded inside AiurWeb.Router."
  use AiurWeb.Kit, :routes

  defmacro reads do
    quote do
      scope "/" do
        pipe_through(:dashboard_auth)

        get("/api/v1/capabilities", AiurWeb.CapabilitiesController, :show)
        match(:*, "/api/v1/capabilities", AiurWeb.CapabilitiesController, :method_not_allowed)
      end
    end
  end
end
