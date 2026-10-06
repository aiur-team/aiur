---
contract: voice-session
version: draft-2
owner_feature: MP-E6 (co-owned with MP-E5 for §2–§5 and §3.5; MP-R5 owns the provider package that implements the §4 STT and TTS roles)
consumers: MP-E5, MP-E6, MP-R5, MP-R6 (Stream Deck), MP-N1, MP-N6, MP-N7
base_main_sha: 45a290e3
date: 2026-10-06
status: reconciled draft — Phase B reconciliation RC-13, RC-14 and RC-16 applied (Phase C, 2026-10-06)
---

> **Phase C changes (draft-2).** §4 adopts MP-R5's `Aiur.Voice` facade, `Transcriber` and
> `Speaker` names and the neutral owner messages (RC-14). §7 adopts the MP-R1 capability IDs
> `voice.stt`, `voice.tts` and `voice.conversation` and the MP-R1 report shape. §3.5 adds the
> device-authenticated voice path for phone and watch (RC-16). §12 fixes the configuration
> namespaces (RC-13). §3.6 records the frame budget for full-duplex converse audio
> (RQ-E6-7, resolved by calculation).

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
  remains an alias for one release (compatibility, MP-E5-C2). The existing auto-submit
  `voice:conversation` topic is unchanged until owner question E5-OQ2 is answered; it is not
  `voice:converse`.
- The daemon validates on join: capability present (§7), target exists and is writable for
  this principal, limiter lease available. Refusals carry a stable `reason_code` (§8) plus
  today's human-readable `reason` text.
