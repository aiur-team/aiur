---
artifact_contract: ce-unified-plan/v1
artifact_readiness: planned-with-blockers
feature_id: MP-E1
base_main_sha: 45a290e3
date: 2026-10-06
bucket: 2-platform
owner_gate: DESIGN-E1
owns_contracts: [MP-CT-queue-readiness-and-build-progress]
consumes_contracts: [MP-CT-events-and-replay, MP-CT-identity-and-capabilities]
---

# MP-E1 Build queue: feature plan

**Target repo:** aiur. All file paths are repository-relative.

| File | Contents |
| --- | --- |
| [findings.md](findings.md) | Verified repository findings F1–F11, with `file:line` citations at `45a290e3` |
| [chunks.md](chunks.md) | Chunks MP-E1-C1 to C9, candidate tickets, test strategy, research questions |
| [../../contracts/queue-readiness-and-build-progress.md](../../contracts/queue-readiness-and-build-progress.md) | The shared contract this feature owns |
| [../../owner-design-tasks/DESIGN-E1.md](../../owner-design-tasks/DESIGN-E1.md) | The owner design gate. It blocks every implementation ticket |

---

## 1. Summary

The plan adds a separately bounded **build queue** component, `Aiur.BuildQueue`
under `src/lib/aiur/build_queue/`. It keeps the agent pool supplied without the
Executor promoting tickets one by one.

- The queue holds ordered lists of tickets. An Executor or a user creates a list,
  or adopts a Build Order root. A list can carry "after #N" edges.
- When a member's prerequisites are complete, the queue adds the configured todo
  label (`agent:todo`). The existing dispatcher still decides when the ticket
  starts.
- A failed prerequisite holds its dependents and raises one attention.
- A dependency change after promotion withdraws the label if no agent has claimed
  the ticket. Otherwise it raises an attention.

The component ships before the refactor (D2). It sits behind a narrow seam, so
MP-R1 can move it without rewriting it.

## 2. Problem frame

- **The pool drains.** Active agents fall from about 10 to a few while the
  Executor reviews and merges ([../../brief.md](../../brief.md) §3).
- **Today's auto-promotion is a side effect.** It works only because every
  member is pre-labelled `agent:todo` at creation and the dispatcher skips
  blocked todo tickets (findings F3, F10). That model has five gaps:
  1. **A list with no GitHub edges cannot wait.** A pre-labelled ticket would
     simply start.
  2. **A `not_planned` blocker releases its dependents.** So does any other
     closed blocker. An `agent:error` blocker holds them silently, with no alert
     (F3).
  3. **Ordering is priority, then age.** There is no critical path (F3).
  4. **`agent:todo` cannot mean "ready".** Units, the capacity alert and the
     Executor all read it as ready, but it is also on blocked tickets (F3, F9).
  5. **Nothing shows queue state or controls it,** beyond `--todo [--only]` (F1).

## 3. Requirements trace

| ID | Requirement | Source | Where |
| --- | --- | --- | --- |
| E1-R1 | A separately bounded component, shipped before the refactor on a seam | D2; R1 component map §4 | §5, C1–C3 |
| E1-R2 | Build orders are an optional dependency; a list with "after #N" edges works without them | D5 | §5.3, C4 |
| E1-R3 | Every ready member gets `agent:todo` at once. Dispatcher capacity and admission gates decide starts | D4 | §5.4 |
| E1-R4 | Among ready tickets: critical path, then priority labels, then age | D3 | §5.6, C1, C2 |
| E1-R5 | A failed prerequisite holds its dependents and raises one needs-attention alert naming it and every ticket it blocks | D6 | §5.7, C5 |
| E1-R6 | After a dependency change: withdraw `agent:todo` if unclaimed, else raise an attention | D8 | §5.5, C3 |
| E1-R7 | CLI add, remove, reorder, hold/release and show, plus a read-only dashboard view | D7 | C6, C8 |
| E1-R8 | Queue membership never bypasses authorization, admission or capacity | brief §5 E1 | §5.4, §6 |
| E1-R9 | Correct across merges, multiple prerequisites, competing writers, duplicate or missing events, restarts and retries | brief §5 E1 | §6 |
| E1-R10 | Owns the queue-readiness and build-progress contract | brief §7 | contract file, C7 |

