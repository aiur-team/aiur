# Executor voice

## Open the prototype

From the Build home page (`/`), open **Settings → Talk to Executor** (`/voice`).
The prototype remains available for Kevin’s acceptance, including both providers,
minute meters, session comparison, ratings and delivery receipts.

Select a worker on that page to open its conversation drawer. Its **Dictate**
and **Converse** controls, listener modes and message delivery remain available
when supported and writable. Close the drawer to return to the Executor controls.

## Composer voice

The shared Executor composer supports **Dictate** and **Converse**, like worker
composers, when Executor messaging is enabled. Voice controls are hidden when
the composer is read-only or its effective listener mode is unavailable.

Dictate appends speech to the editable draft and waits for **Send**. Delivery
receipts come from the Executor send path. Cancel restores the pre-recording
draft; closing the conversation stops capture. The existing **Talk to Executor**
prototype below remains separately available.

The shared composer’s dictation path does not replace the prototype’s provider
comparison, ratings or delivery receipts. Those remain on `/voice` for acceptance.

## Conversation transport

The authenticated dashboard socket `/voice` also accepts `voice:converse`.
Join with `v: 1`, `mode: "converse"`, `surface: "conversation_panel"`, a worker
or Executor `target`, and a client-chosen `client_session_id`. The panel UI
ships separately; this topic does not start capture by itself.

Clients send PCM16 mono 16 kHz `audio` chunks (`data`, base64), `client_text`,
`playback_state` (`playing` or `stopped`), `confirm_draft`, `discard_draft`, and
`end`. Only an authenticated client confirmation can deliver a draft.
The daemon relays `state`, `transcript`, `assistant_text`, `audio`,
`interrupted`, `draft`, `delivery`, `error`, and `ended`.

Audio chunks preserve
the provider's format and contain at most 131,072 decoded bytes; `audio_done`
marks the end of the session's audio stream. Client chunks above 256 KiB are refused.

A reconnect with the same authenticated connection, target and
`client_session_id` reattaches within ten seconds. The session retains its
capacity lease through that grace period. After grace expires it ends with
`transport_lost`; authentication changes end it with `auth_changed`.
The core retains its configured duration, idle and daily limits.

## Voice prototype

On `/voice`, choose **ElevenLabs** or **OpenAI**, enter its model,
and press **Talk to Executor** to start a continuous spoken session. Change the
provider between sessions without editing config or restarting.

Both credentials and the ElevenLabs Agent id must be configured for a two-provider comparison. The voice control
always targets the Executor, regardless of the worker shown in the drawer.

The page shows each provider's cumulative used or reserved minutes. Comparison
limits are 45 minutes each for OpenAI and ElevenLabs on this runtime, separate
from the existing shared daily cap. Starts at the comparison cap are refused;
remaining minutes also shorten the session's automatic stop.

A reservation is
written before connecting. Failed starts and interrupted sessions without a saved
end line charge the whole reservation, including after a daemon restart.

Expand **Compare providers and record Kevin’s rating** for side-by-side session
lines: model, first audio, duration, budget cost estimate, rating (1–5) and note.

First audio measures server session startup to first received agent audio, before
browser playback; sessions with no audio show unavailable.

Ratings and redacted notes survive reloads. The private `comparison.json` sits beside the transcripts;
no audio is stored. Stop the current session before choosing another provider.

The estimates allocate USD 8 / 45 OpenAI minutes and USD 8 / 45 ElevenLabs
minutes; these are evaluation budget rates, not vendor tariffs or invoice limits.
The ledger starts at deployment and excludes earlier provider/account usage.

Before each attended comparison, reconcile actual prior spend and account usage
against the USD 25 approval on #4084; record each delta there. End both sessions
after evaluation and disable the demo. Kevin's choice (or “not yet”) belongs on
#4083 before Stream Deck voice work is filed.

The control shows not configured, connecting, live, ended or failed. Press
**End Executor conversation** to send the transcript and categorized summary.
Each item keeps its sent event id and timestamp after the session ends.

Receipts say **sent, not received** until the Executor acknowledges the
matching wake. **Received** confirms acknowledgment, not approval or execution.
A missing acknowledgment stays visible; re-rendering the page or starting
another session preserves earlier receipts. A failed handoff shows an error.

The summary separates decisions, open questions and ideas. If the assistant did
not record one before ending, the page says **unstructured**; the transcript
is still sent without inventing decisions.

Use HTTPS or localhost for microphone access. See
[Executor voice setup](/reference/configuration-voice#executor-voice-prototype-setup)
for provider configuration, credentials and ElevenLabs client-tool setup.

## Live conversation context

The reusable voice session receives worker status notes, Commands and phase/PR
milestones while you talk. Updates enter context silently, coalesced over five
seconds; agent answers and refreshed notes can be spoken at the next pause.

Each event is redacted and saved before delivery. When a Command resolves elsewhere,
unconfirmed instruction drafts become stale so you can review them against the new
context. A missing live subscription is reported as a gap; tool calls still refresh
the briefing.

Live Executor context reads presence after capability notifications and reports the number
of tickets affected by a failed queue prerequisite, plus when that prerequisite clears.

### Read-only side questions

Hosts that advertise a fork can answer `ask_agent` history or reasoning questions from
an isolated read-only session while the parent keeps working. Questions needing fresh
state or action use checkpoint delivery.

A fork has a 60-second deadline and only one
question can wait per voice session; failure falls back to checkpoint delivery when available.

Replay answers are identified as coming from a summary once per session.

The voice transcript
records `side_query` with the fork mode, child session ID and cost when supplied by the host;
missing identity or cost remains unknown. Host support determines whether this path is available.

### Standalone example for package consumers

`packages/elixir/voice_converse/examples/local_host` is an independent Bandit
application with a browser page at `http://127.0.0.1:4100/`. It requires no Aiur
application or agent CLI. Run `mix deps.get` and `mix run --no-halt` from that
directory, then click **Converse**.

The default fake provider is silent and
uses no credentials; the example README documents real-provider setup.

The host reads `briefing.md` and `notes.md`, writes confirmed instructions and
queued questions to `outbox.ndjson`, reads replies from `inbox.ndjson`, and
stores transcripts under `transcripts/`. It supplies credentials and expiring
transport tokens through the core ports.

Its own `config/runtime.exs` reads
`VOICE_HOST_ROOT`, `VOICE_HOST_PORT`, `VOICE_HOST_PROVIDER`, `VOICE_HOST_MODEL`,
`VOICE_HOST_CLOUD_ACCEPTED`, and `VOICE_HOST_ELEVENLABS_AGENT_ID`.

Provider keys
use `OPENAI_API_KEY`, `ELEVENLABS_API_KEY`, `GEMINI_API_KEY`, and
`ANTHROPIC_API_KEY`; only OpenAI and ElevenLabs transports are selectable in
this example.

Cloud sessions require explicit acceptance. Forks are optional;
CommandSource is absent and stated as unavailable in context.
