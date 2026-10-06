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
  RC-12 settled their classification: Bucket-2 enabling work inside MP-R1 (CQ1, §10).
- **U0 gate (X-58, RC-19).** Every MP-R1 ticket waits for U0 review of the prior plan,
  because RC-19 keeps that gate for refactor work. This includes C2/C3 (Bucket-2
  enabling, RC-12), which ship in the refactor sequence. U0 has no ticket ID, so the gate
  is stated here, in migration-plan S0 and in the tickets READMEs; the MP-R1-C11-T02
  recheck does not replace it.
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

Baseline facts in `baseline/capability-baseline-bucket-1.md` R1 and
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
| Foundation, spine | kernel, config, event-bus, signal, identity (new), web-kit (new, RC-39) | K, CFG, BUS, #11 | U3 (bus), U6 (journal) |
| Domain | tracker, github, github-listeners, linear, agent-sandbox, workspace, harness-adapters, agent-runner, accounting, telemetry | TRK, GHC, GHB, GHR, GHD, ING, LIN, #17, WS, CA, CDX, CLD, OAI, RUN, PM, USG, TEL | U4, U5 |
| Features | orchestration, build-queue (new), build-orders, commands, executor-attention, projections, conversations, listener-modes (new, required send router, RC-36), voice-stt, voice-conversation (new), pairing-discovery (new), machine-gateway (planned, MP-N2), push-relay (new), notification-policy (planned, MP-N5), streamdeck-server | ORC, DSP, CTL, PRL, MSG, BO, DEC, EXE, PRJ, VOX, SD | U2, U3, U6 |
| Surfaces | web-shell, dashboard-ui (split of WEB), tui (+OC), control-cli, launcher, init | WEB, TUI, OC, CLI, #32, INI | U9 |
| Clients / packages | aiur-contracts (new), listener-spec (planned, MP-E7), relay-service (planned, MP-N4, `services/`), streamdeck-sidecar, mobile-app (new), watch-apps (new), aiur-style, docs-site, skills | SD, #39, #40 | — |

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
| Command request and resolution | MP-E2 | Answer delivery stays a synchronous call through a delivery-target port that orchestration implements (MP-R1-C8-T02); the `decision.answered` event is a wake-up only (Phase D, CR-C8-3). Answer target is `session_ref` or ticket — E2 decides. |
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

1. Every source file under `src/lib`, `packages/`, `packaging/` and `services/` (the
   MP-N4 relay service, X-29) belongs to exactly one manifest component (checked).
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
blocked on DESIGN-R1 (MP-REQ2); C10-T04 additionally on its page design.

Phase C refined chunks C1–C5 into 26 tickets: `tickets/MP-R1-C1-T01.md` …
`MP-R1-C5-T06.md`. Index, order and cross-chunk notes:
[tickets/README-C1-C5.md](tickets/README-C1-C5.md). The ticket files are authoritative
where they differ from the summary below.

### MP-R1-C1 — Manifest and dependency checker
- **Outcome:** `components.json` + `components.schema.json`; `scripts/check-components.py`
  (ownership, Elixir module-reference rules, TS import rule) in the required `lint` job
  with a per-component ratchet allowlist; `scripts/test-check-components.sh`.
- **Deps:** none. Cross-feature (RC-11): MP-E1 ships its own source-scan test in wave 0;
  T06 absorbs it.
- **Tickets:** T01 manifest, schema, ownership rule, CI wiring and self-test harness;
  T02 Elixir walker (ported, parse-only) + R-declared/R-private + allowlist; T03 R-down,
  R-optional, SCC report; T04 TS import walker + R-client + reverse `@external_resource`;
  T05 ratchet enforcement (stale entries fail, prune, growth guard, step summary);
  T06 build-queue seams and forbids, MP-E1 scan test deleted.
- **Phase C answers:** RQ1 — prior walker at `45a290e3`: 2.9 s wall, 1,111 modules,
  4,016 module edges, 2,140 cross-boundary and 339 upward edges on the prior 36-boundary
  map, one SCC of all 36; the 41-component baseline is recorded by T02/T03. `mix xref`
  rejected (file-level graph, needs a compile).

### MP-R1-C2 — Identity
- **Outcome:** `identity.json` created at first boot (RC-01) and `Aiur.Identity`
  (`machine`, `instance_key`, `instance_id`, `instance_section`, `identity` capability).
- **Tickets:** T01 machine store (no-clobber `File.ln/2` create, no silent regeneration,
  one attention when degraded); T02 facade and `instance_id`.
