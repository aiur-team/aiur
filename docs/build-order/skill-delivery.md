# Land bounded Executor planning skills

## Outcome

The isolated skill-only PR #1065 was finally reviewed at source head
`6447f9c193d2322d63f54a58b9c54e0a72d3e98f` and squash-merged into `main` as
`ed1846c4bc76d4657095da57951a0dbf3e914c3d`. That landed authority contains
`/aiur-build`, the consolidated bounded `/aiur-run` Executor role,
`/aiur-monitor` wording, `/aiur-loop` retirement, multi-prefix validation, and
the bounded publication contract required by this pack.

The Build Order planning authority for this issue body is
[`4d8de9508206e08e314f2730cd916501a3b4cafd`](https://github.com/aiur-team/aiur/commit/4d8de9508206e08e314f2730cd916501a3b4cafd).

## Why human-blocked

The code delivery is complete. Before dispatch, the live root must record both
the reviewed source head and merged-main SHA above, and the Executor must prove
all three landed skills are discoverable from the installed checkout.

## Scope

- Preserve the exact reviewed source head and squash-merged `main` authority
  above in the publication record.
- Re-run the skill validator, focused skill discovery/installation tests and
  the repository CI gate required at pickup.
- Do not merge mixed research PR #1064 merely to recover skill files; they are
  already present on `main` through the reviewed merge.
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
points, ETA, and completion. Closing it means reviewed source head
`6447f9c193d2322d63f54a58b9c54e0a72d3e98f` and merged-main SHA
`ed1846c4bc76d4657095da57951a0dbf3e914c3d` are recorded and all three skills
are discoverable for both supported worker backends.

## Labels

Apply `human:todo`. Do not apply `agent:todo` or Build Order membership.

<!-- aiur-planning-issue
{"schema":2,"logical_id":"SKILL-DELIVERY-001","plan_version":1,"approved_planning_commit":"4d8de9508206e08e314f2730cd916501a3b4cafd"}
-->
