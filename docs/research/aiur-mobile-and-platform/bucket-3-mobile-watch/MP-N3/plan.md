---
artifact_contract: ce-unified-plan/v1
artifact_readiness: planned-with-blockers
feature_id: MP-N3
base_main_sha: 45a290e3
date: 2026-10-06
bucket: 3 (mobile and watch)
owner_gate: DESIGN-N3
owned_contracts: [contracts/pairing-and-instance-registry.md §7 (per-instance summary), shared with MP-N2]
---

# MP-N3 — Phone meta-dashboard of instances: Plan

## Goal capsule

- **Outcome:** the phone app's top level is a list of aiur instances across every
  paired machine. Each row shows the repository, active agents, Executor state, the
  Commands-awaiting count, build-order progress when the instance has build orders,
  and Executor background agents when that is supported. Unavailable, stale and
  unreachable are visibly different from zero and from idle. Tapping a row opens
  that instance's dashboard. Executor chat is a secondary button. There is no
  combined inbox.
- **Not in scope:** the instance dashboard itself (existing, opened in a WebView per
  MP-N1); Executor chat (MP-E3); push and its badges (MP-N4/N5); watch layout
  (MP-N7 consumes the same data); the visual design (DESIGN-N3).
- **Blockers:** DESIGN-N3; MP-N2 (pairing, registry); MP-N1 (framework); MP-E3 for the
  Executor-chat target and background-agent data.

## 1. Repository findings (extends baseline §N3)

References at `45a290e3`.

- G1. **Commands count wording, verified.** The banner reads `"1 unit awaiting commands"`
  / `"#{open} units awaiting commands"` and its aria label is
  `"#{@open} Commands awaiting you, #{@blocking} blocking"`, with CTA `Issue commands`
  (`src/lib/aiur_web/components/operator_control_center/overview.ex:53,65,168-169`). The
  number is `retained_counts.awaiting`, not `open`: a Command deferred to the Executor is
  still open but no longer on the operator's queue (`overview.ex:37-44`). "Commands
  requested" and "commands needed" do not exist (baseline §4.3).
- G2. The counts come from `Aiur.DecisionQuery.counts/1`
  (`src/lib/aiur/decision_query.ex:76-96`). If the store is unavailable, every count is
  `nil` with an unavailable health, and the dashboard already renders a distinct
  "**Command counts unavailable.**" state, plus "**Partial Command counts.** Counts are at
  least this high." for partial health (`overview.ex:79-89`). `awaiting = open - deferred`,
  `awaiting_blocking = blocking - deferred_blocking`
  (`decision_store/retained_index.ex:86-93`). MP-N3 reuses these semantics exactly.
- G3. **Active agents** = `length(snapshot.running)` in `Presenter.state_payload`
  (`src/lib/aiur_web/presenter.ex:41-58`) from `Orchestrator.dashboard_snapshot/2`
  (`orchestrator.ex:684`), which returns `{:current | :stale, snapshot, freshness}`,
  `:snapshot_unpublished` or `:orchestrator_unavailable` (`presenter.ex:24-35`). Stale
  is load-aware (`orchestrator/snapshot_store.ex:21-50`). The dashboard deliberately does
  not alarm on `snapshot_unpublished` after a restart (`overview.ex:136-142`). The fleet
  strip labels are Active, Blocked, Paused, Stuck, Finished, Total (`overview.ex:8-15`).
- G4. `/api/v1/state` is the whole fleet (running, retrying and idle entries, capacity,
  polling, history, merges, analytics; `presenter.ex:41-80`). It is too heavy for a
  per-row poll across N instances and includes ticket detail that does not belong in a
  list. A dedicated summary is needed (contract §7).
- G5. **Executor state** exists as `Aiur.Executor.Roster.build/1`
  (`src/lib/aiur/executor/roster.ex:50-67`) with states `active | idle | stalled |
  expired | unknown`, derived only from positive evidence (moduledoc `roster.ex:2-34`).
  `build/1` records an observation by default; a read-only summary must pass
  `record?: false`. Multiple Executors are a supported configuration (`roster.ex:6`),
  so the summary needs an aggregation rule. Executor harness and conversation do not exist
  (baseline E3).
