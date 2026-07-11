---
title: "fix: Fail closed at the PR file API cap"
type: fix
status: completed
date: 2026-07-11
origin: docs/brainstorms/2026-07-06-production-readiness-refactor-planning-requirements.md
deepened: 2026-07-11
---

# fix: Fail closed at the PR file API cap

## Summary

Harden the existing regression-suite workflow in place: compare a countable
changed-file listing with trusted pull-request metadata and GitHub's documented
ceiling, then route any incompleteness through the existing operator-approval gate.

---

## Problem Frame

The read-only characterization tripwire required by origin R6 currently treats a
protected path as absent when GitHub's List pull request files endpoint truncates
at 3,000 files. A sufficiently large PR can therefore bypass the approval path
entirely even though the workflow itself otherwise fails closed.

---

## Assumptions

*This plan was authored without synchronous user confirmation. The items below
are agent inferences that fill gaps in the input and should be reviewed during
implementation and PR review.*

- A listing at GitHub's documented 3,000-file ceiling is ambiguous and should
  require the same operator approval as a confirmed protected-path edit; the
  guard should also fail closed if the listed and reported totals disagree or
  either count is unavailable or malformed.
- The secondary sticky-approval reliability concern should not be mixed into
  this security fix without durable approval-to-head-SHA state. Reconstructing
  approval from label history alone could admit a new head when a synchronize
  run is cancelled by a later label event.

---

## Requirements

- R6 (origin). The Phase-1 characterization suite remains read-only unless an
  operator explicitly approves a regression-suite change.
- R14. A PR whose changed-file listing reaches the documented API ceiling must
  not take the unprotected fast path, even when no protected filename appears in
  the returned prefix.
- R15. Missing, non-numeric, or inconsistent listed/total changed-file counts
  must fail closed into operator approval rather than silently passing.
- R16. Existing behavior remains intact below the cap: ordinary paths pass,
  protected current or previous filenames require approval, stale approvals fail,
  and a current operator approval succeeds.
- R17. Executable workflow fixtures cover both sides of the cap boundary and the
  malformed-metadata failure path.
- R18. The file listing and total-count decision must be bound to the event's
  exact head SHA before any fast-path success; a head mismatch fails closed.
- R19. Attacker-controlled filenames containing tabs, newlines, backslashes, or
  marker-like text must remain one countable API record and must not hide a
  protected current or previous path.
- R20. A capped-list diagnostic must tell the operator that approval covers an
  incomplete API view and requires reviewing the full diff through an uncapped
  path before applying the override.

**Origin actors:** A2 (human operator), A3 (executor agents), A4 (aiur-loop pipeline)

**Origin flows:** F2 (ticket execution)

---

## Scope Boundaries

- Do not check out or execute pull-request-controlled code from this
  `pull_request_target` workflow.
- Do not replace the current filename API path with a larger diff-fetching
  mechanism; conservative cap detection closes the reported bypass with less
  parsing and trust-surface risk.
- Do not weaken or redesign the post-push dismissal and current-head approval
  checks introduced by PR #953.

### Deferred to Follow-Up Work

- Issue #963: make approval sticky across unrelated label and reopen events using
  durable, operator-authenticated head-SHA state; label-history inference alone
  is not a sufficient security boundary.

---

## Context & Research

### Relevant Code and Patterns

- `.github/workflows/regression-guard.yml` already centralizes protected-path
  classification, post-push dismissal, current-head checks, and embedded shell
  regression fixtures. Extend those seams instead of adding a second guard.
- PR #953 established the trusted event/head freshness model; the cap fix must
  feed into it rather than bypassing it.
- The pull-request metadata response exposes a total `changed_files` count while
  the List pull request files response has a documented 3,000-file maximum. One
  serialized record per returned file makes those two counts directly comparable
  without confusing rename source paths for extra files.

### Institutional Learnings

- `docs/refactor/regression-safety.md` defines this workflow as an enforced,
  read-only tripwire rather than an advisory check. Uncertainty therefore belongs
  on the approval-required side of the boundary.
- No `docs/solutions/` directory or workflow-specific learning document exists in
  this checkout.

### External References

- GitHub's REST documentation states that List pull request files returns at most
  3,000 files and supports pages of at most 100 items.

---

## Key Technical Decisions

- Serialize one record per API file, compare its count with the pull request's
  total changed-file metadata, and also compare it with the documented API
  ceiling before allowing the unprotected fast path. This catches both the known
  cap and unexpected early truncation while keeping rename source paths inside
  their owning file record.
- Escape or encode attacker-controlled path fields before record counting so
  embedded delimiters cannot create, merge, or conceal physical records; decode
  or parse both current and previous path fields for protected-prefix matching.
- Read the current head SHA with the total count and require it to equal the event
  head before the ordinary fast path. Count agreement alone is not a snapshot
  guarantee when a push races the API calls.
- Treat cap ambiguity as “approval required,” not as an unconditional rejection.
  Operators retain the existing override for legitimate very large PRs, while an
  attacker cannot bury a protected edit beyond the returned prefix.
- Keep the cap predicate and the combined “changes require approval” decision as
  small shell functions exercised by the workflow's existing self-test block.

---

## Open Questions

### Resolved During Planning

- Detect truncation or fetch an uncapped diff: detect the documented boundary.
  It is sufficient to close the fail-open, preserves the trusted-base workflow,
  and avoids parsing attacker-controlled patch text.
- Include sticky approval in this PR: defer it. A safe design must persist or
  otherwise prove the exact approved head; active-label history does not do that
  across cancellation races.

