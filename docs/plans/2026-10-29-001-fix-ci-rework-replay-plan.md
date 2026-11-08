---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
title: "fix: Suppress handled CI rework replays"
type: fix
date: 2026-10-29
execution: code
---

# fix: Suppress handled CI rework replays

## Goal Capsule

**Objective.** Keep an exact CI failure observation from redispatching the same rework after an agent has already handled it and returned the ticket to CI wait.

**Authority.** GitHub issue #7091 and the existing durable CI recovery contract in `src/lib/aiur/events/github_ci_poller/recovery.ex` and `src/lib/aiur/github/ci_recovery_store.ex`.

**Stop conditions.** Do not suppress a failure when the PR head, workflow attempt, failed job/check identity, or conclusion changed. Do not change trusted review/comment routing.

**Execution profile.** Add the durable observation identity, integrate it at the recovery boundary, then prove replay suppression and new-evidence routing with focused tests. CI and review remain the delivery tail.

---

## Product Contract

### Summary

Aiur currently records a failed CI/rework cycle with `head_sha + issue.updated_at`. An explicit `rework -> ci-wait` handoff updates the issue timestamp, so the next poll treats the unchanged failed jobs as a new cycle and routes the ticket back to rework. The in-memory same-head bound also disappears on daemon restart.

The fix makes the daemon-private recovery journal remember the failure observation it successfully routed. A later poll holds an exact replay in CI wait, while genuinely new CI evidence keeps the existing recovery and rework path.

### Requirements

- R1. After a successful CI-to-rework transition, persist the handled failure identity in the existing daemon-private recovery journal.
- R2. An identical observation remains suppressed across an explicit CI-wait handoff and daemon restart.
- R3. A new PR head, workflow attempt, failed job/check identity, or conclusion is not suppressed.
- R4. Changes to issue metadata, including the label-driven `updated_at`, do not manufacture a new failure identity.
- R5. Trusted change requests retain their existing independent route to rework.

### Scope Boundaries

In scope: CI recovery journal identity, failed-handoff cycle counting, CI recovery routing, and focused regression tests.

Out of scope: changing rerun eligibility, MainWatch attribution, review/comment trust, state labels, CI polling cadence, or the three-cycle alert threshold.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Use the existing recovery journal.** It already survives daemon restarts and is updated only after a successful tracker transition, so it is the correct authority for “handled.” A second store would create ordering and reconciliation risk.
- KTD2. **Identity comes from CI evidence, not issue metadata.** Hash the head plus a sorted projection of each failed check's id, name, kind, conclusion/result, timestamps, and URL. This is order-independent. GitHub exposes a rerun attempt through new check/job identity or timestamps, so a new attempt changes the projection even when the head is unchanged.
- KTD3. **Hold at the journal-read boundary.** Return the existing pending recovery shape for an exact handled observation immediately after reading the durable entry, before existing hold, approved-landing, digest, or rerun branches can redispatch it. Review and comment wakes use separate paths and remain unaffected.
- KTD4. **Keep old journal rows conservative.** Legacy `last_cycle` values cannot prove the failed jobs are identical, so they may route once after upgrade; the next successful handoff records the new versioned signature.

### Assumptions

- GitHub Actions reruns produce new check/job ids or timestamps in the CI batch. The failure projection also includes the conclusion/result, so a changed terminal result is distinct.
- `record_failure/3` continues to run only after the rework state write succeeds; an attempted or failed transition must not mark evidence handled.

---

## Implementation Units

### U1. Define and persist handled failure identity

**Goal.** Replace issue-timestamp deduplication with a stable, versioned CI observation signature.

**Requirements.** R1, R3, R4.

**Dependencies.** None.

**Files.**

- `src/lib/aiur/events/github_ci_poller/failure_observation.ex` (new identity and journal helpers)
- `src/lib/aiur/events/github_ci_poller/recovery.ex` (record through the helper without growing the 500-line file)
- `src/test/aiur/events/github_ci_poller/failure_observation_test.exs` (new)

**Approach.** Build a versioned hash from the head and a sorted tuple projection of failed checks. Journal recording updates `last_cycle` and increments `cycles` only when that observation changes. Keep the logic in a small module because `recovery.ex` is already at the repository's 500-line limit.

**Patterns to follow.** `Aiur.CI.FailureDigest` uses stable hashes over sorted evidence; `Aiur.GitHub.CIRecoveryStore` owns the durable JSON update transaction.

**Test scenarios.**

- Recording the same failure before and after an issue `updated_at` change leaves the cycle count at one.
- Reordered failed checks produce the same signature.
- A different head, workflow attempt (represented by new check evidence), check id, or conclusion produces a different signature and increments the cycle count.

**Verification.** The persisted journal contains a versioned signature and the expected cycle count without storing mutable issue metadata.

### U2. Hold exact handled replays and preserve new evidence

**Goal.** Stop duplicate rework dispatch while retaining all authorized wake cases.

**Requirements.** R2, R3, R5.

**Dependencies.** U1.

**Files.**

- `src/lib/aiur/events/github_ci_poller/recovery.ex`
- `src/test/aiur/events/github_ci_poller/handled_failure_replay_test.exs` (new)

**Approach.** Immediately after the recovery journal read, compare the current failure observation with the journal's handled signature. An exact match returns pending CI recovery with a neutral `handled_failure` reason before any older hold or recovery branch can shadow the no-op. Any mismatch continues through the existing recovery path. This code does not touch comment/review transitions.

**Test scenarios.**

- After `record_failure/3`, a fresh recovery call using only the persisted journal holds the identical observation and performs no digest or GitHub read, modeling a daemon restart.
- The same handled observation is held even if the journal also carries an older recovery hold.
- Changing only issue `updated_at` still holds the observation, modeling an explicit `ci-wait` handoff.
- A new head routes.
- A new workflow attempt/check id on the same head routes.
- A changed conclusion on the same head and check id routes.

**Verification.** The focused test observes `decision: :pending` for the replay and `decision: :failed` for each new-evidence case.

---

## Verification Contract

| Gate | Coverage | Done signal |
|---|---|---|
| Focused ExUnit | U1, U2 | New observation and replay tests pass with `--max-cases 4`. |
| Mutation proof | U1, U2 | In an isolated worktree, reverting the production integration makes the replay regression fail; restoring it passes. |
| Affected selector | U1, U2 | `mix aiur.affected_tests` selects and passes every direct/mirror test. |
| Compile and format | U1, U2 | Warnings-as-errors compile and format check pass. |
| Repository lint | U1, U2 | `mix lint`, bare-assert-receive, and PR structure gates pass. |

---

## Definition of Done

- An identical handled CI failure cannot move a CI-wait ticket back to rework after a daemon restart or label handoff.
- A new head, failed job/check identity, or conclusion still reaches rework.
- Failed or uncompleted state transitions never create a handled marker.
- The durable journal remains backward-compatible and corrupt rows still fail closed.
- Focused validation, mutation proof, and repository handoff gates are recorded in the PR body.
