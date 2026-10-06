---
ticket_id: MP-E6-C7-T04
feature_id: MP-E6
chunk_id: MP-E6-C7
bucket: 2-platform
title: Assistant audio playback queue with barge-in stop and echo-cancelled capture
status: blocked
blocked_by: [DESIGN-E6, MP-E6-C1-T01, MP-E6-C7-T02]
prior_units: []
prior_boundaries: [VOX, WEB]
prior_features: [ui-08]
prior_findings: []
size_owner: BROWSER
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C7-T04 — Playback and barge-in

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C7.
- **User value:** natural turn-taking: the operator can interrupt the assistant by speaking,
  and the assistant does not hear itself through the speakers.
- **Deliverable:** in `voice-converse.js`: a playback queue for `audio` events (PCM at the
  negotiated rate), stopped and flushed on `interrupted`; `playback_state` events to the
  daemon; capture opened with `echoCancellation: true` (MP-E5-C1-T02 option). If the spike's
  RQ-E6-5 fails, a **half-duplex fallback** mutes capture while playback runs (DESIGN-E6
  states it).

## Dependencies and blockers

- **Spike:** RQ-E6-5 (echo cancellation with speakers) decides full-duplex vs fallback as
  default. **Owner:** DESIGN-E6 interrupted state.
- **Predecessors:** C7-T02.

## Verified starting point (base `45a290e3`)

Playback precedent: `playAudio` schedules `AudioBufferSourceNode`s at 44,100 Hz with an odd
byte carry and `nextPlaybackAt` (`conversation-voice-controller.js:398-423`); stop/flush
`clearPlaybackSources` (`:477-485`); audio unlocked inside the click gesture (`:145-152`).

## Chosen design

- Reuse the precedent's scheduling, with the sample rate from the `audio` event's `format`
  (`pcm_16000` per contract §3.6) instead of hard-coded 44,100.
- `interrupted{turn_id}` → stop all sources for that turn, drop queued chunks with that
  turn id, send `playback_state: stopped`.
- Playback context created and resumed in the Start click (gesture rule, precedent `:145-152`).

## Implementation steps

Queue module inside `voice-converse.js`, capture option, fallback flag, tests.

## Non-happy paths

Audio for an old turn after interruption → dropped; context suspended by the browser →
status shows "audio blocked; click to resume" (DESIGN-E6 copy).

## Compatibility and rollout

Ships with DESIGN-E6. Rollback: revert.

## Verification

| Test (browser, fake AudioContext) | Expected |
| --- | --- |
| "interruption stops playback and drops queued chunks of that turn" | sources stopped; later chunks for the turn not started |
| "playback uses the negotiated sample rate" | buffer created at 16,000 |
| "capture requests echo cancellation" | `getUserMedia` constraints include `echoCancellation: true` |
| "half-duplex fallback mutes capture while speaking" | no `audio` pushes during playback when the flag is on |

```bash
env -C src/browser npm run test:units
```

Manual (required, from the spike's RQ-E6-5 protocol): desktop with speakers and a phone
browser; 5 trials each; record false barge-ins.

**Mutation check.** Hard-code 44,100: the sample-rate test fails.

## Completion and handoff

- [ ] Playback, barge-in, echo cancellation or fallback per spike result.
