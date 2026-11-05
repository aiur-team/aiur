defmodule VoiceTranscribe.Transcriber do
  @moduledoc """
  The provider-neutral streaming transcription contract.

  A host starts a session, relays captured audio into it, and receives neutral
  messages back. Nothing in this contract names a provider, a credential, a
  transport or a host application, so a host can swap implementations without
  touching its own code.

  ## Audio

  `push/2` takes **one base64-encoded PCM16 frame**: 16 kHz, mono, signed
  16-bit little-endian, no container and no header. The frame is relayed to the
  provider verbatim — it is never decoded, resampled or re-encoded — so the
  string the host produced is the string the provider receives. A frame is
  typically 100–200 ms of audio; the ceiling is the provider's, not this
  contract's.

  ## Messages to the owner

  The `owner:` pid given to `start/1` receives exactly three shapes:

    * `{:voice_transcript, :partial | :final, text}` — `:partial` text is
      revisable and may repeat or replace earlier partials; `:final` text is
      settled and is the authoritative transcript of the utterance.
    * `{:voice_error, %{code: atom, message: binary}}` — a typed provider
      failure. `code` is `:provider_auth`, `:provider_quota` or
      `:provider_error`; `message` is operator-readable and never contains a
      credential.
    * `{:voice_closed}` — the session has ended. It is sent once, after any
      transcript or error, and the session process stops with `:normal`. An
      explicit `stop/1` is the one exception: the caller already knows it closed
      the session, so no `{:voice_closed}` follows.

  ## Lifecycle

  `start/1` returns an **unlinked** session: a provider fault must be able to
  end the session without ending the surface that opened it. The caller is
  expected to monitor the pid.

  `commit/1` seals the utterance and lets the session close itself once the
  settled transcript arrives. `stop/1` closes immediately without committing.
  Both are idempotent and safe to call on a session that has already ended.
  """

  @typedoc "A typed provider failure. `message` is safe to show an operator."
  @type error :: %{code: :provider_auth | :provider_quota | :provider_error, message: String.t()}

  @typedoc "Every message a session sends its owner."
  @type owner_message ::
          {:voice_transcript, :partial | :final, String.t()}
          | {:voice_error, error()}
          | {:voice_closed}

  @doc """
  Start an unlinked session.

  Required options:

    * `:owner` — the pid that receives the `t:owner_message/0` messages.
    * `:api_key_fun` — a zero-arity function returning the provider credential,
      or `nil`/a blank string when none is configured. The function is called
      inside the connect step and what it returns is never stored.

  Optional options:

    * `:language_code` — a provider language hint. Omitted from the request when
      absent, which lets the provider detect the language.
    * `:sample_rate` — the frame rate in Hz. Defaults to `16_000`.
    * `:transport` — a module implementing the provider's transport behaviour.
      Injected so tests never open a socket.
    * `:ready_timeout_ms`, `:flush_timeout_ms`, `:max_backlog_bytes`,
      `:scheduler`, `:ready_scheduler` — the bounds and the clock seams.

  Returns `{:error, :unconfigured}` when no credential is available, so a host
  can say *why* the microphone is off instead of starting a session that
  immediately fails.
  """
  @callback start(keyword()) :: {:ok, pid()} | {:error, :unconfigured | term()}

  @doc "Relay one base64 PCM16 16 kHz mono frame verbatim."
  @callback push(pid(), String.t()) :: :ok

  @doc "Seal the utterance. The session closes itself once the settled text arrives."
  @callback commit(pid()) :: :ok

  @doc "Close the session immediately without committing the current utterance."
  @callback stop(pid()) :: :ok
end