- G6. **Build-order progress** is per root: `RootSummary.progress` (0–100 or nil) and
  `progress_resolution` `:resolved | :partial | :unresolved | :unknown`
  (`build_order/root_summary.ex:6,21-22`), listed by `GraphProjection.catalog/1`
  (`build_order/graph_projection.ex:44`). An instance can have many roots; up to 32
  selected by default (`graph_max_selected_roots`, `config/schema/build_order.ex:39`). There is no single
  "instance build-order %".
- G7. **Background agents:** no data source (searched `subagent|background.agent|background_task`
  in `src/lib`; only `claude/telemetry/contract.ex` matched, which is telemetry naming,
  not an agent list). It must render as unavailable until MP-E3 supplies it.
- G8. **Instance dashboard routes** that a row or button can deep-link to: `/`,
  `/commands`, `/commands/:decision_id`, `/build-orders/:root_number`
  (`router.ex:139-148`). There is no Executor route yet (MP-E3).
- G9. The dashboard already has a value-free degraded pattern for absent data
  (`FinancialDataAccess.locked_capability/0`, `financial_data_access.ex:143-152`), and
  prior research decided "typed complete / held / unknown outcomes with observed age and
  cause" (KTD4; baseline existing-refactor-research §5.1 item 7). AGENTS.md requires that a
  computed age is rendered and that collapsed causes become `:unknown`, never a specific cause.

## 2. Proposed boundaries

| Component | Responsibility | Interface | Required deps | Optional deps |
| --- | --- | --- | --- | --- |
| `Aiur.InstanceSummary` (in each instance) | Build the v1 summary from existing read models, never mutate | `v1/0 → map` over control RPC (contract §7) | none beyond the instance's own read models | orchestrator, DecisionStore, Roster, build orders, E3 (each degrades to a Fact status) |
| Gateway summary fan-out (MP-N2 gateway) | Call `v1/0` on each live instance with a timeout, cache 5 s, attach to `GET /v1/instances?include=summary` | contract §6.3 | MP-N2 gateway | — |
| App meta-dashboard module (phone, framework per MP-N1) | Multi-machine list, per-row states, navigation, refresh, offline cache | app-internal; reads only `aiur.machine/v1` | MP-N2 client | MP-E3 chat target, MP-N4 for background freshness |
| Shared view model (`MetaRow`) | Pure mapping from InstanceEntry to display states, reused by the watch (MP-N7) | pure function, fixture-tested | — | — |

Prior refs: Prior-boundaries `PRJ` #28 (projections) for the summary, `EXE` #26 (roster),
`BO` #30, `DEC` #27, `WEB` #34. Prior-units: U6 owns `decision_store.ex` and
`src/lib/aiur_web/`; the summary only calls public reads, so it adds no U6 conflict.

## 3. Alternatives and recommendation

**Data path.**

| Option | Verdict |
| --- | --- |
| Phone polls every instance's `/api/v1/state` | Rejected: heavy (G4), needs every instance reachable, fails for `--no-dashboard` |
| **Gateway aggregates `InstanceSummary.v1` over RPC; phone polls the gateway (recommended)** | One request per machine; works without dashboards; one place for freshness |
| Event stream (SSE or WebSocket) from the gateway | Later improvement once MP-R2 offers an external subscription API; the data shape stays the same |

**Refresh.** Pull on app foreground and on pull-to-refresh; poll every 15 s while the list is
visible; stop when backgrounded. Background freshness comes only from MP-N4 notifications,
which may carry a hint to refetch; the app never relies on background fetch (brief N4).
The gateway caches each instance summary for 5 s so several devices do not multiply RPCs.

**Executor-state aggregation** (multiple consumers): `active` if any is active; else
`stalled` if any is stalled (the case that matters, roster moduledoc); else `idle`; else
`expired`; `none` when there are no claims; `unknown` otherwise. Rejected: "most recent
consumer wins", which can hide a stalled one.

**Build-order % with several roots.** Recommend: show the count of open build orders and
the progress of the most recently active one, with resolution shown when not `:resolved`.
This is an owner design decision (DESIGN-N3 Q3), not settled here.

