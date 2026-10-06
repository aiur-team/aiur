---
ticket_id: MP-E7-C5-T02
feature_id: MP-E7
chunk_id: MP-E7-C5
bucket: 2-platform
title: "Unread (held-async) count in control capabilities with live updates"
status: ready
blocked_by: [DESIGN-E7, MP-E7-C5-T01, MP-E7-C2-T03]
repo: aiur-team/aiur
wave: 4
prior_units: [U3]
prior_boundaries: [MSG (16), CTL]
prior_features: [MP-R7]
prior_findings: [AGENTS.md "Computed ages and collapsed causes"]
size_owner: ORCH (operator_messages/*)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C5-T02 — Unread count projection

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 2 · MP-E7 · C5.
- **User value:** the operator can see how many messages an `async` agent has
  not read yet, on every surface that already reads the control capabilities
  map (dashboard, CLI status, HTTP).
- **Deliverable:** `unread_count` (non-negative integer) and
  `oldest_unread_at` (`DateTime | nil`) inside the `listener` field that
  MP-E7-C2-T03 adds to `issue_control_capabilities/3`, plus a transcript
  broadcast when the count changes. No rendering (C7).
- **Non-goals:** UI copy or placement (DESIGN-E7 §1.4, C7-T01/T02).

## Dependencies and blockers

- **DESIGN-E7**; **MP-E7-C5-T01** (read marks items consumed);
  **MP-E7-C2-T03** (the `listener` sub-map in control capabilities).
- **May run concurrently with** C5-T03, C5-T04.

## Verified starting point (at `45a290e3`)

- `issue_control_capabilities/3` builds the map and already includes
  `queue_depth: queue_depth_for_issue(state, issue_identifier)`
  (`orchestrator/operator_messages/capabilities.ex:43-60`; helper at `:10`).
- Transcript broadcasts for queue events:
  `AgentPubSub.broadcast_transcript/2` (`orchestrator/operator_messages.ex:1018-1028,1052-1060`).
- Tests: `src/test/aiur/orchestrator/operator_messages/capabilities_test.exs`.

## Chosen design

- `unread_count` = number of the ticket's queue items carrying the
  held-async marker (C3-T01) with status `:pending`. Computed in the same
  pass as `queue_depth` (same item list), so no second scan.
- `oldest_unread_at` = `inserted_at` of the oldest such item; `nil` when the
  count is 0. Surfaces that render the count must render this age
  (AGENTS.md: "If a surface computes an age, it renders the age"; C7 owns
  rendering).
- **Unknown path:** when the orchestrator call times out, callers already
  receive no capabilities map; this ticket adds no fallback value. Held items
  persist for a ticket that is not running (contract §5 durability), so
  `unread_count` is computed from the queue even when `running_entry` is
  `nil`.
- **Change signal:** emit a transcript event `:system` with payload
  `%{listener: %{unread_count: n}}` on hold (C3) and on read (C5-T01). The
  dashboard already subscribes to the transcript topic.

## Implementation steps

1. `capabilities.ex`: compute and add the two fields under `listener`.
2. C5-T01 read path and the C3 hold path: broadcast the new count.
3. Tests.

## Non-happy paths

- **Restart:** count is derived from persisted queue items, so it is correct
  after restore (`AgentQueueStore`).
- **Superseded/failed held items:** not counted.
- **Large backlog:** count is O(items for ticket), same as `queue_depth`.

## Compatibility and rollout

Additive field in an internal map. With `:legacy` routing the count is
always 0. Rollback: remove the field.

## Verification

- `capabilities_test.exs`: `"unread_count counts pending held-async items
  only"` (one held pending, one held consumed, one normal pending → 1).
  **Mutation:** count all pending items → fails.
  `"oldest_unread_at is the oldest held item and nil when none"` — replace
  the `nil` branch with `DateTime.utc_now()` → the nil case fails (AGENTS.md
  unknown-path rule).
  `"unread_count is reported for a ticket with no running entry"`.
- Command: `env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec --
  mix test test/aiur/orchestrator/operator_messages`.
- Manual: covered by C7-T01.

## Completion and handoff

- [ ] Tests and mutation checks in PR.
- Docs: none (no surface yet).
- Dependents: C7-T01, C7-T02, C7-T03 render it.