- **Changed in Phase C:** `repository` and executor state moved to C3-T02 providers
  (identity is L1 and must not reference tracker or executor-attention); the
  `session_ref` builder was dropped — MP-E4 owns `SessionRef` (CQ3 resolved).
- **RQ3 answered:** the launcher already exports `AIUR_INSTANCE_KEY` and the daemon
  already reads it; no launcher change.

### MP-R1-C3 — Capability registry, endpoint, CLI, client contracts package
- **Tickets:** T01 registry (provider behaviour, crash-proof ETS table, monitor, `boot_id`
  = `Aiur.Boot.run_id/0`, in-memory `revision`); T02 core providers; T03 endpoint,
  `capability_unavailable` encoder, concepts page; T04 `aiur capabilities` verb, aiurdev
  routing, CLI reference; T05 `system.capabilities.changed`; T06 `packages/aiur-contracts`
  with a cross-language golden test; T07 optional-component providers.
- **Changed in Phase C:** revision persistence replaced by `boot_id` + in-memory revision;
  the concepts page ships with T03 (docs ship with the change), so T07 now holds the
  optional providers.
- **Answered:** `check-cli-reference.sh` needs no change (it derives commands from the
  engine) and is not run by CI at base; `scripts/aiurdev` must list the verb or it boots
  a release.

### MP-R1-C4 — Config ownership by registration
- **Changed in Phase C (RQ4):** sections stay literal `embeds_one` lines (Ecto compile-time
  composition and `check-config-docs.py` both read them); ownership is manifest data,
  and the work is removing the 24 measured config-layer upward edges.
- **Tickets:** T01 registered semantic checks (`validate!/0`); T02 turn-sandbox root
  contributors; T03 accessor moves and pure helpers down (six edges; backend-catalog
  edges deferred to MP-R7); T04 env/global-config startup edges; T05 ownership data and
  O-config/O-env/O-state rules.

### MP-R1-C5 — Kernel and signal port (prior §7 step 1)
- **Tickets:** T01 `Aiur.DecisionLog` → kernel `Aiur.Journal` (after U6); T02 `Bounded` and
  process signalling to kernel, MapAccess/CoordinationTasks reassigned; T03 `Aiur.Signal`
  alert + refresh port, Alerts as sink; T04 lifecycle telemetry through the port,
  Perf/LogFile to `signal`; T05 alert emitters outside orchestrator (39 files, 69 sites);
  T06 orchestrator emitters (22 files, 91 sites).
- **Research answered:** side-effect order is preserved by construction — the port calls
  the sink synchronously in the caller's process (order listed in C5-T03).

Phase C refined chunks C6–C11 into 43 tickets: `tickets/MP-R1-C6-T01.md` …
`MP-R1-C11-T03.md`. The index, order and open items are in
[tickets/README-C6-C11.md](tickets/README-C6-C11.md). The ticket files are
authoritative where they differ from the summary below.

### MP-R1-C6 — Web-shell / dashboard-ui split
- **Outcome:** the HTTP endpoint and JSON API can run without the LiveView pages.
  Optional components add their own routes and sockets at compile time.
- **Tickets:**
  - T01: router composition through macros (not `forward`).
  - T02: socket registration.
  - T03: internal `dashboard_pages?` run shape (DESIGN-R1 S4 default: internal only).
  - T04: operator flag, blocked on S4.
- **Deps:** C1-T01, C3-T01. C6-T01 and C3-T03 both edit `router.ex`; merge C3-T03 first.
- **Size:** U8 rule: `aiur.ex`, `cli.ex` and `aiur-engine.sh` must not grow.
- **Contract request:** CR-C6-1. The report's `run_shape` gets `http_listener` and
  `dashboard_pages`.

### MP-R1-C7 — Domain moves: tracker split, sandbox, workspace, GitHub family
- **Outcome:** prior §7 steps 3, 4 and 5, done as manifest moves.
- **Tickets:**
  - T01: IssueTracker/CodeHost split.
  - T02: adapter registration.
  - T03: sandbox boundary.
  - T04: GitHub agent-environment contributor.
  - T05: workspace.
  - T06: GitHub family as one *logical* component (KTD11: no package, process or new
    facade module).
  - T07 and T08: Dispatcher goes through the tracker facade, and its CI-readiness gate
    moves out.
- **Deps:** prior U5 (T04, T06, T08), prior U2 (T07, T08), MP-E1-C1 (RC-19/RC-20).
- **Placement:** `AgentGitHubGuard` belongs to `github`. MP-R7 starts after T03 and T04.

