defmodule AiurWeb.EndpointSocketsTest do
  use ExUnit.Case, async: true

  test "socket mounts preserve the pre-registration contract (future regression guard)" do
    session_options = [store: :cookie, key: "_aiur_key", signing_salt: "aiur-session"]

    # Phoenix 1.8.9's private __sockets__/0 returns accumulated mounts in reverse declaration order.
    assert AiurWeb.Endpoint.__sockets__() == [
             {"/voice", AiurWeb.VoiceSocket, websocket: [connect_info: [session: session_options], max_frame_size: 400_000], longpoll: false},
             {"/streamdeck", AiurWeb.StreamdeckSocket, websocket: true, longpoll: false},
             {"/live", Phoenix.LiveView.Socket, websocket: [connect_info: [:user_agent, session: session_options]], longpoll: false}
           ]
  end
end
