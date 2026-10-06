---
contract_id: MP-CT-queue-readiness-and-build-progress
owner_feature: MP-E1
status: draft (Phase B; not reconciled by coordinator)
base_main_sha: 45a290e3
date: 2026-10-06
consumers: MP-N3, MP-N4, MP-N5, MP-N7, MP-E4, MP-R1, MP-R2
evidence: ../bucket-2-platform/MP-E1/plan.md, ../bucket-2-platform/MP-E1/findings.md
---

# Contract: queue readiness and build progress

This contract defines what "ready" means for a queued ticket, how readiness
reaches GitHub and the dispatcher, the queue read model, and the build-progress
facts and milestones that notifications use (D18). Claims about today cite
[findings.md](../bucket-2-platform/MP-E1/findings.md) (F-numbers) at
`45a290e3`. Everything else is **proposed** and blocked on DESIGN-E1.

## 1. Rules this contract rests on

1. **Readiness is a label fact on GitHub.**
   - Ready means the issue carries the configured todo label
     (`<label_prefix>:todo`, F1).
   - Queue-held means it carries the queue marker (`<label_prefix>:queued`,
     name per DESIGN-E1) and no state label.
   - Consumers read readiness from labels or from the queue read model (§3),
     never from bus events alone.
2. **Readiness is not permission.** Promotion never changes dispatch
   authorization, admission or capacity. The dispatcher decides starts (D4, F3).
3. **Events are signals.** Every queue event is a hint plus correlation ids.
   After a restart or a gap, a consumer reconciles against the read model
   ([events-and-replay.md](events-and-replay.md) §1).
4. **Unknown is not zero.** Every fact carries `observed_at`, `age_ms` and
   `freshness` (`current | stale | unknown`), matching the `aiur build-orders`
   JSON sources (F9). A consumer must render `unknown` or `stale` distinctly.

## 2. Readiness vocabulary

### 2.1 Prerequisite verdict (per edge)

| Verdict | Condition |
| --- | --- |
| `satisfied` | The prerequisite is closed with `state_reason: completed` |
| `pending` | Open, and not failed |
| `failed` | Open in `agent:error`; or its latest ticket PR was closed unmerged and no PR is open; or closed `not_planned` (subject to DESIGN-E1 OQ-2) |
| `unknown` | Observation stale or unavailable, the source is not usable, the edge is in a cycle, or closed `duplicate` |

### 2.2 Item readiness (AND over all prerequisites)

The item takes the first matching verdict, in this order:

1. `unknown` if any edge is unknown.
2. `failed` if any edge failed.
3. `waiting` if any edge is pending.
4. `ready` otherwise.

This order follows `Aiur.BuildOrder.Readiness.from_edges/1` (F6), with
`terminal_unsatisfied` renamed to `failed`.

### 2.3 Item state (what the queue shows)

| State | Labels | Queue writes allowed |
| --- | --- | --- |
| `waiting` | marker | none |
| `ready` (transient) | marker | add todo |
| `promoted` | marker + todo | remove todo only through the withdrawal protocol (§2.4) |
| `promoted_unauthorized` | marker + todo, dispatch denied `unauthorized` | none; attention raised |
| `claimed` | marker + any other state label, or the ClaimProbe says running | none |
| `held` | marker; operator hold or external todo removal | none |
| `overridden` | todo applied by someone other than the queue | none |
| `failed_prerequisite` | marker | none; attention raised |
| `unknown` | marker | none |
| `completed` | issue closed `completed` | none |
| `cancelled` | issue closed `not_planned` | none |
| `removed` | marker absent | none |

### 2.4 Withdrawal protocol (D8)

This is the only path that removes the todo label from an item.

1. Put the item in the dispatch hold set.
2. Ask `ClaimProbe.claimed?`.
3. If the answer is `false`, remove todo and leave the marker.
4. If the answer is `true`, raise an attention instead.
5. If the answer is `:unavailable`, keep the hold and write nothing.

