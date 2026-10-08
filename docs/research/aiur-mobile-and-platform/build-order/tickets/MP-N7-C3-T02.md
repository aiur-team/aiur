---
ticket_id: MP-N7-C3-T02
feature_id: MP-N7
chunk_id: MP-N7-C3
bucket: 3-mobile-watch
title: Wear OS compact instance list and instance detail from the snapshot
status: blocked
blocked_by: [DESIGN-N7, DESIGN-N3, MP-N7-C3-T01, MP-N7-C1-T05, MP-N3-C3-T01, MP-N3-C3-T02]
prior_units: []
prior_boundaries: []
prior_features: [MP-N3]
prior_findings: ["overview.ex wording", "client-capability-model §7"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N7-C3-T02 — Wear OS instance list

## Identity and outcome

- Bucket 3, MP-N7, chunk C3. Wear twin of MP-N7-C2-T02 (same rules, Compose UI).
- **Deliverable:** `InstanceListScreen` (`ScalingLazyColumn`), `InstanceDetailScreen`,
  and a pure Kotlin `RowPresenter` that implements **exactly** the field-render table of
  MP-N7-C2-T02 §Chosen design, driven by the shared MetaRow fixtures
  `packages/aiur-mobile/fixtures/meta-row/` (MP-N3-C3-T02) plus watch-only cases in
  `fixtures/watch-link/row-presenter-cases.json` (added here; the Swift presenter test in
  C2-T02 is switched to read it in this PR so both platforms share one truth).
- **Non-goals:** card (C3-T03), controls other than navigation, combined inbox.

## Dependencies and blockers

DESIGN-N7, DESIGN-N3, MP-N7-C3-T01, MP-N7-C1-T05, MP-N3-C3-T01.

## Verified starting point

Same as MP-N7-C2-T02 (`overview.ex:53,168-169` wording; plan §6; capability model §7).
"Needs phone" wording replaces "Needs iPhone nearby" (DESIGN-N7 §5).

## Chosen design

Identical render rules to C2-T02. Compose specifics: `TimeText` shows the system time;
the snapshot age is a separate chip under the title updated every 30 s with
`LaunchedEffect` ticker. Rotary scrolling via the default `ScalingLazyColumn` behaviour.

## Implementation steps

1. `RowPresenter.kt` + shared fixture table.
2. Screens with `SwipeDismissableNavHost` (list → detail → card route placeholder).
3. Compose UI tests with fixture snapshots.

## Non-happy paths

As C2-T02: unavailable → "—" with content description naming the reason; unknown executor
→ "?"; unknown row state → "Unknown"; absent `open_commands` → "Open on phone to load";
phone unreachable → "Needs phone" + age.

## Compatibility and rollout

Wear-only UI.

## Verification

```text
packages/aiur-mobile/wear/gradlew -p packages/aiur-mobile/wear :app:testDebugUnitTest --tests '*RowPresenterTest'
packages/aiur-mobile/wear/gradlew -p packages/aiur-mobile/wear :app:connectedDebugAndroidTest   # Wear OS 5 emulator (API 34)
```

| Test | Expected | Must fail without |
|---|---|---|
| `RowPresenterTest` (table) | every case in `row-presenter-cases.json` | each rule; mutate unavailable → `0` and unknown executor → "Idle": both fail |
| `InstanceListScreenTest.needsPhoneBanner` | banner + age shown | reachability rule |
| `InstanceDetailScreenTest.absentListIsNotEmpty` | "Open on phone to load" | omit-vs-empty rule |

Device rows: DV-W3 (Wear column), MP-N7-C6-T02.

## Completion and handoff

- [ ] Matches DESIGN-N7 screens 1–2 on small (40/41 mm) and large (45 mm) Wear devices.
- Dependents: MP-N7-C3-T03, MP-N7-C3-T05, MP-N7-C5-T02.
