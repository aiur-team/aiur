---
contract: voice-session
version: draft-1
owner_feature: MP-E6 (co-owned with MP-E5 for §2–§5; MP-R5 owns the provider package that implements §4)
consumers: MP-E5, MP-E6, MP-R5, MP-R6 (Stream Deck), MP-N1, MP-N6, MP-N7
base_main_sha: 45a290e3
date: 2026-10-06
status: draft — awaiting Phase B reconciliation
---

# Contract: voice session

One contract for every voice path in aiur: capture, transport, transcription, delivery to a
target, conversation transcript storage, the provider boundary, and the privacy disclosure of
what reaches a cloud provider.

It covers two **modes** (D16, no default):

- **`dictate`** — single-response speech-to-text. The text lands in an editable field. A human
  presses Send. This is today's behaviour (MP-E5 extends it).
- **`converse`** — a live conversation with the MP-E6 voice assistant. The assistant discusses;
  only a confirmed draft reaches an agent.

"Existing" means verified at `45a290e3`. "Proposed" names do not exist yet.

## 1. Invariants (apply to every client and provider)

| ID | Invariant | Source |
| --- | --- | --- |
| V1 | Every activation is explicit: the user picks `dictate` or `converse` from visible buttons. No default mode. Opening a notification or a page never starts capture. | D16; brief §3 |
| V2 | Raw audio is never written to disk, a log, a database, or a crash dump by aiur. It exists only in memory, in transit. | D17 |
| V3 | Converse transcripts are retained locally in full and are reviewable. A summary never replaces or deletes them. | D17; brief §3 |
| V4 | Provider credentials are held only by the daemon. Browser, sidecar, phone and watch never receive a long-lived provider key. | existing: `realtime.ex:14-35`, `voice_channel.ex:14-15`, `website/docs-app/apis/elevenlabs.md:12` |
| V5 | Speech never reaches an agent without a human action: Send (dictate) or Confirm (converse). | existing for dictation (`conversation_drawer.ex:229`); new for converse |
| V6 | No voice key, no voice package, or a provider outage never breaks typed interaction. | existing (`voice_channel.ex:253-254`; brief R5) |
| V7 | Voice output that is delivered goes through the same send path as typed input: listener mode (MP-E7) for messages, the Command answer API (MP-E2) for Command responses. Voice adds no second delivery path. | brief E5; D13 |

The existing dashboard "interactive voice chat" (`voice:conversation`) auto-submits speech to
the worker (`conversation-voice-controller.js:225-235,354-366,379-396`). It violates V5. Its fate is
owner question E5-OQ2 in [DESIGN-E5](../owner-design-tasks/DESIGN-E5.md). Until that is decided
it is preserved unchanged and is **not** the `converse` mode of this contract.

## 2. Capture (client-owned)

| Field | Value | Evidence |
| --- | --- | --- |
| Format | PCM signed 16-bit little-endian, mono, 16 kHz, base64 per chunk | `conversation-voice-controller.js:274-288`; `realtime.ex:320-331` |
| Chunk | ≤ 256 KiB decoded (about 8 s); clients send 100–200 ms chunks | `voice_channel.ex:25-30` |
| Session cap | 9,600,000 bytes (about 5 min) per `dictate` session | `voice_channel.ex:31,89-95` |
| Device choice | client-local (browser: `localStorage` key `aiur-dashboard-microphone-device`) | `conversation-voice-controller.js:57-61,104-123` |
| Secure context | required; otherwise the mic controls are disabled with a reason | `conversation-voice-controller.js:18-22` |

Rules:

- Capture starts only from a V1 activation and stops on: Stop, Cancel, session cap, idle
  timeout (`converse` only, §6), page/app hide (proposed for `converse`), or transport loss.
- `converse` capture requests echo cancellation (`getUserMedia({audio: {echoCancellation:
  true}})`, proposed) because playback and capture overlap (barge-in). Validation: Phase C RQ-E6-5.
- Native clients (MP-N1/N7) capture the same format. A client that can only produce
  on-device text (for example a watch dictation API) sends `client_text` instead of audio
  (§3.3). N7 decides whether it needs that; the contract allows it.

## 3. Transport (daemon-owned endpoint)

### 3.1 Existing

