---
ticket_id: MP-E7-C2-T05
feature_id: MP-E7
chunk_id: MP-E7-C2
bucket: 2-platform
title: "Publish ticket.<id>.agent.listen-mode.changed on the topic exchange once MP-R2 registers it"
status: blocked
repo: aiur-team/aiur
wave: 4
blocked_by: [DESIGN-E7, MP-E7-C2-T04, MP-R2-C5-T01, MP-R2-C5-T03]
prior_units: [U3]
prior_boundaries: [MSG (16), EVENTS]
prior_features: [integrations-43]
prior_findings: []
size_owner: n/a (orchestrator/listener_modes.ex, new; no growth of EVENTS paths)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C2-T05 — Export the listen-mode change event (wave 4)

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E7 / C2. Split out of
  C2-T04 (the chunk's original "emit event") because the topic is registered
  by MP-R2-C5, which RC-09 schedules just before its first consumer.
- **User value:** the Executor, a paired phone (MP-N*) and Khala-style
  consumers can see that an agent's mode changed, with who changed it.
- **Deliverable:** on every broadcast from MP-E7-C2-T04, also
  `Aiur.Events.Publisher.publish("ticket.<id>.agent.listen-mode.changed", payload, opts)`
  with payload `{requested, effective, effective_reason, version, actor}`
  (contract §5) and `resource_source` omitted (no GitHub resource).
- **Non-goals:** no external export allowlist decision (MP-R2-C5/C6); no new
  subscriber.

## Dependencies and blockers

- DESIGN-E7; MP-E7-C2-T04; **MP-R2-C5-T01** (`Aiur.Events.Catalog` entry, RC-08)
  and MP-R2-C5-T03 (namespace reservation).
- **Open item for MP-R2 (contract request filed by the parent):** the topic
  sits under `ticket.<id>.agent.*`, and the publisher labels every
  `ticket.<id>.agent.` topic as the agent's own emission in the IssueLog
  (`src/lib/aiur/events/publisher.ex:339-352`, `kind = :self`). A mode change
  is made by a human, the Executor or the system, not the agent. Either the
  catalog entry carries an override, or the topic moves (for example
  `ticket.<id>.listen-mode.changed`). This ticket implements whichever name
  MP-R2's catalog fixes. **Resolved in Phase D (CR-E7-1):** the name stays
  `ticket.<id>.agent.listen-mode.changed`; the MP-R2 catalog entry declares
  `attribution: :payload_actor` and the IssueLog reads the payload `actor`
  (events contract §9).

## Verified starting point (aiur `45a290e3`)

- `Publisher.publish/3` (`events/publisher.ex:113-122`) requires
  `resource_source` only when `:resource` is present (`:95-97`).
- Default per-ticket subscriptions include only specific `agent.*` subtopics
  (`decision.*`, `blocked`, `unblocked`, `attention.*`;
  `orchestrator/auto_subscriptions.ex:195-205`), so the change event is not
  digested into the agent's own context by default. Test it anyway.

## Chosen design

Publish after the in-process broadcast, in the Orchestrator process (where
`ListenerModes` runs), ignoring `:filtered`/`:deduped` outcomes (logged at
debug). The event never carries message text.

## Implementation steps

1. Add the publish call in `ListenerModes` behind `Aiur.Events.Catalog.registered?/1` (or the MP-R2-C5 equivalent).
2. Tests.

## Non-happy paths

- Exchange not running → publish error is logged; the mode change itself has
  already succeeded and is not rolled back.
- The agent must not receive its own mode change as a digest: assert no queue
  item is created for the target ticket.

## Compatibility and rollout

- New topic only. Rollback: revert.

## Verification

```sh
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/orchestrator/listener_modes_test.exs
```

- "set_mode publishes listen-mode.changed with actor human and no text".
- "a mode change creates no queue item for the target agent".
- "catalog census test lists listen-mode.changed" (MP-R2-C5-T01's census, extended).

Mutation check: remove the publish call → the first test fails.

## Completion and handoff

- [ ] Event published with the catalog's final topic name.
- Dependents: MP-E3-C5 (Executor sees mode changes), MP-N6 (phone), MP-E7-C7.
- Docs: the events page that MP-R2 owns (`message-bus.md` per MP-R2-C5-T03) lists the topic.