**Executor chat entry.** A secondary button per row that opens the instance's Executor
surface (MP-E3 route). Hidden when the instance's capability list lacks
`executor_conversation`; never replaced by Remote Control links.

## 4. Contracts

**Owned (with MP-N2):** contract §7 per-instance summary: field list, Fact envelope,
aggregation rules, size budget.

**Consumed (assumptions):**

- MP-N2 registry, states and auth (contract §1–§6), same pack.
- MP-R1 capability list per instance, including `build_orders`, `commands`,
  `executor_roster`, `executor_conversation`, `background_agents`.
- MP-E2: "awaiting" remains the operator-owned count after E2's routing changes. If E2
  introduces Executor-first windows, the count still means "Commands the human owns now".
  Coordinator to confirm with the E2 planner.
- MP-E3: provides `executor.harness`, `executor.conversation_available` and
  `background_agents` (count, plus a state) as optional summary fields, and an instance
  route for Executor chat.
- MP-E1: build progress semantics. Until E1 publishes, read `RootSummary` directly.
- MP-N1: list screen native or WebView. Recommendation to N1: native, because the list
  spans several machines and must work while every instance is unreachable; the instance
  dashboard itself stays a WebView.

## 5. States and non-happy paths

Each row state is computed by the shared `MetaRow` mapping, in this priority:

| Row state | When | Shows |
| --- | --- | --- |
| Machine unreachable | Phone cannot reach any gateway endpoint | Last-known values greyed, with "last seen <age>"; no zeros |
| Gateway offline | Endpoint reachable, gateway down (connection refused on its port) or `401 device_auth_disabled` | Machine header message; rows from cache with age |
| Device removed | `401 device_revoked` | Machine moved to a "removed" section; cached data wiped |
| Instance crashed / stopped | Registry state | Row dimmed, reason, age; not counted in machine totals |
| Instance stale | Registry `stale` or summary older than 2 poll intervals | Values with age badge |
| Summary unsupported | Older instance release | Identity only, plus "update aiur on this machine" |
| Live | Fresh summary | Values; each Fact individually may still be unavailable or disabled |

Per-field rules: `unavailable` shows an explicit "—" with an accessible reason, never 0;
`disabled` (capability absent, for example no build orders) hides the field; a Commands
count with `lower_bound` shows "≥ N"; active agents with `globally_paused` shows paused,
not idle; `snapshot_unpublished` right after a restart shows "starting", not an error
(matching G3).

Other paths: duplicate repositories (two clones) are disambiguated by root basename;
an instance key change after a repo move shows the old row as stopped and the new one as
live; several devices see the same gateway cache; there are no write actions on this
screen, so there are no conflicting responses here. Privacy: the summary contains counts
and identifiers only (contract §7 budget), so a cached list on a lost phone reveals
repository names and counts, not Command text; the cache is cleared on revoke.

## 6. Acceptance criteria

1. With a fixture gateway returning one live, one stale, one crashed and one
   summary-unsupported instance across two machines (one unreachable), the list renders
   five distinct, labelled row states, and no numeric field renders `0` unless the source
   Fact is `available` with value 0. (Mutation: map `unavailable` to 0 and the test fails.)
2. The Commands figure equals `DecisionQuery.counts/1` `awaiting` for that instance; a
   deferred-to-Executor Command does not increase it; `health: partial` renders "≥ N"; a nil
   count renders the unavailable state, worded consistently with "Command counts unavailable".
3. `InstanceSummary.v1/0` calls `Roster.build(record?: false)`; a test asserts that the
   roster's observation file is unchanged after a summary read.
4. An instance without build orders shows no build-order field; one with two open roots
   follows the DESIGN-N3 rule.
5. Tapping a live, reachable row opens its dashboard at `/` through the MP-N2 device-session
   bootstrap; a row whose `dashboard.reachable_for_devices` is false shows the reason
   instead of opening.
6. The Executor-chat button is absent when the capability is absent and present otherwise;
   no combined inbox exists anywhere in the app (no screen lists Commands from more than one instance).
7. A summary payload for a fixture instance with 30 running agents and 10 open Commands is
   under 4 KiB and contains no Command question text or ticket titles.