### MP-R1-C8 — Feature components: Commands, projections, conversations, build orders, build queue
- **Correction:** answer delivery stays a **synchronous** call. It goes through a
  delivery-target port that orchestration implements. The existing
  `decision.answered` event only wakes the orchestrator (CR-C8-3). `commands` is a
  required component.
- **Tickets:**
  - T01 and T02: Commands.
  - T03 and T04: projections.
  - T05: sanitizer moves to kernel.
  - T06: `Aiur.Conversation.History` facade (not `Aiur.Conversations`, which is the existing tmux pane facade), on top of MP-R6-C1 (RC-06).
  - T07 and T08: build-orders, plus a new `ticket-context` component.
  - T09: build-queue move, with RC-11/RC-19/RC-20 guard tests.
- **Deps:** prior U6 (T02), U5 (T07), U2 graph contract (T08), MP-E1 C1–C7 (T09).

### MP-R1-C9 — Listeners and orchestration core (prior §7 steps 9–10)
- **Tickets:**
  - T01–T04: GitHub listeners. The firehose stays a synchronous call at the same point
    in the tick.
  - T05 and T06: `pr-lifecycle` component.
  - T07–T09: `Orchestrator.State` owner table, back-call removal, and effects.
  - T10–T14: `AgentControlCLI` split. Every function name stays as a delegate,
    because the launcher calls 34 of them by name over RPC.
- **Deps:** C7-T06, MP-R2-C2-T08 (same files), MP-E1-C1, U3 (T11), U6 (T14).
- **Blocked:**
  - T06 and T09 wait on **RQ-U2-TRANSITION**.
  - T14 waits on **RQ-U6-STATUS-MODEL**.
- **Deferred, with no ticket:**
  - CI poll as a listener (after T09).
  - Asynchronous candidate poll. It changes timing, so the gap study gates it.

### MP-R1-C10 — Public component directory page (MP-REQ4)
- **Outcome:** [component-directory.md](component-directory.md). The "Planned" list is
  generated from a `features` array in the manifest, never written by hand.
- **Tickets:**
  - T01: public fields and `features`.
  - T02: VitePress data loader and unlisted page.
  - T03: approved design (DESIGN-R1 §3).
  - T04: docs-sync rules, run in the required `workflow security` job (it also runs on
    docs-only PRs, unlike `lint`), plus a `website.yml` trigger.
  - T05: publish.
- **RQ2 resolved:** the loader reads the root manifest directly (VitePress 1.6.4
  evidence in C10-T02).
- **Deps:** C1-T01; DESIGN-R1 §3. T05 waits for all of C9 and C11-T03 (D20).

### MP-R1-C11 — Plan refresh
- **Tickets:**
  - T01: plan-refresh tool on the research branch (path map, stale citations, size
    owners).
  - T02: recurring runbook. Procedure A runs after each move; Procedure B is the
    **RC-23** size-owner lookup at ticket start, against the current U8 ledger.
  - T03: final refresh, which gates wave 2 and C10-T05.
- **Owner:** the coordinator or the Executor.

## 10. Open questions

**Owner (Kevin), in DESIGN-R1:** §1 confirm no runtime UX change; S1–S5 the operator
surfaces (capabilities verb, endpoint, machine identity file at first boot, an
"API without dashboard pages" run shape, docs); §3 Q1–Q8 the directory page (entry
fields, sidebar placement, grouping, how public planned features are, diagram,
Khala links, source links).

**Coordinator:** none open. CQ1 (classification of C2/C3) was settled by RC-12, CQ2 by
RC-11 and CQ3 by MP-E4's `SessionRef` (see below).

**Research (Phase C):** RQ1 answered (C1-T02); RQ2 VitePress loader reading outside the
docs dir (resolved in MP-R1-C10-T02: yes); RQ3 answered (C2-T02: no launcher change); RQ4
answered (C4-T05: literal embeds, manifest ownership); RQ5 answered (component-map §5:
Muse/AgentTools → harness-adapters, AllowedContributors → github).

**Coordinator (Phase C):** CQ1 settled by RC-12; CQ2 settled by RC-11 (C1-T06); CQ3
settled — MP-E4's `SessionRef` is the session identity.

## 11. Plan-refresh note

R1 is the refactor others depend on. The path map in
[migration-plan.md §4](migration-plan.md) lists, per move, which later features'
tickets change (PR-01 … PR-16). MP-E1 precedes R1 and is moved by S13 (row PR-11).
Contract versions re-checked at each refresh: identity-and-capabilities, event
envelope (R2), Command payload (E2), conversation anchor (E4).
