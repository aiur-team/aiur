# Stream Deck channel

Aiur exposes a Phoenix WebSocket at `/streamdeck/websocket` for push-driven
fleet state. Join the single `streamdeck:fleet` channel; internal PubSub topic
names and tuple shapes are not part of this API.

## Authentication

The device first requests `POST /api/v1/streamdeck/token` with
`Authorization: Bearer <client-token>` (created with `aiur token create`) or the
existing dashboard HTTP Basic credentials on loopback. The response is
`{token, expires_in_seconds}`. Pass that short-lived token as the Phoenix socket
parameter (`/streamdeck/websocket?token=…`), then join `streamdeck:fleet`.

The physical sidecar uses each selected instance's own bearer credential from
`~/.aiur/remote-instances.yaml`; the environment daemon can use
`AIUR_CLIENT_TOKEN` or Basic credentials. A switch closes the previous channel,
stops voice capture, and clears its fleet before opening the selected target.
HTTP 401/403 displays `auth failed` without retrying or falling back; connection
failures retry the selected target with bounded backoff. Reconnecting to the same
instance retains its last grid, navigation, logs and Commands page, stops voice,
and restores the focused agent on the new channel. Client bearer tokens
are never placed in the WebSocket URL or debug output. See the
[physical sidecar guide](../website/docs-app/guide/stream-deck.md#physical-sidecar-status)
for registry and token-file rules.

## Shared projections vs deck presentation

These daemon modules run without the physical sidecar. The dashboard's
`/streamdeck` emulator uses the deck presentation; new non-deck surfaces should
use the shared domain sources directly.

| Module | Role | Needs the sidecar? | Other consumers |
| --- | --- | --- | --- |
| `Aiur.Conversation.Anchors` | Shared event-to-transcript anchoring | No | No non-deck consumer yet; MP-E4 conversations planned. `History` re-exports it; production caller: `StreamdeckLogs`. |
| `AiurWeb.StreamdeckProjection` | Fleet, voice availability, decisions and transcript DTOs for the deck channel | No | `/streamdeck` emulator |
| `AiurWeb.Streamdeck.Deck` | Guarded deck sections over shared read models; focus lane from `BuildQueue.show/0` | No | Emulator |
| `AiurWeb.Streamdeck.Deck.TicketPage` | Focused ticket over Build DataSource and TicketControl; shared server status labels | No | Physical cmd ticket page |
| `AiurWeb.StreamdeckCommands` | Command history and answer DTOs; actor `streamdeck` | No | Emulator |
| `AiurWeb.StreamDeckGrid` | Key ranking for the grid | No | `GET /api/v1/streamdeck/grid`, emulator, `AiurWeb.StreamdeckFleet` |
| `AiurWeb.StreamdeckTranscriptRelay` | Throttled live transcript push | No | Emulator |
| `AiurWeb.StreamdeckLogs`, `AiurWeb.StreamdeckStrip`, `AiurWeb.StreamdeckKeyFaceContract` | Deck presentation: paging, LIVE, log windows and key faces | No; the emulator renders them | — |
| `AiurWeb.StreamdeckAuth`, `AiurWeb.StreamdeckSocket`, `AiurWeb.StreamdeckChannel` | Deck transport | Only for a physical deck | — |

`StreamdeckProjection.voice/0` reads availability from the shared `Aiur.Voice`
port. Command answers retain the operator actor `%{kind: :operator, id: "streamdeck"}`.
`StreamDeckGrid.dependency_ready?/2` remains an internal grid helper with no
external caller.

The canonical visual contract is `src/priv/streamdeck/key-face-contract.json`;
the parity vectors also live in `src/priv/streamdeck/`. The sidecar keeps
byte-checked mirrors in `packages/streamdeck/src/`. Edit the canonical files,
then copy them to the mirrors.

New dashboard, phone or watch surfaces should read `Aiur.DecisionStore`, the
orchestrator snapshot or `Aiur.Conversation.Anchors` directly, rather than the
deck DTOs. Nothing in the dashboard needs the sidecar installed.

## Events

Every payload is JSON and uses `version: 1` in the initial `snapshot` event.

| Event | Payload | Meaning |
| --- | --- | --- |
| `snapshot` | `{version, fleet, grid, usage, decisions, voice}` | Complete state after join; `grid` includes `build`, `build_status` and `counts`. |
| `fleet` | `{agents, grid}` | Complete replacement after fleet or build changes; `grid` includes `build`, `build_status` and `counts`. |
| `ticket` | {v:1, kind:"ticket", id, title, sec, status, agent, pr, control, links, actions, qpos, observed_at} | Focused Build ticket on focus, Build changes and coalesced fleet refresh. |
| `usage` | `{provider_family: meter}` | One entry per provider family, from Build.Usage; semantic session/weekly windows carry `remaining_percent` and `used_percent`. Updates coalesce over 250 ms. |
| `decisions` | `{count}` | Updated decision summary. |
| `transcript` | `{identifier, role, body, sequence, timestamp}` | Latest sampled line for the focused agent. |
| `logs` | `{transcript, event_keys, event_starts, …}` | The focused agent's log surface: the event-key strip and the transcript rows it jumps into. Pushed on focus and again whenever a new transcript line lands. |
| `alert` | `{identifier, name, message, severity, needs_attention, timestamp}` | Focused agent alert. |
| `control` | `{identifier, state}` | Focused agent's redacted control state. `state` may contain `action`, `status`, and lifecycle timestamps (`requested_at`, `accepted_at`, `applied_at`, `rejected_at`, `expiry`); request, tracker, and requester details are never exposed. |
| `commands` | `{identifier, items, next_cursor, has_next, total, partial, unavailable}` | The focused agent's Command history page, newest first: `items` are allowlisted Commands, `next_cursor`/`has_next` page the history, and `unavailable` is set when the decision store could not be read so the device says so instead of showing an empty history. Pushed on focus and again whenever a decision for the focused agent changes. |

`grid.build_status` is `ok`, `none` (no lane with a positive total), or
`unavailable` (queue model could not be read). `grid.build` is null unless
status is `ok`; then it carries the lowest `{set_rank, queue_id}` lane’s
identity, progress fields and `eta_seconds: null`. Unknown percent and completed
counts stay null. `grid.counts` carries `status`, `observed_at`, `agents`, `live`, `queued`, `not_queued` and `by_state` from the Build index. Unavailable counts are null; stale readings retain their values and are dimmed. Build changes share the channel’s 250 ms fleet coalescing.

`ticket.status` carries the shared Build `{label, tone, agent_state}`. The server and desktop modal consume one canonical ticket-status taxonomy asset. `pr` is null without evidence, otherwise `{num, state, ci?}`; open PR/CI facts come from ProgressStore and merged history wins. Unknown fields remain null. `control` uses TicketControl and is disabled on read-only dashboards. `observed_at` is the DTO observation time in epoch milliseconds; the physical strip renders its age after 60 seconds. A missing ticket becomes an explicit unknown frame for that focused id.

`links` contains server-built `modal` and nullable `pr` URLs. `actions.pause`, `priority_up` and `priority_down` are `enabled` or `disabled`; queue edges, read-only dashboards and tickets outside editable list queues disable priority. Send `priority` with `{identifier, direction: "up" | "down"}` for the focused ticket; replies reuse the queue read-back/error shape. The physical client opens HTTP(S) URLs with injected `xdg-open`; the emulator uses links with `target="_blank"`.

Ticket reads run in one background task per channel, coalesce refreshes, and discard results from an old focus so Commands and unfocus stay responsive.

An agent item may contain `identifier`, `status`, `alert_count`, `title`,
`runtime_seconds`, `turn_count`, `work_state`, `pause_reason`,
`tracker_paused`, `backend`, and `model`. Fields absent from the source are
omitted rather than represented by implementation-specific sentinels.

### Device input navigation

Send `input` with `{kind, index, ticks?}`. Kinds are `key_press`, `dial_press`,
`dial_long_press`, and `dial_turn`. Key indexes are 0–7, dial indexes 0–3;
turns require integer `ticks` in -32–32. Unknown kinds, malformed frames and
out-of-range values reply `error` with `{reason: "invalid_input"}`. Accepted
frames reply `ok` with `{view, page}` (zero-based page). Ticket and Fleet inputs
also return a server-rendered `frame` with eight keys and strip regions. Each connection starts
at `ticket`, page 0; reconnects reset navigation.

Dial 4 press cycles Ticket → Feature → Epic → Fleet → Ticket, preserving
root pages and clearing drills. Turning it moves one eight-key page per tick,
clamped against the current list, including after a shrink. Holding it for
500 ms emits **one** `dial_long_press`; clients suppress the release press.
That input pops the drill stack; at root it does nothing. Dial 1 scrolls and
its press is reserved. Dial 2 turns produce selected-ticket priority effects
(negative = up); with no selection they do nothing. Dial 3 is local to the
sidecar and ignored by the reducer. Keys resolve from server-owned sections:
feature, epic and fleet keys drill into tickets; ticket keys select and produce
an open-ticket effect. Priority and open-ticket execution belong to SD-206
and SD-301 respectively.

`Deck.Nav` is pure; `Deck.Input` resolves targets from ordered section items
`%{id: id, tickets: [...]}` before reducing. Sizes are counts per root view
plus the current drill count. The current grid supplies tickets and fleet
categories. Fleet categories push `{:state, states}` drills using the same
filed, deduplicated population as `Tickets.keys/2`. `grid.fleet` contains the
eight summary keys and daemon/capacity/global-pause strip metadata. Unknown
states remain visible in Active; unavailable counts stay explicitly unavailable.
Feature/Epic section producers follow in SD-203–204. The sidecar switches to this protocol in SD-103; emulator pixels
switch in SD-104. Existing controls remain during that transition.

## Focus and transcript rate

Send `focus` with `{identifier}` to watch one agent, or `unfocus` to stop. A
channel subscribes to only that one `agent:<identifier>` source; it never fans
out subscriptions for every agent. Re-focusing unsubscribes the prior agent.

Physical key toggles send `control` with `{identifier, action}`. The accepted
actions are exactly `pause` and `resume`, and nothing else is accepted: the
agent view's five keys are pause, logs, mic, settings and commands, so there is
no surface that can send a priority action and the channel does not pretend to
offer one. Orchestrator priority itself is unchanged and remains reachable from
the dashboard's own controls. The channel routes the request through
`Aiur.AgentChat` and returns the orchestrator result; the device does not
implement a second pause/resume path.

Transcript traffic is latest-value coalesced in 250 ms windows (four pushes per
second maximum per joined channel). A dedicated relay is the sole subscription
to the focused agent, so the channel mailbox is not filled by a transcript
burst. A burst produces one `transcript` event containing the final line from
that window; intermediate lines are intentionally discarded because the device
renders only a small live-log region.

## Commands and answering

The Commands page is history-first: opening it shows the focused agent's past
Commands newest first, with open and deferred ones answerable and completed
ones read-only.

### Device → Aiur

| Event | Payload | Reply |
| --- | --- | --- |
| `commands_page` | `{"cursor": c}` | Next `commands` page, or `{"reason": r}` |
| `answer_command` | `{"decision_id", "version", "idempotency_key", "option_id" \| "custom_response"}` | `{"status", "decision"}` or `{"reason": r}` |

`commands_page` pages the focused agent's history with the opaque `next_cursor`
from the previous page; the device never interprets the store's cursor encoding.
`answer_command` records one operator answer. Exactly one of `option_id` or
`custom_response` is required, mirroring the CLI's `executor-answer
--option|--custom-response` contract so a spoken "none of the above" response
maps onto an already-supported operation.

### Attribution

An answer given on the device is recorded with **operator** attribution — the
operator physically pressing their own deck is the operator answering. The
durable record carries actor `{"kind": "operator", "id": "streamdeck"}` and the
dashboard shows a true operator answer, never an Executor answer with an
operator flavour in free text. This is also what lets the device answer the
`human_required` Commands an Executor cannot.

The device may only answer a Command for the agent it is currently focused on
(focused-ticket enforcement), and it answers the exact `version` it read, so a
retry after a dropped reply is an idempotent replay of the durable action
rather than a second decision. `idempotency_key` must be stable for the same
intended answer across reconnects; the server deduplicates on it.

## Voice input

Voice input streams captured microphone audio to Aiur, and **Aiur** performs the
ElevenLabs call. `ELEVENLABS_API_KEY` never exists in the sidecar process, its
environment, or its configuration; there is no second place to configure it.

### Device → Aiur

| Event | Payload | Reply |
| --- | --- | --- |
| `voice_start` | `{}` | `{"session": id}` or `{"reason": r}` |
| `voice_audio` | `{"session": id, "audio": base64}` | none |
| `voice_stop` | `{"session": id}` | `{}` |

### Aiur → device

| Event | Payload |
| --- | --- |
| `voice` | `{"session", "kind", "text"}` — `kind` is `partial` or `final` |
| `voice_error` | `{"session", "reason"}` |
| `voice_closed` | `{"session"}` |

`voice_start` requires the same authenticated socket as `say`; an unauthenticated
one is refused with `unauthorized`. When no API key is configured the reply is
`unconfigured`, which is a normal state rather than a failure — the device says
why the microphone is off while capture, waveform and the decibel bar keep
working.

`session` is an opaque server-minted id. A second `voice_start` replaces the
live session, stopping it cleanly first. A `voice_audio` or `voice_stop`
carrying a stale or unknown session is ignored, so a late frame from a previous
hold cannot reach the provider, and text the abandoned session had already
produced cannot be relabelled with the new session's id. A frame larger than
64 KiB, or a malformed payload, is dropped rather than crashing the channel.

The session runs in its own monitored process: the channel stops it on
`unfocus`, on refocus, and on `terminate`, and a provider fault ends the session
without ending the channel.

### The `voice` snapshot entry

```json
"voice": { "available": true, "reason": null }
```

`available` is `false` with the reason
`"Aiur has no ElevenLabs API key - transcription is off"` when no key is
configured, so the device can explain a disabled microphone key without a round
trip. Without a voice provider installed, the reason is
`"Voice isn't installed in this Aiur"`, and `voice_start` replies with the
`not_installed` reason code even if a key is set. Typed messages still work.
The entry reports the *presence* of a credential only; neither the key nor
any part of it ever appears in a projection.

### Why base64 in JSON on this channel, and not a binary frame

The sidecar's channel client is a hand-rolled Phoenix v2 JSON serializer, where
a frame is the array `[join_ref, ref, topic, event, payload]`. Phoenix's binary
path carries a raw payload with **no event name**, so a binary frame cannot be
routed alongside `focus`, `control` and `say` without a second socket with its
own authentication and its own reconnect. That cost buys nothing here, because
ElevenLabs' own realtime protocol is already base64-in-JSON: the provider frame
is `{message_type: "input_audio_chunk", audio_base_64, commit, sample_rate}`.
Relaying the base64 string verbatim means Aiur does **zero transcode** — the
string the sidecar produced is the string the provider receives. The 4/3
expansion is therefore paid once, on a leg that would pay it anyway; a binary
channel frame would only force Aiur to base64-encode instead, moving the cost
rather than removing it.

The measured budget: capture is 32,000 B/s (16 kHz mono s16le), regrouped into
3,200-byte 100 ms frames, so **10 messages/s** of 4,272 base64 characters plus
roughly 60 bytes of Phoenix framing — about **43.3 kB/s**, with framing overhead
at 1.4% of the message.

Only transcribed text round-trips. The waveform and the decibel bar are computed
on the sidecar from the captured PCM and never wait on Aiur, so "is my
microphone working" is bounded by the 20 ms capture latency rather than by any
network round trip.

## Server-rendered images

`AiurWeb.Streamdeck.Render` is a pure SVG renderer; transport remains a separate
consumer. `key/1` draws a projected grid agent. `frame/1` accepts the existing
`grid` and `usage` snapshot plus optional `column_offset` and `provider_offset`,
returning exactly eight keys (empty slots are `nil`) and strip regions tiling
800×100. `strip/1` composes regions from title/bar, meter, count, text and pager
parts, so later views share the same drawing path.

Key images use physical row order; ranked input agents fill each column top-to-bottom.

The grid provider panels retain the current session-only layout and show remaining quota.

Each image carries `svg`, a 16-character lowercase SHA-256 content `hash`, and a
plain-text accessible `label`; strip images also carry `x` and `width`. Keys
have width/height/viewBox 120×120; strip regions have their local width ×100.
SVGs contain only inline assets, including the DeepSeek base64 PNG, and escaped
text. There are no external asset references or scripts. The same input gives
identical bytes and hashes; relative ages must arrive in the input model.

All text uses `JetBrains Mono, monospace`. Consumers register the bundled
JetBrains Mono font before rasterizing. Wrapping uses a fixed advance of
0.6 em; key titles occupy at most three lines with a final ellipsis. Unknown
progress draws only a grey track, measured zero draws a visible fill stub, and
stale readings retain their value with reduced opacity. Fixture keys target
4 KiB and 200-wide regions 6 KiB; the original embedded DeepSeek PNG exceeds
that key target and must be budgeted separately.
