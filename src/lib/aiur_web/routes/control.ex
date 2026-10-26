defmodule AiurWeb.Routes.Control do
  @moduledoc "Machine control-call route expanded inside AiurWeb.Router."
  use AiurWeb.Kit, :routes

  defmacro calls do
    quote do
      # Keep this authenticated literal-call endpoint ahead of the issue catch-all.
      scope "/" do
        pipe_through(:control_token)

        post("/api/v1/control", AiurWeb.ControlController, :run)
        match(:*, "/api/v1/control", AiurWeb.ControlController, :method_not_allowed)
      end
    end
  end
end
