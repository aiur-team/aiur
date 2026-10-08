---
ticket_id: MP-E6-C7-T01
feature_id: MP-E6
chunk_id: MP-E6-C7
bucket: 2-platform
title: voice:converse channel — full-duplex audio relay between clients and the session
status: blocked
blocked_by: [DESIGN-E6, MP-E6-C4-T01, MP-E6-C2-T03, MP-E5-C2-T01]
prior_units: []
prior_boundaries: [VOX, WEB]
prior_features: [ui-08]
prior_findings: []
size_owner: n/a (new module; keeps voice_channel.ex < 500 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C7-T01 — `AiurWeb.VoiceConverseChannel`

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C7 dashboard conversation UI.
- **User value:** the browser (and later phone/watch via the device socket) can hold a live
  spoken conversation with the assistant; the daemon keeps the key and the transcript.
- **Deliverable:** `AiurWeb.VoiceConverseChannel` (PROPOSED) on topic `voice:converse`,
  routed on `/voice` (dashboard). The `/voice/device` route comes from MP-E5-C8-T01's
  device socket once both land (wave 5); this ticket does not wait for it (RC-30). Join payload contract
  §3.2 with `mode: "converse"`; client events §3.3 (`audio`, `end`, `confirm_draft`,
  `discard_draft`, `playback_state`, `client_text`); daemon events §3.4 (`state`,
  `transcript`, `assistant_text`, `audio`/`audio_done`, `interrupted`, `draft`, `delivery`,
  `error`). Lease from `VoiceSessionLimiter` for the whole session.
- **Non-goals:** panel UI (C7-T02..T04).

## Dependencies and blockers

- **Owner:** DESIGN-E6 gates all of C7 (DESIGN-E6 header).
- **Predecessors:** C4-T01 (session API), C2-T03, MP-E5-C2-T01 (`VoiceTargets`,
  `reason_code` mapping reused). Not MP-E5-C8-T01: dashboard Converse uses the browser voice
  path (RC-30).

## Verified starting point (base `45a290e3`)

- Socket and frame limit `/voice` `max_frame_size: 400_000` (`endpoint.ex:26-29`); frame
  budget resolved in contract §3.6 (RQ-E6-7): 200 ms uplink chunk ≈ 8.5 KB base64; relay
  splits downlink chunks > 131,072 decoded bytes.
- Dashboard channel auth/lease/generation pattern to mirror: `voice_channel.ex:33-81,184-191,195-216`.
- Audio chunk guard to reuse: `decode_audio/1` (`voice_channel.ex:316-326`).

## Chosen design

- `join`: base checks as VoiceChannel (writable, auth generation or device authority,
  lease); `VoiceTargets.validate/2` with `surface: "conversation_panel"`; capability
  `voice.conversation` not `unavailable`; then `Session.start_session/3` and subscribe.
  `client_session_id` lets a reconnecting client re-attach to the same session within the
  session's 10 s grace (C4-T01).
- `audio` → size guard → `Session.push_audio/2`. No byte budget; time limits are the
  session's.
- Session events → pushes (after the session's persist-before-notify).
- `terminate/2`: `Session.end_session(id, :transport_lost)` unless re-attached; lease
  released.
- Auth change (dashboard) or device revocation (MP-E5-C8-T02 timer) → `auth_changed` end.

## Implementation steps

1. Channel module; 2. register topic in `VoiceSocket` and `DeviceVoiceSocket`; 3. reuse
   `reason_code/1` from VoiceChannel (extract to `AiurWeb.VoiceErrors`); 4. tests.

## Non-happy paths

Oversize chunk → `chunk_too_large`; session start errors → join refusal with code; provider
error mid-session → `error` + `state: ended`.

## Compatibility and rollout

New topic; inert until the panel exists. Rollback: revert.

## Verification

| Test (`test/aiur_web/voice_converse_channel_test.exs`, FakeProvider) | Expected |
| --- | --- |
| "a joined client receives state, transcript and assistant audio in order" | — |
| "a privacy preflight failure refuses the join" | `privacy_preflight_failed` |
| "a reconnect with the same client_session_id re-attaches" | same conversation id |
| "leaving ends the session after the grace period" | `session_ended{transport_lost}` in transcript |
| "a device socket can converse; a revoked device is ended" | added by MP-E5-C8-T01/T02 with their fixtures (RC-30) |
| "downlink chunks larger than 131,072 bytes are split" | two pushes |

```bash
env -C src mise exec -- mix test test/aiur_web/voice_converse_channel_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation check.** Skip `VoiceTargets.validate/2`: a test "a stopped agent cannot be a
converse target" fails.

## Completion and handoff

- [ ] Channel on both sockets.
- **Dependents:** C7-T02..T04, MP-N6-C4-T03, MP-N7 converse relay.