## 4. Alternatives considered

| # | Option | Verdict |
| --- | --- | --- |
| A1 | **Gate model.** Keep pre-labelled `agent:todo`; add a queue gate and rank inside `DispatchPolicy`; write no labels. | Rejected. D4 and D8 settle that readiness is expressed by adding and removing `agent:todo`. It also leaves `agent:todo` meaning "maybe ready" (gap 4). |
| A2 | **Label model, no marker.** Waiting members carry no `agent:*` label; queue state is local only. | Rejected. The zero-label heal re-adds `agent:todo` on the next poll (F5). A waiting ticket is invisible on GitHub, and an Executor reads that as "no work left". Losing the store strands tickets. |
| A3 | **Label model with a registered marker** (`agent:queued`, name under DESIGN-E1). Waiting members carry the marker only; promoted members carry marker + `agent:todo`. Local store is the system of record for order and edges. | **Recommended.** Never zero `agent:*` labels; visible on GitHub; recoverable after store loss; a human-applied marker is valid triage evidence (F1). Costs one marker registration in core (C1). |
| A4 | Write "after #N" edges as GitHub native `blocked_by` dependencies | Deferred (not v1). Makes the dispatcher gate enforce local edges too, but writes a planning statement into the shared graph and doubles the writer set for Build Order edges. Revisit if owners want edges visible on GitHub (owner question OQ-5). |
| A5 | Promote only up to free slots | Rejected by D4. |
| A6 | Order by writing `priority:N` labels | Rejected. It clobbers operator priority (`orchestrator/priority_control.ex:14-121`) and costs writes. Rank is passed as a dispatch hint instead (§5.6). |

---

## 5. Design

### 5.1 Component boundary (seam rules from MP-R1 component map §4)

```text
src/lib/aiur/build_queue/            (all new; facade Aiur.BuildQueue)
  model.ex         Queue, Item, Edge structs (pure)
  readiness.ex     prerequisite verdicts (pure)
  ordering.ex      downstream counts and rank keys (pure)
  planner.ex       desired-vs-observed diff -> actions (pure)
  store.ex         durable JSON under Config.Paths key :build_queue_dir
  server.ex        GenServer: reconcile loop, write intents, latches
  sources/         Source behaviour: executor_list.ex, build_order.ex
  observer.ex      Observer behaviour + tracker-backed impl
  claim_probe.ex   ClaimProbe behaviour (impl lives in orchestration)
  hints.ex         ETS table owned by Server: rank and hold, read by dispatch
  attention.ex     the single function that calls Aiur.Alerts
  progress.ex      progress facts and milestone latch (contract §4)
src/lib/aiur/build_queue_cli.ex      CLI read/format (mirrors build_orders_cli.ex)
src/lib/aiur_web/live/build_queue_live.ex   read-only view (blocked on DESIGN-E1)
```

**Required dependencies:**
- the tracker contract `Aiur.Tracker.add_label/2` and `remove_label/2`
  (`tracker.ex:26-27`)
- `Aiur.Alerts`, `Aiur.Events.Exchange`, `Config`, `Config.Paths`

**Optional dependencies:**
- `Aiur.BuildOrder.GraphProjection`, referenced only from
  `sources/build_order.ex`
- the ClaimProbe implementation, injected by orchestration
- the dashboard

**No module under `build_queue/` references `Aiur.Orchestrator.*` or
`Aiur.GitHub.*`.** This is enforced by a source-scan test until the MP-R1-C1
checker exists.

Orchestration depends on the queue only through `Aiur.BuildQueue.Hints`. That is
an ETS read in `DispatchPolicy`, and it returns neutral values when the table is
absent. Orchestration also supplies a `ClaimProbe` implementation, registered
through application config. This inverts the D8 claim check so the queue never
calls the orchestrator module.

*Reconcile with MP-R1:* the component map says orchestration's optional
dependency on build-queue is "readiness labels only, through tracker". This plan
needs two more narrow edges, `Hints` and `ClaimProbe`, recorded in
[chunks.md](chunks.md) as cross-feature item X-1.

### 5.2 Representation on GitHub

