---
ticket_id: MP-E1-C5-T03
feature_id: MP-E1
chunk_id: MP-E1-C5
bucket: 2-platform
title: Live ticket.<id>.queue.* events
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C3-T04, MP-E1-C3-T06]
prior_units: [U3]
prior_boundaries: [BUS #10]
prior_features: [MP-R2]
prior_findings: [MP-E1 F2]
size_owner: n/a (build_queue files only)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C5-T03 — Publish queue transitions on the bus

> **Plan refresh (wave 0).** Topics are `live` now and may become `exported`
> after MP-R2-C5/C6 (contract §4.3, RC-08).

## Identity and outcome

- Bucket 2, MP-E1, C5, T03.
- **User value:** subscribers (the Executor's listener, later mobile) see
  queue transitions as they happen, as hints.
- **Deliverable:** after each successful transition the server publishes
  `ticket.<id>.queue.<verb>` for `promoted`, `withdrawn`, `held`, `released`,
  `overridden`, `removed`.

## Dependencies and blockers

- DESIGN-E1, C3-T04, C3-T06.

## Verified starting point (`45a290e3`)

- `Aiur.Events.Publisher.publish(topic, payload, opts)` (`events/publisher.ex:111-122`)
  runs `rejection/3` (`:188-213`): the daemon-actor filter applies only when
  `opts[:actor]` is the daemon account (`:405-422`), and the tracked-issue
  filter only when `opts[:issue_number]` is set (`:199-201`, `tracked?(nil)` is
  true, `:497`); `dedup_key` dedupes.

## Chosen design

- Publish with **no** `:actor` and **no** `:issue_number` (the ticket is in
  the topic), `dedup_key: "queue:" <> intent_id`, payload
  `%{"ticket" => id, "queue_id" => q, "cause" => atom_string}` only (contract
  allowlist; no free text).
- Events are not used by the queue itself (F2); they are for consumers.
- Not bound to the Executor by default (contract §4.3 "no").

## Implementation steps

1. `build_queue/events.ex` (PROPOSED, ≈ 30 lines); server calls it after the
   outcome is saved.

## Non-happy paths

Publisher rejection or error → logged, not retried (live class). Duplicate
transition (restart) → deduped by `dedup_key`.

## Compatibility and rollout

New topics inside the reserved `ticket.<id>.queue.*` namespace (events
contract §9).

## Verification

| Test (`src/test/aiur/build_queue/events_test.exs`, PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "promote publishes ticket.N.queue.promoted once" (subscribe via `Exchange.subscribe/1`) | one `{:event, _}` with allowlisted keys only | the publish call |
| "restart re-processing the same intent does not publish twice" | one event | `dedup_key` |
| "payload carries no title" | keys ⊆ allowlist | the allowlist |
| "event survives the daemon-actor filter" — `GitHubConfig.daemon_account` set in test env | event received | omitting `:actor` |

Mutation check: pass `actor: daemon_account` → test 4 receives nothing.

```bash
env -C src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test test/aiur/build_queue/events_test.exs
```

## Completion and handoff

- [ ] Events published. Docs: `concepts/message-bus.md` topic list gains the
  six queue verbs.
- Dependents: MP-N5 (later), C8-T01 (may use PubSub instead).
