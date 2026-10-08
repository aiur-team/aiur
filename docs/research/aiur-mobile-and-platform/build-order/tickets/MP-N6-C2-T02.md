---
ticket_id: MP-N6-C2-T02
feature_id: MP-N6
chunk_id: MP-N6-C2
bucket: 3-mobile-watch
title: Tap landing — cold/warm start routing to the resolved screen, never an inbox, no audio session
status: blocked
blocked_by: [DESIGN-N6 (§5 loading/landing states), DESIGN-N1, MP-N6-C2-T01, MP-N1-C6-T01, MP-N1-C4-T01]
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

Bucket 3, MP-N6, chunk C2. Connect the OS tap callback (exposed by MP-N1-C6-T01 as `onNotificationOpened`; the Phase B
candidate N1-C6-T03 was retired in favour of this ticket, MP-N1 CONTRACT-REQUESTS B5: iOS
`UNUserNotificationCenterDelegate` response, Android `PendingIntent`) to C2-T01 and push
the resolved screen: cold start shows a neutral loading state until the pairing store
loads (no flash of a generic inbox, V-N4); warm start pushes on top of the current stack.
No `AVAudioSession` / `AudioRecord` is created on this path (D16; AC-N6-2).

Boundary: N1 owns the OS callbacks and the route table (`aiur://` scheme, N1-C4-T01);
N6 owns the decision of which screen and the landing states.

## Dependencies and blockers

**Blocked on DESIGN-N6** landing/loading state design and DESIGN-N1 navigation; C2-T01;
MP-N1-C6-T01 (tap callback hand-off), MP-N1-C4-T01.

## Verified starting point

Destination → screen kinds: C2-T01. Device scenarios V-N1, V-N4.

## Chosen design (fixed parts)

- `onNotificationOpened(destination)` (MP-N1-C6-T01) → `resolveDestination` (C2-T01) →
  `landOn(screen)`. The landing module imports no audio module; an ESLint
  `no-restricted-imports` rule on `src/landing/**` forbids `src/voice/**` and the native
  audio module, and a test asserts no audio session is created.
- Cold start: the root navigator mounts `LandingGate` (S01) until the pairing store and the
  destination are loaded, then `replace`s it with the resolved screen; no inbox screen is
  ever mounted first (V-N4).
- Warm start: `push` the resolved screen on the current stack; if the same Command screen
  is already on top, refresh it instead of stacking a duplicate (V-N2; conversation case
  is C2-T03).
- Pairing store locked (iOS before first unlock, keychain `errSecInteractionNotAllowed`)
  → S18 "Unlock to view"; on `protectedDataDidBecomeAvailable` the gate retries once.

## Implementation steps

1. `packages/aiur-mobile/src/landing/landOn.ts` (pure: screen kind → navigation action).
2. `packages/aiur-mobile/src/landing/LandingGate.tsx` (S01, S18).
3. Hook `onNotificationOpened` in `src/app/notifications.ts` (MP-N1 route table owner
   exposes the callback; N6 registers the handler).
4. ESLint rule entry in `packages/aiur-mobile/.eslintrc.*` for `src/landing/**`.
5. Docs (same PR): `website/docs-app/guide/mobile.md` § "Opening a notification" (lands
   on the Command; mic is never on).

## Non-happy paths

- Pairing store locked → S18, not an error.
- Destination for an unpaired machine → C2-T01 "Not paired with this machine" (S12).
- Resolver returns instance-level fallback → instance view with the C2-T01 note.

## Compatibility and rollout

Copy and layout of S01/S18 are DESIGN-N6 (design-pending). Navigation structure follows
DESIGN-N1.

## Verification

```text
npm --prefix packages/aiur-mobile test -- test/landing/landOn.test.ts test/landing/LandingGate.test.tsx
npm --prefix packages/aiur-mobile run lint
```

| Test | Expected | Must fail without |
| --- | --- | --- |
| `tapDoesNotStartAudio` (AC-N6-2) | native audio module mock never called during tap → land | the no-audio rule (pre-warm the recorder → fails) |
| `S01_coldStartNeverMountsInbox` (V-N4) | navigator history is `[LandingGate, Command]`; no inbox screen | the gate (`navigate('Inbox')` first → fails) |
| `warmStartPushesOnTop` | `push` with the resolved screen | the warm branch |
| `sameCommandOnTopRefreshesNotStacks` (V-N2) | one Command screen in the stack | dedup |
| `S18_lockedStoreShowsUnlockToView` | locked error → S18, retry on unlock event | the locked branch (map to error → fails) |
| lint: `landing imports no voice module` | `npm run lint` fails on a planted import in a fixture file | the ESLint rule |

Device: V-N1, V-N4.

## Completion and handoff

- [ ] Each test fails with its hunk reverted in a worktree.
- [ ] Docs: `website/docs-app/guide/mobile.md` (same PR).
- Dependents: C2-T03, C3-T01.