| Item state | `agent:*` labels on the issue | Dispatcher sees |
| --- | --- | --- |
| waiting / held / failed-prerequisite / unknown | `agent:queued` only | No state label, so it is not a candidate |
| promoted | `agent:queued` + `agent:todo` | A todo candidate; all existing gates apply |
| claimed or later | `agent:queued` + any other state label | Normal lifecycle; the queue does not write |
| completed | issue closed (marker may remain) | Terminal |

- `queued` is registered as a **marker suffix** (`github/labels.ex:31-35`). It is
  never parsed as a state, and it survives swaps (F1).
- `IssueSync` treats the marker as deliberate parking for the zero-label heal
  and the strand sweep (F5).
- Both changes ship in C1, **before** any code writes the marker.
- **Triage evidence.** When a human or the Executor applies `agent:queued` with
  their own credential, that counts as an allowed `<prefix>:*` applier (F1).
  Under a strict `allowed_users` list, a later daemon-applied `agent:todo` is
  then authorized as `prior_triage`.
- **The daemon never confers authority.** When the marker comes from
  `aiur queue add` (daemon credential), authorization still rests on whatever
  human triage the issue already has. A denied promotion is shown as
  `promoted (unauthorized)` and raises an attention (§6).

### 5.3 Sources (D5; build order optional)

- **`ExecutorList`.** Local and ordered: `[{number, position}]` plus edges
  `{after: N, item: M}` set by the CLI.
- **`BuildOrder` (optional).** Adopting root R imports the open members of R and
  its native edges from `GraphProjection.selected/2`.
  - The import uses `Member.dependencies` with `kind: :native` and
    `direction: :blocker_to_blocked` (F6).
  - Re-reads happen through `GraphProjection.refresh/2` when a webhook or
    ResourceStore change touches a member.
  - If the projection is not `usable?` (stale, partial or unavailable), every
    edge of that source is `unknown`. The queue then holds and writes nothing
    (F6).
- **Native `blocked_by` of any queued item.** Edges outside a Build Order
  (GitHub dependencies the user set) are respected as prerequisites too. They
  are read from the same `ResourceStore :issue_blocked_by` record that
  `BoundedBlockedBy` keeps (F3). The read path is Phase C research RQ-2.
- **Union.** An item's prerequisites are the union of all sources. Every one of
  them must be satisfied (AND).
- **One owner per issue.** An issue may belong to at most one queue. Adding it
  to a second queue is refused with the owning queue's name.

### 5.4 Promotion (D4)

- **Rule.** Desired label set = marker + `agent:todo` exactly when the item's
  verdict is `ready`, it is not held, and it is not overridden.
- **Action.** On a transition into `ready`, the Server calls
  `Tracker.add_label(id, todo_label)` for **every** ready item, in rank order.
  - Writes are paced by `build_queue.max_writes_per_minute` (default 20). The
    GitHub secondary limit is 80 content-generating requests per minute and
    500 per hour (F11).
  - Then it calls `Orchestrator.note_queued_demand/1` through the ClaimProbe
    implementation, so the idle backoff collapses (F1).
- **The queue does not check capacity, authorization or admission.** The
  dispatcher does, unchanged (F3).
- **Pre-write check.** A write happens only if the latest observation is no
  older than `build_queue.observation_max_age_seconds` (default 2 × the
  dispatch poll interval) and shows **zero** state labels. If another state
  label appeared, the item becomes `claimed` or `overridden` and nothing is
  written. RQ-4 asks whether the tracker can do a conditional add.

### 5.5 Withdrawal after a dependency change (D8)

This applies to a promoted item that is not ready any more: a new edge, a
reopened prerequisite, or a prerequisite that has failed.

1. Insert the item into the Hints hold set. `DispatchPolicy` then skips it with
   `{:skip, :build_queue_hold}` from the next decision on.
2. Ask `ClaimProbe.claimed?(id)`. The orchestration implementation answers from
   `state.running`, `state.claimed`, `retry_attempts` and `auto_resume` inside
   the orchestrator process. Dispatch also runs in that process, so the answer
   is linearized after any in-flight dispatch (F4).
3. Act on the answer:
   - `false`: `Tracker.remove_label(id, todo_label)`. The marker stays, so the
     issue never reaches zero `agent:*` labels. Release the hold once the
     observation shows the label gone.
   - `true`: release the hold, and raise
     `ticket.<id>.queue.attention.dependency_changed_after_start`. Write nothing.
   - `:unavailable` (orchestrator down or probe not installed): keep the hold,
     write nothing, retry on the next reconcile. **Never remove a label without
     proof that the ticket is unclaimed.**

