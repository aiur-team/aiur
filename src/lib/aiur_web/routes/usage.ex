defmodule AiurWeb.Routes.Usage do
  @moduledoc "Component routes expanded inside AiurWeb.Router."
  use AiurWeb.Kit, :routes

  defmacro mutations do
    quote do
      scope "/" do
        pipe_through([:dashboard_auth, :api_write, :require_writable])

        put("/api/v1/:issue_identifier/spend-cap", AiurWeb.Api.SpendCapController, :put)
        delete("/api/v1/:issue_identifier/spend-cap", AiurWeb.Api.SpendCapController, :delete)
      end
    end
  end

  defmacro reads do
    quote do
      scope "/" do
        pipe_through(:dashboard_auth)

        get("/api/v1/:issue_identifier/usage", AiurWeb.Api.UsageController, :show)
        match(:*, "/api/v1/:issue_identifier/usage", AiurWeb.Api.UsageController, :method_not_allowed)
        get("/api/v1/:issue_identifier/spend-cap", AiurWeb.Api.SpendCapController, :show)
        match(:*, "/api/v1/:issue_identifier/spend-cap", AiurWeb.Api.SpendCapController, :method_not_allowed)
      end
    end
  end
end
