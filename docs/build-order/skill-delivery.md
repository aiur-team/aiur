# Land bounded Executor planning skills

## Outcome

After the current dashboard Executor finishes, a human reviews and lands the
isolated skill-only draft PR #1065 so `/aiur-build`, the consolidated bounded
`/aiur-run` Executor role, `/aiur-monitor` wording, `/aiur-loop` retirement and
publication validation are not lost with the research branch.

## Why human-blocked

The active dashboard run still consumes the old skill contracts. Landing the
rewrite mid-run could change its operating instructions. This is a sequencing
gate, not unfinished Build Order implementation.

## Scope

- Wait until the active dashboard Executor confirms its run is complete.
- Review draft PR #1065 at its current isolated head and refresh it against the
  configured integration branch.
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

## Labels

Apply `human:todo`. Do not apply `agent:todo` or Build Order membership.

<!-- aiur-planning-ticket
{"schema":1,"logical_id":"SKILL-DELIVERY-001","provenance":"planned","introduced_in_plan_version":1}
-->
