---
ticket_id: MP-R7-C4-T02
feature_id: MP-R7
chunk_id: MP-R7-C4
bucket: 1-refactor
repo: aiur-team/aiur
wave: 1
title: Promotion-test record for harness-adapters (go/no-go for a physical package)
status: blocked
blocked_by: [DESIGN-R7, MP-R7-C3-T05, MP-R7-C4-T01, MP-R1-C4 (harness config section ticket), RQ-R7-5]
prior_units: [U7, U9]
prior_boundaries: [CA (20), CDX (21), CLD (22), OAI (23)]
prior_features: []
prior_findings: []
size_owner: n/a (evidence record; no production code)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R7-C4-T02 — Promotion-test record for `harness-adapters`

## Identity and outcome

- Bucket 1, MP-R7, chunk C4. **User value:** prevents a package move that the
  project's own rules say is premature (prior KTD3; MP-R1-KD1).
- **Deliverable:** one evidence section appended to
  `docs/research/aiur-mobile-and-platform/bucket-1-refactor/MP-R7/plan.md`
  (or the then-current component record that MP-R1-C11 maintains) that scores
  the five MP-R1 promotion criteria (migration-plan §5) for `harness-adapters`
  with measured values, and states **go** or **no-go** for MP-R7-C4-T03..T05.
- **Non-goals:** no code. Does not decide anything for other components.

## Dependencies and blockers

- **RQ-R7-3 is resolved** (see below), which replaces it with **RQ-R7-5**:
  "do the five promotion criteria hold for harness-adapters?" — answerable only
  after releases have shipped with the C3 boundary rule in force.
- Needs MP-R7-C3-T05 (rule live) and two consecutive merged releases after it
  (criterion 1), MP-R7-C4-T01 (criterion 2), MP-R1-C4's harness section ticket
  (criterion 4).
- Runs alone; nothing else in C4 may start before it says go.

## Verified starting point (base `45a290e3`)

**RQ-R7-3 resolution (layout).** MP-R1 chose option A — "logical components +
manifest + ratcheting checker, physical packages by promotion test"
(MP-R1 plan §3, KD1 "physical packaging is separate", KD7 ratchet), and
rejected "umbrella app now" (option B). Physical moves happen only when the
five criteria of MP-R1 migration-plan §5 hold. The prior plan agrees
(KTD3, KTD11: first seam in-process; U7: "Consider a physical package only if
a later measured problem requires it"). So the original C4 premise ("adapters
live in the package selected by MP-R1") is **not** a decision R1 made; C4 is
re-scoped to T01 (component shape, ready) + this gate + conditional T03..T05.

Starting values for the record (base SHA):

| Criterion (migration-plan §5) | Base value | Source |
| --- | --- | --- |
| 1. Zero allowlisted violations for 2 releases | 33 references in 29 files before C3; after C3, allowlist classes 5–11 remain (MP-R7-C3-T05) | `git grep` in C3-T05 |
| 2. Child specs declared by the component | 1 harness child in `aiur.ex:432`; fixed by C4-T01 | `src/lib/aiur.ex` |
| 3. Tests run without booting the whole app | 97 test files under `src/test/aiur/{codex,claude,muse,open_ai_compat,coding_agent,app_server,agent_tools}` + `coding_agent_test.exs`; 17 declare `async: false`, 77 `async: true`; `test_helper.exs` runs `Aiur.TestBootGuard.check!()` against the shared app | `git ls-tree`/`grep` at base |
| 4. Config section registered by the component | not yet (`config.ex:1305,1340` call adapter validators directly) | C3-T05 row 7 |
| 5. Second consumer or stated independent release need | **none known**: Khala shares the listener spec (MP-E7), not the adapters; MP-R1 lists "Codex and Claude adapters" only as late repo candidates | MP-R1 migration-plan §5 |

Expected outcome on current evidence: **no-go** on criterion 5 unless the owner
states an independent-release need (DESIGN-R7 does not ask for one).

## Chosen design

The record is a table of the five criteria with measured value, date, release
tags covered, and the command that produced each number. Go requires all five.
No-go keeps C4-T03..T05 `blocked` and records the next re-check trigger
(a second consumer appears, or MP-R1-C11's plan refresh asks).

## Implementation steps

1. Criterion 1: run `python3 scripts/check-components.py --component harness-adapters --report`
   (flag name per MP-R1-C1; if absent, filter the full report) on the two
   latest release tags.
2. Criterion 3: `env -C src mise exec -- mix test --no-start test/aiur/codex test/aiur/claude test/aiur/muse test/aiur/open_ai_compat test/aiur/coding_agent test/aiur/app_server test/aiur/agent_tools test/aiur/coding_agent_test.exs`
   and count failures caused by missing application processes (a `--no-start`
   run is the operational meaning of "without booting the whole application").
   Note: narrow `--no-start` runs hide supervision bugs, so this is evidence for
   the criterion only, never a substitute for CI.
3. Criteria 2, 4: cite merged PRs. Criterion 5: cite DESIGN-R7 and the MP-R1
   component record.
4. Write the go/no-go line and update MP-R7 `chunks.md` C4 status.

## Non-happy paths

- Checker report unavailable (R1-C1 not shipped a component filter): record
  the full count and the harness subset by hand-filter, and file a contract
  request to MP-R1.
- A release regresses to a new violation: criterion 1's two-release window restarts.

## Compatibility and rollout

n/a — evidence only.

## Verification

n/a for automated tests — the record itself is the artifact; a reviewer
re-runs the listed commands and must get the same numbers (±the release in
between). No mutation check applies (no production change).

## Completion and handoff

- [ ] Five criteria scored with commands and dates.
- [ ] Go/no-go recorded; C4-T03..T05 status updated accordingly.
- Docs: none.
- Dependents: MP-R7-C4-T03, -T04, -T05.