### Deferred to Implementation

- Exact helper names and diagnostic wording may follow the existing inline shell
  style as long as capped and malformed metadata are visibly distinguished from a
  confirmed protected path.

---

## Implementation Units

### U1. Route incomplete file listings through approval

**Goal:** Prevent a capped or unverifiable changed-file listing from taking the
guard's no-protected-files success path.

**Requirements:** R6, R14, R15, R16, R17, R18, R19, R20

**Dependencies:** None

**Files:**

- Modify: `.github/workflows/regression-guard.yml`
- Test: `.github/workflows/regression-guard.yml` (embedded executable shell fixtures)

**Approach:**

- Emit one delimiter-safe physical record per returned API file so current and
  previous rename paths remain inspectable without inflating the file count, even
  when a filename itself contains shell-significant delimiters.
- Read the total changed-file count from the same trusted pull-request metadata
  endpoint already used for current-head verification, and bind the decision to
  the event head before allowing any no-approval success.
- Classify a listing at the API ceiling, any listed/total mismatch, or missing or
  malformed count data as requiring approval; combine that with existing
  protected-current/previous-path detection.
- Only emit the ordinary fast-path success when the listing is below the ceiling
  and contains no protected path.
- Reuse the existing freshness, active-label, operator, and exact-head checks for
  both confirmed protected changes and cap ambiguity.

**Execution note:** Add the cap-boundary fixtures before changing the production
branch so the old fail-open is observable in the extracted shell harness.

**Patterns to follow:**

- `protected_changed_files/1`, `require_fresh_approval/4`, and
  `run_guard_regression_tests/0` in `.github/workflows/regression-guard.yml`.
- The fail-closed diagnostic and self-test conventions established by PR #953.

**Test scenarios:**

- Happy path: 2,999 ordinary changed files and no protected path produce the
  no-approval fast path.
- Boundary: a total of exactly 3,000 with only ordinary paths requires approval.
- Boundary: a total above 3,000 with the protected edit absent from the returned
  prefix still requires approval.
- Error path: empty or non-numeric count metadata requires approval.
- Error path: a sub-cap API listing whose record count differs from the reported
  total requires approval.
- Error path: the metadata head differs from the event head while counts happen to
  match; the stale run cannot take the ordinary success path.
- Adversarial path: filenames containing tabs, newlines, backslashes, and text
  resembling the record delimiter neither reduce the record count nor hide a
  protected current or previous path.
- Regression: a protected current filename below the cap requires approval.
- Regression: a protected previous filename below the cap requires approval.
- Integration: capped metadata without an active override fails through the
  existing active-label gate; a current operator override reaches the existing
  success path.
- Operational: the cap-specific failure output tells an operator to inspect the
  full diff outside the capped API response before approving.

**Verification:**

- The workflow's embedded fixtures fail against the old decision boundary and
  pass with the cap-aware decision.
- An extracted, mocked execution of the workflow step exercises ordinary,
  protected, capped, malformed, approved, and unapproved API responses.
- The workflow passes Actionlint; the repository's scoped compile and format gate
  remains green.

---

## System-Wide Impact

- **Interaction graph:** GitHub pull-request metadata and file-list responses feed
  one event-head-bound approval decision, which then uses the existing
  label-dismissal and operator-authorization path.
- **Error propagation:** API failures already terminate under `set -e`; malformed
  count data now becomes approval-required instead of success.
- **State lifecycle risks:** No new persisted state is introduced; post-push label
  dismissal and delayed reapproval semantics remain unchanged.
- **API surface parity:** Only the required `regression-guard / guard` check changes.
- **Integration coverage:** Mocked `gh api` responses must prove the API boundary
  reaches the same label/head authorization gates as a protected filename.
- **Unchanged invariants:** Ordinary sub-cap PRs remain fast, protected path renames
  remain guarded, and only configured operators may authorize the current head.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| GitHub changes the file-list ceiling | Compare listed and total counts as a second fail-closed signal, keep the ceiling named beside the API call, and cover the boundary with fixtures. |
| Exactly 3,000-file PRs receive a conservative false positive | Require operator approval rather than rejecting; security takes precedence over this rare availability cost. |
| Cap handling accidentally bypasses freshness checks | Feed both protected-path and incomplete-list cases into the existing shared approval path. |
| A push races the metadata and file-list requests with equal file counts | Compare the live metadata head with the event head before any fast-path success. |
| A hostile filename corrupts line-oriented counting or path parsing | Use delimiter-safe one-record serialization and adversarial filename fixtures. |
| Sticky-approval cleanup reopens a push race | Keep it out of this diff and track a head-bound design separately. |

---

## Documentation / Operational Notes

- The workflow log should state when approval is required because GitHub's file
  list may be incomplete, so operators can distinguish a very large PR from a
  confirmed characterization-test edit. It should direct the operator to review
  the complete git diff rather than relying on the capped API/UI listing.
- No user-facing runtime or CLI documentation changes are needed.

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-07-06-production-readiness-refactor-planning-requirements.md](../brainstorms/2026-07-06-production-readiness-refactor-planning-requirements.md)
- Related safety contract: [docs/refactor/regression-safety.md](../refactor/regression-safety.md)
- Related workflow: [.github/workflows/regression-guard.yml](../../.github/workflows/regression-guard.yml)
- Related issues and PRs: #963, #955, #771, #953
- External documentation: [GitHub REST API endpoints for pull requests](https://docs.github.com/en/rest/pulls/pulls#list-pull-requests-files)
