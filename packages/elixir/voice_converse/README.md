# VoiceConverse

Host-agnostic voice assistant core. It depends on no host application: everything it needs from
the host arrives through `VoiceConverse.Config` and the behaviours in `VoiceConverse.Ports`.

CI job `voice-converse-standalone` compiles and tests this package alone and fails on any
reference to the host application (`scripts/check-voice-converse-isolation.sh`).

Hosts may set `VoiceConverse.Config.allowed_tools` to a list of tool names for a
restricted session. The default `nil` allows all supported tools; an empty list
disables every tool. The session enforces the list on incoming calls as well as
the advertised tool specifications.

## Recording a session summary

The `record_summary` client tool accepts three required string arrays:
`decisions`, `open_questions`, and `ideas`. It validates and redacts their
contents before broadcasting `{:summary_recorded, summary}` to subscribers.
Hosts treat this classification as untrusted context, not delivery authority.
An invalid call returns an error without replacing an accepted summary.

## Asking the agent

A host whose `AgentChannel.capabilities/1` reports `ask: true` or a fork exposes `ask_agent`
to the provider. Questions sent to the agent wait for a checkpoint; answers arrive
asynchronously. The first question in a
session waits for client confirmation by default; hosts can set
`ask_requires_confirm` to `:first_in_session`, `:always`, or `:never` in
`VoiceConverse.Config`. The channel must subscribe the session to replies and deliver
the reply using the reference returned by `ask/4`. A host may provide a fork for
questions classified as history or reasoning; fresh questions require queued asking.

If the send times out, delivery is uncertain: the question remains open until the
operator clears it, because the agent may still receive it.

## Standalone WebSocket

When the host includes the optional `websock_adapter` and `bandit` dependencies, it can supervise
`VoiceConverse.Transport.WebSock` independently of Phoenix:

```elixir
{VoiceConverse.Transport.WebSock,
 instance: MyVoiceInstance,
 token_issuer: MyApp.VoiceTokenIssuer,
 port: 40_400}
```

It binds `127.0.0.1` by default. The host's `VoiceConverse.Ports.TokenIssuer` verifies a
short-lived token with the `"converse"` scope. Non-browser clients use
`Authorization: Bearer <token>`; browser clients use `?token=<token>` because the WebSocket API
cannot set an Authorization header. Invalid credentials close the socket with code `4401` before
a session is started.

`priv/static/voice_converse_client.js` is a build-free ES module for host pages. Construct a
`VoiceConverseClient` with the socket URL, target and a draft-card container, then call
`bindStart(button)`. Microphone permission is requested only by that button click; captured audio
is echo-cancelled and resampled to 16 kHz PCM. The client and the socket exchange versioned v1
frames defined by `VoiceConverse.Wire` and the JSON Schema in
`packages/aiur-contracts/schemas/voice-converse.v1.schema.json`.

### OpenAI Realtime prototype

`VoiceConverse.Providers.OpenAIRealtime` implements the provider behaviour and is
registered as `:openai_realtime`. Set `providers.preference: [:openai_realtime]`
for registry resolution, and set `provider: VoiceConverse.Providers.OpenAIRealtime`
when building the session config. The
credentials port probes `:openai` and fetches the session credential at connect.
An explicit `llm` Realtime model is required; optional `voice_id` defaults to
`marin`. Tools are registered from the session specification. The adapter uses
the GA websocket protocol, converts 16 kHz PCM input to 24 kHz and tags output as
`:pcm_24000`. Barge-in removes the entire interrupted item from model context
until clients supply playback offsets. Tests use transport doubles only.

Read a host's stored conversations without booting it:

```sh
mix voice_converse.transcripts --root /path/to/transcripts --target executor --limit 10
mix voice_converse.transcripts --root /path/to/transcripts vc_aaaaaaaaaaaaaaaaaaaaaa --json
```

The root is explicit; list limits are 1–100 (default 100). JSON preserves index fields
or raw complete transcript records. Text output reports torn tails and skipped records.

## Role pre-context

Supply `Config.roles` as a list of `%{id: "worker", title: "Ticket discussion",
prompt: "Discuss the ticket"}` maps. Optional `targets` defaults to both
`["worker", "executor"]`. `Config.roles_dir` adds Markdown files with YAML
front matter (`id`, `title`, `targets`) and a nonempty prompt body; directory
roles override inline ids. `Roles.load(config)` returns `%{roles: [...],
warnings: [...]}`; invalid entries are skipped and duplicate ids warn.
`Roles.list(config)` lists ids, titles and targets; `Roles.get(config, id)`
returns a role with `prompt` and lowercase SHA-256 `hash`, or `{:error, :not_found}`.

`Config.glossary` is a list of host-supplied strings appended with blank lines.
The core ships no host roles or glossary. Sessions select the role matching the
target's `worker`/`executor` kind by default, or accept `role_id:` explicitly.
An unknown selection or incompatible target refuses startup. Hosts supplying no
roles can continue using sessions without a role. The selected prompt is frozen
for reconnects and its id/hash are recorded in `session_started`.