## 3. Read model (CLI `aiur queue show --json`; dashboard; future clients)

```json
{
  "schema_version": 1,
  "page": "build-queue",
  "instance": "<instance id per identity contract>",
  "snapshot": {"captured_at": "2026-10-06T15:02:13Z"},
  "status": "running | disabled | unsupported_tracker | store_unavailable | writes_paused",
  "sources": {
    "tracker_observation": {"state": "ok", "observed_at": "...", "age_ms": 41000, "freshness": "current", "partial": false, "reasons": []},
    "build_order:2573":    {"state": "ok", "observed_at": "...", "age_ms": 920000, "freshness": "stale", "partial": false, "reasons": ["delivery_staleness"]}
  },
  "queues": [
    {
      "queue_id": "q-7f3a",
      "kind": "list | build_order",
      "root": 2573,
      "name": "paseo",
      "held": false,
      "progress": {"completed": 9, "resolved": 12, "total": 15, "percent": 60, "resolution": "partial"},
      "items": [
        {"number": 2581, "position": 3, "state": "waiting", "verdict": "waiting",
         "prerequisites": [{"number": 2579, "verdict": "pending", "source": "build_order"}],
         "downstream_open": 4, "rank": [ -4, 2, 3, 1791281110, 2581 ],
         "promoted_at": null, "attention": null}
      ]
    }
  ]
}
```

- Field names are stable for `schema_version: 1`. Adding fields does not bump
  the version. Renaming or removing one does.
- No titles or bodies appear in this payload. Clients fetch titles from existing
  dashboard projections, following the events contract rule that free text does
  not travel on the bus.
- `rank` is exposed for explanation only. Clients must not re-sort by it.

## 4. Build progress facts and milestones (D18, consumed by MP-N5/N4/N3/N7)

### 4.1 Progress fact

`{scope, completed, resolved, total, percent, resolution, observed_at,
freshness}`. `scope` is one of:
- `{"queue": "<queue_id>"}`: computed by the queue from its items. `percent` is
  `completed ÷ (total − removed) × 100`, rounded down.
- `{"build_order": <root>}`: taken from `RootSummary.progress` /
  `progress_resolution` (F6). It is not recomputed, so the dashboard and
  notifications agree.

### 4.2 Milestone event

A milestone fires when `percent` first crosses 25, 50, 75 or 100 within a
**generation** of the scope.
- A generation is the queue's lifetime, or a Build Order root's lifetime.
- A root that is reopened after reaching 100 starts a new generation.

Rules:
- **No bursts.** If one observation crosses several thresholds (for example,
  after a restart or reconnect), only the highest crossed milestone is emitted.
- **No repeats.** The last announced milestone is stored durably per scope
  generation. It is never re-announced after a restart, and never announced for
  a decrease.
- **No milestones from stale or unknown data.** If `resolution` is `unresolved`
  or `unknown`, nothing is emitted.

### 4.3 Topics (inside the namespaces reserved by events-and-replay §9)

| Topic | Class | Dedupe key | Executor-bound |
| --- | --- | --- | --- |
| `system.queue.<queue_id>.progress.milestone` | ledgered (exported later) | `(instance, queue_id, generation, milestone)` | no (notification only) |
| `system.build_order.<root>.progress.milestone` | ledgered (exported later) | `(instance, root, generation, milestone)` | no |
| `ticket.<id>.queue.promoted` / `.withdrawn` / `.held` / `.released` / `.overridden` / `.removed` | live | `(instance, id, intent_id)` | no |
| `ticket.<prereq>.queue.attention.prerequisite_failed` (+ `.resolved`) | ledgered | `(instance, prereq, cause)` | **yes**, add `ticket.*.queue.attention.*` to `ExecutorBindings` |
| `ticket.<id>.queue.attention.dependency_changed_after_start` | ledgered | `(instance, id, edge_set_hash)` | yes |
| `ticket.<id>.queue.attention.promoted_unauthorized` / `.write_failed` / `.merged_issue_open` | ledgered | `(instance, id, cause)` | yes |
| `system.queue.attention.inputs_unavailable` / `.store_unavailable` | ledgered | `(instance, cause)` | yes, add `system.queue.attention.*` |

