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

The reviewed planning authority is commit
`f92aa045f6766358d7561dadc1133c4d9180d1f3`. A later compatible successor is
acceptable only after explicit review confirms it preserves the finite feature
boundary, rework-before-ticket-multiplication rule, backlog-growth circuit
breaker, privacy policy, and publication validator behavior. The branch head
now carries successor candidates awaiting that confirmation: `d4640c03`
(planning-skill amendments: required implementation pointers, sizing
calibration, design-for-parallelism rules), merge commit `ec188e7b`
(reconciles the rewrite with the Executor-rename work on `main@9849f329`;
skill tests 17/17, compile/validator clean, PR MERGEABLE), `d9812101` +
`d9426f17` (epic-label/icon freedom and the plan-context block requirement),
and `27ba3c44` (multi-prefix `ticket_prefix` support required by the
consolidated single-manifest pack; 118/118 validator tests). The vendored
validator on the planning branch matches `27ba3c44`.

The Build Order planning authority for this issue body is
[`<APPROVED_SHA>`](https://github.com/its-everdred/aiur/commit/<APPROVED_SHA>).

## Why human-blocked

Only the final review-and-merge remains human-owned: confirming the successor
head preserves the bounded contracts, then merging under current merge
authority. The original sequencing constraint (an active run consuming the old
contracts) was lifted by the user on 2026-07-13.

## Scope

- Reconciliation with `main` is DONE: merge commit `ec188e7b` folded the
  Executor-rename work from `origin/main@9849f329` into the rewrite; the PR is
  MERGEABLE with skill tests, compile, and validator green.
- Review the successor head (amendments `d4640c03` + merge `ec188e7b`) against
  the bounded contracts above.
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
points, ETA, and completion. Closing it means the reviewed revision
(or a proven compatible successor) is landed or installed and all three skills
are discoverable for both supported worker backends; merely closing PR #1065
without those checks does not resolve the gate.

## Labels

Apply `human:todo`. Do not apply `agent:todo` or Build Order membership.

<!-- aiur-planning-issue
{"schema":2,"logical_id":"SKILL-DELIVERY-001","plan_version":1,"approved_planning_commit":"<APPROVED_SHA>"}
-->
