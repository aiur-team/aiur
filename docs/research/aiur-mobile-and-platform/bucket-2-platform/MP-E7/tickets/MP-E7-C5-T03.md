---
ticket_id: MP-E7-C5-T03
feature_id: MP-E7
chunk_id: MP-E7-C5
bucket: 2-platform
title: "Leaving async: apply the owner-chosen backlog rule (notice | skip | batch)"
status: blocked
blocked_by: [DESIGN-E7 (decision E7-D4), MP-E7-C5-T01, MP-E7-C2-T01, MP-E7-C1-T05]
repo: aiur-team/aiur
wave: 4
prior_units: [U3]
prior_boundaries: [MSG (16)]
prior_features: []
prior_findings: [MP-E7 plan "Skip the async backlog like Khala" (not adopted by default)]
size_owner: ORCH
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C5-T03 — Backlog rule on `async → sync | steer`

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 2 · MP-E7 · C5.
- **User value:** after switching an agent out of `async`, messages the agent
  never read are handled the way the operator chose, never silently lost and
  never dumped into context without consent.
- **Deliverable:** a transition handler, invoked by the mode store when the
  requested mode changes from `async`, implementing exactly the option
  recorded for **E7-D4** in DESIGN-E7:
  - `notice` (proposed): enqueue one system message "N earlier messages are
    waiting; read them with aiur_read_messages" (final copy from DESIGN-E7),
    delivered under the new mode; bodies stay pull-only.
  - `skip` (Khala, `packages/agent/src/mode.ts:11-22` at `99e72a43`): mark
    held items `:superseded` with reason `left_async`; no notice.
  - `batch`: convert held items to normal `:listener` items in sequence order
    so the new mode delivers them as one batch.
- **Non-goals:** choosing among the three (owner). The copy (owner).

## Dependencies and blockers

- **DESIGN-E7 decision E7-D4** — implementation of the chosen branch only;
  the ticket must not ship all three as a config switch unless DESIGN-E7 asks.
- **MP-E7-C2-T01** (mode store emits a transition callback),
  **MP-E7-C5-T01** (held items and read API),
  **MP-E7-C1-T05** (`backlog_on_leave_async` field in the shared spec; aiur's
  value must match the recorded decision, and `batch` needs a spec value
  added there if chosen).
- **May run concurrently with** C5-T02, C5-T04.

## Verified starting point (at `45a290e3`)

- Queue statuses include `:superseded` (`agent_queue_item.ex:6`).
- System notices are a queue category (`agent_queue_item.ex:8`,
  `:system_notice`).
- No listener transition code exists (new feature).

## Chosen design

- Hook point: `Aiur.Listener.ModeStore` (C2-T01) calls
  `Aiur.Listener.Transitions.on_change(identifier, from, to, actor)`
  (PROPOSED module, < 120 lines) after a successful CAS write, inside the
  orchestrator process so the queue mutation and the mode write are ordered.
- Only `from == :async and to in [:sync, :steer]` acts; other transitions are
  no-ops (contract §6).
- Count used in the notice is the C5-T02 `unread_count` at the moment of the
  switch.
- Idempotent: re-applying the same transition (same `version`) does nothing.

## Implementation steps

1. `Transitions.on_change/4` with only the decided branch.
2. Call from ModeStore after CAS success.
3. Emit `listen-mode.changed` payload extension `backlog: %{rule, count}`
   (topic owned by MP-R2, RC-08).
4. Tests.

## Non-happy paths

- **Zero unread:** no notice, no event extension.
- **Agent not running:** notice is queued and delivered when the agent runs.
- **Rapid async→sync→async:** the notice from the first switch, if not yet
  delivered, is superseded on re-entering async (it would be noise).
- **Restart mid-transition:** the mode write and queue write are in one
  orchestrator call; persistence order: queue items first, then mode record,
  so a crash leaves at worst a notice with the old mode (harmless).

## Compatibility and rollout

Active only with `:listener` routing. Rollback: revert; held items stay
pull-only (equivalent to `notice` without the notice).

## Verification

- `transitions_test.exs` (new): for the chosen rule, `"async to sync with 3
  unread applies <rule>"` asserting the exact queue state (notice item text
  contains the count / three `:superseded` / three normal items in order).
  **Mutation:** make `on_change/4` a no-op → fails.
  `"sync to steer does nothing"`; `"same version twice is idempotent"`;
  `"re-entering async supersedes an undelivered notice"` (notice rule only).
- Command: `env -C src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= mise exec --
  mix test test/aiur/listener`.
- Manual: wrapper-tmux; agent in async, send 2 messages, switch to sync via
  the C7 control; the chat pane shows the notice (or nothing for `skip`).

## Completion and handoff

- [ ] DESIGN-E7 E7-D4 answer cited in the PR.
- [ ] Parent updates listener-mode §6 to the decided value.
- Docs: C7-T05 documents the rule.
