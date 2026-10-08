---
ticket_id: MP-N7-C4-T03
feature_id: MP-N7
chunk_id: MP-N7-C4
bucket: 3-mobile-watch
title: Watch audio capture to a 16 kHz mono PCM file and transfer to the phone, with deletion after use
status: blocked
blocked_by: [DESIGN-N7, DESIGN-E5, DESIGN-E6, MP-N7-C4-T01, MP-N7-C1-T01]
prior_units: []
prior_boundaries: ["VOX #36"]
prior_features: [MP-E5, MP-E6]
prior_findings: ["framework-evidence S6, S7, S10, S36", "D17 no raw audio retained"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N7-C4-T03 — Watch audio capture and transfer

## Identity and outcome

- Bucket 3, MP-N7, chunk C4.
- **User value:** the watch can send spoken turns to the phone for relayed dictation
  (D-relay) and turn-based Converse, without a live socket on the watch.
- **Deliverable:** a `TurnRecorder` on each watch: press to start, press to stop, hard cap
  60 s per turn; output raw PCM s16le, 16 kHz, mono (`pcm_s16le_16k_mono`, matching the
  daemon's existing 16 kHz mono PCM input, `voice_socket.ex` via voice-session.md §2);
  transfer as a `voice_turn` (C1-T01) with `WCSession.transferFile` (watchOS) or
  `ChannelClient` (Wear); delete the local file once the phone acknowledges receipt or the
  session ends.
- **Non-goals:** phone-side forwarding (C4-T04); playback (C4-T05).

## Dependencies and blockers

DESIGN-N7 (screens 6–7 capture states), DESIGN-E5/E6, MP-N7-C4-T01, MP-N7-C1-T01.

## Verified starting point

- No live socket on watchOS: `URLSessionWebSocketTask` is allowed only for audio
  streaming apps while streaming, VoIP during a call, or tvOS listeners; otherwise
  connections stay `.waiting` (TN3135, S7, revised 2026-07-16). So the watch records to a
  file and the phone relays.
- watchOS can record with `AVAudioRecorder` (watchOS 4.0+, S10); `transferFile` queues in
  the background and is "not delivered immediately" (S6) — latency is measured in DV-W6.
- Wear OS: `MediaRecorder`/`AudioRecord` for recording (S36); `ChannelClient` streams
  between nodes (Data Layer, S32).
- D17: raw audio is never retained.

## Chosen design

- watchOS: `AVAudioRecorder` settings `AVFormatIDKey: kAudioFormatLinearPCM`,
  `AVSampleRateKey: 16000`, `AVNumberOfChannelsKey: 1`, `AVLinearPCMBitDepthKey: 16`,
  `AVLinearPCMIsFloatKey: false`, `AVLinearPCMIsBigEndianKey: false`, file in
  `FileManager.temporaryDirectory`. `AVAudioSession.setCategory(.record)` only after the
  user presses Talk.
- Wear: `AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, 16000,
  CHANNEL_IN_MONO, ENCODING_PCM_16BIT, …)` writing raw PCM to cache dir; requires
  `RECORD_AUDIO` runtime permission.
- Size: 32,000 B/s × 60 s = 1.92 MB max per turn.
- Transfer: watchOS `transferFile(url, metadata: envelope)`; on
  `session(_:didFinish:error:)` success → delete. Wear: `ChannelClient.openChannel(node,
  "/aiur/voice/<session>/<seq>")` + `sendFile`; on completion → delete.
- Every exit path (cancel, error, leaving screen, app termination on next launch sweep)
  deletes files: a launch-time sweep removes any `aiur-turn-*.pcm` older than 5 minutes.

## Implementation steps

1. `TurnRecorder` (Swift/Kotlin) with injectable recorder and transfer facades.
2. Launch sweep.
3. Permission handling (`needs_permission` state to C4-T01 option).
4. Tests.

## Non-happy paths

Mic permission denied → `needs_permission`. Phone unreachable → turn not started ("Needs
phone"), because a queued turn for Converse is useless. Transfer failure → error state,
file deleted, user may talk again. Recording interrupted (incoming call) → turn discarded.

## Compatibility and rollout

Used only when DESIGN-N7 picks D-relay for Dictate or when Converse is available.

## Verification

```text
xcodebuild test ... -scheme AiurWatch -only-testing:AiurWatchTests/TurnRecorderTests
packages/aiur-mobile/wear/gradlew -p packages/aiur-mobile/wear :app:testDebugUnitTest --tests '*TurnRecorderTest'
```

| Test | Expected | Must fail without |
|---|---|---|
| `settingsAre16kMonoPcm` | captured recorder settings | the settings dict |
| `capStopsAt60s` (virtual clock) | auto-stop at 60 s | cap |
| `fileDeletedAfterTransfer` | file gone after success callback | delete-on-success |
| `fileDeletedOnCancel` | gone after cancel | cancel delete |
| `launchSweepRemovesOrphans` | old files removed | sweep |
| `noSessionBeforeTalk` | audio session untouched until Talk | — (guard; commented) |

Device: DV-W6 (latency), DV-W12 (no audio file remains on watch or phone after a turn).

## Completion and handoff

- [ ] Capture + transfer + deletion on both platforms.
- Dependents: MP-N7-C4-T04, MP-N7-C4-T05.
