defmodule AiurWeb.Routes.Usage do
  @moduledoc "Component routes expanded inside AiurWeb.Router."
  use AiurWeb.Kit, :routes

  defmacro reads do
    quote do
      scope "/" do
        pipe_through(:dashboard_auth)

        get("/api/v1/:issue_identifier/usage", AiurWeb.Api.UsageController, :show)
        match(:*, "/api/v1/:issue_identifier/usage", AiurWeb.Api.UsageController, :method_not_allowed)
      end
    end
  end
end
