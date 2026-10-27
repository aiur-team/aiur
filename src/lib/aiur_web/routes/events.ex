defmodule AiurWeb.Routes.Events do
  @moduledoc "Authenticated event feed session route."
  use AiurWeb.Kit, :routes

  defmacro session do
    quote do
      scope "/" do
        pipe_through(:dashboard_auth_required)
        post("/api/v1/events/token", AiurWeb.EventsSessionController, :create)
      end
    end
  end
end
