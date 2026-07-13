# Land bounded Executor planning skills

## Outcome

A human reviews and merges the isolated skill-only draft PR #1065 into `main`
so `/aiur-build`, the consolidated bounded `/aiur-run` Executor role,
`/aiur-monitor` wording, `/aiur-loop` retirement and publication validation
are not lost with the research branch. The user confirmed on 2026-07-13 that
the prior sequencing constraint (an active dashboard run consuming the old
skill contracts) no longer applies and that merging PR #1065 is the accepted
delivery path: the skills land on `main` before Build Order work is
dispatched, and agents are then pointed at documents on `main`.

Commit `27ba3c44094d7c7f463f03b811dba52039a23282` is the minimum ancestry marker
for the `ticket_prefix` array support required by the consolidated
single-manifest pack. It is not an independently approved executor baseline:
PR #1065 is in active review rework. Before dispatch, record the exact final
reviewed successor/merge SHA, prove it descends from `27ba3c44`, and confirm it
preserves multi-prefix validation, the finite feature boundary,
rework-before-ticket-multiplication rule, backlog-growth circuit breaker,
privacy policy, and publication validator behavior. The older `f92aa045`
revision is also not compatible with this pack.

The Build Order planning authority for this issue body is
[`<APPROVED_SHA>`](https://github.com/its-everdred/aiur/commit/<APPROVED_SHA>).

## Why human-blocked

Only the final review-and-merge remains human-owned: confirming the successor
head preserves the bounded contracts, then merging under current merge
authority. The original sequencing constraint (an active run consuming the old
contracts) was lifted by the user on 2026-07-13.

## Scope

- Reconciliation with the then-current `main` is represented by merge commit
  `ec188e7b`; PR #1065 remains in active review rework and must be refreshed as
  needed before its final reviewed successor/merge SHA is recorded.
- Resolve the active review findings and review the final successor head
  against the bounded contracts above.
- Run the skill validator, focused skill discovery/installation tests and the
  repository CI gate required at pickup.
- Land only the isolated skill PR under current merge authority; do not merge
  the mixed research PR #1064 to recover these files.
- Confirm `/aiur-build`, `/aiur-run` and `/aiur-monitor` are discoverable for
  both supported worker backends and the removed loop no longer appears.

## Non-goals

- Implement or dispatch Build Order.
- Change the currently active Executor's instructions before its run ends.
- Recreate the changes manually from the research branch.

## Build Order gate

This issue is published as an external native blocker of BO-004 and BO-008—the
two independent initial branches. BO-001 depends on BO-004 and therefore
inherits the gate. The skill issue remains outside Build Order membership,
points, ETA, and completion. Closing it means the exact final reviewed
successor/merge SHA is recorded, proven to descend from `27ba3c44`, landed or
installed, and all three skills are discoverable for both supported worker
backends; merely closing PR #1065 without those checks does not resolve the
gate.

## Labels

Apply `human:todo`. Do not apply `agent:todo` or Build Order membership.

<!-- aiur-planning-issue
{"schema":2,"logical_id":"SKILL-DELIVERY-001","plan_version":1,"approved_planning_commit":"<APPROVED_SHA>"}
-->
