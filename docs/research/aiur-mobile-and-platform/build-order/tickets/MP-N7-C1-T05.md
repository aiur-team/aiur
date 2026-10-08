---
ticket_id: MP-N7-C1-T05
feature_id: MP-N7
chunk_id: MP-N7-C1
bucket: 3-mobile-watch
title: Snapshot push triggers and debounce (phone to watch)
status: blocked
blocked_by: [DESIGN-N7, RQ-TRANSPORT, MP-N7-C1-T02, MP-N7-C1-T03, MP-N1-C3-T01, MP-N1-C3-T04, MP-N3-C3-T01]
prior_units: []
prior_boundaries: []
prior_features: [MP-N1, MP-N3, MP-N4]
prior_findings: ["client-capability-model §6 refresh triggers"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N7-C1-T05 — Snapshot push triggers

## Identity and outcome

- Bucket 3, MP-N7, chunk C1.
- **User value:** the watch's compact list stays as fresh as the phone's knowledge
  without the watch polling (battery, plan §8).
- **Deliverable:** a native `SnapshotScheduler` per platform that decides **when** to call
  `sendSnapshot` (iOS) / `SnapshotPublisher.publish` (Android) and builds the body from the
  MP-N1-C3-T04 projection.
- **Non-goals:** how data reaches the phone (MP-N1-C3, MP-N3-C4, MP-N4). The phone never
  wakes itself to refresh for the watch (no background fetch, brief N4).

## Dependencies and blockers

- DESIGN-N7; RQ-TRANSPORT (refresh fetches); MP-N7-C1-T02/T03 (send primitives);
  MP-N1-C3-T01 (capability cache events), MP-N1-C3-T04 (projection), MP-N3-C3-T01
  (`MetaRow` row state, so watch and phone share one state priority).

## Verified starting point

- No client code exists. Refresh rules to follow: `contracts/client-capability-model.md` §6
  (foreground refetch, 30 s foreground polling fallback, none in background) and MP-N3 plan
  §3 (15 s while the list is visible; stop when backgrounded).
- Platform delivery semantics: `updateApplicationContext` keeps only the newest value
  (S6); Data Layer items without `setUrgent()` may wait up to 30 minutes
  (<https://developer.android.com/training/wearables/data/data-items>, updated 2026-09-22).

## Chosen design

Triggers (each schedules a send; sends are coalesced):

| Trigger | Source |
|---|---|
| Capability cache revision change for any instance | MP-N1-C3-T01 event |
| Registry/summary refresh result changes any rendered field (row state, counts, Fact status) | MP-N3-C4 data store change event |
| Reachability change of any machine | MP-N1-C5 probe result |
| Device revoked for a machine | MP-N1 typed `device_revoked` handling (MP-N1-C3 resolver input I3) |
| Notification received for a Command (NSE/FCM service writes a hint to the app group / shared prefs; on next app process run) | MP-N1-C6 |
| Watch became active / reachable (`sessionReachabilityDidChange`, Wear `CapabilityClient` change) | brokers |

Debounce: 2 s trailing window, max one send per 2 s; a send whose body is byte-identical
(except `as_of`) to the last sent body is skipped, **unless** the last send is older than
5 minutes (so the watch's age display can be refreshed with `as_of` while the phone is
active). No sends while the phone app has no fresh data at all; the watch keeps the old
snapshot and shows its age.

`open_commands[]` in the snapshot comes from the MP-N6 `needs_you` list
(MP-N6-C1-T02) when the phone has fetched it; otherwise the instance's `open_commands`
is omitted and its `awaiting` Fact is still shown (never an empty list presented as
"no Commands").

## Implementation steps

1. `SnapshotScheduler` (Swift / Kotlin) with injected clock, sender, and change stream.
2. Subscribe to the triggers above through the native module's event emitter (data events
   are published by JS screens into native via `AiurNative.publishWatchState(json)` for
   JS-owned stores; native-owned sources call directly).
3. Body = projection(MP-N1-C3-T04) + `open_commands` merge; validate size budget (C1-T01).
4. Unit tests with a fake clock.

## Non-happy paths

- Phone app suspended: no sends happen; the watch shows the last `as_of` age (plan §8).
- Body over 16 KiB (RC-38; MP-N7-C1-T01 invariant 2 owns the budget and the order): drop
  `open_commands` beyond 5 per instance, then `background_agents`, then `stopped`, `crashed`,
  oldest `stale` instances counted in `truncated`; never drop `live`/`starting` rows,
  `row_state` or Facts; log `snapshot_truncated`.
- Rapid flapping reachability: debounce prevents a send storm.

## Compatibility and rollout

Client-only. No config.

## Verification

```text
xcodebuild test -workspace packages/aiur-mobile/ios/aiur.xcworkspace -scheme aiur -only-testing:aiurTests/SnapshotSchedulerTests -destination 'platform=iOS Simulator,name=iPhone 16'
packages/aiur-mobile/android/gradlew -p packages/aiur-mobile/android :aiur-native:testDebugUnitTest --tests '*SnapshotSchedulerTest'
```

| Test | Expected | Must fail without |
|---|---|---|
| `coalescesBurst` | 10 triggers in 1 s → 1 send | the debounce |
| `skipsIdenticalBody` | identical body within 5 min → no send | the equality check |
| `refreshesAgeAfterFiveMinutes` | identical body after 5 min → send | the 5-minute override |
| `revocationSendsImmediately` | revoke → send within the 2 s window with machine removed | revoke trigger wiring |
| `truncationKeepsFacts` | oversize input → rows and Facts present, extra commands dropped | truncation order |
| `missingNeedsYouOmitsList` | no `needs_you` data → `open_commands` absent, not `[]` | the omit rule (replace with `[]` → fails) |

## Completion and handoff

- [ ] Scheduler on both platforms; tests pass and fail with hunks reverted.
- Dependents: MP-N7-C2-T02, MP-N7-C3-T02, MP-N7-C5.
