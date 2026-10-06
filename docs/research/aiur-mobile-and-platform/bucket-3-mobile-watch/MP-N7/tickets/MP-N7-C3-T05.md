---
ticket_id: MP-N7-C3-T05
feature_id: MP-N7
chunk_id: MP-N7-C3
bucket: 3-mobile-watch
title: Wear OS interactive-control inventory test (no orchestration controls, AC6)
status: blocked
blocked_by: [DESIGN-N7, MP-N7-C3-T02, MP-N7-C3-T03]
prior_units: []
prior_boundaries: []
prior_features: []
prior_findings: ["brief §3 watch scope; plan AC6"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N7-C3-T05 — Wear OS control inventory

## Identity and outcome

- Bucket 3, MP-N7, chunk C3. Wear twin of MP-N7-C2-T05.
- **Deliverable:** a Compose UI test that renders every screen from fixtures and collects
  all nodes with click/toggle semantics (`hasClickAction()`), asserting each has a
  `testTag` with prefix `aiur.` and that the set equals the **same** allow-list file used by
  the watchOS test (`packages/aiur-mobile/fixtures/watch-link/control-allowlist.json`; this
  ticket moves the allow-list from `targets/watch/Tests/` to the shared fixtures directory
  and updates the Swift test path), plus the shared deny patterns.

## Dependencies and blockers

DESIGN-N7, MP-N7-C3-T02, MP-N7-C3-T03.

## Verified starting point

Brief §3 / §6 N7; plan AC6. No code at `45a290e3`.

## Chosen design

As MP-N7-C2-T05, using `composeTestRule.onAllNodes(hasClickAction())` and
`SemanticsProperties.TestTag`. Screens rendered with fixture snapshots injected into
`SnapshotRepository` (no phone).

## Implementation steps

1. Add `testTag`s in C3 screens.
2. Move allow-list to shared fixtures; update Swift test path.
3. `ControlInventoryTest.kt`.

## Non-happy paths

n/a — test-only ticket; failure behaviour is the test's failure.

## Compatibility and rollout

Test-only.

## Verification

```text
packages/aiur-mobile/wear/gradlew -p packages/aiur-mobile/wear :app:connectedDebugAndroidTest --tests '*ControlInventoryTest'
```

| Test | Expected | Must fail without |
|---|---|---|
| `inventoryMatchesAllowList` | set equality | guard: proven by a scratch commit adding a "Pause" chip (record in PR body) |
| `denyPatterns` | no match | same proof |
| `untaggedClickableFails` | scratch untagged chip fails | prefix rule |

## Completion and handoff

- [ ] Shared allow-list used by both platforms.
- Dependents: MP-N7-C4-T01, MP-N7-C4-T05.
