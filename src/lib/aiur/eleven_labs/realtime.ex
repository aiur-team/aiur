defmodule Aiur.ElevenLabs.Realtime do
  @moduledoc """
  Aiur's binding of the extracted `VoiceTranscribe.Scribe` session.

  The protocol — readiness, first-word backlog, backlog ceiling, commit flush,
  provider error classification, credential handling — lives in the
  `voice_transcribe` package so another host can pin it by commit and reuse one
  implementation. This module supplies only the two values that belong to Aiur:

    * where the credential comes from (`Aiur.Config`), and
    * which language to request (`elevenlabs.language_code`).

  Everything else is a straight delegation, so the dashboard and Stream Deck
  paths keep the `Aiur.Voice.Transcriber` contract and their existing behaviour.
  """

  @behaviour Aiur.Voice.Transcriber

  alias Aiur.Config
  alias VoiceTranscribe.Scribe

  @impl Aiur.Voice.Transcriber
  @doc """
  Start a session unlinked. The caller is expected to monitor it: a provider
  fault must be able to end the session without ending the surface that opened
  it.
  """
  @spec start(keyword()) :: GenServer.on_start() | {:error, :unconfigured}
  def start(opts), do: Scribe.start(host_opts(opts))

  @doc "Start a session linked to the caller. See `start/1` for the unlinked form."
  @spec start_link(keyword()) :: GenServer.on_start() | {:error, :unconfigured}
  def start_link(opts), do: Scribe.start_link(host_opts(opts))

  @impl Aiur.Voice.Transcriber
  @doc "Relay one base64 PCM frame verbatim. Nothing is decoded or re-encoded here."
  @spec push(GenServer.server(), String.t()) :: :ok
  def push(server, audio_base64), do: Scribe.push(server, audio_base64)

  @impl Aiur.Voice.Transcriber
  @doc "Seal the utterance with the documented empty-chunk commit flush, then close."
  @spec commit(GenServer.server()) :: :ok
  def commit(server), do: Scribe.commit(server)

  @impl Aiur.Voice.Transcriber
  @doc "Close a session immediately without committing the current utterance."
  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: Scribe.stop(server)

  # `put_new` rather than `put`: a caller that injects its own reader (the
  # external latency test does) keeps it, and the config read is only a default.
  defp host_opts(opts) do
    opts
    |> Keyword.put_new(:api_key_fun, &Config.elevenlabs_api_key/0)
    |> Keyword.put_new(:language_code, language_code())
  end

  defp language_code do
    Config.elevenlabs_language_code()
  rescue
    _unavailable -> "eng"
  catch
    _kind, _reason -> "eng"
  end
end
