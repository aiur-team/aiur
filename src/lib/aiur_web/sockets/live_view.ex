defmodule AiurWeb.Sockets.LiveView do
  @moduledoc """
  LiveView socket mount contributed by the dashboard component.
  """

  defmacro mount(_session_options) do
    quote do
      socket("/live", Phoenix.LiveView.Socket,
        websocket: [connect_info: [:user_agent, session: {Aiur.Config.SessionOptions, :runtime_options, []}]],
        longpoll: false
      )
    end
  end
end
