defmodule AiurWeb.Routes.Streamdeck do
  @moduledoc "Component routes expanded inside AiurWeb.Router."
  use AiurWeb.Kit, :routes

  defmacro session do
    quote do
      scope "/" do
        pipe_through(:dashboard_auth_required)

        post("/api/v1/streamdeck/token", AiurWeb.StreamdeckSessionController, :create)
      end
    end
  end
end