Phoenix socket `/voice` (`AiurWeb.VoiceSocket`, `endpoint.ex:26-27`, `max_frame_size`
400,000). Connect requires the dashboard to be writable, a valid CSRF token and the dashboard
session (`voice_socket.ex:21-35`). Topics `voice:dictation`, `voice:conversation`
(`voice_socket.ex:17-18`). Per-authority cap 2, global cap 8 (`voice_session_limiter.ex:12-13`).

The channel is **target-blind** today: the target lives in the LiveView form that later
submits the text (`dashboard_live.ex:640-661`).

### 3.2 Proposed join payload (both modes)

```json
{
  "v": 1,
  "mode": "dictate | converse",
  "surface": "agent_composer | executor_composer | command_response | conversation_panel",
  "target": { "...": "a target reference, §5.1" },
  "client_session_id": "uuid chosen by the client, reused on reconnect",
  "client": { "kind": "dashboard | phone | watch | streamdeck", "version": "..." }
}
```

- Topic names become `voice:dictate` and `voice:converse` (proposed). `voice:dictation`
  remains an alias for one release (compatibility, MP-E5-C2).
- The daemon validates on join: capability present (§7), target exists and is writable for
  this principal, limiter lease available. Refusals carry a stable `reason` code (§8).
- Phone and watch authenticate with the MP-N2 device credential instead of the dashboard
  session. The channel protocol is the same. (Consumed from the pairing contract; N2 owns it.)

### 3.3 Client → daemon events

| Event | Modes | Payload |
| --- | --- | --- |
| `audio` | both | `{data: base64 pcm}` (existing) |
| `stop` | both | `{}` — commit the current utterance (existing) |
| `cancel` | both | `{}` — discard the uncommitted utterance and end capture (proposed) |
| `client_text` | both | `{text}` — on-device transcription result (proposed; native clients only) |
| `confirm_draft` | converse | `{draft_id, edited_text?}` (§5.3) |
| `discard_draft` | converse | `{draft_id}` |
| `end` | converse | `{}` — end the conversation |
| `playback_state` | converse | `{state: "playing" \| "stopped"}` — lets the daemon log interruptions |

### 3.4 Daemon → client events

| Event | Modes | Payload |
| --- | --- | --- |
| `transcript` | both | `{kind: "partial" \| "final", text}` (existing) |
| `stopped` | dictate | `{}` (existing) |
| `error` | both | `{reason_code, message}` (existing has `reason` only; add `reason_code`) |
| `state` | converse | `{state}` from §6 |
| `assistant_text` | converse | `{turn_id, text, final?}` |
| `audio` / `audio_done` / `audio_error` | converse | existing names (`voice_channel.ex:169-182`); format from provider metadata, not hard-coded `pcm_44100` |
| `interrupted` | converse | `{turn_id}` — provider detected barge-in; client stops playback |
| `draft` | converse | `{draft_id, kind, target, text, status}` (§5.3) |
| `delivery` | both | `{draft_id \| message_id, status}` mirrored from MP-E7 / MP-E2 |

## 4. Transcription and provider boundary

Three daemon-side provider roles. Each is a behaviour with a fake for tests, as today's
`voice_stt_start_fun` / `voice_tts_start_fun` injection does (`voice_channel.ex:235-291`).

| Role | Proposed behaviour | Implementation at launch | Owner |
| --- | --- | --- | --- |
| Streaming STT | `Voice.Transcriber` — `start(owner, opts)`, `push/2`, `commit/1`, `stop/1`; messages `{:transcript, :partial \| :final, text}`, `{:transcriber_error, code}`, `{:transcriber_closed}` | `Aiur.ElevenLabs.Realtime` (`scribe_v2_realtime`, `commit_strategy=vad`) | MP-R5 package |
| TTS | `Voice.Synthesizer` — `start(owner, text, opts)`; `{:audio, :chunk \| :done \| :error, ...}` | `Aiur.ElevenLabs.TTS` (`eleven_flash_v2_5`, `pcm_44100`) | MP-R5 package |
| Conversation | `Voice.ConversationProvider` — `open(session_spec)`, `push_audio/2`, `send_context/2`, `tool_result/3`, `close/1`; emits normalized events (§4.1) | ElevenLabs Agents Platform over a daemon-held websocket (MP-E6 recommendation, see `../bucket-2-platform/MP-E6/provider-research.md`) | MP-E6 |

