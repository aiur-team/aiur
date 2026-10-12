defmodule Aiur.ElevenLabs do
  @moduledoc "The ElevenLabs voice provider behind `Aiur.Voice`."

  @behaviour Aiur.Voice.Provider

  alias Aiur.Config

  @impl true
  def transcriber, do: Aiur.ElevenLabs.Realtime

  @impl true
  def synthesizer, do: Aiur.ElevenLabs.TTS

  @impl true
  def configured? do
    case Config.elevenlabs_api_key() do
      key when is_binary(key) -> String.trim(key) != ""
      _absent -> false
    end
  rescue
    _unavailable -> false
  catch
    _kind, _reason -> false
  end
end