### 5.6 Ordering (D3)

- **Rank key:** `{-downstream_open, priority_rank, list_position, created_at,
  number}`.
- `downstream_open` is the count of open, not-removed queue items that
  transitively depend on the item, computed over the union graph with the
  closure approach of `DependencyChain.reachable/2` (F6).
- `list_position` applies to `ExecutorList` items only. Its place between
  priority and age is **owner question OQ-1**. D3 names only critical path,
  priority and age.
- **Delivery to dispatch.** The rank reaches the dispatcher as a hint.
  `DispatchPolicy.sort_issues_for_dispatch/1` (F3) prepends
  `Hints.rank(issue_id)`, which returns `{0}` for non-queue tickets and when the
  table is absent. So without the queue, today's order is reproduced exactly.
- **Scope.** The rank also orders the promotion writes. The two `sort` callers
  (`dispatcher.ex:1004`, `issue_sync.ex:2123`) both pick it up.

### 5.7 Prerequisite verdicts and failure (D6)

| Prerequisite observation | Verdict | Effect on dependents |
| --- | --- | --- |
| closed, `state_reason: completed` | satisfied | may become ready |
| open, any non-error state | pending | wait |
| open, `agent:error` | **failed** | hold + attention |
| open, its latest ticket PR closed unmerged and no open PR | **failed** | hold + attention (needs RQ-1) |
| closed, `not_planned` | **failed** (matches `EdgeState` `:terminal_unsatisfied`) | hold + attention; owner confirm OQ-2 |
| closed, `duplicate` or unknown reason | unknown | hold + attention naming the cause |
| `pr.merged` observed but issue still open after `build_queue.merged_open_grace_seconds` (600) | pending + attention | the closing-keyword gap (F7) |
| observation stale / source unusable / cyclic | unknown | hold; one `system.queue.inputs_unavailable` attention after the grace period |

- **One attention per failed prerequisite.** Topic
  `ticket.<prereq>.queue.attention.prerequisite_failed`, payload: prerequisite,
  cause, and every transitively blocked queue item (direct ones first). It is
  latched in the store and survives restarts. When the cause clears, it resolves
  with `.resolved`. Pattern: F9 `sync_contradictory_state_label_alert`.
- **Already-promoted dependents.** Dependents that were already promoted follow
  §5.5.

### 5.8 Competing writers and manual overrides

The Executor, humans, agents and other Aiur code also edit labels. The queue
never fights them.

| Observed, not written by the queue | Queue response |
| --- | --- |
| `agent:todo` added to a waiting item | `overridden (manual promotion)`. Stop managing promotion and withdrawal for it; show it; `aiur queue release N` resumes management |
| `agent:todo` removed from a promoted, unclaimed item (e.g. `--todo --only`, a hand edit) | `held (external)`. Never re-add; `release` resumes |
| marker removed | item removed from the queue (dequeued); edges to it are dropped and dependents are re-evaluated |
| `agent:paused` / `agent:parked` / `needs-triage` / `human:todo` | Shown as held by marker; promotion still allowed only if DESIGN-E1 says so (OQ-3; recommend: do not promote while parked) |
| other state label (in-progress, rework, …) | `claimed`; read-only |

- **Telling the queue's writes apart.** The queue records a write intent (item,
  action, target labels, time) **before** each write, and the outcome after.
  When an observation shows a label change that matches no recorded intent, the
  change came from someone else.
- **Why not bus events.** Bus events cannot be used for this, because the daemon
  filters its own actor (F2).

---

## 6. Non-happy paths

### Capability absence

| Missing | Behaviour |
| --- | --- |
| Tracker is not GitHub (no `add_label`/`remove_label`: `tracker.ex:29-32`) | Queue disabled; CLI exits non-zero with "build queue needs a label-capable tracker"; status `unsupported_tracker` |
| Build Orders unavailable | `queue add --build-order` refused; ExecutorList works |
| Webhook absent | Polling cadence only; slower, correct |
| Dashboard off | CLI only |
| Orchestrator down | Promotion still writes labels; withdrawal waits (§5.5) |
| `build_queue.enabled: false` | No process, no hints table: dispatch order unchanged |

