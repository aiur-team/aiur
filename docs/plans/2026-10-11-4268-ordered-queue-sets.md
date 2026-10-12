---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
---
# Ordered queue sets

Issue #4268 extends the ordering from merged PR #4257. No dashboard changes or new CLI verbs.

## Decisions and scope

Persist a nonnegative queue rank. New list and adopted queues append after the greatest existing rank. Missing ranks in version 1 stores migrate by creation time, preserving file order for ties. Expose rank in the read model for the sibling CLI work.

Publish queue membership and reconciliation state alongside existing ETS dispatch hints. Keep the existing ready/optimistic/held tiers; ranked mode prefers set rank, then list position for ready work and deepest-first order for optimistic work. `none` is the default and preserves the existing candidate order; this repository opts into `ranked`. Unqueued work retains ordinary ordering after ranked queue members.

Admission checks count sets with started unfinished members, including review and CI waits, plus newly admitted runtime claims. Held sets never consume the set cap. A new set may start only below `max_active_sets`. Reserve slots apply to spill past the earliest unfinished unheld set. Unknown readiness in an earlier set blocks spill and names the uncertainty. Existing runners are never preempted.

Carry the named set-order decline through status waiting descriptors and the existing claim-probe boundary into queue item reasons. Render the reason in the existing CLI waiting column.

## Implementation units

1. Queue domain and configuration: `model.ex`, `codec.ex`, list/adoption constructors, schema, templates and configuration reference. Tests: `src/test/aiur/build_queue/set_rank_test.exs`, `src/test/aiur/config/queue_sets_test.exs`. Prove old files migrate in creation order, ranks round-trip, new queues append, invalid config is rejected and absent keys default correctly.
2. Ordering and admission: existing `dispatch_candidates.ex`, hint publication, small set-policy module, dispatch/manual-resume and waiting surfaces. Tests: `src/test/aiur/orchestrator/queue_sets_dispatch_test.exs`, existing `waiting_descriptor_test.exs`, queue CLI tests. Prove A/B/C allocation 2/4/0, cap=1 allocation 2/0/0, reserve=1 with A in review allocation 0/5/0, none reproduces legacy order, holds excluded, stale/missing evidence blocks spill, ready work precedes optimistic work and queue/status reasons name the cause.

## Risks and verification

When a cap or reserve is configured, a stale hint must never be interpreted as an empty set; age the snapshot at consumption as well as handling unknown projections. A cap must count review waits rather than only running processes. Recheck at serialized admission so a batch cannot exceed limits. Preserve hint row formats for existing consumers.

Run focused tests and the affected-test selector, compile, format, lint, structural and config-doc gates. Mutation-check new tests in an isolated worktree. Full CI is the handoff gate; manual sandbox runs are forbidden from agent workspaces.

Plan self-review: scope and dependency resolved; acceptance scenarios mapped. No blocking product decisions.
