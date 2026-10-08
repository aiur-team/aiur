---
ticket_id: MP-N7-C4-T04
feature_id: MP-N7
chunk_id: MP-N7-C4
bucket: 3-mobile-watch
title: Phone-side relay of watch voice turns to the daemon's device-authenticated voice path
status: blocked
blocked_by: [DESIGN-N7, DESIGN-E5, RQ-TRANSPORT, MP-N2-C10-T01, MP-E5-C8-T01, MP-N7-C4-T03, MP-N7-C1-T02, MP-N7-C1-T03, RQ-N7-6]
prior_units: []
prior_boundaries: ["VOX #36"]
prior_features: [MP-E5, MP-E6, MP-N2]
prior_findings: ["voice-session.md §3.5 device path", "endpoint.ex:26-29 /voice frame size"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N7-C4-T04 — Phone relay for watch voice turns

## Identity and outcome

- Bucket 3, MP-N7, chunk C4.
- **User value:** speech recorded on the watch reaches the operator's configured voice
  provider through the phone, and the transcript comes back for review (D-relay Dictate),
  or feeds a Converse turn (C4-T05).
- **Deliverable:** `VoiceRelay` in each phone broker (native, no JS): on a `voice_turn`
  file, obtain a voice ticket (`POST /api/v1/device/voice-ticket`), connect
  `/voice/device`, join `voice:dictate` (or `voice:converse`, C4-T05) with
  `{v:1, mode, surface: "command_response", target: {instance_id, decision_id}, client:
  {kind: "watch", version}, client_session_id: session}`, stream the PCM as `audio`
  frames, send `stop`, collect `transcript{final}`, reply `voice_result`, delete the file.
- **Non-goals:** the daemon socket itself (MP-E5, RC-16); Converse reply audio (C4-T05).

## Dependencies and blockers

- **RC-16 device voice path** (`contracts/voice-session.md` §3.5): **MP-E5-C8-T01**
  (ticket endpoint and `/voice/device` socket; Phase D). It accepts `client.kind: "watch"`
  on joins made with the phone's device credential (§3.5 item 5).
- RQ-TRANSPORT / MP-N2-C10-T01: `wss://` vs owner-approved `ws://` on a tailnet (§3.5 rule 8).
- **RQ-N7-6 (new):** whether the daemon's STT path (ElevenLabs realtime, MP-R5) and the
  MP-E6 provider accept audio sent faster than real time. Until answered, the relay paces
  frames at real time (200 ms chunk every 200 ms), which adds the turn's length to latency.
  DV-W6 measures both pacings in a debug build; the faster pacing ships only if
  transcripts are identical in 10 of 10 trials.
- DESIGN-E5 (D-relay review rule), MP-N7-C4-T03, brokers C1-T02/T03.

## Verified starting point

- The browser socket cannot be used by native clients: `/voice` requires CSRF, session and
  `dashboard_writable` (`src/lib/aiur_web/voice_socket.ex:21-37`; `endpoint.ex:26-29`,
  `max_frame_size: 400_000`).
- Device path spec: voice-session.md §3.5 (ticket, `/voice/device`, topics
  `voice:dictate`/`voice:converse`, limiter `"device:"<>device_id`, two sessions per device,
  re-check every 15 s). Frame budget: 200 ms of 16 kHz PCM16 = 6,400 bytes, 8,536 as base64
  (§3.6). Client events `audio`, `stop`, `cancel`, `client_text`; daemon events
  `transcript`, `stopped`, `error{reason_code}` (§3.3–3.4).
- The phone may hold WebSockets (only watchOS is restricted, S7).

## Chosen design

```text
voice_turn(file) ─► VoiceRelay
   ticket = POST /api/v1/device/voice-ticket (bearer)        # 403 read_only → voice_result{outcome: read_only}
   socket = connect wss://<instance>/voice/device?ticket=…   # Phoenix channels client (native: SwiftPhoenixClient / JavaPhoenixClient — pin in MP-N1-C2 or hand-written minimal client)
   join voice:dictate {v:1,…, client.kind:"watch"}
   for chunk in file (6,400 B): push audio{data: base64}; pace per RQ-N7-6
   push stop → await transcript{final} (timeout 15 s) → voice_result{transcript}
   leave; delete file
```

- One socket per session (dictate: one turn; converse: many turns, C4-T05).
- Errors map to `voice_result.outcome = error{code, retry}` (Phase D feasibility M7: **typed,
  not passed through generically**). `code` must be a row of voice-session §8.1 (the shared
  fixture `packages/aiur-mobile/fixtures/contract/voice/end-reasons.json`); `retry` is copied
  from that row. A daemon code not in the table becomes `unknown` (retry `now`), never a guessed
  cause. Network → `unreachable`; timeout → `timeout`. `cost_cap`, `provider_quota`,
  `provider_unavailable` and `transport_lost` stay distinct all the way to the watch.
- The transcript is returned for review on the watch (no auto-send).
- **Library choice:** a minimal Phoenix Channels v2 JSON client written in each native core
  (join/push/reply/heartbeat only) to avoid two third-party dependencies; the decision is
  recorded here because the channels wire format is small and documented by Phoenix.
  PROPOSED path `AiurClientKit/Voice/PhoenixChannel.swift`, `aiur-client-core/voice/PhoenixChannel.kt`.

## Implementation steps

1. Minimal Phoenix channel client + tests against a recorded frame transcript fixture.
2. `VoiceRelay` with injected ticket fetcher, socket factory, clock.
3. Broker dispatch for `voice_turn` (watchOS: `session(_:didReceive file:)`; Wear:
   `onChannelOpened`/`receiveFile`).
4. Deletion on every path.

## Non-happy paths

- Dashboard read-only → `read_only` (watch shows Dictate unavailable with that reason).
- Revoked mid-session → `auth_changed` error → `failed{revoked}`; broker triggers the
  revocation snapshot (C1-T02/T03).
- Limiter full (two sessions per device) → `error{reason_code}` passed through; watch shows
  "Voice busy".
- Phone app suspended on iOS when the file arrives: `transferFile` delivery waits until
  the app runs; DV-W6 records whether the turn round trip is usable.

## Compatibility and rollout

Requires a daemon with RC-16. When the capability report lacks `voice.stt` (or the device
path), the snapshot marks `mic_dictate_server` `unavailable` and the watch never sends turns.

## Verification

```text
xcodebuild test -workspace packages/aiur-mobile/ios/aiur.xcworkspace -scheme aiur -only-testing:aiurTests/VoiceRelayTests -destination 'platform=iOS Simulator,name=iPhone 16'
packages/aiur-mobile/android/gradlew -p packages/aiur-mobile/android :aiur-native:testDebugUnitTest --tests '*VoiceRelayTest'
```

Plus a fake-daemon round trip (C4 chunk test): `fixtures/voice/turn-hello.pcm` through a fake
socket server in the test harness that returns `transcript{final:"hello"}`.

| Test | Expected | Must fail without |
|---|---|---|
| `joinPayloadIdentifiesWatch` | join has `client.kind == "watch"`, target, `v:1` | payload builder |
| `framesAre6400Bytes` | all but the last chunk 6,400 B | chunker |
| `readOnlyMapsToReadOnly` | 403 → `read_only` | mapping |
| `unknownErrorIsUnknown` | unlisted reason → `unknown` | default branch |
| `typedErrorCarriesFixtureRetry` | `cost_cap` → `error{code: cost_cap, retry: none}`; `transport_lost` → `retry: now` | the fixture lookup (pass `reason_code` through without `retry` → fails) |
| `fileDeletedOnEveryPath` | success, error, timeout → file gone | deletes |
| `realTimePacingDefault` | 10 chunks take ≥ 2 s virtual time | pacing gate |

Device: DV-W5 (D-relay variant), DV-W6, DV-W12.

## Completion and handoff

- [ ] Round trip works against the fake daemon and on device.
- Dependents: MP-N7-C4-T05.