8. Polling stops within one interval of backgrounding the app (client test with a fake timer).

## 7. UX/UI → `owner-design-tasks/DESIGN-N3.md`

## 8. Decomposition

| Chunk | Outcome | Depends on | Candidate tickets | Test sketch |
| --- | --- | --- | --- | --- |
| **MP-N3-C1** Instance summary provider | `Aiur.InstanceSummary.v1/0` with Fact envelope for agents, fleet pause, Commands, Executor, build orders, capabilities; `background_agents` unavailable | MP-R1 capability list (or a local stub); none else | MP-N3-C1-T1 Fact type and envelope; T2 agents and pause from `dashboard_snapshot`; T3 Commands from `DecisionQuery.counts/1`; T4 Executor aggregation from `Roster.build(record?: false)`; T5 build-order roots from `GraphProjection.catalog/1`; T6 size budget and redaction test | Unit tests per source with injected providers for every degraded branch; mutation per unavailable branch (AGENTS.md); no real state read |
| **MP-N3-C2** Gateway fan-out | `GET /v1/instances?include=summary`, per-instance RPC timeout (2 s), 5 s cache, `unsupported` on `undef` | MP-N2-C4, MP-N3-C1 | T1 fan-out with bounded concurrency; T2 cache and `observed_at`; T3 version negotiation | Fake nodes: slow, down, old release; assert stale and unsupported mapping |
| **MP-N3-C3** `MetaRow` view model | Pure mapping InstanceEntry → row state and field display, shared with MP-N7 | contract only | T1 state priority table; T2 per-field rules; T3 fixtures as JSON shared with the gateway tests | Table-driven; mutation: collapse two states and a test fails |
| **MP-N3-C4** App meta-dashboard screen | Multi-machine list, machine sections, row tap → dashboard, secondary Executor chat button, refresh policy, offline cache | MP-N1 app shell, MP-N2-C5 client, MP-N3-C3, **DESIGN-N3** | T1 machine sections and empty state; T2 row rendering per DESIGN-N3; T3 navigation to dashboard via device session; T4 Executor chat button gated by capability; T5 refresh and backgrounding; T6 encrypted-at-rest cache cleared on revoke | Component tests with fixtures; device tests on iOS and Android |
| **MP-N3-C5** Synthetic multi-instance fixture | A script that runs a fake gateway with scripted instance states, for UI work and the parity check without live agents | MP-N3-C3 | T1 fixture server; T2 scenario files | Used by C4 tests and design review |

Order: C1 → C2 → C3 (C3 can start in parallel from the contract) → C5 → C4.

## 9. Open questions

**Owner (DESIGN-N3):** row content order and density; how stopped instances appear and
for how long (shared with OQ-N2-6); build-order rule for several roots; whether rows are
grouped by machine or merged and sorted by urgency (sorting by Commands count is allowed;
a combined inbox is not); whether the app badge shows the sum of Commands awaiting (a count,
not an inbox; decide with DESIGN-N5).

**Research (Phase C):**

- RQ-N3-1 RPC cost of `InstanceSummary.v1/0` on a busy instance (the dashboard snapshot read timeout is 15 s,
  `snapshot_timeout_ms`, `http_server.ex:67`; the summary needs a much smaller budget).
- RQ-N3-2 Whether `GraphProjection.catalog/1` can be called cheaply when build orders are
  configured but not yet loaded; what "disabled" means in config terms (no build-order
  labels or no projection child).
- RQ-N3-3 Whether E2's routing changes alter `awaiting` (coordinate with the E2 planner).
- RQ-N3-4 The polling interval against battery use on the target devices.

## 10. Plan-refresh note

After MP-R1: `Aiur.InstanceSummary` belongs in the projections package (`PRJ` #28) or a thin
module in the composition root; its reads become calls to the public interfaces of the
`aiur_decisions`, `aiur_executor` and build-order packages rather than module internals. If
MP-R2 adds an external subscription API, MP-N3-C2 may switch from polling to a stream
without changing the summary shape. If MP-E3 adds an Executor route, MP-N3-C4-T4 takes that
path from the capability entry, not a hard-coded URL.
