# Target Architecture — the Modular End State

Same complete feature set, dramatically less code: modular, DRY, extensible.
The binding **module name map** lives in `research-arch/giant-*.md` (one per
oversized file); this document sets the principles, the seams, and the
consolidations. Downstream tickets treat the name map as a contract —
"modules created exactly as named"; renames require amending downstream
ticket docs before they open. Generated 2026-07-06.

---

## Principles (the house style)

Proven in-repo by the prewarm/attach simplification
(`docs/brainstorms/2026-05-23-opencode-prewarm-spaghetti-audit.md` →
`docs/measurements/2026-06-23-emfile-structural-fix-census.md`):

1. One source of truth per fact (ETS registry over copied state).
2. Pure policy functions instead of synchronous GenServer call chains.
3. No M×N fan-out; resource costs budgeted structurally.
4. Behaviour/base owns cross-cutting work; concrete modules stay thin; one
   dependency direction (concrete → base, never back).
5. Size norms as guiding targets, not lint: functions ≤20 logic lines, files
   ≤200 lines, ≤2 nesting levels. `config/schema.ex`-style cohesive schema
   modules may judgment-call larger.
6. Extraction trigger is the second concrete usage — not speculative, not
   waiting for a third.

## The decomposition name map

Each giant decomposes per its research file — full module names, paths,
responsibilities, LOC budgets, extraction waves, and preserved-semantics
notes there:

| Source (LOC) | New modules | Name map |
|---|---:|---|
| `orchestrator.ex` (7,617) | 26 | `research-arch/giant-orchestrator.md` |
| `github/client.ex` (2,597) | 18 | `research-arch/giant-client.md` |
| `init.ex` (2,253) | 17 | `research-arch/giant-init.md` |
| `agent_runner.ex` (2,215) | 14 | `research-arch/giant-agent_runner.md` |
| `agent_list/renderer.ex` (2,139) | 14 | `research-arch/giant-renderer.md` |
| `codex/coding_agent.ex` (1,997) | 14 | `research-arch/giant-coding_agent.md` |
| `pane_manager.ex` (1,839) | 13 | `research-arch/giant-pane_manager.md` |
| `agent_list/app.ex` (1,587) | 12 | `research-arch/giant-app.md` |
| `opencode/slot.ex` (1,392) | 6 | `research-arch/giant-slot.md` |
| `workspace.ex` (1,235) | 12 | `research-arch/giant-workspace.md` |
| `claude/repl_agent.ex` (1,175) | 10 | `research-arch/giant-repl_agent.md` |
| `opencode/chat_completions.ex` (1,127) | — | `research-arch/giant-chat_completions.md` |
| `codex/dynamic_tool.ex` (1,073) | — | `research-arch/giant-dynamic_tool.md` |
| `config/schema.ex` (1,017) | — | `research-arch/giant-schema.md` |
| `tmux.ex` (1,005) | — | `research-arch/giant-tmux.md` |

Shape notes: the orchestrator becomes a thin GenServer over
`Orchestrator.State` + pure policy modules (`DispatchPolicy`, `RetryEngine`,
`Reconciler`, `CommentWake`, `PauseResume`, …); the renderer split isolates
the `render_state` threading seam (`AgentList.RenderState`) that produced the
#414/#473/#730 regression class; workspace splits along the
refresh/recreate decision table that is hotspot #4.

## The coding-agent backend seam

Formalize `Aiur.CodingAgent.Backend` as a real `@behaviour` over the
**existing** registry (`coding_agent.ex backends/0` stays the single source
of backend identity):

- Callbacks confirmed against the residual `agent_runner.ex` branches
  (~638–1052): session start/stop, message/prompt delivery, interrupt policy
  (`can_interrupt`, `safe_checkpoints`), `resumable?/1` + `resume/2`,
  transcript module, remote-control promotion (the claude → claude-repl
  promotion and spawn-failure fallback become backend-declared capabilities,
  not inline `case` clauses).
- Both app-server adapters sit on a shared `Aiur.AppServer` core (port
  lifecycle, JSON-RPC framing, handshake, turn-loop control messages,
  usage/token normalization) — collapsing the codex/claude twin duplication.
- **No new backend is implemented.** The test of the seam: adding one is a
  new module + one registry entry, zero edits elsewhere.
- **Persistence prep (#609):** #609 is cross-restart session resume for the
  claude backends, built on `Aiur.SessionHandle` + `resumable?/1` (#605). The
  behaviour carries session-identity/resume semantics as first-class
  callbacks so #609 lands as backend-local changes plus a flag flip. Rule
  preserved: backend resolved once at `start_session`, read from
  `session[:backend]`, never re-resolved mid-session.

## Consolidations (from the duplication map)

Ticket-sized shared modules absorbing the 27 clusters
(`research-arch/dup-backends.md`, `dup-infra.md`), headline targets:

- `Aiur.AppServer` (adapter core, above) + one event-humanizer dispatch
  (delete or wire the latent Claude copy — preserve-or-fix decision).
- Poller skeleton (periodic-tick GenServer + connectivity
  streak/backoff/alert fold + sanitize-then-publish pipeline) shared by the
  GitHub pollers and tickers.
- One `shell_escape`, one identifier/filesystem sanitization module (it is a
  cross-subsystem join key today — five copies must stay bit-identical), one
  atomic write-then-rename, one JSONL decode-or-skip helper.
- Single-source `$VAR` env resolution (Schema absorbs `Linear.Config`'s
  copy); codex approval-policy validator and sandbox-policy defaults each get
  one home.
- Cross-language contracts (control-RPC marker, reap stack, root discovery,
  tmux conf) get one canonical side plus a generated/tested mirror — never
  two hand-maintained copies with drift.

## Engineering norms adoption

Adapt ethereum-optimism/actions `CONTRIBUTING.md` into an aiur
`CONTRIBUTING.md` (proposal ticket): size/nesting/single-responsibility
targets, reuse-before-invention with second-usage extraction, mock at
boundaries / never pure utilities, regression test per bug fix, flaky tests
fixed or deleted, zero-new-warnings ratchet — mapped onto the existing gate
(`make ci`, `mix specs.check`, credo, dialyzer). The coverage
`ignore_modules` list only shrinks (see `regression-safety.md` §4).

## Docs framework

**VitePress**, as a separate docs package building into `website/dist/docs`
(served at `/docs/`), marketing build first, docs failure fails the deploy.
Runner-up Starlight; full rationale, constraints checklist (golden snapshot
untouched, bun-clean install, no leakage into the marketing bundle), and
integration options in `research-docs-framework.md`. Pages per the brief:
quick-start, configuration (from FI-CFG), what-aiur-is/how-to-use, and a
skills page split into driver skills vs workspace-agent skills.

## v2 integration branch mechanics

All refactor PRs target the long-lived `v2` branch. Verified against code
(`research-v2-mechanics.md`): PR CI already runs for any base; `push` CI and
`RepoBase` need small changes (Phase-1 pre-ticket — `tracker.base_branch`
support in `repo_base.ex`, CI `push:` += `v2`); notify/subscriptions follow
`tracker.base_branch` config; blocker-branch detection is base-agnostic;
executor PRs are opened with base `v2`.
