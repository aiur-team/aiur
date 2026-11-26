defmodule AiurWeb.Sockets.Events do
  @moduledoc "Socket mount for the external event feed."

  defmacro mount(_session_options) do
    quote do
      socket("/events", AiurWeb.EventsSocket, websocket: true, longpoll: false)
    end
  end
end
