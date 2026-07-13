# Build Order dashboard

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
  [`<APPROVED_SHA>`](https://github.com/its-everdred/aiur/commit/<APPROVED_SHA>)
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
- PR #1065 commit `f92aa045` or an explicitly reviewed compatible successor is
  installed and `/aiur-build`, `/aiur-run`, and `/aiur-monitor` are
  discoverable.

These are external execution gates, not child tickets and not additions to the
54-member denominator. The skill-delivery issue is published as a native
blocker of both initial BO nodes so no branch silently bypasses GATE-002.

## Closure

BO-015 owns the acceptance matrix and post-merge proof, and depends on
DASH-033's dashboard-parity evidence. The Executor closes
this root with state reason `COMPLETED` only after BO-015 satisfies the terminal
condition for all 54 members. Incidental non-blockers remain deferred.

<!-- aiur-planning-issue
{"schema":2,"logical_id":"its-everdred/aiur:build-order-dashboard","plan_version":1,"approved_planning_commit":"<APPROVED_SHA>"}
-->
