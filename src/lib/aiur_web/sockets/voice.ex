defmodule AiurWeb.Sockets.Voice do
  @moduledoc """
  Socket mount contributed by the speech-to-text component.
  """

  defmacro mount(session_options) do
    quote do
      # Dashboard dictation audio. The browser streams PCM here and the server owns
      # the ElevenLabs STT session; auth reuses the LiveView session proof.
      socket("/voice", AiurWeb.VoiceSocket,
        websocket: [connect_info: [session: unquote(session_options)], max_frame_size: 400_000],
        longpoll: false
      )
    end
  end
end
