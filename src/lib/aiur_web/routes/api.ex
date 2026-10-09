defmodule AiurWeb.Routes.Api do
  @moduledoc "Component routes expanded inside AiurWeb.Router."
  use AiurWeb.Kit, :routes

  defmacro agent_writes do
    quote do
      # Agent-write endpoints driven from the browser/API. Writes are enabled by
      # default; set `observability.dashboard_writable: false` to make them read-only.
      scope "/" do
        pipe_through([:dashboard_auth, :api_write, :require_writable])

        post("/api/v1/refresh", AiurWeb.ObservabilityApiController, :refresh)
        match(:*, "/api/v1/refresh", AiurWeb.ObservabilityApiController, :method_not_allowed)
        post("/api/v1/:issue_identifier/messages", AiurWeb.ObservabilityApiController, :send_message)
        match(:*, "/api/v1/:issue_identifier/messages", AiurWeb.ObservabilityApiController, :method_not_allowed)
        post("/api/v1/:issue_identifier/pause", AiurWeb.ObservabilityApiController, :pause)
        match(:*, "/api/v1/:issue_identifier/pause", AiurWeb.ObservabilityApiController, :method_not_allowed)
        post("/api/v1/:issue_identifier/resume", AiurWeb.ObservabilityApiController, :resume)
        match(:*, "/api/v1/:issue_identifier/resume", AiurWeb.ObservabilityApiController, :method_not_allowed)
      end
    end
  end

  defmacro machine_writes do
    quote do
      # Machine-to-machine write surfaces that are NOT browser-facing and must keep
      # working in read-only mode: the TUI's tmux pane key bindings (interrupt/hide,
      # see aiur.tmux.conf) and the RC claude lifecycle-hook sink (#367).
      scope "/" do
        pipe_through([:dashboard_auth, :api_write])

        post("/api/v1/pane/interrupt", AiurWeb.ObservabilityApiController, :pane_interrupt)
        match(:*, "/api/v1/pane/interrupt", AiurWeb.ObservabilityApiController, :method_not_allowed)
        post("/api/v1/pane/hide", AiurWeb.ObservabilityApiController, :pane_hide)
        match(:*, "/api/v1/pane/hide", AiurWeb.ObservabilityApiController, :method_not_allowed)
        post("/api/v1/:issue_identifier/claude-hook", AiurWeb.ObservabilityApiController, :claude_hook)
        match(:*, "/api/v1/:issue_identifier/claude-hook", AiurWeb.ObservabilityApiController, :method_not_allowed)
      end
    end
  end

  defmacro reads_and_catch_all do
    quote do
      scope "/" do
        pipe_through(:dashboard_auth)

        get("/api/v1/state", AiurWeb.ObservabilityApiController, :state)
        get("/api/v1/streamdeck/grid", AiurWeb.ObservabilityApiController, :streamdeck_grid)
        get("/api/v1/:issue_identifier/events", AiurWeb.ObservabilityApiController, :events)
        match(:*, "/api/v1/:issue_identifier/events", AiurWeb.ObservabilityApiController, :method_not_allowed)
        get("/api/v1/:issue_identifier", AiurWeb.ObservabilityApiController, :issue)
        match(:*, "/", AiurWeb.ObservabilityApiController, :method_not_allowed)
        match(:*, "/api/v1/state", AiurWeb.ObservabilityApiController, :method_not_allowed)
        match(:*, "/api/v1/streamdeck/grid", AiurWeb.ObservabilityApiController, :method_not_allowed)
        match(:*, "/api/v1/:issue_identifier", AiurWeb.ObservabilityApiController, :method_not_allowed)
        match(:*, "/*path", AiurWeb.ObservabilityApiController, :not_found)
      end
    end
  end
end
