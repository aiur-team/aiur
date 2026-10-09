---
title: MP0 CI failure digest - Plan
type: feat
date: 2026-10-09
topic: merge-policy
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
origin: docs/research/merge-policy/brainstorm.md
base_main_sha: fd158cef8
---

# MP0 CI failure digest - Plan

## Goal Capsule

- **Objective:** the daemon can turn any completed, failed commit's check runs
  into a digest: failing checks, failing tests, and for each test whether it is
  a known flake. Main-watch (MP4) and stuck ci-wait handling (#3864) both use
  it.
- **Product authority:** [brainstorm.md](brainstorm.md) (R11, R12; Key
  Decisions "Failing tests reach the daemon through check-run annotations",
  "The failure digest is shared with #3864", "Known flakes").
- **Open blockers:** none.
- **Product Contract preservation:** unchanged.

---

## Problem Frame

CI already classifies failing ExUnit tests against
`.github/known-flaky-tests.txt` (`scripts/report-known-flaky-tests.sh`), but it
writes the result only to the job step summary. The daemon cannot read step
summaries or logs: the GitHub App has Actions = Never
(`website/docs-app/apis/github.md`). It can read check runs and annotations.
Today the daemon's only flake rule is a one-cycle deferral when the check
named `test` fails alone (`src/lib/aiur/orchestrator/ci_lifecycle.ex`).

## Requirements

- MP0-R1. CI writes one annotation per failing ExUnit test on the failing
  coverage job, with the test identity and `known-flake` or `new-failure`.
- MP0-R2. `Aiur.CI.FailureDigest.build(sha)` returns failing check names, run
  URLs, failing tests with classification, and a stable signature.
- MP0-R3. A test is a known flake when it is in the known-flaky file at that
  SHA, or named in an open issue labelled `flake`.
- MP0-R4. A failing check with no test annotations (lint, dialyzer, build) is
  a check-level failure and is never a known flake.
- MP0-R5. The `flake` label exists (created by `aiur init` label set) and the
  open flake tickets carry it.

## Key Technical Decisions

- **Annotations, not logs.** GitHub turns `::error title=...::message` lines
  into check-run annotations, readable with Checks: read. GitHub keeps at most
  10 error annotations per step and 50 per job; the reporter writes the first
  9 tests and a tenth "and N more" line. The digest marks itself truncated.
- **Annotation format is a contract.** Title `aiur-test-failure`, message
  `<classification> :: <Module> :: <test name>`. Fixture-tested on both sides.
- **Read the known-flaky file through the contents API at the commit SHA**, not
  the daemon's checkout, so the classification matches what CI used.
- **Flake issues are matched by exact `<Module> :: <test name>` text in the
  issue body or title.** Fuzzy matching would hide real regressions.
- **Signature = sorted failing check names plus sorted new-failure test
  identities, hashed.** Known flakes are excluded so a flake firing alongside a
  real failure does not create a new signature.
- **Cache per SHA in `Aiur.GitHub.ResourceStore`.** A completed SHA's digest
  never changes except through a rerun, which produces new check-run ids;
  the cache key includes the check-run ids.

## Implementation Units

### U1. CI annotations

**Goal:** failing tests reach check-run annotations.
**Requirements:** MP0-R1.
**Dependencies:** none.
**Files:** `scripts/report-known-flaky-tests.sh`,
`scripts/test-report-known-flaky-tests.sh`.
**Approach:** after classification, print one `::error` workflow command per
failing test in the format above, capped as decided. Keep the step summary.
**Test scenarios:**
- Log with 2 failures, one listed: two annotation lines with the right
  classifications.
- Log with 15 failures: 9 test lines plus "and 6 more".
- Log with no ExUnit failures: no annotation lines, exit 0.
- Test name containing `::` or `%`: escaped per workflow-command rules.
**Verification:** a deliberately failing test in a draft PR shows the
annotation on the job.

### U2. Digest builder

**Goal:** one module builds the digest for a SHA.
**Requirements:** MP0-R2, MP0-R3, MP0-R4.
**Dependencies:** U1 (format contract), U3 (label).
**Files:** `src/lib/aiur/ci/failure_digest.ex` (new),
`src/lib/aiur/github/pull_requests.ex` (annotations read beside
`fetch_commit_ci_status`), `src/test/aiur/ci/failure_digest_test.exs` (new).
**Approach:** read the latest check runs for the SHA (existing path), then
annotations for each failed run, then the known-flaky file at the SHA and the
open `flake` issues (one cached listing). Return a plain struct. No events, no
side effects.
**Patterns to follow:** `fetch_commit_ci_status` for check-run reads;
`ResourceStore` usage in `src/lib/aiur/github/`.
**Test scenarios:**
- Lint failed, no annotations: one check-level failure, not a flake.
- Coverage failed with one listed test: test classified `known-flake`;
  signature equals the signature of a run with no failures in that check.
- Test named in an open `flake` issue but not in the file: `known-flake`.
- Same failures, different check-run ids: same signature, new cache entry.
- Annotations API returns 403 or 5xx: digest has checks, `tests: :unknown`,
  and never classifies the run as flake-only.
**Verification:** unit tests pass with recorded fixtures of real annotation
payloads.

### U3. `flake` label

**Goal:** flake tickets are machine-findable.
**Requirements:** MP0-R5.
**Dependencies:** none.
**Files:** `src/lib/aiur/init/labels.ex`, its test, and a one-time
operator step in the PR description to label the open flake tickets (#3861,
#3852, #3854, #3851, #3775, #3776, #3773, #3611, #3569, #3558, #2402, #2655).
**Test scenarios:** `aiur init` label set includes `flake` with a description.
**Verification:** `gh issue list --label flake` lists the open flake tickets.

## Scope Boundaries

- No reruns here; #3864 and MP4 own reruns.
- Only ExUnit tests get test-level detail. Other runners stay check-level.

## Risks

- Annotation caps hide tests past the ninth. Mitigation: truncated digests
  are never flake-only.

## Verification Contract

- Script fixture tests and digest unit tests pass locally and in CI.

## Definition of Done

- U1-U3 merged; a real failed coverage job shows test annotations; the digest
  of that SHA lists them; #3864 and MP4 can call `FailureDigest.build/1`.