### Stale data

- No write happens on an observation older than
  `observation_max_age_seconds`, or on a source that is not usable.
- Output follows the AGENTS.md age rule: every CLI and dashboard surface renders
  `observed_at`, `age_ms` and `freshness`, and shows `unknown` distinctly from
  zero.

### Duplicate or missing events

- Events are hints. Every trigger runs the same idempotent reconcile, so a
  duplicate is a no-op.
- A missing event is covered by the reconcile that follows each tracker poll,
  and by a fallback timer (`build_queue.reconcile_interval_seconds`, 60).
- This is the "events are signals" rule of
  [../../contracts/events-and-replay.md](../../contracts/events-and-replay.md) §1.

### Restart recovery

On boot the Server:
1. Loads the store.
2. Resolves write intents with no recorded outcome by observing.
3. Re-derives every item's verdict from fresh observations, then reconciles.

The process is level-triggered, so a crash between a write and its record
converges. If the store is lost or corrupt, the Server fails closed (no writes)
and raises `system.queue.store_unavailable`. `aiur queue recover` rebuilds the
membership of open issues carrying the marker as one unordered ExecutorList,
with no edges, held, for the operator to re-order.

### Retries

- A failed write is retried with backoff (max 3 per reconcile). After 5
  consecutive failures for one item, raise
  `ticket.<id>.queue.attention.write_failed`.
- A GitHub budget hold or a secondary-limit backoff pauses all queue writes and
  shows `writes paused (github budget)`.

### Failed work and multiple prerequisites

Covered in §5.7. An item that is itself closed `not_planned` is shown as
`cancelled`. It counts as failed for its own dependents.

### Authorization

- The queue never changes `DispatchAuthorization`.
- If a promoted item's dispatch is denied as `unauthorized` (a decline on the
  dispatcher's own decision), the item shows `promoted (unauthorized)`. One
  attention names the item and says that a human must triage it, for example by
  applying the marker or `agent:todo` themselves.

### Agent-originated mutations

- Queue mutations are **operator surface only**. `aiur queue` mutations through
  the control RPC are refused inside agent workspaces, using the guard that
  blocks `--test` there (AGENTS.md "Driving the TUI"; RQ-6).
- Even without the guard, a daemon-applied marker confers no triage under a
  strict `allowed_users`. Under the default CODEOWNERS fallback, the daemon is
  already trusted (F1), so the queue adds no new authority path.

### Multiple devices and clients

Not applicable to writes in v1. Mutations come from the CLI on the machine.
Mobile only reads progress (contract §4).

### Privacy

- The store holds issue numbers, order, edges, intents and latches. No titles or
  bodies are stored.
- The CLI and dashboard fetch titles from existing projections at render time.

---

## 7. Acceptance criteria (feature level; each maps to tests in chunks.md)

- AC1. With an ExecutorList `[A, B after A]`, only A gets `agent:todo`. When A
  closes as completed, B gets `agent:todo` within one reconcile, with no
  Executor action.
- AC2. Three items become ready in one reconcile. All three are labelled in one
  pass. With one free slot, the dispatcher starts the one with the most open
  downstream items. A tie goes to the lower `priority:N`, then the older ticket.
- AC3. A prerequisite moves to `agent:error`. Its dependents stay unlabelled, and
  exactly one attention names it and all of them. A restart does not re-fire it.
  Clearing the error resolves it.
- AC4. A new edge is added to a promoted, unclaimed item. The item loses
  `agent:todo` and keeps the marker. The zero-label heal does not re-add the
  label on the next poll.
- AC5. The same change on a claimed item (running with only `agent:todo`) writes
  nothing and raises the attention.
- AC6. With the ClaimProbe unavailable, AC4's case writes nothing and keeps the
  hold.
- AC7. If the Executor removes `agent:todo` from a promoted item, the queue never
  re-adds it until `aiur queue release`.
- AC8. With `build_queue.enabled: false`, or with an empty queue, dispatch order
  and GitHub API calls are byte-for-byte the current behaviour (the sort-key
  mutation test).
- AC9. A stale Build Order snapshot causes no write.
  `aiur queue show --json` reports `freshness: stale` with `age_ms`.
