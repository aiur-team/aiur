---
artifact_contract: ce-unified-plan/v1
artifact_readiness: planned-with-blockers
feature_id: MP-R1
bucket: 1-refactor
base_main_sha: 45a290e3
date: 2026-10-06
owner_gate: DESIGN-R1
owns_contracts: [MP-CT-identity-and-capabilities]
owns_deliverables: [MP-REQ4]
---

# MP-R1 — Modular platform and component map

## Goal capsule

- **Objective.** Extend the prior refactor research (U0–U9, the 40-proposed /
  36-measured boundary survey, the SCC finding, the size ledger) into one component
  map that also covers the components this pack adds, with public interfaces,
  required vs optional dependencies, config ownership, a capability matrix, minimum
  companion requirements, a client capability-detection contract, and a migration
  plan with a plan-refresh task. Also deliver the public component directory page
  (MP-REQ4), live after the refactor (D20).
- **Not a second architecture.** Every component maps to a prior boundary or is
  marked new. KTD3/KTD11 stay: logical components first, physical packages only by
  the promotion test.
- **Behaviour.** No user-facing change, except the directory page (public docs) and
  two additive read-only surfaces (`GET /api/v1/capabilities`, `aiur capabilities`).
  Their bucket classification is coordinator question CQ1 (§10).
- **Blockers.** DESIGN-R1 (directory page, confirmation of no user-facing change);
  MP-R2 event contract for `system.capabilities.changed`; MP-N2 for paired-device
  auth on the capability endpoint.

Companion files:

| File | Content |
|---|---|
| [component-map.md](component-map.md) | Components, layers, dependency rules, facades, deps, config ownership, build-queue seam |
| [capability-matrix.md](capability-matrix.md) | Capability IDs, what works without each component, minimum combinations, companion requirements |
| [migration-plan.md](migration-plan.md) | Ordered steps reconciled with prior §7 and U-units, path map, promotion test |
| [component-directory.md](component-directory.md) | MP-REQ4 page design and sync check |
| [../../contracts/identity-and-capabilities.md](../../contracts/identity-and-capabilities.md) | Owned contract |
| [../../owner-design-tasks/DESIGN-R1.md](../../owner-design-tasks/DESIGN-R1.md) | Owner gate |

## 1. Repository findings (extending the baseline)

Baseline facts in `baseline/capability-baseline.md` R1 and
`baseline/existing-refactor-research.md` §2 are not repeated. New, verified at
`45a290e3`:

1. **The run shape is already a composition switch.** `Aiur.Application.child_specs/1`
   (`src/lib/aiur.ex:244-486`) takes `interactive_cli?`, `headless?`, `dashboard?`,
   `telemetry?`, `executor_mode?`, `recording?` and is pure "so the gating is
   unit-testable". It is the natural seed of a capability registry.
2. **`--no-dashboard` removes the HTTP listener, not only pages.** `dashboard?` gates
   `Aiur.HttpServer` (`aiur.ex:469`), so the Stream Deck socket, voice socket, the
   Supervisor Decision API and the Remote Control hook all go with it
   (`endpoint.ex:14-27`, `router.ex:81-97,172-183`). A "web-shell vs dashboard-ui"
   split is needed before any client can have the API without the pages.
3. **Typed absence already exists in one place.** `Presenter` returns
   `snapshot_unpublished` / `orchestrator_unavailable` and a stale freshness block
   (`src/lib/aiur_web/presenter.ex:24-33,58`). The capability contract generalises
   this instead of inventing a new style.
4. **Route order matters.** `get("/api/v1/:issue_identifier", …)` at `router.ex:193`
   catches any unknown `/api/v1/<x>` GET; `/api/v1/state` is declared just before it
   (`:189`). A new `/api/v1/capabilities` must be declared above line 193.
5. **No machine identity exists.** Searches for `machine_id`, `host_id`,
   `/etc/machine-id` in `src/lib` and `packaging` are empty. Instance identity exists
   only launcher-side (`aiur-engine.sh:269-277`); the Executor consumer id falls back
   to `<hostname>-<instance>` (`executor/claims.ex:185-195`).
