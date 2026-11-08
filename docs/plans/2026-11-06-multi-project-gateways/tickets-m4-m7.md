# Tickets: M4 scheduler and shared intent, M5 Executors, M6 dashboard, M7 acceptance

Part of [the plan](../2026-11-06-multi-project-gateways.md). Conventions are in [tickets-m0-m1.md](tickets-m0-m1.md).
Paths are under `src/lib/aiur/` unless they start with `src/`, `packaging/` or `website/`.

---

## M4 — Local scheduler and optional shared intent

### Design the allocation and scheduling policy

- Plan id: MPG-401 · `lane:scheduler` · complexity 4 · kind: design (no research ticket) · depends on: none
- **Outcome.** `docs/research/MPG-401.md` fixes the algorithm the scope delegates: hard maximum vs flexible target,
  reservations, borrowing, preemption, fair share and named queues. It reads
  `docs/research/multi-gateway/priority-reconciliation.md` (borrowing prior art).
- **Acceptance.**
  - [ ] A pure function contract `allocate(capacity, demands, priorities, limits, running) -> grants` with types.
  - [ ] The scope's worked example (12 slots; A p1 max 3, B p2 max 5, C p3 max 8) gives A 3, B 5, C 4.
  - [ ] Rules for: no eligible work in a high-priority project (lower ones borrow), a promoted ticket (wins the next free slot, never preempts), hysteresis against oscillation.
  - [ ] At least ten table-driven cases with expected grants, ready to paste into MPG-402's test.
  - [ ] It keeps priority and allocation separate: no rule raises a limit because priority is high.
  - [ ] Focus rule (Kevin decided): the highest-priority feature is filled first so one feature finishes at a time, and any slot it cannot use goes to the next eligible feature or project; a case shows no slot idle while eligible work exists.

### Dispatch by cross-project priority within machine capacity

- Plan id: MPG-402 · `lane:scheduler` · complexity 3 · depends on: MPG-307, MPG-401, MPG-402R
- **Outcome.** `Aiur.Gateway.Capacity` grants slots in the order MPG-401 defines, using effective priority (shared
  intent when available, else `projects[].priority` and `build_order.feature_order`).
- **Next action.** Implement `gateway/allocation.ex` as the pure function from MPG-401 and call it from
  `gateway/capacity.ex` on every request and release.