- AC10. A duplicated `pr.merged` delivery causes no duplicate write. A missing one
  is recovered on the next poll-triggered reconcile.
- AC11. Kill the daemon between write intent and outcome, then restart. The
  queue converges with no duplicate label, and every item ends in the state
  observation implies.
- AC12. End to end, through `aiurdev --test` in the wrapper tmux (AGENTS.md
  "Manual testing"): a two-item queue promotes its second item after the first
  merges, and the TUI agent list shows the second agent start.

## 8. Risks

| Risk | Mitigation |
| --- | --- |
| Rollback to a release without the `queued` marker: the marker parses as a state, so `agent:todo` + `agent:queued` is denied as contradictory and swaps strip it (F1) | C1 (marker registration) ships one release ahead of any marker write; rollback runbook: `aiur queue clear --remove-markers` before downgrading |
| Promotion races a human relabel and forms a state pair; the heal makes `todo` win (`issue_sync.ex:41-58`) | Freshness check before writing (§5.4); RQ-4 conditional add |
| `dispatch_policy.ex` and `issue_sync.ex` are over 500 lines (U8 size debt) | C1 adds no more than ~30 lines to each and records the `Size-owner` |
| Label write volume | ≈ 1 add per promotion, plus withdrawals; paced (§5.4). No saving is claimed |
| Two writers of `agent:todo` (the queue and `--todo`) | §5.8 overrides; docs for `--todo --only` say it holds queue items |

## 9. Open questions

**Owner (Kevin; also in DESIGN-E1):**
- OQ-1. Where list position sits in the rank key (recommend: after priority,
  before age).
- OQ-2. Does `not_planned` fail a prerequisite (recommend: yes) or satisfy it
  (the dispatcher's view today)?
- OQ-3. Should parked or paused items be promoted when ready (recommend: no)?
- OQ-4. The marker label name (recommend `agent:queued`; note that `units
  --condition queued` already means todo, F9).
- OQ-5. Should "after #N" edges also be written as GitHub dependencies (A4;
  recommend no for v1)?
- OQ-6. Default for `build_queue.enabled` (recommend `true`; an empty queue costs
  nothing).
- OQ-7. Should the aiur-build and aiur-run conventions change to "create
  waiting members with `agent:queued`", and should adopting a pre-labelled Build
  Order withdraw `agent:todo` from its blocked members (recommend yes and yes)?

**Research (Phase C):** RQ-1 to RQ-9 in [chunks.md](chunks.md).

## 10. Plan refresh (after MP-R1..R7)

| Now (pre-refactor) | After refactor | Trigger |
| --- | --- | --- |
| `src/lib/aiur/build_queue/**` in the core app | `build-queue` component package (R1 map: "core now; package after R1") | MP-R1 carve step for L3 features |
| `Aiur.BuildQueue.Hints` read in `orchestrator/dispatch_policy.ex` | Read in the `aiur_dispatch_policy` package; the hint port becomes a published interface | R1 orchestration split (prior boundaries ORC/DSP #12–13) |
| `ClaimProbe` impl in `orchestrator/` | Moves with orchestration; same behaviour | Prior unit U2 ("who owns the authoritative ticket transition") must name the queue as the owner of the marker-only ↔ todo transitions |
| `attention.ex` calls `Aiur.Alerts` | Calls `Signal.emit/2` (R1 plan-refresh row PR-07) | Signal port lands |
| In-BEAM `Exchange.subscribe` for hints | Same API from the `aiur_events` package; optionally a durable consumer cursor (events contract §7.1) | MP-R2 C3 |
| Progress milestones as ledgered alerts/events | `exported` topics in the R2 catalog | MP-R2 C5/C6 |
| `Aiur.GitHub.*` observation through the Tracker adapter | Unchanged interface; GitHub moves to `aiur_github` | Prior unit U5 |

Prior references for tickets:
- `Prior-units: U2, U3, U5`
- `Prior-boundaries: BO #30, ORC #12, DSP #13, CLI #31, WEB #34, BUS #10`
- `Size-owner`: the U8 package owning `dispatch_policy.ex` and `issue_sync.ex`
  (look up in `synthesis/u8-release-007/assignments.csv` at C1 time).
