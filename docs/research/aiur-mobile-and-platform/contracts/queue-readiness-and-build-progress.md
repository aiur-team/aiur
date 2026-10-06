---
contract_id: MP-CT-queue-readiness-and-build-progress
owner_feature: MP-E1
status: reconciled (Phase C, 2026-10-06; applies RC-08, RC-10, RC-11, RC-19, RC-20)
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

1. Put the item in the dispatch hold set (`Hints`).
2. Ask `ClaimProbe.status([id])`. The orchestration implementation answers
   inside the orchestrator process, so the answer is ordered after any
   in-flight dispatch decision (findings F4).
3. If the answer is `:unclaimed`, remove todo and leave the marker.
4. If the answer is `:claimed`, release the hold and raise an attention instead.
5. If the answer is `:unavailable`, keep the hold and write nothing.

### 2.5 Promotion write (RC-20)

Promotion is a **conditional** state write through the existing label-writer
seam: `Aiur.Tracker.update_issue_state(id, "todo", expected_state: :none)`.
`:none` means "the issue carries no state label now"; the GitHub
implementation re-reads the issue before writing
(`github/issue_state.ex:142-188`), so a state label that another writer added
since the queue's observation makes the write fail with `:stale_issue_state`
and nothing is written. Markers survive the swap (F1). The queue is a
sanctioned caller of the single label-writer seam: before U2 it calls the
existing `IssueState` path; after U2 it calls U2's writer (RC-20).
Withdrawal uses `Aiur.Tracker.remove_label/2` only after §2.4 proves the item
is unclaimed.

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

### 4.0 Owner and read API (RC-10)

Progress facts are held by a neutral module, `Aiur.BuildProgress` (proposed,
`src/lib/aiur/build_progress.ex`, MP-E1-C7). It has two producers: the queue
server (queue scopes) and a Build Order observer
(`Aiur.BuildOrder.ProgressObserver`, build-order scopes; RC-08 names MP-E1-C7
as the producer). It does not depend on `build_queue.enabled`: Build Order
milestones exist without a queue.

- **Read API:** `Aiur.BuildProgress.facts(scope_filter)` returns the current
  facts (§4.1) for every scope, or for one.
- **Progress-changed signal (internal):** Phoenix PubSub topic
  `"build_progress"`, message `{:build_progress_changed, fact}`, sent whenever
  a scope's `percent`, `resolution` or `freshness` changes. It is not a bus
  topic and is not exported. MP-N5 computes per-device thresholds (for example
  10% steps) from it; this contract keeps the milestone events at 25%.

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
| `system.queue.<queue_id>.progress` | ledgered (exported later) | `(instance, queue_id, generation, milestone)` | no (notification only) |
| `system.build_order.<root>.progress` (RC-08; producer MP-E1-C7) | ledgered (exported later) | `(instance, root, generation, milestone)` | no |
| `ticket.<id>.queue.promoted` / `.withdrawn` / `.held` / `.released` / `.overridden` / `.removed` | live | `(instance, id, intent_id)` | no |
| `ticket.<prereq>.queue.attention.prerequisite_failed` (+ `.resolved`) | ledgered | `(instance, prereq, cause)` | **yes**, add `ticket.*.queue.attention.#` to `ExecutorBindings` (`#` so the `.resolved` suffix also matches) |
| `ticket.<id>.queue.attention.dependency_changed_after_start` | ledgered | `(instance, id, edge_set_hash)` | yes |
| `ticket.<id>.queue.attention.promoted_unauthorized` / `.write_failed` / `.merged_issue_open` | ledgered | `(instance, id, cause)` | yes |
| `system.queue.attention.inputs_unavailable` / `.store_unavailable` | ledgered | `(instance, cause)` | yes, add `system.queue.attention.#` |

**Payload allowlist (attrs/refs only; no free text on the bus):**
- refs: `ticket`, `prerequisite`, `queue_id`, `root`, `blocked` (a list of
  issue numbers)
- attrs: `cause` (enum), `milestone` (25, 50, 75 or 100), `percent`,
  `generation`, `freshness`

The human-readable message is built by `Aiur.Alerts` for the local alert feed,
as today.

