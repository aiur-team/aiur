defmodule AiurWeb.Sockets.LiveView do
  @moduledoc """
  LiveView socket mount contributed by the dashboard component.
  """

  defmacro mount(session_options) do
    quote do
      socket("/live", Phoenix.LiveView.Socket,
        websocket: [connect_info: [:user_agent, session: unquote(session_options)]],
        longpoll: false
      )
    end
  end
end
