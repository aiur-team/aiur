---
ticket_id: MP-N7-C3-T03
feature_id: MP-N7
chunk_id: MP-N7-C3
bucket: 3-mobile-watch
title: Wear OS Command card with options and answer outcome states
status: blocked
blocked_by: [DESIGN-N7, DESIGN-N6, DESIGN-E2, MP-N7-C3-T02, MP-N7-C1-T03, MP-N7-C1-T04]
prior_units: []
prior_boundaries: []
prior_features: [MP-E2, MP-N6]
prior_findings: ["decision.ex fields", "command contract §6"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N7-C3-T03 — Wear OS Command card

## Identity and outcome

- Bucket 3, MP-N7, chunk C3. Wear twin of MP-N7-C2-T03.
- **Deliverable:** `CommandCardViewModel` (Kotlin `StateFlow`) implementing the **same**
  state machine as C2-T03, and `CommandCardScreen` (Compose for Wear). The state machine is
  specified once as a transition fixture `fixtures/watch-link/command-card-transitions.json`
  (added here; C2-T03's Swift test is switched to read it in the same PR).
- **Difference from watchOS:** no queued path: a failed `sendRequest` is `notConfirmed`
  immediately (C3-T01). The mic button is behind the `voice` feature flag until C4-T01.
- **Ownership note:** as C2-T03 (MP-N6-C5-T01 overlap; CONTRACT-REQUESTS item 2).

## Dependencies and blockers

DESIGN-N7, DESIGN-N6, DESIGN-E2; MP-N7-C3-T02, MP-N7-C1-T03, MP-N7-C1-T04.

## Verified starting point

Same as MP-N7-C2-T03: `decision.ex:21-27,120-126`; command contract §6 rules 1, 2, 5.

## Chosen design

See MP-N7-C2-T03 state machine. Haptic on success via `HapticFeedbackType` (Compose)
or `Vibrator` one-shot; confirm step identical. Options as `Chip`s; recommended one marked
with an icon and content description "recommended".

## Implementation steps

1. Transition fixture JSON; Kotlin table test; update Swift test to read the same file.
2. ViewModel + screen.
3. Navigation route `card/{instanceId}/{decisionId}`.

## Non-happy paths

As C2-T03 (phone unreachable, daemon unreachable, resolved elsewhere, conflict, stale,
unknown). No Command text persisted.

## Compatibility and rollout

Wear-only.

## Verification

```text
packages/aiur-mobile/wear/gradlew -p packages/aiur-mobile/wear :app:testDebugUnitTest --tests '*CommandCardViewModelTest'
xcodebuild test ... -only-testing:AiurWatchTests/CommandCardModelTests   # Swift reads the shared transition fixture
```

| Test | Expected | Must fail without |
|---|---|---|
| `transitionsMatchFixture` (both languages) | every transition row | each branch; mapping `failed`→`success` must fail |
| `retryReusesKey` | same key on retry | key reuse |
| `resolvedHidesOptions` | no chips | resolved rule |

Device: DV-W4 (Wear column).

## Completion and handoff

- [ ] Card matches DESIGN-N7 screens 3–4 on Wear; both platform suites read one fixture.
- Dependents: MP-N7-C3-T04, MP-N7-C3-T05, MP-N7-C4-T01.
