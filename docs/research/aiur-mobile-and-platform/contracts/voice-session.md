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
| `executor_composer` | `executor` | Parsed; target is currently unsupported. |
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

## Mic choice handoff

`open-voice-conversation` carries `surface` and a JSON-encoded `target` from
that composer's Dictate control. `AiurWeb.VoiceConversationEvents.open/2`
strictly parses the target, calls `VoiceTargets.validate/2`, and re-reads the
conversation capability before assigning `voice_conversation_panel` to
`%{target: parsed_target, surface: surface}`. Refusal clears the panel request
and assigns `voice_conversation_error` with `reason_code` and inline `reason`.
`close/1` clears both assigns; neither function starts capture or a session.

MP-E6-C7-T02 consumes this assign to render `AiurWeb.Components.ConversePanel`.
Until that component is installed, the dashboard reports Converse as
`not_installed` even if the conversation host is available. The panel's Start
step owns consent and capture. The handoff requests no agent summary or pause.
Command response and revision surfaces omit Converse. Executor targets parse
but remain `unsupported_target` until their target owner supplies validation;
the future Executor LiveView can delegate the same event to `open/2`.
