# Final post-refactor refresh — MP-R1-C11-T03

This report clears the final-refresh gate for the source-reviewed ready subset
when its PR merges. It does not clear named REFRESH holds, product approvals,
tracker errors, or conditional package-promotion gates.

## Sign-off and boundaries

- Refreshed main: `4fbe109541ba1e279d3eb315d8455c4d139c92ba`; full range starts at `45a290e3053423100a73b534c620fdd12ebe11ad`.
- C9/S16: all 14 tickets closed through merged PRs; every merge SHA is an ancestor
  of this target. See [receipts](merges.md).
- Executor decision on 2026-10-26: deliver through the canonical main PR.
  This supersedes research-only publication; it does not approve downstream UX.
- Wave 2 may start **MP-E2-C1-T01 backend-only**, after this PR merges, using the
  existing DESIGN-E2 header exception. Its source owners, five semantic citation
  checks, revised focused-test placement and [RC-23 budget](admissions-final.md)
  are explicit. Product/visible copy and escalation-default approvals stay gated.
- Other E2 implementation tickets retain product/predecessor gates and any named
  source-review hold. Free spikes retain their separate tracker execution state;
  this report claims no manual/model-run result for them.
- The directory publisher may consume the final [component path inventory](component-paths.md)
  and [migration map](../../bucket-1-refactor/MP-R1/migration-plan.md).
  Planned physical packages must not be presented as shipped.

## Scope and dispositions

389 canonical MP ticket documents were refreshed and are retained. Their
build-order mirrors were removed per review; canonical ticket paths are the
authoritative copy.
This covers E2–E7/N1–N7, later R2 C5–C7, and the open canonical refactor tickets.
E8 is a separately added program, outside the requested E2…N7 range; Executor QA
wrappers with no canonical research ticket are not manufactured here.

The current imported pack statuses are: {'ready': 86, 'blocked': 302, 'superseded': 1}.

57 verified mechanical citation edits are recorded in [the exact inventory](mechanical.md).
Existing partially refreshed citations use the C11-T02 stamp's baseline; other
coordinates use their original ticket baseline. Existing base_sha stays unchanged
unless the whole cited code scope was re-read; C1-T01's code baseline is advanced.
Accepted MP-R2 owner ticket text/statuses are preserved from the merged refresh.

91 tickets have named REFRESH source-audit holds,
covering 126 changed/missing starting-point ranges. Each hold records the
old citation, old SHA, owner and completion rule; it rejects implementing from
unverified historical locations, not the product design. These tickets are
explicitly blocked and no unresolved range is claimed fixed by a tool heuristic.

The E2 ready implementation subset has no unresolved GONE/LINES-CHANGED source
range: the old store monolith and helper placements were replaced with current
Requests/Persistence/Codec/Reducers owners and [five semantic spot checks](spot-checks.md).
All other unresolved E2 starting-point ranges are attached to explicitly blocked
tickets in [the E2 review list](reviews-E2.md).

## Full-range evidence

The pre-edit C11-T01 report found 60 moves and 9086 citations: GONE 260,
LINES-CHANGED 1136, LINES-SHIFTED 489, MOVED 65, OK 3008, UNRESOLVED 4128.
It also emitted 16 migration rows and 665 candidate owner outcomes.

Raw counts include proposed files, globs, directories, other repositories,
non-ticket research and already-refreshed coordinates. They are not semantic
failure counts. The generated raw report shards were removed per review; the
pinned regeneration command below replaces those checked-in copies.

Same-range replay does not understand mixed coordinate baselines. The ready
subset is checked directly at the target and its mechanical/semantic decisions
are recorded separately; no all-OK full-pack replay claim is made.

## Contracts and migration

[All 14 contract metadata records](contracts.md) were compared with the adopted
C11-T02 publication; [68 citing-ticket records](contract-consumers-01.md) identify
owners' consumers. MP-R2's accepted events-and-replay refresh is preserved.
This ticket changes no owner contract or product decision. Foreign corrections
already listed in MP-R2 CONTRACT-REQUESTS stay with their named owners.

