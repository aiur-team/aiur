# Production-Readiness Refactor — Overview

Aiur goes from vibe-coded sprawl to production-ready: **the same complete
feature set, in dramatically less code** — modular, DRY, extensible, with
zero feature loss. Aiur's own agents execute the refactor ticket-by-ticket
via the aiur-loop, orchestrated by an Opus agent, merging into a long-lived
`v2` integration branch. Authoritative brief:
`fable-planning-prompt.md`. Spike plan:
`docs/plans/2026-07-06-001-refactor-production-readiness-planning-spike-plan.md`.

---

## Success criteria

1. Every feature in `feature-inventory.md` (1,062 entries) survives.
   Verification is **scoped, not exhaustive**: each PR/phase checks only the
   Inventory-IDs it touches (their characterization tests + at-merge `Check:`
   probes); the full 1,062-feature sweep runs **once**, at final `v2`
   acceptance. See `RUNBOOK.md` §7.
2. `v2` is green after every single ticket (full `make ci` gate).
3. The giants are decomposed per the name map (~190 focused modules); the
   coverage `ignore_modules` list only shrinks; duplication clusters
   consolidated to single homes.
4. Adding a coding-agent backend = one module + one registry entry.
5. Docs site live at `/docs` (VitePress) with quick-start, configuration,
   concept, and skills pages.
6. The human tests the finished `v2` once and merges to main.

## Document index

| Doc | Role |
|---|---|
| `feature-inventory.md` (+ `feature-inventory/`) | the anti-regression contract (FI IDs) |
| `current-architecture.md` | how it's built today + pain analysis |
| `target-architecture.md` | end state, seams, name-map contract |
| `regression-safety.md` | testing strategy, tripwire, flake rules, halt rules |
| `phasing-and-parallelization.md` | phase model, dependency rules, duty split |
| `RUNBOOK.md` | **operating manual for the agent running the loop** — start here to execute |
| `research-history-hotspots.md`, `research-arch/`, `research-docs-framework.md`, `research-v2-mechanics.md` | evidence artifacts |
| `tickets/` | the backlog (generated after the checkpoint) |

## Deviations from the brief (evidence-driven, per the brief's own rule)

1. **Backend seam is half-built** — registry exists; the ticket formalizes a
   `@behaviour` + migrates residual `agent_runner.ex` branches (not
   greenfield).
2. **#609 is session resume**, not a generic persistence layer; the seam
   carries resume semantics.
