---
ticket_id: MP-N7-C4-T05
feature_id: MP-N7
chunk_id: MP-N7-C4
bucket: 3-mobile-watch
title: Turn-based Converse on the watch through the phone (MP-E6), with reply playback and session end
status: blocked
blocked_by: [DESIGN-N7, DESIGN-E6, OQ-N7-3, MP-N7-C4-T04, "MP-E6-C4-T01", "MP-E6-C5-T03", "RC-16 MP-E5 device voice path", RQ-N7-6]
prior_units: []
prior_boundaries: ["VOX #36"]
prior_features: [MP-E6, MP-E5]
prior_findings: ["framework-evidence S7: no duplex audio on watchOS"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N7-C4-T05 — Turn-based Converse

## Identity and outcome

- Bucket 3, MP-N7, chunk C4.
- **User value:** talk a blocker through with the conversational assistant from the wrist,
  one turn at a time, and confirm any proposed answer explicitly.
- **Deliverable:** watch `ConverseView` (talk → waiting → reply playing/reply text → talk
  again or End) and phone `VoiceRelay` converse mode: one `voice:converse` channel per
  session kept open on the phone, each watch turn streamed as `audio` + `stop`, assistant
  `assistant_text` and `audio` frames collected per `turn_id` and returned as
  `voice_result{reply_text, reply_audio_ref}` (file transfer), `draft` events forwarded so
  the watch can show Confirm/Discard, `end` on leave.
- **Non-goals:** duplex/barge-in on the watch (not feasible, S7); the conversation
  component itself (MP-E6).

## Dependencies and blockers

- MP-E6-C4-T01 (session process), MP-E6-C5-T03 (draft confirm/discard), RC-16 device path,
  RQ-N7-6 (pacing), MP-N7-C4-T04.
- **OQ-N7-3 / D-N7-4:** if DV-W6 misses the D-N7-3 latency figure, "Continue on phone" is
  the fallback only with owner approval; this ticket implements the handoff button only if
  approved.
- DESIGN-E6 (draft confirmation, provider disclosure), DESIGN-N7 (screen 7).

## Verified starting point

- Converse protocol: voice-session.md §3.3–3.4 (`audio`, `stop`, `end`, `confirm_draft`,
  `discard_draft`, `playback_state`; daemon `state`, `assistant_text`, `audio`/`audio_done`,
  `interrupted`, `draft`, `delivery`). Reply audio format comes "from provider metadata, not
  hard-coded `pcm_44100`" (§3.4).
- Today the browser "voice conversation" is half-duplex and talks to the worker
  (MP-E6 plan line 31, `voice_channel.ex:118-144,169-182`); MP-E6 replaces it with a daemon
  relay that "works for phone/watch unchanged" (MP-E6 plan §alternatives).
- Provider processing: Converse audio and context go to the configured provider (voice-session.md
  §privacy table); the watch must show the same disclosure as the phone (brief §7).

## Chosen design

Watch state machine:

```text
idle ─Talk→ recording ─Stop→ uploading ─phone ack→ waiting ─voice_result→ replying(text, audio?)
replying ─playback done or Skip→ idle        any ─End/leave screen→ ended (voice_session_end)
waiting ─timeout 20 s→ error(timeout)        any ─phone unreachable→ needsPhone (session ended)
draft event → draftCard(Confirm | Discard)   # Confirm sends confirm_draft through the phone
```

- Reply audio: phone writes the provider audio for one `turn_id` to a temporary file in
  the format announced by the daemon, converts to a watch-playable container only if the
  format is not raw PCM (AAC via `AVAudioConverter` on iOS, `MediaCodec` on Android), sends
  it by `transferFile`/`ChannelClient`; the watch plays it with `AVAudioPlayer` /
  `MediaPlayer`, then deletes it. Text is always shown, so a failed audio transfer degrades to
  text-only (`degraded`).
- Leaving the screen sends `end`; the phone leaves the channel. MP-E6 retains the full
  transcript; no audio is retained anywhere (D17).
- Drafts are never confirmed implicitly.

## Implementation steps

1. Watch `ConverseModel` + view (both platforms), shared transition fixture
   `fixtures/watch-link/converse-transitions.json`.
2. Phone `VoiceRelay` converse mode: session map keyed by `session`, per-turn collectors.
3. Reply audio file handling and deletion.
4. Extend inventory allow-lists (`aiur.converse.talk`, `.stop`, `.end`, `.confirm`, `.discard`, `.skip`).

## Non-happy paths

Capability `voice.conversation` unavailable → Converse option unavailable (C4-T01). Daemon
`error` → error state with `reason_code`. Revocation → `auth_changed` → session ends.
Phone suspended between turns (iOS) → next turn may wait; DV-W6 records. Watch wrist-down
during playback → playback stops; the text remains.

## Compatibility and rollout

Behind capability `voice.conversation`; no flag beyond that.

## Verification

```text
xcodebuild test ... -scheme AiurWatch -only-testing:AiurWatchTests/ConverseModelTests
xcodebuild test ... -scheme aiur -only-testing:aiurTests/VoiceRelayConverseTests
packages/aiur-mobile/wear/gradlew -p packages/aiur-mobile/wear :app:testDebugUnitTest --tests '*ConverseModelTest'
packages/aiur-mobile/android/gradlew -p packages/aiur-mobile/android :aiur-native:testDebugUnitTest --tests '*VoiceRelayConverseTest'
```

| Test | Expected | Must fail without |
|---|---|---|
| `transitionsMatchFixture` | every row | each transition |
| `draftNeverAutoConfirmed` | draft event → no `confirm_draft` pushed without user action | the explicit-confirm rule |
| `leaveSendsEnd` | leaving → `end` pushed and channel left | end-on-leave |
| `audioFailureDegradesToText` | transfer error → replying(text) with degraded flag | fallback |
| `replyFilesDeleted` | no reply file after playback/skip/error | deletes |

Device: DV-W6 (latency vs D-N7-3), DV-W12.

## Completion and handoff

- [ ] Converse turn round trip on device meets D-N7-3 or the approved fallback is in place.
- Dependents: MP-N7-C6-T01, C6-T02.
