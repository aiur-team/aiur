---
ticket_id: MP-R1-C1-T5
feature_id: MP-R1
chunk_id: MP-R1-C1
bucket: 1-refactor
title: Ratchet enforcement - stale allowlist entries fail, remove-only update mode, CI summary
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C1-T2, MP-R1-C1-T3]
prior_units: [U0]
prior_boundaries: []
prior_features: []
prior_findings: []
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C1-T5 — Ratchet enforcement and maintainer workflow

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1, MP-R1, C1. Step S0. Acceptance criterion 3 of
  [plan.md §7](../plan.md): "the violation count at merge of each MP-R1 PR is ≤ the
  count before it".
- **User value:** none at runtime. Makes the ratchet one-directional: a PR that removes
  a violation must also delete its allowlist line (so the gain cannot be spent later),
  and no PR can add a line without a reviewer seeing it.
- **Deliverable:**
  1. **Stale-entry failure:** an allowlist line with no matching violation fails lint
     (`stale allowlist entry: <rule> <source> -> <target>; delete it`).
  2. `--prune` mode: rewrites allowlist files removing only stale entries; never adds.
  3. **Growth guard:** in CI on `pull_request`, compare allowlist line counts with the
     merge base (`git diff --numstat origin/<base>... -- scripts/components/allowlist/`);
     an added line fails unless its `reason` names a ticket ID (`MP-…`, `U…`, `#NNNN`).
     CI cannot judge intent; the named ticket gives the reviewer something to check.
  4. Step summary: per-rule totals, SCC size and runtime written to
     `$GITHUB_STEP_SUMMARY` (the pattern `report-ci-run-attempt.sh` uses).
  5. `CONTRIBUTING.md` section "Component boundaries" (how to read a failure, how to
     prune, when an allowlist line is acceptable).
- **Non-goals:** new rules; fixing violations.

## Dependencies and blockers

- DESIGN-R1 §1; C1-T2, C1-T3 (both rule sets and their baselines exist).
- **Concurrent:** C1-T4, C1-T6. **Dependents:** every move ticket that claims an edge
  removal (C4, C5, C7–C9) relies on stale-entry failure to prove it.

## Verified starting point (`45a290e3`)

- `check-config-docs.py` documents its exemption list in-code (`EXEMPT`,
  `scripts/check-config-docs.py:36-38`) with "a one-line reason with each entry; 'it is
  new' is not a reason" — the same review norm this ticket applies to allowlist lines.
- CI step summaries are already used (`ci.yml:115-140` writes `$GITHUB_STEP_SUMMARY`).
- The `lint` job checks out with default depth (`actions/checkout` at `ci.yml:240-242`),
  i.e. depth 1; the growth guard therefore needs `fetch-depth: 0` or an explicit
  `git fetch --depth=1 origin <base_sha>` in that step.

## Chosen design

- Stale detection is exact on the key `(rule, source component, target module)`.
- Growth guard is computed against `github.event.pull_request.base.sha` (fetched with
  depth 1); on `push`/`merge_group` the guard is skipped (the PR already passed it) but
  stale detection still runs.
- Reason grammar: `^(baseline [0-9a-f]{7,40}|(MP-[A-Z0-9-]+|U[0-9]+|#[0-9]+)\b.*)$`.

## Implementation steps

1. Add stale detection to the comparison in `check-components.py`.
2. Add `--prune`.
3. Add `--growth-base <sha>`; wire it in the lint step with
   `${{ github.event.pull_request.base.sha }}` when the event is `pull_request`.
4. Step summary writer.
5. CONTRIBUTING.md section (≤ 40 lines).

## Non-happy paths

- Base SHA not fetchable (force-pushed base) → guard prints a warning and is skipped;
  stale detection still runs. Never a silent pass of new violations: new violations
  still fail because they are not in the allowlist.
- Concurrent PRs each pruning the same line → second merge has a conflict in the
  allowlist file; resolution is trivial.

## Compatibility and rollout

No runtime change. Rollback: revert.

## Verification

| Test | Fixture | Expected |
|---|---|---|
| `stale_entry_fails` | allowlist line, no matching reference | exit 1 `stale allowlist entry` |
| `prune_removes_only_stale` | two lines, one stale | file has one line; exit 0 after |
| `prune_never_adds` | new violation present | prune leaves it out; check exits 1 |
| `growth_without_ticket_reason_fails` | base has N lines, head N+1 with reason `todo` | exit 1 |
| `growth_with_ticket_reason_passes` | reason `MP-R1-C7-T3 temporary` | exit 0 |
| `summary_written` | `GITHUB_STEP_SUMMARY` set to temp file | file contains `R-private:` totals |

Mutation check: disable stale detection → `stale_entry_fails` fails; make prune append
current violations → `prune_never_adds` fails; drop the reason regex →
`growth_without_ticket_reason_fails` fails.

## Completion and handoff

- [ ] Stale entries fail in the required lint job; growth guard active on PRs.
- [ ] Step summary visible on a test PR (link in PR body).
- [ ] CONTRIBUTING.md section merged (contributor docs; no `website/docs-app` change).
- **Dependents:** all MP-R1 move tickets; C10-T4 (docs rules join the same checker).