The sidecar's unwired TTS provider (`packages/streamdeck/src/audio/elevenlabs-tts.ts:56`,
used only by tests) takes an `apiKey` (`:48`). It contradicts V4 and must not be wired. The
Stream Deck receives synthesized audio from the daemon, like the dashboard.

### 4.1 Normalized conversation events (provider → session manager)

`user_transcript{text, final}`, `agent_text{turn_id, text, final}`, `agent_audio{turn_id,
format, bytes}`, `interruption{turn_id}`, `tool_call{call_id, name, params}`,
`provider_conversation_id{id}`, `closed{reason}`, `error{code}`. A provider that cannot emit
one of these declares it in its capability (§7). No ElevenLabs event name leaks past the
adapter.

## 5. Delivery to a target

### 5.1 Target reference

Consumed from the identity contract (coordinator) — assumed shape:

```json
{ "kind": "worker",   "instance_id": "...", "ticket": "owner/repo#123", "session_id": "optional" }
{ "kind": "executor", "instance_id": "..." }
{ "kind": "command",  "instance_id": "...", "decision_id": "dec_...", "expected_version": 7 }
```

### 5.2 Dictate delivery

The daemon never delivers dictated text. It returns `transcript` events; the client puts the
text in the surface's editable field; the human edits and presses the surface's own Send. That
Send calls:

| Surface | Send path | Contract |
| --- | --- | --- |
| Worker or Executor message | listener-mode send (`AgentChat.send/3` today, `agent_chat.ex:12-49`, with `message_id` idempotency #2717) | MP-E7 listener mode |
| Command response | `answer` with `custom_response`, `expected_version`, `idempotency_key` (`decision_store.ex:188-190`; `decision_commands.ex:143-155`) | MP-E2 command request |

### 5.3 Converse delivery: drafts

The assistant never sends. It creates **drafts** via tools; a human confirms each one.

| Draft kind | Created by tool | On confirm |
| --- | --- | --- |
| `instruction` | `propose_instruction` | listener-mode send to the session target, with `message_id = draft_id` |
| `command_answer` | `propose_command_answer` | Command `answer` with `idempotency_key = draft_id` and the version the draft was built on |
| `consult` | `consult_agent` | listener-mode send of a question framed as a non-instruction (MP-E6 plan §6) |

Draft status: `proposed → confirmed → sent → delivered | failed`, or `proposed → discarded`,
or `proposed → stale` (target changed: Command resolved elsewhere, agent ended). Confirm is a
button on a visible draft (owner question E6-OQ1 decides whether speech alone may confirm).
`edited_text` lets the human correct the draft before confirming.

## 6. Conversation session states (`converse`)

`connecting → listening ⇄ thinking ⇄ speaking → ended`, plus `consulting` (waiting for the real
agent), `reconnecting`, `error`. End reasons: `user_end`, `idle_timeout`, `max_duration`,
`target_gone`, `provider_error`, `capability_lost`, `auth_changed`
(`voice_channel.ex:184-191` already stops on dashboard auth change).

## 7. Capability advertisement

Consumed by the capabilities contract (MP-R1). Voice publishes:

```json
{ "voice.dictate":   { "status": "available | unconfigured | not_installed | degraded", "reason": "..." },
  "voice.converse":  { "status": "...", "provider": "elevenlabs_agents", "reason": "..." },
  "voice.speak":     { "status": "...", "reason": "..." } }
```

Clients render a mode button only from this map (V1, V6). Today the dashboard learns about a
missing key only after a failed join (`voice_channel.ex:253-254`); MP-E5-C2 moves that check
to render time. The Stream Deck already pre-advertises (`StreamdeckProjection.voice/0`).

## 8. Error codes (stable, client-translatable)

`unconfigured`, `not_installed`, `read_only`, `auth_changed`, `capacity`, `target_not_found`,
`target_not_writable`, `target_stale`, `provider_auth`, `provider_quota`, `provider_unavailable`,
`chunk_too_large`, `session_limit`, `permission_denied` (client-side), `no_device`
(client-side), `transport_lost`, `privacy_preflight_failed` (converse, §10). Existing messages
map onto these (`voice_channel.ex:54-56,93,254-266,308-314`; `realtime.ex:402-403`).

## 9. Conversation transcript storage (`converse` only)

Dictate text is not stored by the voice layer. Once sent it is part of the agent conversation
(MP-E4 contract) or the Command record (MP-E2).

Converse transcripts:

- **Location (proposed):** a daemon-private directory resolved like
  `Aiur.Config.Paths.decision_state_dir/0` (`paths.ex:61-66`): instance- and
  repository-qualified, root-contained. One append-only `<conversation_id>.ndjson` per
  conversation plus an `index.ndjson`.
- **Write rule:** append and fsync before emitting the matching client event, the
  DecisionStore "persist before notify" rule.
- **Records:** `session_started{conversation_id, target, role_id, role_hash, provider, model,
  context_digest}`, `context{source, ref, observed_at, text}`, `user_turn{turn_id, text, at}`,
  `assistant_turn{turn_id, text, interrupted?, at}`, `tool_call{call_id, name, params}`,
  `tool_result{call_id, summary}`, `draft{draft_id, kind, status, text, target}`,
  `delivery{draft_id, message_id, status}`, `session_ended{reason, at}`.
- **Redaction:** every text field passes `Aiur.SecretRedactor.redact/1`
  (`secret_redactor.ex:49-50`) before storage **and** before it is sent to the provider.
- **Never stored:** audio, provider credentials, signed URLs.
- **Retention:** indefinite. Deletion only by an explicit user action, if the owner allows it
  (E6-OQ5). Not a storage-optimisation target (brief E6).
- **Review:** read API (`list`, `get`) for the dashboard and a CLI (MP-E6-C6).

## 10. Privacy disclosure (normative copy source for docs and the UI)

Encrypted push (MP-N4) and private tailnet access do **not** make voice local. When voice is
enabled, these leave the machine:

| Mode | Sent to ElevenLabs | Sent to an LLM vendor | Stays local only |
| --- | --- | --- | --- |
| Dictate | microphone audio while recording; returned text | nothing | the edited text until Send |
| Spoken reply (existing TTS) | the agent reply text | nothing | — |
| Converse (recommended provider) | microphone audio; assistant speech; role pre-context; target context (ticket summary, recent conversation excerpts, open Commands, status snapshot); tool results | the same text context, through ElevenLabs' built-in LLM pass-through to the model's vendor (for example Anthropic, Google or OpenAI) | the full transcript; drafts until confirmed |

Provider-side retention (sources in the MP-E6 provider research, accessed 2026-10-06):

- ElevenLabs Agents stores conversation audio by default. aiur's agent config sets
  `platform_settings.privacy.record_voice = false`; the daemon checks this before every
  session and refuses (`privacy_preflight_failed`) if it is not false.
- ElevenLabs keeps Agents transcripts for a configurable period (default 2 years). aiur sets
  the shortest available and deletes each conversation through
  `DELETE /v1/convai/conversations/{id}` once the local transcript is fsynced.
- Zero Retention Mode is Enterprise-only. Without it, aiur cannot guarantee that ElevenLabs or
  the LLM vendor never retains content. The UI and docs must say this plainly.
- The STT endpoint used for dictation is subject to the account's ElevenLabs data policy. aiur
  stores nothing; provider retention is outside aiur's control.

Disabling voice (no key, or package absent) means no voice data leaves the machine
(`website/docs-app/apis/elevenlabs.md:54`).

## 11. Open items for reconciliation

- Identity contract: the target shapes in §5.1 are assumptions.
- MP-E7: assumes a send call returning `{message_id, status}` with statuses at least
  `queued | delivered | consumed | failed`, and a mode chosen per agent (default sync, D13).
  The voice layer does not choose the listener mode.
- MP-E2: assumes `answer(decision_id, %{custom_response | option_id, expected_version,
  idempotency_key})` survives, and a version conflict returns a typed error the client can show.
- MP-R5: assumes the package exposes the §4 STT and TTS behaviours and the §7 capability.
  Config namespace (`elevenlabs.*` today, `voice.*` proposed for converse) is R5's call.