6. **Config is one root with 20 embedded sections** (`config/schema.ex:52-71`); the
   only mechanical docs check is `scripts/check-config-docs.py`, in the required
   `lint` job (`ci.yml:262`), skipped on docs-only PRs (`ci.yml:260`).
7. **The docs build only runs on `website/**` changes** (`.github/workflows/website.yml`
   `on.paths`). The Aiur sidebar is `config.ts:126-170`.
8. **Build orders do not reach dispatch.** No file under
   `src/lib/aiur/orchestrator/` references `Aiur.BuildOrder`, which makes
   build-orders optional without behaviour change and lets MP-E1 depend on it
   optionally.
9. **Components the prior survey does not cover:** the Muse backend
   (`src/lib/aiur/muse/`, 18 files, 1,620 lines), `AllowedContributors`
   (`src/lib/aiur/allowed_contributors*`, started last in the tree, `aiur.ex:480`), and
   everything new in this pack (build queue, listener modes, pairing, push, mobile,
   watch, conversational voice, client contracts).
10. **The Stream Deck package still has a compile-time link into core:**
    `AiurWeb.StreamdeckKeyFaceContract` reads `packages/streamdeck/src/key-face-contract.json`
    via `@external_resource` + `File.read!` (`streamdeck_key_face_contract.ex:11-12`).
    MP-R6 owns breaking it; R1's checker records it as an allowlisted L4→L5 edge.
11. **Prior art for a boundary checker in the sibling product:** Khala's
    `scripts/check-boundaries.mjs` (Khala `d898e6b8`) walks TypeScript imports per
    workspace package and fails on forbidden edges. It covers the TS side (sidecar,
    contracts, mobile); the Elixir side needs a module-reference walk like the prior
    research's `tooling/module_references.exs` (branch-only; must be ported to `main`).

## 2. Proposed boundaries (summary)

Full table in [component-map.md §3](component-map.md). 41 components in six layers
(L0 foundation → L5 clients). Mapping to prior work:

| Group | Components | Prior-boundaries | Prior-units |
|---|---|---|---|
| Foundation, spine | kernel, config, event-bus, signal, identity (new) | K, CFG, BUS, #11 | U3 (bus), U6 (journal) |
| Domain | tracker, github, github-listeners, linear, agent-sandbox, workspace, harness-adapters, agent-runner, accounting, telemetry | TRK, GHC, GHB, GHR, GHD, ING, LIN, #17, WS, CA, CDX, CLD, OAI, RUN, PM, USG, TEL | U4, U5 |
| Features | orchestration, build-queue (new), build-orders, commands, executor-attention, projections, conversations, listener-modes (new), voice-stt, voice-conversation (new), pairing-discovery (new), push-relay (new), streamdeck-server | ORC, DSP, CTL, PRL, MSG, BO, DEC, EXE, PRJ, VOX, SD | U2, U3, U6 |
| Surfaces | web-shell, dashboard-ui (split of WEB), tui (+OC), control-cli, launcher, init | WEB, TUI, OC, CLI, #32, INI | U9 |
| Clients / packages | aiur-contracts (new), streamdeck-sidecar, mobile-app (new), watch-apps (new), aiur-style, docs-site, skills | SD, #39, #40 | — |

The build-queue seam that MP-E1 must follow is [component-map.md §4](component-map.md).

## 3. Alternatives considered

| Option | Verdict |
|---|---|
| **A. Logical components + manifest + ratcheting checker, physical packages by promotion test** | **Recommended.** Respects KTD3/KTD11 and the SCC finding; gives clients a contract now; each move is a reversible PR; the same manifest drives the directory page. |
| B. Umbrella app now, one Mix app per prior boundary | Rejected. The 35-boundary SCC means a big-bang split, and prior research says package count is not a success measure. |
| C. Separate repositories for clients and optional features now | Rejected for now. The brief says not to assume every module moves to its own repo; only the sidecar and the Khala-shared package have a second consumer. |
| D. No capability endpoint; clients infer from `/api/v1/state` fields and join errors (status quo) | Rejected. Makes "missing" indistinguishable from "zero" and from "broken", which brief N3 and AGENTS.md forbid. |
| E. Capability flags inside `/api/v1/state` instead of a new route | Rejected. `/api/v1/state` is an orchestrator snapshot that becomes an error object when the orchestrator is down (`presenter.ex:30-33`); capabilities must be readable exactly then. |
| F. Mobile app inside `website/` or as a PWA of the dashboard | Not R1's decision (MP-N1); R1 only fixes the boundary: a separate package depending on `aiur-contracts`. |