**Payload allowlist (attrs/refs only; no free text on the bus):**
- refs: `ticket`, `prerequisite`, `queue_id`, `root`, `blocked` (a list of
  issue numbers)
- attrs: `cause` (enum), `milestone` (25, 50, 75 or 100), `percent`,
  `generation`, `freshness`

The human-readable message is built by `Aiur.Alerts` for the local alert feed,
as today.

**Note for reconciliation.** Events-and-replay §9 assigns the
`system.build_order.<root>.*` producer to Build Orders. This contract defines
the payload. MP-E1 chunk C7 implements the producer inside
`src/lib/aiur/build_order/` (a small observer), unless the coordinator assigns
it elsewhere.

## 5. Interfaces offered (proposed)

| Interface | Shape | Consumers |
| --- | --- | --- |
| `Aiur.BuildQueue.show/1` | read model §3 (map) | CLI, dashboard, MP-N3 meta counts |
| `Aiur.BuildQueue.progress/1` | progress facts §4.1 for all scopes | MP-N3, MP-N5, MP-N7 |
| `Aiur.BuildQueue.Hints.rank/1`, `held?/1` | ETS reads, `{0}`/`false` when absent | `DispatchPolicy` only |
| `Aiur.BuildQueue.ClaimProbe` | behaviour `claimed?(issue_id) :: boolean() \| :unavailable`; `notify_demand([id]) :: :ok` | implemented by orchestration |
| `Aiur.BuildQueue.Source` | behaviour `members(queue) :: {:ok, [item], [edge], freshness} \| {:unavailable, reason}` | ExecutorList, BuildOrder |
| Capability | `build_queue`, `build_queue.build_order_source` (identity-and-capabilities contract) | clients detect presence |

## 6. Assumptions on contracts owned by others

**MP-R2 events-and-replay:**
- E-A1. The topic grammar is frozen. `ticket.<id>.queue.*` and `system.queue.*`
  are reserved for MP-E1 (§9 there). *Matches the current draft.*
- E-A2. `ticket.<id>.pr.merged` stays `live` and may be lost. The queue does
  not depend on it, and uses it only as a trigger (§11 there). *Matches.*
- E-A3. **Requested:** a `ticket.<id>.pr.closed_unmerged` topic, published by
  the webhook normalizer and the poll path (today nothing is published, F7).
  If R2 does not add it, MP-E1 C4 observes closed-unmerged PRs from
  `ResourceStore` pull-request deposits instead (RQ-1).
- E-A4. Attention topics emitted through `Aiur.Alerts` are `ledgered` and reach
  the Executor only when bound in `ExecutorBindings`. MP-E1 adds the two
  bindings in §4.3.
- E-A5. The optional durable-consumer cursor (§7.1 there) is not required by
  MP-E1 v1. The queue is level-triggered.

**Identity and capabilities:**
- I-A1. A stable `instance` id exists for the read model and the milestone
  dedupe keys. Until it lands, the queue uses the instance key already in
  `Config.Paths.decision_state_dir/0` (F9).
- I-A2. The capability registry accepts `build_queue` and
  `build_queue.build_order_source`. These names match the MP-R1 capability
  matrix.

**MP-N5:** a notification rule subscribes to milestone topics and applies
D18's defaults. N5 owns per-device preference and suppression, not this
contract.

## 7. Compatibility

- `schema_version` 1 for the read model, and `payload_version` 1 per topic.
- Rollback: a pre-marker release parses `agent:queued` as a state label (F1).
  The marker registration must ship at least one release before any marker
  write, and downgrading needs `aiur queue clear --remove-markers` first.
