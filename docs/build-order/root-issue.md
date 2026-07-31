# BO: Build Order dashboard

Deliver a truthful, selectable dependency view of one bounded GitHub-rooted
feature while Aiur executes it. GitHub owns current membership, ticket facts,
lifecycle and native hard blockers; Aiur owns current activity and progress.

## Finite boundary

This root contains all 54 members: BO-001 through BO-020 and DASH-001 through
DASH-034. Completion requires all 54
issues implemented, reviewed, green on the current configured integration
branch, merged, documented, cleaned up and proven after merge through the real
CLI plus authenticated browser workflow. Linear
parity, skill delivery, reliability findings and optimizations do not change
this root's remaining count or ETA.

## Approved planning authority

- Approved planning commit:
  [`4d8de9508206e08e314f2730cd916501a3b4cafd`](https://github.com/aiur-team/aiur/commit/4d8de9508206e08e314f2730cd916501a3b4cafd)
- Planning pack: `docs/build-order/`
- Read first: `docs/build-order/README.md`
- Executor handoff: `docs/build-order/EXECUTOR-HANDOFF.md`
- Canonical baseline: `docs/build-order/build-order.json`

GitHub becomes authoritative for live membership and blockers after
publication. The linked commit preserves reviewed intent and scheduling
metadata.

The current root must also contain one `aiur-build-order-reconciliation`
comment linking the immutable post-publication reconciliation commit. That
comment, not a pending field in the approved planning commit, proves returned
issue identities, native membership, blockers, and full labels were re-read.

## Pre-dispatch gates

Do not dispatch any member until both gates in `build-order.json` are recorded
as resolved on this root. BO-004 and BO-008 are the independent initial nodes;
BO-001 depends on BO-004 and inherits both gates:

- the configured integration branch contains the completed OCC predecessor
  baseline and its accepted successors; and
- the final reviewed PR #1065 source head
  `6447f9c193d2322d63f54a58b9c54e0a72d3e98f` and its squash-merged `main`
  commit `ed1846c4bc76d4657095da57951a0dbf3e914c3d` are recorded, and
  `/aiur-build`, `/aiur-run`, and `/aiur-monitor` are discoverable from that
  landed authority.

These are external execution gates, not child tickets and not additions to the
54-member denominator. The skill-delivery issue is published as a native
blocker of both initial BO nodes so no branch silently bypasses GATE-002.

## Closure

BO-015 owns the acceptance matrix and post-merge proof, and depends on
DASH-033's dashboard-parity evidence. The Executor closes
this root with state reason `COMPLETED` only after BO-015 satisfies the terminal
condition for all 54 members. Incidental non-blockers remain deferred.

<!-- aiur-planning-issue
{"schema":2,"logical_id":"aiur-team/aiur:build-order-dashboard","plan_version":1,"approved_planning_commit":"4d8de9508206e08e314f2730cd916501a3b4cafd"}
-->