3. **Verification gate corrected** — the brief's worked example under-scoped
   it; real gate = `make ci` / the five dev-loop commands, with manual
   verification split to at-merge checks (executors can't run `aiurdev
   --test*`).
4. **Feature inventory is split** into an index + 18 section files (~615 KB
   total would not render as one file).
5. **Issue conversion is done by the successor agent** (user decision), not
   the human: issues created in dependency order, `Depends-on` rewritten from
   the creation log, T-id→#N mapping verified before `agent:todo` labels go
   on. After conversion, the GitHub issue is the source of truth; ticket docs
   are frozen snapshots.
6. **`v2` integration branch** (user decision): all ticket PRs target `v2`;
   main untouched until final acceptance.
7. **Autonomous execution** (user decision): no human intervention between
   conversion and completion — see mandate below.
8. **Phase count is flexible** (the brief's wiggle-room clause governs);
   single-file chains run as serialized sub-waves under the delayed-open
   protocol.

## The Opus agent's mandate (autonomy model)

The agent running `/aiur-loop` for each phase:

- Uses each phase's aiur run itself as the integration test — a healthy
  fleet on `v2` validates prior merges.
- Owns PR readiness, green builds, merge conflicts, one-at-a-time merges,
  at-merge checks, and phase-exit.
- Opens new issues for unforeseen bugs/regressions and slots them into
  phases (same conventions, complexity 1–3 preferred).
- Is the backstop: if aiur becomes unusable, implement any fix necessary to
  restore the fleet, then record it (issue + PR into `v2`).
- Escalates to the human only at the two defined touchpoints (ticket-doc
  review; final `v2` acceptance) or when the change set itself is at risk.

## Conversion protocol (for the successor agent)

1. Human reviews `tickets/` and approves.
2. Operator setup: create `v2` from main; set `tracker.base_branch: "v2"` in
   the refactor run's `.aiur/config` (pre-ticket also updates `RepoBase` +
   CI; see `research-v2-mechanics.md`).
3. Create issues **oldest-first in phase then dependency order** (phase 1
   first, sub-waves delayed-open — a dependent's issue is created only after
   its blocker merges). Lowest issue numbers are worked first, so creation
   order = execution priority. Rewrite `Depends-on: T-NNN` to real issue
   numbers from your own creation log as you go.
4. **Every issue gets the `refactor` label** plus a `phase:N` label and
   `complexity:N` (1–3). Only the active sub-run gets `agent:todo`, and
   `model:*` routing overrides are not pre-applied; complexity labels select
   the backend. Ticket docs (`T-NNN`) are numbered in the same order and
   state their Phase prominently so the backlog reads in execution order.
   Only `refactor` issues ever carry `agent:todo` — the tracker has no
   extra-label filter, so this exclusivity is what scopes the loop (verify:
   `gh issue list --label agent:todo --state open` shows only `refactor`
   issues; today it is empty).
5. Before applying `agent:todo` to any issue, verify the full T-id→#N map
   lined up as expected (single actor, serial creation — numbering cannot
   drift; verify anyway).
5. Maintain the T-id→#N table in this file (pass 2).

## Checkpoint (R13) — what the human approves here

The six docs above, and specifically: the phase model + sub-wave rules, the
name-map contract, the tripwire mechanics + prerequisite tickets, the
VitePress decision, the v2 mechanics pre-ticket, and the doc-drift
restore-or-fix-docs decisions (FI-DOC entries: chat-pane ANSI recorder,
`--record` screen.ansi, stale `make -C elixir` reference, PR-template vs
dev-loop contradiction — default: fix the docs, don't resurrect unbuilt
features). **Approved-at SHA: _recorded here at approval_.** After approval,
ticket generation begins; the final PR is reviewed as: docs = delta since the
approval SHA; `tickets/` = new content, reviewed in full.

## Ticket index

59 tickets in `tickets/`, numbered in execution order (oldest-first). Within
a chain (→) tickets are serialized sub-waves under delayed-open; unchained
same-phase tickets run in parallel (disjoint files).

| ID | Title | Phase | Depends-on |
|----|-------|:-----:|------------|
| T-001 | RepoBase base-branch support + CI push += v2 | 1 | — |
| T-002 | Global :log_file test isolation + purge src/log | 1 | — |
| T-003 | Fix SlotPolicyTest flake (#506) deterministic sync | 1 | — |
| T-004 | Website CI job (own workflow file) | 1 | — |
| T-005 | Tripwire CI guard (own workflow file, override label) | 1 | — |
| T-006 | Compile-time path-embedding guard test | 1 | — |
| T-007 | Characterization: orchestrator lifecycle & dispatch gates | 1 | — |
| T-008 | Characterization: GitHub ingestion & wake/rework | 1 | — |
| T-009 | Characterization: engine identity, reap & control RPC | 1 | — |
| T-010 | Characterization: workspace lifecycle & git metadata | 1 | — |
| T-011 | Characterization: opencode slots, attach & FD budget | 1 | — |
| T-012 | Characterization: renderer/app render-state & snapshots | 1 | — |
| T-013 | Characterization: agent_runner drain/resume & digest | 1 | — |
| T-014 | Extract Aiur.AppServer shared adapter core | 2 | — |
| T-015 | Formalize Aiur.CodingAgent.Backend behaviour | 2 | T-014 |
| T-016 | Migrate agent_runner residual backend branches | 2 | T-015 |
| T-017 | Shared poller skeleton (tick/backoff/sanitize-publish) | 2 | — |
| T-018 | Single shell_escape helper | 2 | — |
| T-019 | Single identifier/path sanitization module | 2 | — |
| T-020 | Shared atomic-write + JSONL-decode helpers | 2 | — |
| T-021 | Unify $VAR resolution + codex validator dedup | 2 | — |
| T-022 | orchestrator ▸ State, EventTopics, DispatchPolicy, Slots | 3 | — |
| T-023 | orchestrator ▸ Dispatcher, RetryEngine, Reconciler | 3 | T-022 |
| T-024 | orchestrator ▸ CommentWake, PrAnchored, PushRouting, CommentPolling, CommandScan | 3 | T-023 |
| T-025 | orchestrator ▸ IssueSync, AutoSubscriptions, TrackerHealth, OperatorMessages, DigestCoalescer | 3 | T-024 |
| T-026 | orchestrator ▸ PauseResume, Interrupts, RemoteControlMode, TokenAccounting | 3 | T-025 |
| T-027 | orchestrator ▸ StatusReport, WorkspaceCleanup, HumanReview, AgentTeardown, RuntimeWatchdog; slim | 3 | T-026 |
| T-028 | github client ▸ Transport, Errors, AuthPreflight, StatePolicy, BotIdentity | 3 | — |
| T-029 | github client ▸ Issues, Comments, PullRequests, RepoEvents, Dependencies, Teams | 3 | T-028 |
| T-030 | github client ▸ ReviewThreads(+Reply/Resolution), HumanReviewGate, IssueState; slim | 3 | T-029 |
| T-031 | init ▸ Runtime, Format, Questions, Resume, Templates | 3 | — |
| T-032 | init ▸ Scaffold, Migration, Prewarm, Alerts | 3 | T-031 |
| T-033 | init ▸ Codeowners, Labels, GitHub, AgentCli, Dotenv; slim | 3 | T-032 |
| T-034 | agent_runner ▸ SessionLifecycle, SessionResume, TurnLoop, TurnPrompt | 3 | — |
| T-035 | agent_runner ▸ QueueDrain, CheckpointDelivery, EventsDigest, BootstrapDigest, CommentContext | 3 | T-034 |
| T-036 | agent_runner ▸ MessageHandler, TurnStreams, ToolExecutor, TurnAlerts; slim | 3 | T-035 |
| T-037 | codex ▸ AppServerPort, Rpc, Frames, Handshake | 3 | — |
| T-038 | codex ▸ TurnLoop, TurnState, Interrupts, OperatorDelivery | 3 | T-037 |
| T-039 | codex ▸ Approvals, UserInputAnswers, NotificationPolicy, EventNormalizer, TurnEvents; slim | 3 | T-038 |
| T-040 | renderer ▸ Style, Text, Links, EventPhrases, EventLine, EventsBlock | 4 | — |
| T-041 | renderer ▸ Model, Markers, Layout, Cells, Table, Chrome, Help; slim | 4 | T-040 |
| T-042 | app ▸ State, Summaries, Selection, Roster, EventIntake, RenderState | 4 | — |
| T-043 | app ▸ PerfIntake, WarmthIntake, RcPaneBorders, Activation, Controls; slim | 4 | T-042 |
| T-044 | pane_manager ▸ State, OpenQueue, Anchor, ScreenGrab, Layout | 4 | — |
| T-045 | pane_manager ▸ GenericOpen, Close, Reconcile, SlotAttach, ConvoPaint, Placeholder, OpencodeOpen; slim | 4 | T-044 |
| T-046 | opencode slot ▸ State, Events, AttachPane, ServeLifecycle, Sessions; slim | 4 | — |
| T-047 | chat_completions ▸ wire shapes into Aiur.Opencode.Protocol | 4 | — |
| T-048 | workspace ▸ Layout, Context, Remote, Checkout, GitMetadata | 4 | — |
| T-049 | workspace ▸ Materialize, Provisioner, Hooks, BootstrapImage, Refresh, Remove; slim | 4 | T-048 |
| T-050 | repl_agent ▸ Launcher, Command, RcAttach, Reaper, PromptSubmit, tailers; slim | 4 | — |
| T-051 | dynamic_tool ▸ split registration & dispatch | 4 | — |
| T-052 | config/schema ▸ per-section schema modules | 4 | — |
| T-053 | tmux ▸ split command layer | 4 | — |
| T-054 | Adopt CONTRIBUTING.md engineering norms | 5 | — |
| T-055 | Install VitePress docs package → website/dist/docs | 5 | — |
| T-056 | Docs: quick-start + configuration reference | 5 | T-055 |
| T-057 | Docs: concept pages (what aiur is / how to use) | 5 | T-055 |
| T-058 | Docs: skills page (driver vs workspace-agent) | 5 | T-055 |
| T-059 | Website: surface newly-catalogued features | 5 | — |

**T-id → issue-number map (filled at conversion):** _pending_.