- A join with **no payload** (today's browser) is accepted on `voice:dictate` and
  `voice:dictation` as `{mode: dictate, surface: agent_composer, target: null}`: no target
  validation, exactly today's behaviour. A payload with `v: 1` is validated.
- Phone and watch authenticate with the MP-N2 device credential through §3.5. The channel
  protocol after connect is the same.

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

### 3.5 Device-authenticated voice path (RC-16; MP-E5 owns, MP-N6 and MP-N7 consume)

The dashboard socket cannot serve native clients: `AiurWeb.VoiceSocket.connect/3` requires a
CSRF token and the signed dashboard cookie session (`voice_socket.ex:21-35`). A native app has
neither. The device path follows the existing Stream Deck precedent: a short-lived signed
ticket from an authenticated HTTP call, then a socket that verifies that ticket
(`StreamdeckSessionController.create/2`, `streamdeck_auth.ex:11-36`,
`streamdeck_socket.ex:11-23`).

1. **Ticket.** `POST /api/v1/device/voice-ticket` with `Authorization: Bearer
   <access_token>` (pairing contract §4.4), body `{}`. The route sits behind the MP-N2
   device-auth plug and the writable gate (`:require_writable`, `router.ex:60-62`), so a
   read-only dashboard refuses (`403`, `{error: {code: "read_only"}}`). Response `200
   {ticket, expires_in_seconds: 60}`. The ticket is a `Phoenix.Token` with salt
   `"device-voice-v1"` carrying `{device_id, expires_at_ms}`; it carries no access token.
   A device token that is unknown, expired or revoked gets the pairing contract's `401`.
2. **Socket.** `/voice/device` (`AiurWeb.DeviceVoiceSocket`, proposed) with params
   `{ticket}`. `connect/3` verifies the token (`max_age: 60`), that the dashboard is
   writable, and that the device row is still active in the machine store (MP-N2-C1). It
   assigns `voice_authority = %{kind: :device, device_id}`. Topics: `voice:dictate` and
   `voice:converse` (the same channel modules as the browser). The legacy topics
   `voice:dictation` and `voice:conversation` are **not** served on this socket.
3. **Session lifetime.** The ticket is checked once, at connect. While a channel is joined,
   the daemon re-checks the device row every 15 s and on every `stop`/`end`; a revoked
   device ends the channel with `auth_changed`. A device session is bounded by the same
   audio budget as the browser (9,600,000 bytes for `dictate`).
4. **Limits.** The limiter authority is `"device:" <> device_id`: two concurrent sessions per
   device, inside the shared global cap of eight (`voice_session_limiter.ex:12-13`).
5. **Authority.** Device auth grants the same voice authority as a Basic-Auth operator on
   that instance (D19), no more: the target checks of §3.2 apply unchanged.
6. **Logging.** Tickets and access tokens never reach a log line or crash reason. The
   socket logs `device_id` only. A ticket is a bearer value in a URL query; its 60-second
   life and single purpose bound the exposure (the Stream Deck token has 300 s,
   `streamdeck_auth.ex:9`).
7. **Transport security.** Whether the app reaches the socket over `wss://` or a tailnet
   `ws://` is RQ-TRANSPORT (RC-15, owned by MP-N2). This path does not change that choice.

### 3.6 Frame budget for converse audio (RQ-E6-7, resolved)

Uplink: PCM16 mono 16 kHz = 32,000 B/s. A 200 ms chunk is 6,400 bytes, 8,536 bytes as
base64, well under the socket's 400,000-byte `max_frame_size` (`endpoint.ex:27`) and the
262,144-byte decoded chunk cap (`voice_channel.ex:29`). Downlink: the provider's agent
output format is negotiated at start (`pcm_16000` requested, contract §4.1); at 16 kHz the
daemon relays provider chunks as they arrive. A daemon-side relay splits any provider chunk
larger than 131,072 decoded bytes before pushing it to the client. No change to
`max_frame_size` is needed. The 9,600,000-byte `dictate` budget does **not** apply to
`converse`; converse is bounded by time (§6, `voice.conversation.max_session_seconds`).

## 4. Transcription and provider boundary

Three daemon-side provider roles. Each is a behaviour with a fake for tests, as today's
`voice_stt_start_fun` / `voice_tts_start_fun` injection does (`voice_channel.ex:235-291`).

| Role | Behaviour (names from MP-R5 plan §2, RC-14) | Implementation at launch | Owner |
| --- | --- | --- | --- |
| Facade | `Aiur.Voice` (core, always compiled): `availability/0 -> %{available: boolean, reason: nil \| :unconfigured \| :not_installed}`, `start_transcription(owner, opts) -> {:ok, ref} \| {:error, :unconfigured \| :not_installed \| term}`, `push(ref, b64_pcm16)`, `commit(ref)`, `stop(ref)`, `quota_snapshot/0` | MP-R5-C1 | MP-R5 |
| Streaming STT | `Aiur.Voice.Transcriber`; owner messages `{:voice_transcript, :partial \| :final, text}`, `{:voice_error, reason}`, `{:voice_closed}` | `Aiur.ElevenLabs.Realtime` (`scribe_v2_realtime`, `commit_strategy=vad`, `realtime.ex:53-54,320-329`) | MP-R5 package |
| TTS | `Aiur.Voice.Speaker` | `Aiur.ElevenLabs.TTS` (`eleven_flash_v2_5`, `pcm_44100`, `tts.ex:13-17`) | MP-R5 package |
| Conversation | `Aiur.VoiceConversation.Provider` — `open(session_spec)`, `push_audio/2`, `send_context/2`, `tool_result/3`, `close/1`; emits normalized events (§4.1) | ElevenLabs Agents Platform over a daemon-held websocket (MP-E6 recommendation, see `../bucket-2-platform/MP-E6/provider-research.md`) | MP-E6 |

`stop(ref)` closes **without** committing the current utterance (today
`Aiur.ElevenLabs.Realtime.stop/1`, `realtime.ex:114-120`); it is the primitive behind the
`cancel` event (§3.3). `commit(ref)` flushes and then closes (`realtime.ex:106-112`).

Until MP-R5-C1 lands, the code still uses `{:elevenlabs_transcript, …}`,
`{:elevenlabs_error, …}` and `{:elevenlabs_closed}` (`voice_channel.ex:154-167`). MP-E5 and
MP-E6 tickets are scheduled after MP-R5-C1 (wave 4 after wave 1) and use only the neutral
names.

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
`target_gone`, `provider_error`, `capability_lost`, `auth_changed`, `cost_cap`
(`voice_channel.ex:184-191` already stops on dashboard auth change; a revoked device ends with
`auth_changed`, §3.5).

| From | Event | To |
| --- | --- | --- |
| `connecting` | provider `conversation_initiation_metadata` received | `listening` |
| `listening` | `user_transcript{final: true}` | `thinking` |
| `thinking` | first `agent_text` or `agent_audio` | `speaking` |
| `speaking` | `interruption` | `listening` |
| `speaking` | agent turn complete (`agent_text{final: true}` and audio drained) | `listening` |
| any live state | `tool_call{name: "consult_agent"}` accepted | `consulting` (audio continues; returns to the prior state when the tool result is sent) |
| any live state | provider socket closed unexpectedly | `reconnecting` (one retry, MP-E6 plan §8) |
| `reconnecting` | retry fails | `error` → `ended{provider_error}` |
| any | end trigger (above) | `ended{reason}` |

The session manager (MP-E6-C4) owns this table; the provider adapter only emits §4.1 events.

## 7. Capability advertisement

Voice publishes three IDs in the MP-R1 capability report
([identity-and-capabilities.md](identity-and-capabilities.md) §2.2;
[capability-matrix.md](../bucket-1-refactor/MP-R1/capability-matrix.md) §2). This contract
uses those IDs and that shape; it defines no second map.

| ID | Mode it gates | Computed from | Reasons when not `available` |
| --- | --- | --- | --- |
| `voice.stt` | `dictate` | `Aiur.Voice.availability/0` (MP-R5) | `:unconfigured` → `not_configured`; `:not_installed` → `not_installed`; read-only dashboard → `disabled` |
| `voice.tts` | spoken replies (today's `voice:conversation`; `voice.conversation` audio) | key present and `elevenlabs.voice_id` set | `not_configured`, `not_installed`, `disabled` |
| `voice.conversation` | `converse` | MP-E6 registered callback: `voice.stt` available, `voice.conversation.agent_id` set, last privacy preflight not failed | `not_installed`, `not_configured`, `disabled`, `dependency_unavailable` (`depends_on: ["voice.stt"]`), `unknown` (preflight never run) |

```json
"voice.stt":          { "state": "available" },
"voice.tts":          { "state": "unavailable", "reason": "not_configured" },
"voice.conversation": { "state": "degraded", "reason": "dependency_unavailable", "depends_on": ["voice.tts"] }
```

- `state ∈ {available, degraded, unavailable, unknown}` (MP-R1). `voice.conversation` is
  `degraded` when `voice.tts` is unavailable: the session still runs, but text-only.
- **Internal atom versus wire reason.** MP-R5's facade returns `:unconfigured`
  (RC-14); the capability report spells it `not_configured` (MP-R1 §2.2). The channel error
  code (§8) keeps `unconfigured`, the string the Stream Deck already sends
  (`streamdeck_channel_test.exs:1089-1095`). The mapping lives in one function in the voice
  capability callback (MP-E5-C2-T03).
- Clients render a mode button only from this report (V1, V6). Today the dashboard learns
  about a missing key only after a failed join (`voice_channel.ex:253-254`); MP-E5-C2 moves
  that check to render time. The Stream Deck already pre-advertises
  (`StreamdeckProjection.voice/0`).
- Earlier drafts used `voice.dictate`, `voice.converse` and `voice.speak`. They are retired
  and never reused.

## 8. Error codes (stable, client-translatable)

`unconfigured`, `not_installed`, `read_only`, `auth_changed`, `capacity`, `target_not_found`,
`target_not_writable`, `target_stale`, `provider_auth`, `provider_quota`, `provider_unavailable`,
`chunk_too_large`, `session_limit`, `permission_denied` (client-side), `no_device`
(client-side), `transport_lost`, `privacy_preflight_failed` (converse, §10),
`unsupported_target` (a target kind this build cannot address yet, e.g. `executor` before
MP-E3), `invalid_payload`, `cost_cap_reached` (converse, §12), `provider_error` (a provider
failure of no known class — cause-neutral, never relabelled as auth or quota), `unknown` (an
unclassified daemon-side failure; AGENTS.md "a collapsed cause names the collapse at the
source"). Existing messages map onto
these (`voice_channel.ex:54-56,93,254-266,308-314`; `realtime.ex:402-403`); the mapping
table is in MP-E5-C2-T01.

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

## 11. Reconciliation status

| Item | Status (draft-2) |
| --- | --- |
| Identity: target shapes §5.1 | Kept. `instance_id = <machine_id>/<instance_key>` (RC-02). `ticket` is the tracker identifier string the dashboard already uses for `send-operator-message`. |
| MP-E7 send | Consumed as `send(conversation_ref, text, client_request_id) → delivery_id` with receipts `accepted \| held_async \| harness_queued \| in_context \| read \| failed \| outcome_unknown` (listener-mode §7). The voice layer never chooses the mode. **Contract request:** an `origin` option (`:voice_assistant`) so consult and instruction entries are labelled in the agent transcript (MP-E6 `tickets/CONTRACT-REQUESTS.md`). |
| MP-E2 answer | Consumed unchanged: `DecisionStore.answer/5` with `option_id \| custom_response`, `expected_version`, `idempotency_key` (`decision_store.ex:190`, `decision_commands.ex:85-107`). Conflicts are the typed `{:conflict, …}` set rendered by `decision_commands.ex:347-382`. |
| MP-R5 | Names adopted (§4, RC-14). Config namespace fixed (§12, RC-13). |
| MP-N2 | Device path §3.5 consumes the device-auth plug (MP-N2-C6) and a device-row read (MP-N2-C1). **Contract request** to MP-N2: expose `device_active?(device_id)` from the store library (MP-E5 `tickets/CONTRACT-REQUESTS.md`). |
| MP-N6 / MP-N7 | Use `voice.stt` / `voice.conversation` (§7) and §3.5. N7's on-device dictation sends `client_text` (§3.3) only if OQ-N7-2 picks the relay path; system dictation needs no server voice. |

## 12. Configuration namespaces (RC-13)

| Namespace | Keys | Owner | Notes |
| --- | --- | --- | --- |
| `elevenlabs.*` | `api_key`, `language_code`, `voice_id` (`config/schema/eleven_labs.ex:13-19`) | MP-R5 | Unchanged. The same key serves STT, TTS and the Agents Platform; the key additionally needs the ElevenLabs Agents permission for `converse`. |
| `voice.conversation.*` | `agent_id`, `llm`, `roles_dir`, `max_session_seconds`, `idle_timeout_seconds`, `daily_minutes_cap`, `context_token_budget` | MP-E6 (MP-E6-C3-T01) | New. Defaults are owner decisions E6-OQ6/OQ7; until answered the keys have no shipped defaults and `voice.conversation` reports `not_configured`. |

No new environment variable is introduced. `ELEVENLABS_API_KEY` remains the only voice
secret, and it stays in the daemon (V4).
