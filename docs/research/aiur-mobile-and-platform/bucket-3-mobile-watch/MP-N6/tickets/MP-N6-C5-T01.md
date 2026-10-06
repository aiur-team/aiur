---
ticket_id: MP-N6-C5-T01
feature_id: MP-N6
chunk_id: MP-N6-C5
bucket: 3-mobile-watch
title: Watch Command card rules and fixtures — label, requester, question, up to three options, outcome line (screens are MP-N7-C2-T03 / C3-T03)
status: blocked
blocked_by: [DESIGN-N6 (§3 watch card, D-4, D-5), DESIGN-N7, MP-N6-C1-T03]
prior_units: []
prior_boundaries: [mobile-app (watch apps inside packages/aiur-mobile, RC-17)]
prior_features: [MP-N7, MP-N4]
prior_findings: [E-B5 (WatchConnectivity is opportunistic), client-capability-model §7 (watch projection)]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C5-T01 — Watch Command card

## Identity and outcome

> **Phase D (N7 item 2):** ownership split. This ticket owns the Command response
> **rules** for the watch card (states, option ordering, copy keys) as shared fixtures under
> `fixtures/watch-link/` that both watch apps test against. MP-N7-C2-T03 (watchOS) and
> MP-N7-C3-T03 (Wear OS) implement the screens; MP-N6-C5-T03 keeps the "Open on phone"
> hand-off. The description below is the behaviour those fixtures pin down.

Bucket 3, MP-N6, chunk C5. On watchOS and Wear OS: a compact card for a Command (short
label, requester, question in two lines, up to three option buttons with the recommended
first, Mic, "Open on phone") and a compact outcome line (accepted / already answered / no
longer needed / can't reach). Answers use the same C1-T03 API and outcomes, sent by the
path MP-N7 chooses (phone broker vs direct).

## Dependencies and blockers

**Blocked** on DESIGN-N6 §3 watch card and D-4 (multi-question → "Answer on phone"
proposed) and D-5 (option details on watch — proposed no); DESIGN-N7; the MP-N7 apps and
watch-link protocol (N7-C1..C3); MP-N4-C6-T01 (how notifications reach the watch).

## Verified starting point

E-B5 (WatchConnectivity "you can't rely on … as your only means"); client capability model
§7 (watch projection sent by the phone).

## Chosen design (fixed parts)

- Watch answers carry `surface: "watch"`; an idempotency key is minted on the watch per
  action and reused on retry through the phone.
- Answer wire keys: `option_id` (X-13). The watch never sends free text from the card;
  Dictate is C5-T02 / MP-N7-C4-T02.
- **Fixtures this ticket owns** (both watch apps test against them; MP-N7-C2-T03 and
  MP-N7-C3-T03 read them):
  - `packages/aiur-mobile/fixtures/watch-link/command-card-transitions.json`: rows
    `{from, event, to}` for the card state machine of MP-N7-C2-T03 (`loading`, `ready`,
    `confirming`, `sending`, `success`, `resolvedElsewhere`, `stale`, `notConfirmed`,
    `needsPhone`, `error(kind)`), with each event taken from the C1-T03 outcome table
    (`accepted`, `duplicate`, 409 reasons, `queued`, `phone_unavailable`, unknown).
  - `packages/aiur-mobile/fixtures/watch-link/command-card-cases/*.json`: input Command
    view + expected card (`short_label`, requester, question clipped to 2 lines, ≤ 3
    options with the recommended one marked and first only if DESIGN-E2 orders it, "More
    on iPhone" when > 3, `answer_on_phone: true` for multi-question Commands per D-4
    proposal, no option details per D-5 proposal).
  - Copy **keys** only (`watch.outcome.accepted`, `.already_answered`,
    `.no_longer_needed`, `.cant_reach`, `.not_confirmed`, `.answer_on_phone`); strings
    are DESIGN-N6/N7 (design-pending).
- `queued` (the `transferUserInfo` late path, plan §6 exception) maps to `notConfirmed`,
  never `success`.
- The card holds Command text in memory only (plan §5.6).

## Implementation steps

1. Write both fixture sets above; validate them against the MP-N7-C1-T01 watch-link
   schema (`fixtures/watch-link/schema/`).
2. `packages/aiur-mobile/test/watch/commandCardFixtures.test.ts`: schema validation and
   coverage checks (below).
3. Docs: none, because the fixtures are internal test data; the watch user docs come with
   MP-N7-C2-T01 / C3-T01.

## Non-happy paths

Phone unreachable from watch → `needsPhone` ("can't reach"); a late `transferUserInfo`
answer that meets a changed Command → `stale` (DV-W4b); unknown outcome → `error(unknown)`.

## Compatibility and rollout

watchOS 10 / Wear OS per MP-N7. A new outcome added by the daemon requires a fixture row
first; the coverage test fails until it exists.

## Verification

```text
npm --prefix packages/aiur-mobile test -- test/watch/commandCardFixtures.test.ts
```

| Test | Expected | Must fail without |
| --- | --- | --- |
| `fixturesMatchWatchLinkSchema` | every case file validates | schema conformance |
| `everyC1T03OutcomeHasATransition` | each outcome in the C1-T03 table (copied list) appears as an event from `sending` | a row (delete one → fails) |
| `queuedNeverReachesSuccess` | no `{event: queued, to: success}` row; `queued → notConfirmed` exists | the queued rule |
| `atMostThreeOptions` | every case renders ≤ 3 options, "More on iPhone" when > 3 | the cap |
| `multiQuestionAnswersOnPhone` | multi-question case → `answer_on_phone: true`, no option buttons | the D-4 rule |

Consumers' tests (`CommandCardModelTests`, `CommandCardViewModelTest`, MP-N7) read the
same files. Device: V-W2, DV-W4, DV-W4b.

## Completion and handoff

- [ ] Fixtures merged before MP-N7-C2-T03 / C3-T03; each test fails with its row removed.
- Dependents: C5-T02, C5-T03, MP-N7-C2-T03, MP-N7-C3-T03.
