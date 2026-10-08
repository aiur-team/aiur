---
ticket_id: MP-N7-C2-T03
feature_id: MP-N7
chunk_id: MP-N7-C2
bucket: 3-mobile-watch
title: watchOS Command card with options and answer outcome states
status: blocked
blocked_by: [DESIGN-N7, DESIGN-N6, DESIGN-E2, MP-N7-C2-T02, MP-N7-C1-T02, MP-N7-C1-T04, MP-N6-C5-T01]
prior_units: []
prior_boundaries: []
prior_features: [MP-E2, MP-N6]
prior_findings: ["decision.ex fields", "command contract §6 D11"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N7-C2-T03 — watchOS Command card

## Identity and outcome

- Bucket 3, MP-N7, chunk C2.
- **User value:** read a blocker's short summary and pick a suggested option on the wrist,
  with an honest confirmation of what happened.
- **Deliverable:** `CommandCardView` + `CommandCardModel` (state machine) on watchOS:
  fetch via `PhoneLink.fetchCommand`, show summary, ≤ 2 excerpt lines, ≤ 3 options with
  the recommendation marker, an option tap → confirm → `sendAnswer`, and outcome states.
  The mic button is present but routes to C4-T01 (disabled until that ticket lands, with
  reason "not in this build" hidden from users by feature flag).
- **Non-goals:** custom text entry (C4-T02 Dictate), notification routing (C2-T04).
- **Ownership note:** MP-N6-C5-T01 lists the same watch card. This ticket implements it
  on watchOS; MP-N6 owns the Command response *rules* (DESIGN-N6/E2 states, the shared view
  model). Recorded in CONTRACT-REQUESTS.md item 2.

## Dependencies and blockers

- DESIGN-N7 (layout, D-N7-8 context depth), DESIGN-N6 and DESIGN-E2 (states and copy).
- MP-N7-C2-T02, MP-N7-C1-T02 (broker replies), MP-N7-C1-T04 (stale outcome).

## Verified starting point

- Command fields: `context.short_summary`, `options[{id,label,…}]`,
  `recommendation{option_id,reason}`, `urgency`, `blocking`
  (`src/lib/aiur/decision.ex:21-27` docs; type at `:120-126`).
- Answer semantics: first answer wins; same key → `:duplicate`; conflict returns winner
  summary (`contracts/command-request-and-resolution.md` §6 rules 1–2, 5).

## Chosen design

State machine (`CommandCardModel`):

```text
loading ─ok→ ready ─tapOption→ confirming ─confirm→ sending
   │                                   └cancel→ ready
   ├─phone unreachable→ needsPhone (stored summary only, options disabled)
   ├─unreachable/not_found/unknown→ error(kind)
   └─resolved→ resolvedElsewhere(by, at, summary)
sending ─delivered|duplicate→ success (haptic .success, text, auto-return to list after 2 s)
        ─conflict(winner)→ resolvedElsewhere(winner)
        ─stale(reason)→ stale(reason) → refetch → ready (new version)
        ─failed(phone_unavailable|unreachable)→ notConfirmed ("Not confirmed. Check on iPhone.")
        ─queued→ notConfirmed (never shown as delivered)
        ─unknown→ error(unknown)
```

- One `idempotency_key` per confirm action; a user "Try again" from `notConfirmed`
  reuses it (plan §8), so the server dedupes.
- Options render in server order with the recommended one marked (not reordered unless
  DESIGN-E2 says so). More than 3 options: show 3 and "More on iPhone".
- The short summary is agent-authored text (E2 short label): it renders with the "from agent"
  style that DESIGN-N7 picks, never as aiur's own words (Phase D security m3).
- **Design-pending vs fixed (Phase D T-1).** Fixed now: the state machine, transitions, test
  names and files below. Design-pending only: copy strings and layout (DESIGN-N7 §4 screens
  3–4, §5 states; DESIGN-E2 copy). Strings live in `Localizable.strings` keys named after the
  DESIGN-N7 §5 state, so approval changes values, not code.
- No option is preselected; confirm step guards against wrist mis-taps (DESIGN-N7 may
  remove it; then delete the `confirming` state and its test in the same PR).

## Implementation steps

Files to create (paths PROPOSED, under `packages/aiur-mobile/ios/AiurWatch/`):

1. `Command/CommandCardModel.swift` (pure, testable, injected `PhoneLinkProtocol` and clock).
2. `Command/CommandCardView.swift` with a `.digitalCrownRotation`-free scrolling list.
3. `Command/CommandCardStrings.swift` mapping each state to a `Localizable.strings` key
   `n7.card.<state>` (keys named after DESIGN-N7 §5).
4. Accessibility labels for options including "recommended".
5. `AiurWatchTests/CommandCardModelTests.swift` (table below), driven by fixtures
   `packages/aiur-mobile/fixtures/watch-link/valid/get_command_result-*.json` and
   `answer_result-*.json` (MP-N7-C1-T01).
6. `AiurWatchUITests/CommandCardUITests.swift`: one UI test per DESIGN-N7 §5 state that
   applies to the card, asserting the accessibility identifier `n7.card.<state>` is present.

## Non-happy paths

Covered by the state machine: phone unreachable, daemon unreachable, resolved elsewhere,
conflict, stale, queued, unknown. Privacy: the card holds Command text in memory only;
not persisted (only the snapshot's `short_summary` is stored).

## Compatibility and rollout

Watch-only. Mic button behind `WatchFeatures.voice` flag until C4-T01.

## Verification

```text
xcodebuild test -workspace packages/aiur-mobile/ios/aiur.xcworkspace -scheme AiurWatch -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)' -only-testing:AiurWatchTests/CommandCardModelTests
```

| Test | Expected | Must fail without |
|---|---|---|
| `testQueuedIsNeverDelivered` | `.queued` → `notConfirmed` | the queued branch (map to success → fails) |
| `testConflictShowsWinner` | conflict → `resolvedElsewhere` with winner text | conflict branch |
| `testStaleRefetches` | stale → fetch called → ready with new version | refetch |
| `testRetryReusesKey` | two sends after `notConfirmed` carry the same key | key reuse |
| `testUnknownOutcomeIsError` | unknown → `error(unknown)` | default branch |
| `testResolvedHidesOptions` | resolved card → no option buttons | resolved rule |
| `testMaxThreeOptions` | 5 options → 3 + "More on iPhone" | cap |
| `testState_Loading_NoFakeOptions` (DESIGN-N7 §5 Loading) | `loading` → no option buttons rendered | loading branch (render placeholders → fails) |
| `testState_NeedsPhone_ShowsAgeAndDisablesOptions` (§5 Needs phone) | phone unreachable → stored summary + age; options disabled | needsPhone branch (leave options enabled → fails) |
| `testState_MachineUnreachable_IsNotZero` (§5 Machine unreachable) | `get_command_result{outcome: unreachable}` → `error(unreachable)`, not an empty card | the unreachable mapping (map to `ready` with no options → fails) |
| `testState_Stale_ShowsAge` (§5 Stale) | stored card older than the snapshot age budget → age label present | the age render (AGENTS.md "if a surface computes an age, it renders the age") |
| `testState_Success_ReturnsToList` (§5 Success) | delivered → success, then list after 2 s on the injected clock | the auto-return timer |
| `testSummaryUsesFromAgentStyle` | summary text view carries the `fromAgent` style id | the style (render plain → fails) |

UI tests (simulator):

```text
xcodebuild test -workspace packages/aiur-mobile/ios/aiur.xcworkspace -scheme AiurWatch -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)' -only-testing:AiurWatchUITests/CommandCardUITests
```

Device rows: DV-W4 (exactly one answer, `client.surface: "watch"`), DV-W2.

## Completion and handoff

- [ ] Card matches DESIGN-N7 screens 3–4; tests pass; each fails with its hunk reverted
  (revert in a worktree, `git status --porcelain` shows only that hunk; command in the PR).
- Docs: `website/docs-app/guide/mobile.md` watch section, "Answering on the watch": the
  confirm step, "More on iPhone", and that "Not confirmed" never means delivered.
- Dependents: MP-N7-C2-T04, MP-N7-C2-T05, MP-N7-C4-T01.