Every migration PR-01…PR-16 row now gives actual paths and a merge or explicit
non-move disposition. R7's accepted NO-GO keeps adapters in core; #3478/#3479
remain blocked on promotion. R5 provider packaging #3456 remains unmerged.
R6 anchors and the existing conversation facade are merged. Unrelated R3/R4
work is not a blocker. No missing move SHA is fabricated.

The prior production-readiness plan closes RC-19–RC-22, names C9-T10–T14,
and distinguishes synchronous answer delivery from the decision.answered wake.
Component-map section 3 updates Paths today from the actual manifest; other
columns retain their explicitly labelled research design.

## Validation

- Existing plan-refresh fixture suite: 17 tests pass; no new tests or production code.
- Component source checker: passes with existing allowed baselines; 2919 files owned.
- Component docs-reference checker: passes.
- Five wave-2 ranges were read for the named behavior at the refreshed SHA.
- Ready-subset replay at the target: 18 citations, 13 OK, 5 UNRESOLVED proposed paths;
  zero GONE or LINES-CHANGED. This is a coordinate check, not semantic proof.
- Before mirror removal, all 389 canonical/build-order pairs matched after
  resolving relative links; only canonical ticket documents are retained.
- Self-review corrected C1-T01 to select the request version before an answer exists.
- A full post-edit replay attempt exited 137; mixed baselines remain represented by
  the original full-range report, explicit holds and the scoped target check above.
- All retained edited/new planning documents remain <=500 lines.
- Final lint, structural, ready-subset replay, canonical-link checks and handoff-gate
  evidence are recorded in the PR's Local tests section when run; no unrun pass is claimed here.

## Owned source reviews

- [reviews-E2](reviews-E2.md)
- [reviews-E3](reviews-E3.md)
- [reviews-E4](reviews-E4.md)
- [reviews-E5](reviews-E5.md)
- [reviews-E6](reviews-E6.md)
- [reviews-E7](reviews-E7.md)
- [reviews-N1](reviews-N1.md)
- [reviews-N2](reviews-N2.md)
- [reviews-N3](reviews-N3.md)
- [reviews-N4](reviews-N4.md)
- [reviews-N5](reviews-N5.md)
- [reviews-N7](reviews-N7.md)

## Regenerate the raw C11-T01 report

Run from a repository checkout containing the pinned commits below. The input is
composite: the entire research pack at `de341053cc16d2e6096a3a0d0fbacb43ef9f6eb0`,
overlaid with all 28 pack files present on refreshed main.

This reproduces the
pre-edit input, including its historical mirrors; using only `--pack-ref` or the
current canonical-only pack would scan different documents and yield different
counts.

The script is pinned to refreshed main, and the U8 ledger to its adopted
publication. Output goes to a temporary directory outside the tracked pack.

```bash
set -euo pipefail
refresh_repo="${AIUR_AGENT_WORKSPACE:-$PWD}"
refresh_tmp=$(mktemp -d)
refresh_pack=docs/research/aiur-mobile-and-platform
refresh_research=de341053cc16d2e6096a3a0d0fbacb43ef9f6eb0
refresh_main=4fbe109541ba1e279d3eb315d8455c4d139c92ba
mkdir -p "$refresh_tmp/input"
git -C "$refresh_repo" archive "$refresh_research" "$refresh_pack" |
  tar -x -C "$refresh_tmp/input"
git -C "$refresh_repo" archive "$refresh_main" "$refresh_pack" |
  tar -x -C "$refresh_tmp/input"
git -C "$refresh_repo" show "$refresh_main:scripts/plan_refresh.py" > "$refresh_tmp/plan_refresh.py"
git -C "$refresh_repo" show c96025161f1688888de4159d8c31fb117a989b6a:docs/research/refactor-2026-09-26/synthesis/u8-release-007/assignments.csv > "$refresh_tmp/assignments.csv"
python3 -I "$refresh_tmp/plan_refresh.py" --repo "$refresh_repo" \
  --from 45a290e3053423100a73b534c620fdd12ebe11ad --to "$refresh_main" \
  --pack "$refresh_tmp/input/$refresh_pack" \
  --u8-ledger "$refresh_tmp/assignments.csv" --out "$refresh_tmp/full-range.md"
printf '%s\n' "$refresh_tmp/full-range.md"
```
