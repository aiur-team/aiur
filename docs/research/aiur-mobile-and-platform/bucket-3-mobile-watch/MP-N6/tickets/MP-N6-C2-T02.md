---
ticket_id: MP-N6-C2-T02
feature_id: MP-N6
chunk_id: MP-N6-C2
bucket: 3-mobile-watch
title: Tap landing — cold/warm start routing to the resolved screen, never an inbox, no audio session
status: blocked
blocked_by: [DESIGN-N6 (§5 loading/landing states), DESIGN-N1, MP-N6-C2-T01, N1-C6-T3, N1-C4-T1]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-N1, MP-N4]
prior_findings: [D16 (no mic on tap), V-N1, V-N4]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C2-T02 — Tap landing

## Identity and outcome

Bucket 3, MP-N6, chunk C2. Connect the OS tap callback (owned by N1-C6-T3: iOS
`UNUserNotificationCenterDelegate` response, Android `PendingIntent`) to C2-T01 and push
the resolved screen: cold start shows a neutral loading state until the pairing store
loads (no flash of a generic inbox, V-N4); warm start pushes on top of the current stack.
No `AVAudioSession` / `AudioRecord` is created on this path (D16; AC-N6-2).

Boundary: N1 owns the OS callbacks and the route table (`aiur://` scheme, N1-C4-T1);
N6 owns the decision of which screen and the landing states.

## Dependencies and blockers

**Blocked on DESIGN-N6** landing/loading state design and DESIGN-N1 navigation; C2-T01;
N1-C6-T3, N1-C4-T1.

## Verified starting point

Destination → screen kinds: C2-T01. Device scenarios V-N1, V-N4.

## Chosen design (fixed parts)

The tap path imports no audio module; a lint rule or test asserts it.

## Implementation steps

After approval: navigation glue + loading screen + tests.

## Non-happy paths

Tap while pairing store is locked (before first unlock, iOS) → loading → "Unlock to view"
state (DESIGN-N6) rather than an error.

## Compatibility and rollout

n/a.

## Verification

UI test `tapDoesNotStartAudio` (asserts no audio session before Mic + choice; must fail if
the screen pre-warms the recorder, AC-N6-2); cold/warm routing tests; device V-N1, V-N4.

## Completion and handoff

- [ ] Dependents: C2-T03, C3-T01.
