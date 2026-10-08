---
ticket_id: MP-E1-C7-T01
feature_id: MP-E1
chunk_id: MP-E1-C7
bucket: 2-platform
title: Aiur.BuildProgress - progress facts, read API, change signal and milestones
status: blocked
blocked_by: [DESIGN-E1]
prior_units: [U3, U6]
prior_boundaries: [BUS #10, BO #30]
prior_features: [MP-R2, MP-N5]
prior_findings: [MP-E1 F6, RC-08, RC-10]
size_owner: "APP_BOOT (src/lib/aiur.ex one child line); new file otherwise; provisional, RC-23"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C7-T01 — `Aiur.BuildProgress`

> **Plan refresh (wave 0).** RC-10: a progress read API and an internal
> progress-changed signal, milestones at 25%. RC-08: milestone topics
> `system.queue.<queue_id>.progress` and `system.build_order.<root>.progress`
> (producer MP-E1-C7), registered in MP-R2's catalog later and possibly
> exported (R2-C5/C6). RC-40: this module belongs to the **`build-orders`**
> component. MP-E1-C7 writes it; the queue (C7-T02) is one producer and the Build
> Order observer (C7-T03) the other. D18's defaults need no queue. The API is the
> stable interface for MP-N3/N5/N7; MP-N5 gates build-order options on capability
> `build_orders` and queue options on `build_queue`.

## Identity and outcome

- Bucket 2, MP-E1, C7, T01. Contract §4.
- **User value:** progress notifications (D18: every 25% and completion) fire
  exactly once each, never in bursts, never from bad data; phone features can
  read progress any time.
- **Deliverable:** PROPOSED `src/lib/aiur/build_progress.ex` (GenServer):
  - `put_fact(fact)` (producers), `facts(filter \\ :all)`, `subscribe/0`;
  - PubSub `"build_progress"` `{:build_progress_changed, fact}` on any change
    of `percent`, `resolution` or `freshness`;
  - milestone latch per `{scope, generation}` persisted under
    `decision_state_dir/build-progress.json` (JsonStore);
  - milestone emission.
- **Non-goals:** per-device thresholds or suppression (MP-N5 owns them).

## Dependencies and blockers

- DESIGN-E1 (gate). No ticket predecessor; C7-T02/T03 produce into it.
  Not gated on `build_queue.enabled` (Build Order milestones exist without a
  queue).

## Verified starting point (`45a290e3`)

- No progress event exists today; changes reach consumers only in
  GraphProjection snapshot messages (`build_order/graph_projection.ex:1506-1515`, F6).
- `Aiur.Alerts.emit_system/2` publishes, ledgers and broadcasts
  (`alerts.ex:103-106, 144-200`) — the ledgered path.
- JsonStore atomic write (F9); `Config.Paths.decision_state_dir/0`
  (`config/paths.ex:60-66`).
- Children list `src/lib/aiur.ex:419-481`.

## Chosen design

- Fact (contract §4.1): `%{scope: {:queue, id} | {:build_order, root},
  completed, resolved, total, percent, resolution, generation, observed_at,
  freshness}`.
- **Milestone rule** on each `put_fact/1`:
  - skip unless `resolution in [:resolved, :partial]` and `freshness == :current`;
  - `crossed = max(m in [25,50,75,100] where percent >= m)`;
  - emit only if `crossed > latch[{scope, generation}]` — and emit only
    `crossed` (no burst); update the latch durably **before** emitting;
  - a new `generation` starts with an empty latch.
- Emission: `Alerts.emit_system("system.build_order.#{root}.progress", message:, needs_attention: false, severity: "info")`
  (or `system.queue.<id>.progress`) with attrs `milestone`, `percent`,
  `generation`; message built here (no titles).
- Signal is sent for every fact change, independent of milestones.

## Implementation steps

1. `build_progress.ex` (≈ 120 lines) + store file.
2. `src/lib/aiur.ex`: child under `recording?`.
3. Tests below.

## Non-happy paths

- Latch store unreadable → no milestones (fail closed: missing a
  notification is preferred to repeating one); facts and signal still work.
- Percent decreases → no event; latch unchanged.

## Compatibility and rollout

New process and topics. No config (D18 defaults live in MP-N5).

## Verification

| Test (`src/test/aiur/build_progress_test.exs`, PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "20% → 80% in one fact emits only 75" | one event, `milestone: 75` | highest-only rule |
| "restart at 80% emits nothing" | zero events after reload | durable latch |
| "partial resolution emits; unresolved does not" | as stated | resolution guard |
| "stale freshness emits nothing" | zero | freshness guard |
| "new generation after 100 starts again at 25" | event on generation 2 | generation key |
| "signal fires on percent change, not on identical fact" | one message for two identical puts | change detection |

Mutation check: emit every crossed milestone → test 1 sees three; keep the
latch in memory only → test 2 fails.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/build_progress_test.exs
```

## Completion and handoff

- [ ] Facts, read API, signal, milestones, durable latch.
- Docs: `concepts/message-bus.md` lists the two progress topics.
- Contract: the owning contract §4.0 already describes this module.
- Dependents: C7-T02, C7-T03, C8-T01, MP-N3, MP-N5, MP-N7.