**Producer (RC-08).** MP-E1-C7 produces `system.build_order.<root>.progress`
from a small observer inside `src/lib/aiur/build_order/`. MP-R2's catalog
(R2-C5) registers every topic in this table, plus the requested
`ticket.<id>.pr.closed_unmerged` and `ticket.<id>.issue.closed`. MP-E1 v1 does
not depend on those two producers (§6 E-A3).

## 5. Interfaces offered (proposed)

| Interface | Shape | Consumers |
| --- | --- | --- |
| `Aiur.BuildQueue.show/1` | read model §3 (map) | CLI, dashboard, MP-N3 meta counts |
| `Aiur.BuildProgress.facts/1`, `subscribe/0` | progress facts §4.1 for all scopes; the progress-changed signal §4.0 | MP-N3, MP-N5, MP-N7 |
| `Aiur.BuildQueue.Hints.sort_key/1`, `held?/1` | ETS reads; `{0, 0}`/`false` when the table or the key is absent. `sort_key` returns `{-downstream_open, list_position}` as two integers that `DispatchPolicy` splices into its own key (`{d, priority_rank, position, created_at, identifier}`). It is **not** a whole tuple prepended to the key: Erlang orders tuples by size first, so a 1-tuple default would sort ahead of every 5-tuple rank | `DispatchPolicy` only (RC-11 edge 1) |
| `Aiur.BuildQueue.ClaimProbe` | behaviour `status([issue_id]) :: %{issue_id => :claimed \| :unclaimed \| {:declined, atom()}} \| :unavailable`; `notify_demand([id]) :: :ok \| :unavailable` | implemented by orchestration (RC-11 edge 2) |
| `Aiur.Tracker` optional observation callbacks | `open_issue_labels/1`, `blocked_by/1`, `issue_closure/1`, `ticket_pull_request/1` (MP-E1-C1-T03, C4-T03..T05). The GitHub adapter implements them; Linear answers `{:error, :unsupported}` | the queue's observer, so `build_queue/` never references `Aiur.GitHub.*` |
| `Aiur.BuildQueue.Source` | behaviour `members(queue) :: {:ok, [item], [edge], freshness} \| {:unavailable, reason}` | ExecutorList, BuildOrder |
| Capability | `build_queue`, `build_queue.build_order_source` (identity-and-capabilities contract) | clients detect presence |

## 6. Assumptions on contracts owned by others

**MP-R2 events-and-replay:**
- E-A1. The topic grammar is frozen. `ticket.<id>.queue.*` and `system.queue.*`
  are reserved for MP-E1 (§9 there). *Matches the current draft.*
- E-A2. `ticket.<id>.pr.merged` stays `live` and may be lost. The queue does
  not depend on it, and uses it only as a trigger (§11 there). *Matches.*
- E-A3. **Resolved (RQ-1).** MP-E1 v1 observes a closed-unmerged ticket PR
  from the `ResourceStore` `:branch_pull_request` deposit
  (`events/github_webhook/deposit.ex:630-642`), read through the tracker's
  `ticket_pull_request/1` callback at no request cost. Coverage is webhook
  mode only: in poll-only mode the prerequisite stays `pending` (the safe
  direction) and no `failed` verdict is produced. RC-08 registers
  `ticket.<id>.pr.closed_unmerged`; once a producer exists the queue may use it
  as a reconcile trigger, never as the source of truth.
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

## 8. Seam rules (RC-11, RC-19, RC-20)

- No module under `src/lib/aiur/build_queue/` references `Aiur.Orchestrator`
  or `Aiur.GitHub`; only `sources/build_order.ex` references
  `Aiur.BuildOrder`. MP-E1 ships its own source-scan test (MP-E1-C1-T07);
  MP-R1-C1 absorbs it later.
- Orchestration depends on the queue through exactly two narrow edges: the
  `Hints` read in `DispatchPolicy`, and the `ClaimProbe` implementation.
- Core edits outside `build_queue/` are limited to the MP-E1-C1 hooks (plus
  the tracker observation callbacks of C4 and the progress observer of C7).
  The prior refactor's U2 and U5 tickets rebase over them and keep them
  (RC-19).
