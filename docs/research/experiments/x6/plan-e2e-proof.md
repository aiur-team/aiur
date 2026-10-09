---
title: EXP-X6-6 - Prove the analyst loop end to end on a fixture experiment - Plan
date: 2026-10-09
area: EXP-X6
ticket: EXP-X6-6
complexity: 2
brainstorm: docs/research/experiments/x6/brainstorm.md
---

# EXP-X6-6 - End-to-end proof (area capstone)

## Outcome

A committed fixture experiment and a scripted check prove that the X6 pieces
fit with X2, X4 and X5: request -> events -> stats -> pre-registration ->
report -> page. Then one real analyst run on the fixture, by a fleet worker,
shows the skill works with a real model.

## Fixture

`src/test/fixtures/experiments/fixture-feature/`:

- spec: `kind: line`, delivery-speed pack, before and after windows of 10 days,
  `min_samples: 12`, feature epic `#9001` (synthetic).
- ticket records: 40 before, 40 after; after-window start-to-merge medians
  about 20% lower; complexity mix balanced.
- seeded confounders inside the after-window: a 6 h base-branch red period, a
  cap drop 8 -> 4 for 1 day, one merged CI-config PR, one PR of the epic itself.

## Implementation units

### U1. Fixture and offline integration test

- **Files:** the fixture tree; `src/test/aiur/experiments/analyst_loop_test.exs`.
- **Scenario:** with stubbed GitHub responses, `events` returns exactly the
  four seeded events (plus the epic PR as `attrs.epic`); `stats` (X4) returns
  rows; the golden pre-registration (registered before the first results read)
  stores with `post_hoc: false`; the golden report that marks the start-to-merge
  metric `confounded` stores as v1; a copy that omits the main-red row is
  rejected; a copy that upgrades a label is rejected; a pre-registration stored
  after `show --results` is `post_hoc: true`.

### U2. Page render check

- **Scenario:** with the fixture store mounted (the OCC fixture-run pattern in
  docs/measurements and the dashboard fixture mode), the X5 page shows the
  report sections in order, label chips with n and CI, and the confounder
  table with four rows. Desktop and mobile screenshots attached to the ticket.

### U3. Live analyst run

- **Scenario:** `aiur experiments analyze fixture-feature --mode report` on a
  dev daemon with the fixture store files an analysis ticket; a fleet worker
  (Codex and Claude once each) submits a report that passes validation on the
  first or second attempt. Record attempts, tokens and wall time in the ticket.
  This is the acceptance evidence for EXP-X6-1.

## Test expectation

U1 fails without EXP-X6-2/3; U2 fails without X5's report renderer; U3 is
manual evidence, recorded in the ticket.
