# Land bounded Executor planning skills

## Outcome

After the current dashboard Executor finishes, a human reviews and lands the
isolated skill-only draft PR #1065 so `/aiur-build`, the consolidated bounded
`/aiur-run` Executor role, `/aiur-monitor` wording, `/aiur-loop` retirement and
publication validation are not lost with the research branch.

The reviewed planning authority is commit
`0daf29726fbe8345a79588e14b6f4c556584a57c`. A later compatible successor is
acceptable only after explicit review confirms it preserves the finite feature
boundary, rework-before-ticket-multiplication rule, backlog-growth circuit
breaker, privacy policy, and publication validator behavior.

The Build Order planning authority for this issue body is
[`<APPROVED_SHA>`](https://github.com/its-everdred/aiur/commit/<APPROVED_SHA>).

## Why human-blocked

The active dashboard run still consumes the old skill contracts. Landing the
rewrite mid-run could change its operating instructions. This is a sequencing
gate, not unfinished Build Order implementation.

## Scope

- Wait until the active dashboard Executor confirms its run is complete.
- Review draft PR #1065 at its current isolated head and reconcile its
  conflicting `aiur-run`/`aiur-monitor`/loop changes with the Executor
  terminology and documentation now on `origin/main` at `1e0cfba3`, then
  refresh it against the
  configured integration branch without dropping the bounded contracts.
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

This issue is published as an external native blocker of BO-001. It remains
outside Build Order membership, points, ETA, and completion. Closing it means
the reviewed revision (or a proven compatible successor) is landed or installed
and all three skills are discoverable for both supported worker backends; merely
closing PR #1065 without those checks does not resolve the gate.

## Labels

Apply `human:todo`. Do not apply `agent:todo` or Build Order membership.

<!-- aiur-planning-issue
{"schema":2,"logical_id":"SKILL-DELIVERY-001","plan_version":1,"approved_planning_commit":"<APPROVED_SHA>"}
-->
