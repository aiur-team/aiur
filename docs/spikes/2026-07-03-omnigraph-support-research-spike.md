# Research Spike — Omnigraph support in Aiur

- **Date:** 2026-07-03
- **Status:** research spike (analysis only — no implementation)
- **Question:** What would it look like to add [Omnigraph](https://github.com/ModernRelay/omnigraph) support to Aiur? What is the overlap vs. the delta, what is the lift, and what do we gain vs. what are the risks?
- **Method:** repo research over Aiur's extension seams (`src/lib/aiur/**`, `SPEC.md`) + external research over Omnigraph's docs, HTTP API, CLI, and release history.

---

## TL;DR

Aiur and Omnigraph are **complementary layers, not competitors**. Aiur is a process-orchestration *runtime* that pulls work from a tracker, runs coding agents in isolated worktrees, and ships PRs. Omnigraph is a Rust *"lakehouse-native graph engine"* — a durable, queryable knowledge/state graph with hybrid retrieval (graph traversal + vector k-NN + BM25) and git-style branch/merge.

They overlap on exactly one idea: **durable, queryable, coordinated fleet memory** — which is precisely the capability Aiur *lacks* today (its cross-run state is ephemeral ETS + scattered JSON sidecars + append-only logs, "no durable orchestrator DB", SPEC §2.1) and the thing Omnigraph is built to be.

**Recommendation:** worth a **2–3 day spike**, not a production commitment yet. Integrate as an **HTTP client** (Aiur is Elixir, Omnigraph ships no embedded mode for non-Rust hosts). Build **write-first**: a fire-and-forget run-history sink (Shape C) → retrieval into the prompt (Shape A) → cross-run coordination (Shape B). **Stay on `main`; do not map Aiur runs to Omnigraph branches.** And answer one honest bake-off first: *does a Postgres/SQLite sink extending the existing `memory` backend get us 80% of the value without a Rust graph DB + Lance + S3?* Adopt Omnigraph **only if** its graph-traversal + hybrid-retrieval differentiator is genuinely the goal.

---

## 1. What each system is

| | **Aiur** (ours) | **Omnigraph** (ModernRelay) |
|---|---|---|
| Role | Process-orchestration runtime | Queryable knowledge/state graph + retrieval |
| Job | Pull work from a tracker → run coding agents → ship PRs | Store nodes/edges; answer graph + vector + BM25 queries |
| Runtime | Elixir/OTP (Phoenix present; core is plain OTP) | Rust (Axum server, Lance columnar storage) |
| State model | Ephemeral: git worktrees + JSON sidecars + logs + ETS | Durable: branched, time-travelled, S3/Lance-backed |
| "Branch" means | A git worktree of a **code** repo | A row-level **graph-state** branch (three-way merge) |
| Retrieval | None — prompt is a static two-variable Liquid template | `nearest()` k-NN, `bm25()`, `rrf()` hybrid, in-query |
| Deployment | An Elixir app we already run | A **new** Rust binary + S3/Lance/Cedar to operate |
| Maturity | Ours | MIT, ~560★, v0.8.0 (Jul 2026), pre-1.0 churn |

---

## 2. Overlap vs. delta

### Genuine overlap (narrow but real)

- **Cross-agent coordination substrate.** Aiur already has `Aiur.Events.Exchange` (`src/lib/aiur/events/exchange.ex`) — an ETS-backed, AMQP-topic-style pub/sub (`ticket.<id>.agent.<name>`) with `emit_event` / `aiur_subscribe` / `aiur_declare_blocker` dynamic tools. Omnigraph is positioned (per its ~$3M raise) as "shared agent-coordination infrastructure." **Both try to let a fleet of concurrent agents see each other's work — and this is exactly where Aiur's implementation is weakest (ephemeral, in-memory, lost on restart).**
- **Git-style isolation for safe parallel work — at different layers.** Aiur isolates runs with filesystem git worktrees; Omnigraph offers three-way, row-level graph branch/merge. A real conceptual rhyme, but Aiur branches *code* and Omnigraph branches *graph state* — **not the same branches** (see Risk §6.4).

### Not overlap (superficial resemblance)

- Omnigraph is **not** an orchestrator: no work queue, no agent lifecycle, no PR shipping, no polling loop. It never *runs* an agent.
- Aiur is **not** a queryable store: its persistence is per-issue JSON sidecars, append-only logs, and ETS rings — none queryable across runs.

### The delta is the productive framing

A clean **control-plane / data-plane split**: *Aiur does the work; Omnigraph remembers and retrieves what the work found.* Aiur's context pipeline is deliberately thin; Omnigraph's whole reason to exist is retrieval + durable shared state. Neither duplicates the other's core. The friction is the **Elixir↔Rust boundary** — Omnigraph ships no first-party embedded mode for non-Rust hosts, so Aiur integrates as an **HTTP client against `omnigraph-server`** (or CLI shell-out, or MCP bridge). That constraint shapes every option below.

---

## 3. Aiur's extension seams (where Omnigraph could plug in)

Established from source. Aiur has two extension idioms: a **hardcoded-dispatch** tracker boundary and a **registry-driven** coding-agent boundary.

- **Tracker boundary** — `Aiur.Tracker` (`src/lib/aiur/tracker.ex`), ~12 issue/PR-shaped callbacks; adapter chosen by a **hardcoded `case`** in `adapter/0` (tracker.ex:96-104). Adding a backend edits 3 sites (`adapter/0`, `Config.validate_kinds_and_secrets/1` at config.ex:427, `inferred_tracker_kind/1`). Impls: `github`, `linear`, `memory`.
- **Coding-agent boundary** — `Aiur.CodingAgent` (`src/lib/aiur/coding_agent.ex`); backends live in **one registry map** `backends/0` (the clean pattern — "add a backend = add one entry").
- **Context assembly** — `Aiur.PromptBuilder.build_prompt/2` (`src/lib/aiur/prompt_builder.ex:11-31`): shared prefix + strict-mode Liquid render with **exactly two variables** (`issue`, `attempt`) + complexity suffix. *(Note: `Aiur.IssueContext` is opencode-pane observability only — it does NOT feed the agent prompt.)*
- **Coordination bus** — `Aiur.Events.Exchange` + `emit_event`/`aiur_subscribe`/`aiur_declare_blocker` dynamic tools (`Aiur.Codex.DynamicTool`).
- **Persistence sinks** — `Aiur.IssueLog`, `Aiur.AgentEventLog` (`agent.md`/`agent.ndjson`), `Aiur.SessionHandle` (JSON sidecars), `Aiur.ProgressTracker` (ETS ring). **No durable, queryable, cross-run store.**
- **Transport convention** — external HTTP goes through **`Req` with an injectable `request_fun` seam** (`Aiur.Linear.Client`, `Aiur.GitHub.Client`) — the natural fit for Omnigraph's HTTP/OpenAPI surface. Config is live-reloaded from `.aiurconfig` (SPEC §6.2).

---

## 4. Omnigraph's integration surface (what Aiur would call)

Established from Omnigraph's docs. Axum server, **cluster-mode only** (v0.7.0+), routes under `/graphs/{id}/…`; OpenAPI at `GET /openapi.json`.

- **Reads:** `POST /graphs/{id}/query` — `.gq` language (`match{}`/`return{}`/`order`/`limit`, hop-bounded traversal) with in-query search: `nearest($field,$q)` (cosine k-NN), `bm25(field,q)`, `rrf(r1,r2,k=60)` (Reciprocal Rank Fusion). Also `/snapshot`, `/schema`, `/export` (NDJSON stream), stored `/queries/{name}`.
- **Writes:** `POST /graphs/{id}/mutate` — `insert Type {props}` / `update Type set{} where` / `delete Type where`, atomic; a mutation is insert/update-only *or* delete-only. `POST /graphs/{id}/load` — bulk JSONL (32 MB, `overwrite|append|merge`). Edges use the same `insert EdgeType {...}` syntax.
- **Branch/merge:** `POST /graphs/{id}/branches`, `.../branches/merge` (three-way, row-level; 409 with structured `merge_conflicts[]`, 8 conflict kinds, **manual resolution, no auto-resolve**); `/commits` for time-travel.
- **Schema/config:** typed `.pg` files; `cluster.yaml` (Terraform-style `validate/plan/apply`) declares graphs/schemas/queries/policies over an S3 or local-dir root.
- **Policy:** Cedar per-action (`read, change, branch_merge, invoke_query, …`), enforced engine-level (uniform across HTTP/CLI/SDK). Three states: **Open** (`--unauthenticated`), **DefaultDeny** (tokens, no policy), **PolicyEnabled**. Per-row predicate pushdown **not yet implemented**.
- **Envelope/limits:** `ReadOutput`/`ChangeOutput`/`ErrorOutput{error, code, merge_conflicts[]}`; codes map to 200/400/401/403/404/409/429/500; default 1 MB body; per-actor admission control (`OMNIGRAPH_PER_ACTOR_INFLIGHT_MAX=16`).
- **Ops:** `omnigraph-server --cluster <dir|s3://…>`; Lance columnar storage (schema v4); **no hot reload**; single-writer lock on `cluster apply`; **multi-replica HA documented but explicitly not yet validated**.
- **MCP bridge** (`@modernrelay/omnigraph-mcp`, stdio): tools for schema/branches/queries/mutations/ingest — for *agents* (Claude Desktop/Code) to talk to Omnigraph directly, **not** for an Elixir service.

---

## 5. Integration shapes (ranked)

For each: the exact Aiur seam, the transport, and the fit. All use **`Req` HTTP** — not CLI (subprocess overhead for no gain), not the MCP bridge (wrong layer for an Elixir *service*).

### Shape C — Run-history / proof-of-work knowledge graph — *build first*
**Seam:** a new PubSub-subscribing GenServer sink alongside `Aiur.IssueLog`, writing run outcomes (CI results, PR-review comments, `complexity:N`, walkthrough summaries) as nodes/edges. **Transport:** `POST /mutate` on completion (fire-and-forget), `POST /load` for backfill. **Fit: strong, low-risk** — pure write-mostly sink, no hot-path dependency (if Omnigraph is down, Aiur keeps shipping PRs). It's the on-ramp that builds the corpus Shapes A/B need. *(Caveat: Shape C alone doesn't exploit Omnigraph's graph/retrieval differentiator — a relational sink would serve it too. See Risk §6.7.)*

### Shape A — Retrieval into `PromptBuilder` — *the payoff, phase 2*
**Seam:** a new `"context"` render variable in `PromptBuilder.build_prompt/2` (prompt_builder.ex:20-26), fed by a graph query; per-turn refresh at the `AgentRunner` continuation-nudge path (agent_runner.ex:1854-1886). **Transport:** `POST /query` with `rrf(nearest($d.embedding,$q), bm25($d.body,$q))` — Omnigraph's hybrid retrieval is genuinely differentiated. **Fit: highest end-user value, but gated on a corpus (Shape C first).** Strict-variables mode means the query must be resilient (empty-on-miss, timeout-bounded) or it breaks prompt building. **Zero-Elixir-code variant:** expose Omnigraph to the coding agents directly via codex's MCP pass-through (`@modernrelay/omnigraph-mcp`), sidestepping per-backend `DynamicTool` duplication.

### Shape B — Durable cross-run coordination backend — *closes the loop, phase 3*
**Seam:** durable backing for `Aiur.Events.Exchange` + `graph_query`/`graph_upsert` entries in `Aiur.Codex.DynamicTool.tool_specs/0` (mirrored per backend). **Transport:** `POST /mutate` ("this run touches paths X,Y") + `POST /query` ("who else is touching module Z?" — a graph traversal). **Fit: highest architectural value** — it targets Aiur's actual weakness (ephemeral `Events.Exchange`) and collision-avoidance is literally an edge query. Sequenced last because it needs both the write layer (C) and read maturity (A), and the agent-callable half needs per-backend tool wiring.

### Shape D — Omnigraph as a `Aiur.Tracker` adapter — *do not pursue*
Implement ~12 issue/PR-shaped callbacks over graph nodes. **Fit: mismatch.** The Tracker behaviour is deeply issue/PR-shaped (`fetch_unaddressed_pr_review_thread_comments`, `fetch_open_pull_request_for_branch`, `update_issue_state`); Omnigraph is a graph DB, not a work source. You'd reimplement GitHub/Linear's domain in `.pg` schema for no benefit. Inverts the natural data-plane fit.

**Value ranking:** B > A > C > D. **Build sequence:** **C → A → B** (write layer → read layer → coordination loop).

---

## 6. Risks (honest)

1. **Heavy new dependency.** A Rust graph DB + Lance columnar engine + S3 is significant to operate for a project that proudly has "no durable orchestrator DB." Single biggest strike.
2. **v0.x breaking-change churn.** *Every* minor v0.5→v0.8 shipped a breaking change (routes moved under `/graphs/{id}` in v0.6; cluster-only boot + config split in v0.7; storage format v4 requiring export/reimport in v0.8). Wire API + storage format are **not stable** — pin versions, budget re-validation each upgrade.
3. **Elixir↔Rust boundary, no native SDK.** Everything is a network hop with admission control (16 in-flight/actor), 1 MB body default, and 429/409 paths Aiur doesn't handle today. Absorbable via `Req`, but new surface.
4. **Concept collision: git worktrees vs graph branches.** Naively mapping one run → one graph branch inherits Omnigraph's three-way row-level merge and 8 manual conflict kinds. **Keep coordination writes on `main`; do NOT map runs to graph branches** unless a concrete need forces it.
5. **HA not validated.** Multi-replica-from-shared-storage is documented but explicitly untested; single-writer lock on `cluster apply`; no hot reload. Caps availability for a fleet-scale orchestrator.
6. **Maturity/vendor risk.** ~560★, funded startup positioning this as commercial agent infra — active but small, with possible future licensing/product shifts outside the OSS core.
7. **Build-vs-adopt — the sharpest question.** Aiur already has `Aiur.Memory.Tracker` + `Events.Exchange`. For pure structured coordination (who-touched-what) and run history, a Postgres/SQLite sink is simpler. **Omnigraph's differentiator is specifically graph traversal + hybrid vector/BM25 retrieval** (Shapes A/B). If we don't need *those*, we probably don't need Omnigraph — Shape C alone would be over-served by it.
8. **Scope creep.** "Add Omnigraph support" can balloon into schema design, Cedar policy authoring, S3 ops, and merge-conflict handling. Fence the first delivery hard.

---

## 7. Gains

- **Durable fleet memory** — first cross-run state that survives worktree reclaim and process restart (today Aiur forgets everything on reclaim).
- **Cross-run collision avoidance** — parallel runs query "who else touches this module/path/dep" as a graph traversal — the direct antidote to fleet rework.
- **Queryable org/run knowledge** — CI outcomes, PR-review patterns, complexity, walkthroughs become a searchable corpus (`bm25`+`nearest`+`rrf`) instead of write-once logs.
- **Better prompt context** — retrieval of prior decisions / similar past runs into `PromptBuilder`, replacing the static two-variable template.
- **Policy-enforced writes** — Cedar per-action authz at engine level, uniform across transports, if multi-tenant fleet writes ever need governance.
- **Upgrade path for a known-weak component** — `Events.Exchange` goes from ephemeral ETS to durable, queryable, branchable state.

---

## 8. Lift & phasing

**Transport decision: HTTP via `Req`** (mirror `Aiur.Linear.Client`'s injectable `request_fun`). New modules: `Aiur.Omnigraph.Client` (~150–250 LOC), `Aiur.Omnigraph.Config` (`validate!/0`, ~40 LOC), `Aiur.Omnigraph.Sink` (Shape C GenServer, ~150 LOC); follow-ons `Aiur.Omnigraph.Coordinator` + `DynamicTool` entries (Shape B, per-backend), a `PromptBuilder` render-map addition (Shape A, ~30 LOC + resilience). New `omnigraph:` `.aiurconfig` section (base URL, `graph_id`, token ref, optional branch). Tests follow the established `request_fun`/`tool_executor` injection pattern (no live network); cover 409/429 paths. **The heaviest cost is operational, not code:** running `omnigraph-server` (cluster-mode, S3/Lance), managing `cluster.yaml` + `.pg` schemas + Cedar, no hot reload, single-writer lock.

| Phase | Size | Scope |
|---|---|---|
| **Spike** | S (~2–3 days) | `omnigraph-server --unauthenticated` on a local `file://` cluster; `Aiur.Omnigraph.Client` + throwaway sink; write run-completion nodes for one repo; run one `rrf(nearest,bm25)` by hand. **Goal: prove the wire protocol + Elixir↔Rust round-trip, and whether the retrieval is worth the weight.** |
| **MVP** | M (~1–1.5 wk) | Shape C production-grade: client + config + `Sink` GenServer + tests, fire-and-forget, S3-backed, Cedar DefaultDeny. Aiur unaffected if Omnigraph is down. **`main` only — no run→branch mapping.** |
| **Full** | L (~3–4 wk cumulative) | Shape A retrieval into `PromptBuilder` (or MCP pass-through), then Shape B coordination tools + durable `Events.Exchange` backing; Cedar PolicyEnabled; per-backend tool mirroring. |

---

## 9. Recommendation & open questions

**Worth a time-boxed spike — yes. Worth a production commitment today — not yet, and only if the graph/retrieval differentiator is genuinely wanted.**

1. **Run the 2–3 day spike.** It de-risks the only genuinely uncertain thing (the wire protocol + whether hybrid retrieval justifies the weight). Cost tiny, answer decisive.
2. **If it lands, ship Shape C first** (fire-and-forget run-history sink) — lowest-risk path to production, builds the corpus. **`main` only.**
3. **Then Shape A retrieval, then Shape B coordination.** **Do not pursue Shape D.**
4. **Answer the bake-off on paper before the MVP:** *"For collision avoidance and run history, does a Postgres/SQLite sink extending the existing `memory` backend get us there without a Rust graph DB + Lance + S3?"* If yes, adopt that and shelve Omnigraph. **Adopt Omnigraph specifically and only if graph-traversal + hybrid-retrieval (Shapes A/B) is the actual goal — the sole thing it does that a boring relational sink cannot.**

**Open questions for the spike:**
- Does Omnigraph's hybrid retrieval measurably beat a simpler keyword/embedding store for agent context? *(the core build-vs-adopt evidence.)*
- Can a single-writer, HA-unvalidated server keep up with a fleet's concurrent run-completion writes, or does the sink need batching via `POST /load`?
- Given every minor is breaking, is the re-validation cadence an acceptable standing tax?
- Cedar posture: is DefaultDeny + one bearer token enough for a single-tenant fleet, deferring full PolicyEnabled?
- Schema ownership: who designs and migrates the `.pg` schema as run-outcome shapes evolve?

---

## Sources

**Aiur:** `SPEC.md` (§2.1, §4, §6, §10, §11, §12); `src/lib/aiur/{tracker,coding_agent,prompt_builder,agent_runner,issue_context}.ex`, `events/exchange.ex`, `memory/{tracker,config}.ex`, `codex/dynamic_tool.ex`, `linear/client.ex`.
**Omnigraph:** [repo](https://github.com/ModernRelay/omnigraph), [docs](https://www.omnigraph.dev/docs), [server/HTTP](https://github.com/ModernRelay/omnigraph/blob/main/docs/user/operations/server.md), [merge](https://github.com/ModernRelay/omnigraph/blob/main/docs/user/branching/merge.md), [policy](https://github.com/ModernRelay/omnigraph/blob/main/docs/user/operations/policy.md), [search](https://github.com/ModernRelay/omnigraph/blob/main/docs/user/search/index.md), [mutations](https://github.com/ModernRelay/omnigraph/blob/main/docs/user/mutations/index.md), [deployment](https://github.com/ModernRelay/omnigraph/blob/main/docs/user/deployment.md), [releases](https://github.com/ModernRelay/omnigraph/releases), [@modernrelay/omnigraph-mcp](https://registry.npmjs.org/@modernrelay/omnigraph-mcp/latest).
