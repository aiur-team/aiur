defmodule Aiur.Voice.Synthesizer do
  @moduledoc """
  Streams one piece of text as speech.

  The owner pid receives:

    * `{:voice_audio, :chunk, binary}`
    * `{:voice_audio, :done}`
    * `{:voice_audio, :error, binary}`
  """

  @doc "Start speaking `text` to `owner`."
  @callback start(pid(), String.t(), keyword()) :: {:ok, pid()} | {:error, atom()}
end
