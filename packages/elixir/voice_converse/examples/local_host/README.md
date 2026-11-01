# Standalone local host

A Bandit application using only `voice_converse`, its own configuration, and
files. No Aiur daemon, dashboard, agent CLI, or parent application is needed.

## Quick start (five steps)

1. Install Elixir 1.19 / OTP 28 and Node 24 (Node is needed only for tests).
2. Enter `packages/elixir/voice_converse/examples/local_host` and run `mix deps.get`.
3. Edit `briefing.md` and `notes.md` to describe your project.
4. Run `mix run --no-halt`. The default fake provider opens a silent session
   without credentials. For speech, choose a provider as described below before starting.
5. Open <http://127.0.0.1:4100/>, click **Converse**, and allow microphone access.
   With a real provider, ask “what am I doing?”, propose an instruction, and
   click **Confirm** on its draft. Inspect `outbox.ndjson` and `transcripts/`.
   Click **End conversation** when finished. Reload the page to get a fresh
   token after five minutes, or before opening a new session.

## Configuration

`config/runtime.exs` is the host's configuration file. It reads these variables;
there is no `.aiur/config` discovery or `.env` loading.

| Variable | Default | Meaning |
| --- | --- | --- |
| `VOICE_HOST_ROOT` | current directory | Directory holding Markdown, NDJSON and transcripts |
| `VOICE_HOST_PORT` | `4100` | HTTP and WebSocket port; IPv4 loopback only |
| `VOICE_HOST_PROVIDER` | `fake` | `fake`, `openai`, or `elevenlabs` |
| `VOICE_HOST_MODEL` | `fake` | Explicit model for the chosen provider |
| `VOICE_HOST_CLOUD_ACCEPTED` | false | Set `true` to accept sending audio/text to a cloud provider |
| `VOICE_HOST_ELEVENLABS_AGENT_ID` | absent | Your configured ElevenLabs conversational agent id |

The credentials port reads `OPENAI_API_KEY`, `ELEVENLABS_API_KEY`,
`GEMINI_API_KEY`, and `ANTHROPIC_API_KEY` at use time. Gemini and Anthropic
credentials are exposed for future host extensions; this example selects only
the currently implemented OpenAI Realtime and ElevenLabs Agents transports.

For OpenAI, export `OPENAI_API_KEY`, `VOICE_HOST_PROVIDER=openai`, your
`VOICE_HOST_MODEL`, and `VOICE_HOST_CLOUD_ACCEPTED=true`. For ElevenLabs,
export `ELEVENLABS_API_KEY`, `VOICE_HOST_PROVIDER=elevenlabs`, your model,
`VOICE_HOST_ELEVENLABS_AGENT_ID`, and the same cloud acceptance. Real sessions
can incur provider charges. Tests never select these transports.

The host installs an ephemeral HMAC signing secret and supplies the issuer and
credentials through ports. Tokens expire after five minutes and are never
provider credentials. Restarting the host invalidates existing tokens. It serves
only the expected loopback Host, so use the numeric URL above.

## File ports

The fixed headings **Summary**, **Doing now**, **Next**, **Waiting on**, and
**Questions for you** populate `VoiceConverse.Briefing`. Missing headings remain
unknown. `details(target, "notes", [])` reads `notes.md`. A 500 ms poll detects
briefing changes and sends `{:briefing_updated, target, {:ok, briefing}}` to
subscribers; a missing file yields `{:error, :unavailable}`. The current core
reads the latest briefing on session start and explicit refresh; it does not
consume this host notification automatically.

The channel appends one JSON object per line to `outbox.ndjson`:

```json
{"type":"ask","target":"local","text":"What lens?","ref":"delivery-reference"}
```

Confirmed instructions have `type: "instruct"` and use the draft id as `ref`.
No instruction is written before confirmation. An external agent or script
reads the outbox and appends replies to `inbox.ndjson`, ending each line with LF:

```json
{"target":"local","ref":"delivery-reference","text":"A glass lens"}
```

Only matching target subscribers receive each reply. Incomplete final lines wait
for their LF. Malformed lines are warned about and skipped. The inbox cursor is
in memory: do not replace the inbox while running; archived replies may replay
on host restart. Keep these files local; they can contain private project text.

Fork capability is `:none` without a session handle; no executable lookup occurs.
Elixir embedders may pass `%{session_handle: handle}` to use `VoiceConverse.AgentFork`.
The browser uses the fixed `"local"` target. There is deliberately no CommandSource:
context states “Command data unavailable” and advertises no command-listing tool.

## Automated checks

```sh
mix compile --warnings-as-errors
mix format --check-formatted
mix test --max-cases 4
```

Tests launch the actual Bandit router and use the core JavaScript client over a
real WebSocket. They inject fake provider events, prove the confirmation/outbox
boundary, verify file updates/replies and transcript persistence, and measure
fake session startup without recording (at most 300 ms). The separate
latency guard excludes the transcript store’s host-wide `sync(1)` creation
barrier; the WebSocket test keeps real transcript recording enabled. They use no microphone, paid provider,
real API key, Claude Code, or Codex executable. The TypeScript client integration
is pending its package in #5690; the JavaScript check does not substitute for it.