- **Files.** `gateway/allocation.ex` (new); `gateway/capacity.ex`; test `src/test/aiur/gateway/allocation_test.exs`
  (MPG-401's cases verbatim); docs `website/docs-app/concepts/headroom-dispatch.md`.
- **Acceptance.**
  - [ ] **[fails without]** Every MPG-401 table case passes.
  - [ ] **[fails without]** Integration: two projects, priority A > B, both saturated: A fills to its max before B gets a slot; when A has no ready work, B uses all free slots.
  - [ ] A running agent is never stopped to make room (test asserts no stop calls).
- **Research MPG-402R** (complexity 2, depends on MPG-401).

### Decide conflict ordering for shared intent

- Plan id: MPG-403 · `lane:intent-sync` · complexity 3 · kind: design (no research ticket) · depends on: none
- **Outcome.** `docs/research/MPG-403.md` confirms or amends the rule set in the plan (section "Reconciliation"):
  slot precedence, HLC order, `supersedes`-based Executor takeover, skew hold, pause-wins tie, no republish.
- **Acceptance.**
  - [ ] A TLA+ or property-test model with three invariants: same change set gives the same state on every gateway; a daemon change never displaces a human or Executor value; applying a remote change emits nothing to the outbox.
  - [ ] A worked table of at least eight interleavings (concurrent human and Executor edits, skewed clocks, a late offline edit, a duplicate delivery) with the winner of each.
  - [ ] It names the answer to open question Q4 it assumed.

### Store shared intent changes with a local cache and outbox

- Plan id: MPG-404 · `lane:intent-sync` · complexity 3 · depends on: MPG-403, MPG-002, MPG-404R
- **Outcome.** Schema S4 exists in the coordination Postgres; each gateway keeps `intent/changes.ndjson`,
  `intent/registers.json` and `intent/outbox.ndjson` under its state root, and syncs when the store is reachable.
- **Next action.** Add the two tables to `instance/lease_store/postgres.ex` (same `CREATE TABLE IF NOT EXISTS`
  pattern) and create `intent/store.ex` (local files) and `intent/sync.ex` (push outbox, pull by `seq`).
- **Files.** above; `intent/hlc.ex` (new; persisted, never moves backwards); tests
  `src/test/aiur/intent/store_test.exs`, `src/test/aiur/intent/hlc_test.exs`, `src/test/aiur/intent/sync_test.exs`.
- **Acceptance.**
  - [ ] **[fails without]** A change written while the store is down is in the outbox; after reconnect it is in `aiur_intent_changes` exactly once.
  - [ ] Pushing the same change twice inserts one row (`ON CONFLICT (change_id) DO NOTHING`).
  - [ ] HLC after a restart with the wall clock set back 5 minutes is greater than the last persisted value.
- **Research MPG-404R** (complexity 2, depends on MPG-403).

### Reconcile shared intent deterministically

- Plan id: MPG-405 · `lane:intent-sync` · complexity 3 · depends on: MPG-404, MPG-405R
- **Outcome.** `Aiur.Intent.Reconciler.fold/1` computes each register from its changes as MPG-403 defines; applying
  remote changes never writes to the outbox; far-future changes are held and alerted.
- **Next action.** Implement `intent/reconciler.ex` as a pure fold over changes sorted by
  `(hlc_wall_ms, hlc_counter, origin_gateway, change_id)` only, applying the slot rules of the plan's
  "Reconciliation" section as each change is folded.
- **Settled.** Q4, decided by Kevin: an Executor overrides a human change only with explicit force and a reason naming it.
- **Files.** `intent/reconciler.ex` (new); `intent/sync.ex`; tests `src/test/aiur/intent/reconciler_test.exs`
  (MPG-403's interleaving table), a StreamData property test for order independence.
- **Acceptance.**
  - [ ] **[fails without]** Every MPG-403 interleaving gives its stated winner.
  - [ ] **[fails without]** Human H1, forced Executor E (supersedes H1), human H2: final value is H2. Forced E naming an older human change while H2 is current: H2 stays.
  - [ ] Property: any permutation of a change set folds to the same registers.
  - [ ] Pause: human unpause, then an Executor pause: effective value is paused.
  - [ ] A change 61 s ahead of local time is held, raises `system.intent.clock_skew` once, and applies when the clock passes it.
- **Research MPG-405R** (complexity 2, depends on MPG-403).

### Deliver gateway pause and pause-all durably

- Plan id: MPG-406 · `lane:intent-sync` · complexity 2 · depends on: MPG-405, MPG-406R
- **Outcome.** `aiur pause --all-gateways` writes register `fleet.pause` and calls every reachable gateway at once.
  An unreachable gateway applies it when it next syncs, before dispatching anything.
- **Next action.** In `orchestrator/global_pause.ex`, treat the effective pause as `local gateway pause OR
  fleet.pause register`; on boot, sync intent before the first dispatch when the store is reachable within 5 s.
- **Files.** `orchestrator/global_pause.ex`; `intent/registers.ex`; `engine/commands.sh` (`--all-gateways`); tests
  `src/test/aiur/intent/pause_delivery_test.exs`; docs `cli-operations.md`.
- **Acceptance.**
  - [ ] **[fails without]** Gateway offline when pause-all is set: on reconnect it reports `paused (fleet)` and dispatches nothing.
  - [ ] The command output lists each gateway as `paused now`, `will pause on reconnect`, or `unknown`.
  - [ ] Store down and gateway reachable: the direct call still pauses it.
- **Research MPG-406R** (complexity 1, depends on MPG-403).

### Publish full gateway workload in heartbeats

- Plan id: MPG-407 · `lane:dashboard` · complexity 2 · depends on: MPG-001, MPG-407R
- **Outcome.** Heartbeats publish `gateway_id`, `agent_count`, `agent_capacity`, `held_tickets`, `projects`,
  `public_url` and `executor_present`, so `/instances` and `gateway status` stop rendering them as unknown.
- **Next action.** Add the keys in `instance.ex` `heartbeat_metadata` (lines 223-240) from the orchestrator snapshot.
- **Files.** `instance.ex`; `orchestrator/instance_heartbeat_metadata.ex`; tests `src/test/aiur/instance_roster_test.exs`.
- **Acceptance.**
  - [ ] **[fails without]** A roster row for a fixture heartbeat shows `agent_count: 3`, not `unknown`.
  - [ ] A field the snapshot cannot supply is omitted, and the roster still renders `unknown` for it (test replaces it with `0` and fails).
- **Research MPG-407R** (complexity 1). Metadata size limit; field names shared with MPG-602.

### Alert once when a gateway goes offline

- Plan id: MPG-408 · `lane:dashboard` · complexity 2 · depends on: MPG-407, MPG-408R
- **Outcome.** A peer silent longer than `coordination.offline_after_seconds` (default 180) raises one push alert
  `system.gateway.offline` per outage; no alert on recovery; observers dedupe through the store when it is up.
- **Next action.** Add `gateway/liveness.ex` that reads the roster (store) or hello (direct) every 30 s.
- **Files.** `gateway/liveness.ex` (new); the machine `coordination:` schema from MPG-002 for the threshold;
  tests `src/test/aiur/gateway/liveness_test.exs`; docs `configuration-daemon.md`.
- **Acceptance.**
  - [ ] **[fails without]** Peer silent 4 minutes: exactly one alert; silent 2 minutes then back: none.
  - [ ] Back online then offline again an hour later: a second alert.
- **Research MPG-408R** (complexity 1). Alert channel (existing push) and dedupe key.

---

## M5 — Executors and delegation

### Delegate a ticket to another gateway through ownership

- Plan id: MPG-501 · `lane:executor` · complexity 3 · depends on: MPG-106, MPG-306, MPG-501R
- **Outcome.** `aiur ticket assign <n> --to pc --reason <r>` from Nook's Executor is the delegation. Before writing,
  `assign` reads PC's project list (S6 summary, or the last cached one). If PC lacks the repo, `assign` refuses (Q2
  decided). If PC is unreachable and has no cached list, `assign` writes the transfer and warns. The delegating
  gateway, which polls the repo, labels such a ticket `gateway-waiting:project-missing` when PC's list later shows
  the repo missing.
- **Settled.** Q2, decided by Kevin: refuse, or wait with a visible label; never auto-clone.
- **Next action.** Add the project-list check to `Aiur.Ownership.CLI.assign` and the waiting-label pass to the
  delegating gateway's poll in `ownership/projection.ex`.
- **Files.** `ownership.ex`; `orchestrator/dispatch_policy.ex`; tests `src/test/aiur/ownership/delegation_test.exs`;
  docs `website/docs-app/concepts/executor.md`.
- **Acceptance.**
  - [ ] **[fails without]** Assigning to a gateway whose summary lacks the repo exits 64 `pc does not run o/r`.
  - [ ] Transfer written while PC is unreachable, PC later reports no such repo: the delegating gateway adds the waiting label once.
  - [ ] While PC is offline, the assigned ticket stays owned by PC and Nook does not dispatch it.
- **Research MPG-501R** (complexity 1). Waiting-label name and clearance rule.

### Route Executor wakes by gateway and let one Executor claim a Decision

- Plan id: MPG-502 · `lane:executor` · complexity 3 · depends on: MPG-001, MPG-502R
- **Outcome.** Wake records and Decisions carry `gateway_id`; PR review wakes go to the gateway that ran the agent.
  A new per-Decision claim (`aiur executor-claim-decision <id> --as <executor>`) lets one Executor own an open
  Decision; others are refused. (Today's `executor-claim` claims the whole wake stream, not one Decision.)
- **Next action.** Add `gateway_id` in `executor_listener.ex` where records are built (line 311), then add
  `decision_store/claims.ex` with `claim/2`, `release/2` and a check in the answer path.
- **Files.** `executor_listener.ex`; `decision_store/` record module; tests `src/test/aiur/executor_listener_instance_test.exs`;
  docs `concepts/executor.md`.
- **Acceptance.**
  - [ ] **[fails without]** A wake from PC fetched with `--gateway all executor-wait --json` names `gateway_id` PC.
  - [ ] A second Executor's `executor-answer` on a claimed Decision is refused with the claimant's id.
- **Research MPG-502R** (complexity 1).

---

## M6 — Project-first dashboard

### Design the project-first dashboard and its browser sign-in

- Plan id: MPG-601 · `lane:dashboard` · complexity 4 · kind: design (no research ticket) · depends on: none
- **Outcome.** `docs/research/MPG-601.md` and annotated wireframes for the home screen (order from the scope),
  gateway view, cross-project queue grouping, unreachable states, pause controls and later drag-and-drop. It decides
  browser-to-daemon auth for Tailscale gateways and states the limitation for others.
- **Acceptance.**
  - [ ] Home layout in the scope's order; how 1,000+ tickets group, collapse and filter.
  - [ ] Separate connectivity (`online|offline|connecting|error|unknown`) and workload (`idle|active|saturated|paused`) states, with icon slots left for the separate icon work.
  - [ ] Auth: recommended flow for one sign-in across gateways, with CORS, Private Network Access / Local Network Access browser behaviour, and phone access.
  - [ ] A non-Tailscale gateway limitation section that does not change the decided browser-to-daemon architecture.

### Serve a gateway summary API the dashboard can read cross-origin

- Plan id: MPG-602 · `lane:dashboard` · complexity 3 · depends on: MPG-407, MPG-601, MPG-602R
- **Outcome.** `GET /api/v1/gateway/summary` returns schema S6 for every local project; the endpoint answers CORS for
  origins in `server.dashboard_origins` only, with the auth MPG-601 picked.
- **Next action.** Add the route in `src/lib/aiur_web/routes/api.ex` and `gateway_summary_controller.ex`; add a
  CORS plug limited to that route.
- **Files.** controller, `src/lib/aiur_web/dashboard_cors.ex` (new plug, beside `host_allowlist.ex`); `config/schema/server.ex`; tests
  `src/test/aiur_web/controllers/gateway_summary_controller_test.exs`; docs `configuration-daemon.md`.
- **Acceptance.**
  - [ ] **[fails without]** An OPTIONS preflight from a listed origin gets `Access-Control-Allow-Origin` with that origin; an unlisted origin gets none.
  - [ ] The payload's `observed_at` and `age_ms` are present for every project.
  - [ ] Write routes remain same-origin only (existing router test stays green).
- **Research MPG-602R** (complexity 2, depends on MPG-601).

### Show every project on one home screen

- Plan id: MPG-603 · `lane:dashboard` · complexity 3 · depends on: MPG-602, MPG-603R
- **Outcome.** The home screen lists projects, focus features, current agents, queue entry, gateway health and
  pending Decisions across all reachable gateways. An unreachable gateway shows `unreachable` with last-known age,
  and totals mark unknown parts.
- **Next action.** Add `src/lib/aiur_web/live/projects_home_live.ex` fed by a browser-side fetch of each gateway's
  summary (per MPG-601), mounted at `/` behind `dashboard.projects_home: true` (document the key in
  `website/docs-app/reference/configuration-daemon.md`). If MPG-601 picks a hosted aiur.dev page instead, MPG-603R
  restates the file list for that surface before work starts.
- **Files.** LiveView, its hook `src/priv/static/projects-home-hook.js`; browser test `src/browser/tests/projects-home.spec.mjs`.
- **Acceptance.**
  - [ ] **[fails without]** With one gateway stub down, the page loads in under 3 s and that gateway's card reads `unreachable · last seen 5m ago`.
  - [ ] Replacing the unreachable branch with `0 agents` makes the browser test fail.
  - [ ] Existing Build pages stay reachable from each project row.
- **Research MPG-603R** (complexity 2, depends on MPG-601).

### Add gateway views and pause controls

- Plan id: MPG-604 · `lane:dashboard` · complexity 2 · depends on: MPG-603, MPG-406, MPG-604R
- **Outcome.** A gateway view per gateway (agents, projects, capacity, local queue, health, connectivity) and
  gateway filters on the home screen; buttons for gateway pause and pause-all with a delivery report.
- **Files.** `src/lib/aiur_web/live/gateway_live.ex` (new); browser test `src/browser/tests/gateway-view.spec.mjs`.
- **Acceptance.**
  - [ ] **[fails without]** Pause-all with one gateway offline shows `will pause on reconnect` for it.
  - [ ] An online, idle gateway shows connectivity `online` and workload `idle` as two separate fields.
- **Research MPG-604R** (complexity 1, depends on MPG-601).

---

## M7 — MVP acceptance

### Prove the multi-project, multi-gateway MVP live

- Plan id: MPG-701 · `lane:acceptance` · complexity 5 (capstone: two live machines, outages) · depends on:
  MPG-109, MPG-210, MPG-308..311, MPG-402, MPG-406, MPG-408, MPG-501, MPG-502, MPG-604, MPG-701R
- **Outcome.** Recorded evidence for acceptance tests A1-A12 and G1-G10 (plan, section "Acceptance tests") on PC and
  Nook, with PC running a second project, including restart cost before and after.
- **Acceptance.**
  - [ ] Each test has its commands, redacted output and pass/fail in `docs/research/MPG-701-evidence.md`.
  - [ ] Daemon restart with `--keep-agents`: zero agents lost; minutes without dispatch measured and stated against the briefing's "20+ minutes".
  - [ ] Manual TUI and dashboard checks per `docs/manual-testing.md`, with screenshots of the unreachable gateway state.
- **Research MPG-701R** (complexity 2). Runbook: order, how to cause each outage safely (stop the store service, stop
  a daemon, block the peer port), how to count duplicates, expected values.