## 4. Key decisions (MP-R1-KD)

| ID | Decision | Reason |
|---|---|---|
| MP-R1-KD1 | A component is a manifest entry with paths, facades, deps and owned config/state/capabilities; physical packaging is separate. | KTD3, KTD11 |
| MP-R1-KD2 | One root `components.json` drives the dependency checker and the directory page. | No drift (MP-REQ4) |
| MP-R1-KD3 | Clients detect capabilities from `GET /api/v1/capabilities` / `aiur capabilities`, never by inference. | Brief R1; KTD4 |
| MP-R1-KD4 | The mobile app (and watch targets unless MP-N1 decides otherwise) is a separate workspace package `packages/aiur-mobile`, depending only on `packages/aiur-contracts`; the checker forbids imports from `src/`. | Brief R1 "prevent monolith internals leaking into clients"; repo convention puts the sidecar in `packages/` |
| MP-R1-KD5 | Split `web-shell` (endpoint, auth, JSON API, sockets) from `dashboard-ui` (LiveView pages). | Finding 2 |
| MP-R1-KD6 | Machine = one OS user's installation; `machine_id` random, stored in MP-N2's machine store `~/.config/aiur/machine/identity.json`, created at first boot (RC-ID-1). | Contract §1.1 |
| MP-R1-KD7 | Dependency violations are a ratchet (count only goes down), not a gate on day one. | 35-boundary SCC |

## 5. Contracts

**Owned:** `MP-CT-identity-and-capabilities` (draft in `contracts/`). Defines machine,
instance, repository, Executor, worker and session identifiers; the capability report
shape, reasons, versioning, freshness; client detection rules.

**Consumed (assumptions the coordinator must reconcile):**

