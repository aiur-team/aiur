defmodule Aiur.Voice.Transcriber do
  @moduledoc """
  One streaming speech-to-text session.

  The `owner:` pid given to `start/1` receives:

    * `{:voice_transcript, :partial | :final, text}`
    * `{:voice_error, %{code: atom, message: binary}}`
    * `{:voice_closed}`
  """

  @doc "Start an unlinked session. `opts` include `owner: pid`."
  @callback start(keyword()) :: {:ok, pid()} | {:error, :unconfigured | term()}

  @doc "Relay one base64 PCM16 16 kHz mono frame verbatim."
  @callback push(pid(), String.t()) :: :ok

  @doc "Flush the tail of the utterance. The session closes itself afterwards."
  @callback commit(pid()) :: :ok

  @doc "Close the session immediately without committing."
  @callback stop(pid()) :: :ok
end
