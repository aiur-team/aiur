defmodule AiurWeb.Sockets.Streamdeck do
  @moduledoc """
  Socket mount contributed by the Stream Deck server component.
  """

  defmacro mount(_session_options) do
    quote do
      socket("/streamdeck", AiurWeb.StreamdeckSocket,
        websocket: true,
        longpoll: false
      )
    end
  end
end