| Contract | Owner | Assumption R1 makes |
|---|---|---|
| Events and replay | MP-R2 | Envelope carries `instance_id`; an external subscription can carry `system.capabilities.changed`; R2 decides which bus owns which fact (MP-Q5), and R1's map puts both `Aiur.PubSub` and `Events.Exchange` inside `event-bus`. |
| Command request and resolution | MP-E2 | Answer delivery can become a `decision.answered` event consumed by orchestration (prior #27), so `commands` does not depend on orchestration. Answer target is `session_ref` or ticket — E2 decides. |
| Conversations and anchors | MP-E4 | The neutral `conversations` component owns the anchor rule now in `StreamdeckLogs` (moved by MP-R6). |
| Build progress and queue readiness | MP-E1 | Build queue follows the seam in component-map §4 and registers `build_queue` capabilities. |
| Listener mode | MP-E7 | Package lives outside `src/` (MP-Q1); aiur consumes it through harness-adapters. |
| Harness capability callbacks | MP-R7 | Adapters expose remote-session, resume, interrupt and native-question capability callbacks; R1 surfaces them. |
| Pairing credentials | MP-N2 | Paired-device credential is accepted on the capability endpoint with machine-wide scope (D19). |
| Notification payload | MP-N4 | Relay-visible fields use `machine_id`/`instance_id` only. |

## 6. Non-happy paths

| Case | Handling |
|---|---|
| Optional component absent | `unavailable: not_installed`; surfaces hide or disable with the reason; never 0/empty |
| Optional component configured but broken | `degraded` or `unavailable: not_running`; one attention via the signal port |
| Orchestrator down | Capability endpoint still answers (it does not read the orchestrator mailbox); Commands `degraded` (recorded, not delivered) |
| Stale data | `observed_at`/`age_ms`/`freshness` on the report; clients keep `unreachable`, `stale`, `unavailable` distinct |
| Restart | `revision` must not go backwards (contract §4); clients refetch on reconnect |
| Duplicate instances (same repo, two roots) | Distinct `instance_id`, shared `repository` |
| Multiple devices | Capability report is per instance and identical for every authorized client; no per-device state in it |
| Conflicting writes | Out of scope for capabilities; every write path keeps its own gate and optimistic version (`expected_version` for Commands) |
| Privacy | Report has no paths, ports, tokens, hostnames beyond the operator-chosen `label`; `machine_id` is random, not hardware-derived |
| Checker false positive blocks a PR | Allowlist entry with reason in the same PR, reviewed like `check-config-docs.py`'s `EXEMPT` |
| Manifest drift | `check-components.py` in the required `lint` job and in `website.yml` guards |

## 7. Acceptance criteria

1. Every source file under `src/lib`, `packages/`, `packaging/` belongs to exactly one
   manifest component (checked).
2. The checker fails on a new reference to a private module of another component, a
   new upward-layer edge, a required→optional edge, or a `packages/aiur-mobile` /
   `packages/aiur-contracts` import from `src/`; each rule has a failing fixture.
3. The violation count at merge of each MP-R1 PR is ≤ the count before it.
4. `aiur capabilities --json` and `GET /api/v1/capabilities` return the contract v1
   shape in every run shape (`--bg`, `--no-dashboard` for the CLI, foreground,
   `--executor`), and report `orchestration: unavailable/not_running` while the
   orchestrator is stopped (test kills it).
5. Removing the ElevenLabs key flips `voice.stt` to `unavailable/not_configured`
   without changing any other capability; text chat still works (existing tests).
6. With no build-order root, `build_orders.progress` is `unavailable` and the meta
   fields that depend on it are absent, not 0 (contract test on the JSON).
7. `/api/v1/capabilities` is not shadowed by `/api/v1/:issue_identifier` (router test).
8. Every config section has exactly one owner component in the manifest, and
   `check-config-docs.py` still passes after schema registration.
9. The directory page builds from `components.json`, lists every non-planned component
   and every planned entry, and fails CI when a manifest docs link is broken.
10. Foreground `scripts/aiurdev --test` acceptance (AGENTS.md manual testing) shows no
    TUI or dashboard change after each move step.

## 8. UX/UI

No user-facing change is intended for the runtime. Configuration and setup UX do not
change (`.aiur/config` keys keep their names; only the owning module changes). The
directory page is new public content. Both go through
[DESIGN-R1](../../owner-design-tasks/DESIGN-R1.md); C10 is blocked on it.

## 9. Decomposition

Ticket IDs follow `MP-R1-C<n>-T<m>` (assignment instruction; the baseline's
`MP-R1.C1.T01` dotted form is the same identity). Every implementation ticket is
blocked on DESIGN-R1 (MP-REQ2); C10-T4 additionally on its page design.

### MP-R1-C1 — Manifest and dependency checker
- **Outcome:** `components.json` + schema describing today's code; `scripts/check-components.py`
  (Elixir module-reference walk + TS import walk) in the required `lint` job with a
  ratchet allowlist; `scripts/test-check-components.sh`.
- **Deps:** none. Cross-feature: **MP-E1 needs T3 in wave 0**, or ships its own source-scan test.
- **Tickets:** T1 manifest schema and initial manifest (all 41 components, today's paths);
  T2 Elixir reference walker ported from the research tooling; T3 rule set (private
  module, layer, required→optional, client→src) with build-queue rule first; T4 TS
  import walker for `packages/*` (Khala `check-boundaries.mjs` pattern); T5 ratchet
  allowlist and CI wiring; T6 checker self-tests with failing fixtures.
- **Tests:** fixture trees per rule that must fail; run against `45a290e3` to record the baseline count.
- **Research (Phase C):** exact baseline violation count at the implementation head;
  whether `mix xref` output can replace the custom walker; runtime of the check in CI.

### MP-R1-C2 — Identity
- **Outcome:** `Aiur.Identity` with `machine_id` (file, generation, reset path),
  `instance_id`, `repository`, executor state, `session_ref` helper.
- **Deps:** C1-T1. Cross: MP-N2 (reset verb, records), MP-E3 (executor harness fields).
- **Tickets:** T1 `machine/identity.json` creation at first boot (format per MP-N2) (0600, atomic write, corrupt-file handling,
  no silent regen); T2 daemon learns `instance_key` from the launcher (env var at
  boot) and composes `instance_id`; T3 `repository` from tracker config; T4 executor
  state projection from `Roster` + `Principal` incl. `absent`; T5 `session_ref` builder.
- **Tests:** corrupt/unreadable file, two OS users, empty instance key, moved root.
- **Research:** how the launcher passes `AIUR_INSTANCE_KEY` into the release today (or must start to).

### MP-R1-C3 — Capability registry, endpoint, CLI, client contracts package
- **Outcome:** `Aiur.Capabilities` registry fed by component callbacks and run-shape
  flags; `GET /api/v1/capabilities`; `aiur capabilities [--json]`;
  `system.capabilities.changed`; `packages/aiur-contracts` with JSON Schema for the
  contract and generated TS types.
- **Deps:** C2; MP-R2 for the event; MP-N2 for device auth (later ticket).
- **Tickets:** T1 registry + callback behaviour; T2 initial callbacks for existing
  components (orchestration, commands, build_orders, voice.stt, streamdeck,
  webhook_ingress, remote_control, executor.wakes, accounting.meters); T3 route
  (above `router.ex:193`) + controller; T4 CLI verb + `website/docs-app/reference/cli.md`
  entry; T5 revision persistence and change event; T6 `aiur-contracts` package and
  schema test; T7 docs: new `concepts` section on capabilities (docs ship with the change).
- **Tests:** per run shape; orchestrator killed; key removed; router shadowing; no
  secrets in payload (scan test).
- **Research:** whether `check-cli-reference.sh` needs a change for a new verb.

### MP-R1-C4 — Config ownership by registration
- **Outcome:** each component registers its section, validator, `Config.Paths` keys
  and env vars; root keeps `tracker`, `server`, `observability`, registry.
- **Deps:** C1. One ticket per section group so it can ride along with moves.
- **Tickets:** T1 registration mechanism keeping `embeds_one` reachability for
  `check-config-docs.py`; T2–T9 one per owner (workspace, orchestration, harness,
  commands, events, executor-attention, build-orders, voice/webhooks/upgrade).
- **Tests:** config round-trip of `.aiur/examples/config.example` unchanged; `check-config-docs.py` passes.
- **Research:** whether Ecto `embeds_one` can be composed at compile time from a registry, or the checker must learn registration.

### MP-R1-C5 — Kernel and signal port (prior §7 step 1)
- **Outcome:** journal primitive, `Bounded`, `MapAccess`, process-kill helper in
  kernel; `Signal.emit/2`; `Alerts`, `RunTelemetry.Lifecycle`, `Perf`,
  `ObservabilityPubSub` become consumers.
- **Deps:** C1; prior U6 (journal) first.
- **Tickets:** T1 journal primitive move; T2 `Bounded`/`MapAccess`/kill helper; T3
  `Signal.emit/2` + `Alerts` consumer; T4 telemetry consumers; T5 migrate callers in
  batches (≤ 1 boundary per PR).
- **Research:** behaviour proof that alert side effects (up to four files, three
  broadcasts per alert, prior §6) keep their order.

### MP-R1-C6 — Web-shell / dashboard-ui split
- **Outcome:** HTTP endpoint and JSON API can run without LiveView pages; optional
  components register routes and sockets.
- **Deps:** C3. Cross: MP-R5, MP-R6 (their sockets register here).
- **Tickets:** T1 router split with registration; T2 new run-shape flag distinct from
  `dashboard?` (CLI flag naming is a docs + DESIGN-R1 confirmation); T3 socket registration; T4 tests per shape.
- **Research:** whether a pages-off/API-on shape is wanted as an operator flag or only internally (DESIGN-R1 S4).

### MP-R1-C7 — Domain moves: tracker split, sandbox, workspace, GitHub family
- **Outcome:** prior §7 steps 3, 4, 5 executed as manifest moves.
- **Deps:** C1; prior U5 for GitHub. Cross: MP-R7 after sandbox.
- **Tickets:** T1 IssueTracker/CodeHost split; T2 adapter registration; T3 agent sandbox;
  T4 workspace; T5 GitHub umbrella component; T6 remove `Dispatcher` direct GitHub calls.
- **Research:** per-ticket recheck of prior findings at the implementation head.

### MP-R1-C8 — Feature components: Commands, projections, conversations, build orders, build queue
- **Outcome:** prior §7 steps 7–8 for these; `decision.answered` event; neutral
  conversations read API (with MP-R6); build-orders component; build-queue final shape.
- **Deps:** C5, MP-R2; prior U6. Cross: MP-E1 owner review for T5.
- **Tickets:** T1 Commands facade + event delivery; T2 projections component; T3
  conversations component (absorbs `LiveConversation`, `AgentEventFeed`, anchor rule);
  T4 build-orders component; T5 build-queue move + `Signal.emit`.

### MP-R1-C9 — Listeners and orchestration core (prior §7 steps 9–10)
- **Outcome:** `GitHub.Listeners` owns poll cursors; orchestration state fields have
  owners; `AgentControlCLI` split by component with per-component verbs.
- **Deps:** C7, C8, MP-R2; prior U2.
- **Tickets:** T1 listener supervisor + cursor move; T2 `PRHealthScanner`/`ReworkRequeue`
  out of core; T3 state-field owner table; T4 effects return; T5 CLI split.
- **Research:** U2 ticket-transition ownership (prior open question) must be closed first.

### MP-R1-C10 — Public component directory page (MP-REQ4)
- **Outcome:** [component-directory.md](component-directory.md).
- **Deps:** C1 (manifest); go-live after C9 and C11 final run; DESIGN-R1.
- **Tickets:** T1 public manifest fields and planned entries; T2 data loader + Vue
  table; T3 `check-components.py` docs rules + `website.yml` trigger/guard; T4 sidebar
  entry, AGENTS.md docs-table row, publish.

### MP-R1-C11 — Plan refresh
- **Outcome:** after each move merges, regenerate the path map
  ([migration-plan.md §4](migration-plan.md)) against the merged head and update every
  later-wave ticket's `Verified starting point` and contract versions; final run after C9.
- **Deps:** each move PR. Owner: coordinator or Executor, not an agent ticket alone.
- **Tickets:** T1 path-map generator from `components.json` history (git diff of
  `paths`); T2 per-wave ticket sweep; T3 final refresh before wave 2 (MP-E2) starts.

## 10. Open questions

**Owner (Kevin), in DESIGN-R1:** §1 confirm no runtime UX change; S1–S5 the operator
surfaces (capabilities verb, endpoint, machine identity file at first boot, an
"API without dashboard pages" run shape, docs); §3 Q1–Q8 the directory page (entry
fields, sidebar placement, grouping, how public planned features are, diagram,
Khala links, source links).

**Coordinator:** CQ1 classify C2/C3 (identity + capability endpoint) as Bucket 1
enablement or move them to a Bucket 2 feature — they add an API but change no
behaviour; CQ2 pull C1-T1/T3 into wave 0 for MP-E1's seam, or have E1 ship its own
scan test; CQ3 reconcile `session_ref` with MP-E2/E4.

**Research (Phase C):** RQ1 baseline violation count and checker runtime; RQ2 VitePress
loader reading outside the docs dir; RQ3 launcher→daemon instance-key handoff; RQ4
Ecto section registration vs checker change; RQ5 Muse and `AllowedContributors`
boundary placement confirmed by reference walk.

## 11. Plan-refresh note

R1 is the refactor others depend on. The path map in
[migration-plan.md §4](migration-plan.md) lists, per move, which later features'
tickets change (PR-01 … PR-16). MP-E1 precedes R1 and is moved by S13 (row PR-11).
Contract versions re-checked at each refresh: identity-and-capabilities, event
envelope (R2), Command payload (E2), conversation anchor (E4).
