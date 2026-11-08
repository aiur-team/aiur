defmodule AiurWeb.Routes.CommandsApi do
  @moduledoc "Ticket-scoped Commands routes expanded inside AiurWeb.Router."
  use AiurWeb.Kit, :routes

  defmacro reads do
    quote do
      # Embedded-host reads carry a ticket-scoped grant, not the supervisor
      # credential, and stay available while the dashboard is observe-only.
      # They precede `/api/v1/:issue_identifier` so `commands` is never read as
      # an issue identifier.
      scope "/" do
        pipe_through([:commands_scope_auth])

        get("/api/v1/commands", AiurWeb.CommandsApiController, :index)
        get("/api/v1/commands/:decision_id", AiurWeb.CommandsApiController, :show)
        # Media reads stay on the same scoped grant: the host renders the
        # Command's typed media through this route, and the controller re-checks
        # the ticket set and the Command's own attachment list on every read.
        get("/api/v1/commands/:decision_id/media/:attachment_id", AiurWeb.CommandsApiController, :media)
      end
    end
  end

  defmacro mutations do
    quote do
      scope "/" do
        pipe_through([:commands_scope_auth, :require_writable])

        post("/api/v1/commands/:decision_id/answer", AiurWeb.CommandsApiController, :answer)
        post("/api/v1/commands/:decision_id/reject", AiurWeb.CommandsApiController, :reject)
      end

      # Only the instance supervisor may mint a grant; the host swaps this
      # credential for a short-lived scope at its own server boundary.
      scope "/" do
        pipe_through([:supervisor_auth, :require_writable])

        post("/api/v1/commands/scope", AiurWeb.CommandsApiController, :mint_scope)
      end
    end
  end

  defmacro method_catches do
    quote do
      # The mint path's non-POST methods are caught on the supervisor boundary.
      # A GET for `scope` is matched earlier by the `:decision_id` read, which
      # fails closed on a missing grant, so it needs no supervisor catch here.
      scope "/" do
        pipe_through([:supervisor_auth])

        match(:put, "/api/v1/commands/scope", AiurWeb.CommandsApiController, :method_not_allowed)
        match(:patch, "/api/v1/commands/scope", AiurWeb.CommandsApiController, :method_not_allowed)
        match(:delete, "/api/v1/commands/scope", AiurWeb.CommandsApiController, :method_not_allowed)
      end

      # Unsupported methods stay on the scoped path, so they cannot fall
      # through into the dashboard's Basic-Auth issue API.
      scope "/" do
        pipe_through([:commands_scope_auth])

        match(:put, "/api/v1/commands", AiurWeb.CommandsApiController, :method_not_allowed)
        match(:patch, "/api/v1/commands", AiurWeb.CommandsApiController, :method_not_allowed)
        match(:delete, "/api/v1/commands", AiurWeb.CommandsApiController, :method_not_allowed)
        match(:post, "/api/v1/commands", AiurWeb.CommandsApiController, :method_not_allowed)

        match(:get, "/api/v1/commands/:decision_id/answer", AiurWeb.CommandsApiController, :method_not_allowed)
        match(:put, "/api/v1/commands/:decision_id/answer", AiurWeb.CommandsApiController, :method_not_allowed)
        match(:patch, "/api/v1/commands/:decision_id/answer", AiurWeb.CommandsApiController, :method_not_allowed)
        match(:delete, "/api/v1/commands/:decision_id/answer", AiurWeb.CommandsApiController, :method_not_allowed)

        match(:get, "/api/v1/commands/:decision_id/reject", AiurWeb.CommandsApiController, :method_not_allowed)
        match(:put, "/api/v1/commands/:decision_id/reject", AiurWeb.CommandsApiController, :method_not_allowed)
        match(:patch, "/api/v1/commands/:decision_id/reject", AiurWeb.CommandsApiController, :method_not_allowed)
        match(:delete, "/api/v1/commands/:decision_id/reject", AiurWeb.CommandsApiController, :method_not_allowed)

        match(:post, "/api/v1/commands/:decision_id", AiurWeb.CommandsApiController, :method_not_allowed)
        match(:put, "/api/v1/commands/:decision_id", AiurWeb.CommandsApiController, :method_not_allowed)
        match(:patch, "/api/v1/commands/:decision_id", AiurWeb.CommandsApiController, :method_not_allowed)
        match(:delete, "/api/v1/commands/:decision_id", AiurWeb.CommandsApiController, :method_not_allowed)

        match(:*, "/api/v1/commands/:decision_id/*path", AiurWeb.CommandsApiController, :not_found)
      end
    end
  end
end
