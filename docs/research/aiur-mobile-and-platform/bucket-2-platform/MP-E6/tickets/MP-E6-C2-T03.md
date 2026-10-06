---
ticket_id: MP-E6-C2-T03
feature_id: MP-E6
chunk_id: MP-E6-C2
bucket: 2-platform
title: ElevenLabs Agents event mapping and client-tool round trip, pinned to spike fixtures
status: blocked
blocked_by: ["DESIGN-E6 (waived for this ticket: backend)", MP-E6-C1-T01, MP-E6-C2-T02]
prior_units: []
prior_boundaries: [VOX]
prior_features: [integrations-51]
prior_findings: []
size_owner: n/a (adapter file stays < 500 lines; mapping may live in a sibling `eleven_labs_agents/decoder.ex`)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C2-T03 — Event mapping and tool round trip

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C2.
- **User value:** the assistant's speech, the operator's transcribed speech, interruptions
  and tool calls reach the session manager in one provider-neutral form, verified against
  frames recorded from the real service, not only against documentation.
- **Deliverable:** a pure decoder `Provider.ElevenLabsAgents.Decoder.decode/1` (PROPOSED)
  mapping each inbound frame to a contract §4.1 struct, and `tool_result/3` encoding
  `client_tool_result`. Fixture-driven tests using the spike's redacted frames.
- **Non-goals:** deciding what tools do (MP-E6-C5); session state (C4).

## Dependencies and blockers

- **Spike:** MP-E6-C1-T01 supplies fixtures and settles RQ-E6-2 (tool timeout) and RQ-E6-6
  (partials). If the spike fails RQ-E6-1/RQ-E6-3, this ticket is re-planned for the fallback
  adapter (spike pass/fail table).
- **Predecessors:** MP-E6-C2-T02.

## Verified starting point

- Documented frame shapes (accessed 2026-10-06,
  <https://elevenlabs.io/docs/agents-platform/api-reference/agents-platform/websocket>):
  `user_transcript.user_transcription_event.user_transcript`;
  `agent_response.agent_response_event.{agent_response, response_id}`;
  `agent_response_correction.agent_response_correction_event.{corrected_agent_response, response_id}`;
  `audio.audio_event.{audio_base_64, event_id, is_final}`;
  `interruption.interruption_event.event_id`;
  `client_tool_call.client_tool_call.{tool_name, tool_call_id, parameters, expects_response}`;
  client `client_tool_result{tool_call_id, result, is_error}`.
- The documented `user_transcript` carries no partial/final flag; whether partials exist is
  RQ-E6-6.
- Precedent for a matched-set decoder with explicit error types:
  `realtime.ex:64-79` (final/partial/error type sets).

## Chosen design

| Frame `type` | Struct |
| --- | --- |
| `user_transcript` | `UserTranscript{text, final?: true}` (partials only if the spike shows a partial event type; then `final?: false` for it) |
| `agent_response` | `AgentText{turn_id: response_id, text, final?: true}` |
| `agent_response_correction` | `AgentText{turn_id, text: corrected, final?: true}` (replaces the turn's text; the transcript stores both, C6) |
| `audio` | `AgentAudio{turn_id: response_id_or_event_id, format: negotiated, data_b64}` |
| `interruption` | `Interruption{turn_id: current}` |
| `client_tool_call` | `ToolCall{call_id: tool_call_id, name: tool_name, params: parameters}`; a call with `expects_response: false` is still routed, and no result is sent |
| `ping` | answered in C2-T02 |
| any other `type` | ignored; counted in a `:telemetry` counter `[:aiur, :voice_conversation, :provider, :unknown_event]` with the type name only |

- `tool_result/3` sends `{"type": "client_tool_result", "tool_call_id", "result",
  "is_error": false}`; an error result sets `is_error: true` with a short safe message.
- **Timeout guard (RQ-E6-2):** the adapter does not wait for the session; the session must
  answer within the spike-measured timeout minus 2 s. C5-T04 (consult) therefore returns an
  immediate acknowledgement result and delivers the agent's reply later through
  `send_context/2`.
- Fixtures: `src/test/fixtures/voice_conversation/elevenlabs_agents/*.ndjson`, one frame per
  line, secrets replaced by `REDACTED_*`.

## Implementation steps

1. Decoder module and mapping table.
2. Adapter calls the decoder on `{:elevenlabs_transport, :text, frame}` and forwards structs
   to the owner.
3. `tool_result/3` encoder.
4. Commit spike fixtures (after a redaction grep) and table-driven tests.

## Non-happy paths

- Malformed JSON frame: ignored and counted; never crashes the adapter.
- Tool call for an unknown tool name: forwarded; the session's router answers with
  `is_error: true` (C5).
- Correction for an unknown `response_id`: forwarded as a new turn.

## Compatibility and rollout

Internal; no config. Rollback: revert.

## Verification

| Test | Expected |
| --- | --- |
| "every fixture frame decodes to the documented struct" | table over the fixture files |
| "no provider event name appears in decoded structs" | property: for every decoded struct, `inspect/1` contains none of the raw `type` strings |
| "an unknown event type is ignored and counted" | telemetry handler receives one event; owner receives nothing |
| "tool_result encodes the documented frame" | JSON equals the documented shape |
| "fixtures contain no secrets" | `File.read!` of each fixture has no `xi-api-key`, `sk_`, `signed_url`, `token=` |

```bash
env -C src mise exec -- mix test test/aiur/voice_conversation/provider/eleven_labs_agents_decoder_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation check.** Map `interruption` to `AgentText`: the fixture test fails. Pass unknown
types through as raw maps: the "no provider event name" property fails.

## Completion and handoff

- [ ] Decoder, encoder, fixtures, tests.
- **Dependents:** MP-E6-C4-T01, MP-E6-C5-*, MP-E6-C7-T01.
