# Voice session contract

This page records the implemented dictation join contract. The parser in
`AiurWeb.VoiceJoinPayload` and target checks in `AiurWeb.VoiceTargets` enforce it.

## 3.2 Dictation surfaces

A version 1 `voice:dictate` join supplies `v: 1`, `mode: "dictate"`, `surface`,
`target`, and a `client_session_id`. Optional `client` metadata identifies the client.
Unknown keys are refused. An empty payload retains legacy join behavior.

| Surface | Target kind | Join eligibility |
| --- | --- | --- |
| `agent_composer` | `worker` | One running worker with the named ticket. |
| `command_response` | `command` | Command remains answerable at the expected version. |
| `command_revision` | `command` | Command has an answer at the expected version. |
| `executor_composer` | `executor` | Same instance with an available or degraded, writable Executor conversation. |
| `conversation_panel` | None yet | Parsed; target validation currently refuses it. |

Command targets contain `kind: "command"`, `decision_id`, and optional
`expected_version` and `instance_id`. A supplied version must equal the current
Command version; a missing answer or moved version refuses revision dictation
with `target_stale`. Missing Commands return `target_not_found`; unavailable
store state returns `unknown`.

Revision dictation selects `revision[choice]=custom`, waits for the response
field, and appends to `revision[custom_response]`. Capture stops at the field's
4,000-character limit while preserving the transcript for editing. The operator
reviews the text, supplies a reason, and submits through `revise-decision`.
Dictation does not submit a revision or bypass revision delivery guards.

## Converse transport

`voice:converse` on `/voice` requires a versioned join with `mode: "converse"`
and `surface: "conversation_panel"`, targeting a running worker or the Executor.
The target is validated by the same rules as its composer. Command targets
remain outside this channel. `/voice/device` belongs to MP-E5-C8-T01/T02.

The channel uses `VoiceConverse.Wire` for frame validation and
`VoiceConverse.EventFrames` for session events. Phoenix event names preserve
`assistant_text` and `audio`; their payloads retain the core `agent_text` and
`agent_audio` type names. `audio` adds `data` alongside `data_b64`; errors add
`reason_code` alongside `code`. `client_text` maps to a core `text` frame;
`playback_state` maps to a core `state` frame in the client direction.
`audio_done` marks session audio completion, not an inferred per-turn boundary.
Reconnect keys include authentication generation, connection, target and client id.
Only loss of the last subscriber starts the core's ten-second transport grace.

## Mic choice handoff

`open-voice-conversation` carries `surface` and a JSON-encoded `target` from
that composer's Dictate control. `AiurWeb.VoiceConversationEvents.open/2`
strictly parses the target, calls `VoiceTargets.validate/2`, and re-reads the
conversation capability before assigning `voice_conversation_panel` to
`%{target: parsed_target, surface: surface}`. Refusal clears the panel request
and assigns `voice_conversation_error` with `reason_code` and inline `reason`.
`close/1` clears both assigns; neither function starts capture or a session.
Known unmapped capability causes stay in `reasons` beside a neutral `unknown` code.

MP-E6-C7-T02 consumes this assign to render `AiurWeb.Components.ConversePanel`.
Until that component is installed, the dashboard reports Converse as
`not_installed` even if the conversation host is available. The panel's Start
step owns consent and capture. The handoff requests no agent summary or pause.
Command response and revision surfaces omit Converse. Executor targets use
`AiurWeb.ExecutorVoiceTarget` to validate the instance and conversation capability. Composer controls are hidden without an effective
listener mode; dictation still requires review and the ordinary Send action.

## Compatibility audit — 2026-10-29

No shipped client in `src/priv/static` or `packages/` references
`voice:dictation`; dashboard dictation uses `voice:dictate`. The server alias
is retained for browser tabs loaded before that migration: no retirement or
forced-reload boundary has been established for those clients. Remove the alias
when that boundary is established; its presence does not select a different
capture or delivery path.

Dashboard privacy and retention are documented in the
[ElevenLabs API guide](../../../../website/docs-app/apis/elevenlabs.md#privacy-and-secret-handling).

## 3.3 Conversation client → daemon

The existing `playback_state` v1 frame carries `state: "playing" | "stopped"`.
It optionally carries `turn_id` and nonnegative integer `played_until_ms`;
`played_until_ms` requires `turn_id`. Old state-only frames remain valid.
Clients report `{state: "stopped", turn_id, played_until_ms}` after barge-in.
The clock is milliseconds from that turn's first audio sample.

## 3.4 Conversation daemon → client

`agent_text_timing` carries `turn_id`, chunk `text`, `audio_offset_ms`, boolean
`estimated`, and optional `chars: [{offset_ms, length}]` (JSON objects).
Offsets are turn-relative milliseconds and lengths count Unicode grapheme
clusters (`String.graphemes/1`, browser `Intl.Segmenter`). Missing or null
`chars` means reveal on arrival. `estimated: false` identifies provider timing.
The public codec schema lives in
`packages/aiur-contracts/schemas/voice-converse.v1.schema.json`.

## 4.1 Normalized assistant timing

`VoiceConverse.Events.AgentTextTiming` is the provider-neutral
`agent_text_timing` event. Its in-memory `chars` are `{offset_ms, length}` tuples.
Adapters use `from_char_alignment/3` with ElevenLabs displayed alignment,
`from_word_timestamps/2`, or `from_text_deltas/2` with the matching chunk audio
duration. Chunk-local provider offsets gain `audio_offset_ms`; all helpers
produce monotonic grapheme spans. Invalid alignment falls back to estimation
and emits `[:voice_converse, :text_timing, :alignment_mismatch]` telemetry.
No audio duration produces `chars: nil` with `estimated: true`.

## 9 Conversation interruption records

Timings remain in session memory. Transcripts contain only final assistant
text, never `chars` or `offset_ms`. Voiced final text waits for playback stop
(or session end) before persistence, so completed generation can still be cut
when the user interrupts playback. Text-only final turns persist immediately.

On `Interruption`, the session waits up to two seconds for a matching stopped
report. It writes one `assistant_turn` with `interrupted?: true` and the prefix
whose grapheme start offsets are strictly below `played_until_ms`. Zero selects
empty text and an offset beyond the final span selects all text. Missing timing
or a missing report retains all received text. Later provider events wait until
that interrupted record is durable. A provider declaring `manual_truncation: true`
receives optional `truncate(ref, turn_id, played_until_ms)` once after the report.
