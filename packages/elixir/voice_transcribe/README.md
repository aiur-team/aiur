# VoiceTranscribe

A provider-neutral streaming transcription contract plus an ElevenLabs Scribe v2
realtime implementation, packaged so another Elixir host can pin it by commit
without depending on Aiur, Phoenix dashboard auth, or Stream Deck code.

The package depends on `mint`, `mint_web_socket` and `jason` and on nothing else.
It has no host application, no configuration file, no credential store and no
logging.

## Install

Pin the package by commit from the Aiur monorepo with a sparse checkout, so only
this directory is fetched:

```elixir
def deps do
  [
    {:voice_transcribe,
     git: "https://github.com/aiur-team/aiur.git",
     sparse: "packages/elixir/voice_transcribe",
     rev: "0000000000000000000000000000000000000000"}
  ]
end
```

Replace `rev` with the commit you want to pin. `sparse:` keeps the rest of the
monorepo out of your `deps/` tree.

## Start a session

```elixir
{:ok, session} =
  VoiceTranscribe.Scribe.start(
    owner: self(),
    api_key_fun: fn -> System.get_env("ELEVENLABS_API_KEY") end,
    language_code: "eng"
  )

VoiceTranscribe.Scribe.push(session, Base.encode64(pcm_frame))
VoiceTranscribe.Scribe.commit(session)
```

`start/1` returns an **unlinked** session. Monitor the pid: a provider fault must
be able to end the session without ending the surface that opened it.

| Option | Required | Meaning |
| --- | --- | --- |
| `:owner` | yes | Pid that receives the owner messages below. |
| `:api_key_fun` | yes | Zero-arity function returning the credential, or `nil`/blank when none is configured. |
| `:language_code` | no | Provider language hint. Omitted from the request when absent, so the provider detects the language. |
| `:sample_rate` | no | Frame rate in Hz. Defaults to `16_000`. |
| `:transport` | no | Module implementing `VoiceTranscribe.Scribe.Transport`. Injected so tests never open a socket. |
| `:ready_timeout_ms` | no | How long the session may wait for `session_started`. Defaults to `10_000`. |
| `:flush_timeout_ms` | no | How long the commit flush may wait for the settled transcript. Defaults to `2_000`. |
| `:max_backlog_bytes` | no | Ceiling on audio queued before readiness. Defaults to `426_668`. |
| `:scheduler` / `:ready_scheduler` | no | Clock seams: `fn delay_ms -> ... end` that arrange for `:flush_deadline` / `:ready_deadline`. |

`start/1` returns `{:error, :unconfigured}` when no credential is available, so a
host can say *why* the microphone is off instead of starting a session that
immediately fails.

## Audio format

`push/2` takes **one base64-encoded PCM16 frame**: 16 kHz, mono, signed 16-bit
little-endian, no container and no header. A frame is typically 100–200 ms of
audio.

The frame is relayed to the provider verbatim. It is never decoded, resampled or
re-encoded, so the string you produced is the string the provider receives. If
your capture is at another rate, resample it before encoding — the session will
not do it for you.

## Owner messages

The `owner:` pid receives exactly three shapes:

| Message | Meaning |
| --- | --- |
| `{:voice_transcript, :partial, text}` | Revisable text. May repeat or replace earlier partials. |
| `{:voice_transcript, :final, text}` | Settled text. The authoritative transcript of the utterance. |
| `{:voice_error, %{code: code, message: message}}` | A typed provider failure. `code` is `:provider_auth`, `:provider_quota` or `:provider_error`. `message` is operator-readable. |
| `{:voice_closed}` | The session ended on its own. Sent once, after any transcript or error. |

An explicit `stop/1` closes the session silently: the caller already knows.

## Lifecycle

- **Readiness.** Audio pushed before the provider reports `session_started` is
  queued and flushed in order on that frame, so the first word of a hold is not
  lost. The queue is bounded by `:max_backlog_bytes`; exceeding it fails the
  session rather than growing without limit.
- **Commit.** `commit/1` seals the utterance with the documented empty-chunk
  commit frame and waits for the settled transcript, closing as soon as it
  arrives or on `:flush_timeout_ms`. Audio pushed after a commit is dropped
  rather than reopening the utterance.
- **Release before ready.** A commit that arrives before `session_started` keeps
  the queued audio and flushes it once the session is ready, instead of
  discarding the whole recording.
- **Stop.** `stop/1` closes immediately without committing. `stop/1`, `push/2`
  and `commit/1` are all safe to call on a session that has already ended.

## Credential boundary

The API key is a secret and is handled as narrowly as possible:

- It travels in the `xi-api-key` **request header**, never in the URL. A URL is
  the thing that ends up in logs and error messages.
- It is resolved inside the connect step and discarded there. It is never
  written into the session's process state, so `:sys.get_state/1`, a crash dump
  or an observer session cannot show it.
- A raised or returned failure value is discarded rather than logged or attached
  to a reason, because it can carry the request that raised and the request
  carries the key. Connection failures are reported as a generic message.
- Nothing in this package logs.

The package never reads a credential from the environment or a config file. The
host supplies `:api_key_fun`; the package calls it and forgets the result.

## Testing

The transport is a behaviour, so the whole protocol is exercised without a
socket, and the flush deadline goes through an injected scheduler, so no test
waits on elapsed time:

```bash
mix deps.get
mix compile --warnings-as-errors
mix format --check-formatted
mix test
```

`VoiceTranscribe.Scribe.MintSocketTest` is the one place that drives
`Mint.WebSocket`, against a hand-rolled loopback server that can put the upgrade
response and the first frame in a single TCP segment — the condition that made
the readiness gate fail to open in production.
