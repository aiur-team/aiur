---
ticket_id: MP-N7-C2-T05
feature_id: MP-N7
chunk_id: MP-N7-C2
bucket: 3-mobile-watch
title: watchOS interactive-control inventory test (no orchestration controls, AC6)
status: blocked
blocked_by: [DESIGN-N7, MP-N7-C2-T02, MP-N7-C2-T03]
prior_units: []
prior_boundaries: []
prior_features: []
prior_findings: ["brief §3 watch scope; plan AC6"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N7-C2-T05 — watchOS control inventory

## Identity and outcome

- Bucket 3, MP-N7, chunk C2.
- **User value:** the watch stays a steering tool, not a shrunken operations console:
  any future pause/resume/spawn button fails CI.
- **Deliverable:** an XCUITest that walks every screen reachable from fixtures
  (list, detail, card in each state, mic sheet once C4-T01 lands, Dictate review, Converse)
  and records each interactive element's accessibility identifier; it compares the set to
  an allow-list file `targets/watch/Tests/control-allowlist.json`.
- **Non-goals:** visual testing.

## Dependencies and blockers

DESIGN-N7 (its §6 acceptance requires an inventory per screen; the allow-list is that
inventory), MP-N7-C2-T02, MP-N7-C2-T03. C4 screens are added to the walk by C4-T01/T05 in
their own PRs (each must extend the allow-list deliberately).

## Verified starting point

Brief §3 and §6 N7 forbid pause/resume, spawn and general orchestration controls on the
watch; MP-N7 plan AC6 requires "a UI inventory test lists every interactive control".
No code exists at `45a290e3`.

## Chosen design

- Every interactive element gets an accessibility identifier with prefix `aiur.` (rule
  enforced by the test: an interactive element without the prefix fails).
- Allow-list (initial): `aiur.list.row`, `aiur.detail.command`, `aiur.card.option`,
  `aiur.card.confirm`, `aiur.card.cancel`, `aiur.card.retry`, `aiur.card.mic`,
  `aiur.card.moreOnPhone`, `aiur.nav.back`.
- A deny-pattern list also fails the test if any identifier or label matches
  `/pause|resume|spawn|stop agent|restart|merge|dispatch/i`, so renaming cannot sneak one in.
- The app reads a launch argument `-AiurFixtureSnapshot <file>` (debug builds only) to load
  fixtures without a phone.

## Implementation steps

1. Add identifiers in C2 views (small edits).
2. `ControlInventoryUITests.swift` with the walker.
3. Allow-list JSON and deny patterns.

## Non-happy paths

Fixture loading is compiled only in `DEBUG`; a test asserts the release build ignores the
argument.

## Compatibility and rollout

Test-only plus identifiers.

## Verification

```text
xcodebuild test -workspace packages/aiur-mobile/ios/aiur.xcworkspace -scheme AiurWatch -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)' -only-testing:AiurWatchUITests/ControlInventoryUITests
```

| Test | Expected | Must fail without |
|---|---|---|
| `testInventoryMatchesAllowList` | set equality | — this is a guard: proven by adding a dummy `aiur.card.pause` button in a scratch commit → test fails (record in PR body) |
| `testDenyPatterns` | no match | same proof with a label "Pause agent" |
| `testUnprefixedInteractiveFails` | an unprefixed button in a scratch commit fails | prefix rule |
| `testFixtureArgIgnoredInRelease` | release config ignores launch arg | `#if DEBUG` guard |

## Completion and handoff

- [ ] Test in CI; the PR body records the scratch-commit failure proof.
- Dependents: MP-N7-C4-T01, MP-N7-C4-T05 (extend the walk).
