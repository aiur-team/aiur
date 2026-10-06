---
ticket_id: MP-R1-C3-T5
feature_id: MP-R1
chunk_id: MP-R1-C3
bucket: 1-refactor (Bucket-2 enabling work, RC-12)
title: Publish system.capabilities.changed on every revision change
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C3-T1]
prior_units: [U3]
prior_boundaries: ["BUS #10"]
prior_features: [MP-R2]
prior_findings: []
size_owner: n/a (monitor file from C3-T1; add ≤ 25 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C3-T5 — `system.capabilities.changed`

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1 (RC-12 enabling), MP-R1, C3. Contract §2.1, §3
  rule 5.
- **User value:** clients refetch the report when something changed instead of polling;
  the dashboard and Stream Deck can update a disabled control within one tick.
- **Deliverable:** in `Aiur.Capabilities.Monitor` (C3-T1), after a revision bump, call
  `Aiur.Events.Publisher.publish("system.capabilities.changed", %{"revision" => r,
  "boot_id" => id}, [])`. Plus a `Phoenix.PubSub` broadcast on `Aiur.PubSub` topic
  `"capabilities"` with `{:capabilities_changed, r}` for in-node LiveView consumers
  (internal invalidation, MP-Q5: PubSub carries internal invalidation only).
- **Non-goals:** remote delivery (MP-R2-C7 external API), catalog registration (MP-R2-C5,
  requested in `CONTRACT-REQUESTS-C1-C5.md` CR-R1-1), any consumer change.

## Dependencies and blockers

- DESIGN-R1 §1; C3-T1. Soft: MP-R2-C5 catalog — this ticket can merge first because
  `Publisher.publish/3` accepts any `system.*` topic today; the catalog entry follows.
- **Dependents:** MP-R2-C7 (forwards it), MP-N1/N3 clients, dashboard JS.

## Verified starting point (`45a290e3`)

- `Aiur.Events.Publisher.publish/3` (`publisher.ex:111-121`): rejects only durable
  decision topics, executor-namespace-from-GitHub, bot self-loops, dedup; a `system.*`
  topic with a plain map passes. Existing `system.*` producers: e.g.
  `system.daemon.gap` (`daemon_heartbeat_checker.ex:21`),
  `system.decision_dispatch.saturated` (`decision_dispatch_tasks/saturation.ex:35`).
- Executor wake bindings (`executor_bindings.ex:7-35`) contain no `system.#` and no
  `system.capabilities.*` pattern, so this event does **not** wake the Executor. A
  capability flap must not spam the Executor; keep it that way.
- Publisher may be absent in early boot; `Alerts.publish_to_exchange` treats a missing
  Publisher/IdGenerator as non-fatal (`alerts.ex:194-226`) — same rule here.

## Chosen design

- Publish only on a revision change (never per tick). Debounce: none in the daemon
  (contract §4 "the report itself is not debounced"); clients debounce rendering.
- Failure to publish (`{:error, _}`, exit because Publisher is down) is logged once per
  state and does not affect the revision or the stored report.
- Payload deliberately excludes the capability map: subscribers refetch through the
  authenticated endpoint, so the bus never carries more than the report's version.

## Implementation steps

1. In the monitor's bump branch, call an injectable `publish_fun` (default above),
   wrapped in `try/catch :exit`.
2. PubSub broadcast via `Phoenix.PubSub.broadcast/3` guarded by
   `Process.whereis(Aiur.PubSub)` (pattern of `AiurWeb.ObservabilityPubSub.broadcast_update/1`,
   `observability_pubsub.ex:16-25`, but called directly so the identity component does
   not reference `AiurWeb`).
3. Document the topic in `website/docs-app/concepts/message-bus.md` system-topic list
   (one row) — docs ship with a new published topic.

## Non-happy paths

- Publisher down → no event; next bump publishes; clients also refetch on reconnect.
- Two bumps in one tick cannot happen (one compute per tick).
- Restart → new `boot_id`; first report after boot publishes revision 1 (from 0) so
  subscribers learn of the restart.

## Compatibility and rollout

New topic; no binding matches it. Rollback: revert.

## Verification

Extend `src/test/aiur/capabilities_test.exs`:

| Test | Expected |
|---|---|
| `publishes once per revision change` | flip provider twice → two publishes with revisions n+1, n+2 |
| `no publish on unchanged tick` | zero calls |
| `payload carries only revision and boot_id` | keys == `["boot_id", "revision"]` |
| `publisher failure does not block the revision` | publish fun raises exit → revision still bumped, report stored |
| `capabilities.changed does not match any executor binding` | `Aiur.ExecutorBindings.defaults()` patterns via `Aiur.Events.Topic` matching return false (guard against a future `system.#` binding; named as a regression guard) |

Command: `$TESTCMD test/aiur/capabilities_test.exs`.

Mutation check: publish on every tick → second test fails; include the map in the
payload → third fails.

## Completion and handoff

- [ ] Event published on change; message-bus page row added.
- [ ] CR-R1-1 sent to MP-R2 (catalog entry).
- **Dependents:** MP-R2-C7, MP-N1-C3 (refresh triggers).
