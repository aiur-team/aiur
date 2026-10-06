---
ticket_id: MP-N3-C4-T04
feature_id: MP-N3
chunk_id: MP-N3-C4
bucket: 3-mobile-watch
title: "Refresh policy: foreground fetch, pull-to-refresh, 15 s poll while visible, stop in background"
status: blocked
blocked_by: [DESIGN-N3, MP-N3-C4-T01, MP-N3-C2-T02]
prior_units: []
prior_boundaries: []
prior_features: [MP-N1, MP-N4]
prior_findings: []
size_owner: n/a (new package code)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N3-C4-T04 — Refresh and state synchronisation

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N3 / MP-N3-C4.
- **User value:** the list is current while you look at it, costs nothing while you don't, and
  never pretends to be live when it is not.
- **Deliverable:** `useMetaRefresh()` (PROPOSED): fetch on mount and on app foreground;
  pull-to-refresh; poll every 15 s while the screen is focused **and** the app is `active`; stop
  within one interval of backgrounding; a refetch hint from a decrypted notification (MP-N4) marks
  the machine due.
- **Non-goals:** background fetch (not relied on, brief N4); event streams (later, MP-R2).

## Dependencies and blockers

DESIGN-N3 (refresh affordance); MP-N3-C4-T01; MP-N3-C2-T02 (gateway cache keeps 15 s polling from
multiplying RPCs).

## Verified starting point (base `45a290e3`)

- No app. Platform facts (accessed 2026-10-06): iOS does not relaunch a force-quit app for
  background pushes (`application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`,
  <https://developer.apple.com/documentation/uikit/uiapplicationdelegate/application(_:didreceiveremotenotification:fetchcompletionhandler:)>),
  so the list must not depend on background refresh (MP-N1 framework-evidence S41).
- React Native `AppState` reports `active | background | inactive`
  (<https://reactnative.dev/docs/appstate>, accessed 2026-10-06, RN 0.86/0.87 docs).
- RQ-N3-4 (battery): one HTTPS GET per machine per 15 s only while the screen is visible; the
  advisory DV-P13 measures background drain. No polling in background, so battery cost while
  backgrounded is zero by construction. **Resolved** as "foreground-only polling; measure in DV-P13".

## Chosen design

- Timer per machine, jittered ±1 s, reset after each response. `AppState` `background` or screen
  blur → clear timers; `active` + focus → immediate fetch if the last fetch is older than 15 s.
- Failure backoff: 15 s → 30 s → 60 s cap per machine; the row keeps cached values with age.
- The 60 s client freshness budget (client-capability-model.md §6) drives `stale` independently.

## Implementation steps

`src/screens/meta/useMetaRefresh.ts`; wire into T01. About 100 lines.

## Non-happy paths

Rapid foreground/background flapping (debounce 1 s); clock changes (monotonic timers); a
machine that never answers (backoff, unreachable state with age).

## Compatibility and rollout

Interval is a constant; DESIGN-N3 may change the number, not the rule.

## Verification

`src/screens/meta/__tests__/useMetaRefresh.test.ts` with fake timers and a mocked `AppState`:

1. `"polls every 15 s while active and focused"`.
2. `"stops within one interval after background"` (MP-N3 AC8). Mutation: ignore `AppState` → fails.
3. `"foreground after 20 s fetches immediately"`. 4. `"backoff doubles to 60 s on failures"`.
5. `"notification hint marks the machine due"`.

```bash
npm --prefix packages/aiur-mobile test -- src/screens/meta/__tests__/useMetaRefresh.test.ts
```

Device: DV-P13 (advisory) on the iPhone and Android slots — 8 h backgrounded, record battery
attribution (iOS Settings › Battery; `adb shell dumpsys batterystats`).

## Completion and handoff

- [ ] Tests pass with mutation checks; DV-P13 recorded. Docs: none beyond the mobile guide's
      "How fresh is the list" line. Dependents: MP-N7 snapshot push triggers (phone side).
