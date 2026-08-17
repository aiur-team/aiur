# Aiur Production-Readiness Refactor — Planning & Ticket-Generation

You are a senior staff engineer running a **planning-only** spike on the `aiur`
repository. You will **not implement the refactor.** Your entire output is:

1. Upfront brainstorming / planning documentation, and
2. A backlog of **30–60 self-contained, issue-ready ticket documents** that *less
   capable agents* will execute later through the `aiur-run` Executor workflow.

Do all the hard thinking now so their execution is mechanical, parallelizable, and
low-risk. Deliver everything as a single PR.

---

## The one-paragraph goal

Take aiur from vibe-coded sprawl to production-ready: **the same complete feature
set, in dramatically less code — more modular, more efficient, and easy to extend.**
aiur began as a fork of an OpenAI coding-agent CLI and accreted many features built
by different agents with different context, so expect heavy redundancy, duplicate
code paths, and oversized files. The refactor consolidates that mess **without
dropping a single feature.**

---

## Non-negotiable constraints (read twice)

1. **No feature is removed.** Every capability — however small — survives. This is
   the top risk; a regression here is failure.
2. **The repo is never left broken.** aiur runs *its own* refactor: an Executor
   uses `aiur-run` to execute these tickets on this codebase. After **every single ticket**, the repo
   must build and the test suite must be green.
3. **Behavior-preserving.** Refactors change structure, not behavior. Tie every
   risky change to the Phase-1 characterization-test tripwire (below).
4. **Optimized for lesser agents.** Each ticket names the exact files, the exact
   approach, and exact acceptance criteria + verification commands. The ticket
   carries the intelligence; the executing agent should not have to re-derive design.
5. **Parallelizable in ≤3 phases of ~10 agents each** (wiggle room ok). Within a
   phase, tickets must be mutually independent — no two concurrently-runnable tickets
   touch the same file/module — or carry explicit dependency ordering.

---

## What "done well" looks like (target norms)

- **≤20-line functions, ≤200-line files** as guiding targets — decompose with
  judgment, not as a mechanical lint.
- **Aggressive DRY:** collapse duplicate code paths built by different agents, and
  **pull reusable abstractions upward.**
- **Modular & extensible**, ready for the next phase (including the persistence
  layer, Issue #609).
- Adopt the engineering norms from **ethereum-optimism/actions `CONTRIBUTING.md`**
  (fetch it — there is no local one) and propose formally adopting the
  file-size / function-size / DRY rules for aiur.

---

## Context: what aiur is (a starting map — VERIFY, do not trust)

The grounding below was assembled quickly by another agent. Treat it as a lead, not
ground truth; confirm it against the code and correct it in your inventory.

- **Stack:** Elixir/OTP with a Phoenix LiveView dashboard (`src/lib/aiur_web/`). CLI
  in `src/lib/aiur/cli.ex` + `scripts/aiurdev` + `src/bin/aiur`.
- **Dual coding-agent backends today:** Codex agents and Claude agents. Claude
  support runs through a separate repo you also own —
  **`its-everdred/claude-app-server`** (the `aiur-claude` app-server). Backend code:
  `src/lib/aiur/coding_agent.ex`, `src/lib/aiur/codex/coding_agent.ex`,
  `src/lib/aiur/session_handle.ex`.
- **Feature anchors** (paths to verify — this is where "no feature removed" is
  enforced):
  - Config & personalization: `src/lib/aiur/config/schema.ex`, `src/config/config.exs`,
    `.aiur/config`, `.aiur/hooks`, `.aiur/prompt.md`
  - Event bus / agent emit-subscribe: `src/lib/aiur/events/` (`exchange.ex`,
    `publisher.ex`, `subscription_store.ex`); agent APIs `emit_event`,
    `aiur_subscribe`, `aiur_declare_blocker`
  - Repo pre-warm: `src/lib/aiur/prewarm/`, `.aiur/prewarm`
  - Sound-effect / alert lifecycle: `.aiur/alerts.yaml`, `src/lib/aiur/alerts.ex`,
    `alert_feed.ex`, `emit_alert`
  - PR monitoring + code-owner-comment-triggered spin-up:
    `src/lib/aiur/events/pr_command_scanner.ex`, `github_comments_poller.ex`,
    `github_firehose.ex`, `orchestrator.ex`
  - Agent-drives-aiur / interactive parity (agent limit, reading conversations,
    messaging agents, log tailing/summarizing): `src/lib/aiur/agent_control_cli.ex`,
    `orchestrator.ex`, `pane_manager.ex`, `tmux.ex`, LiveView under
    `src/lib/aiur_web/live/`
  - Two kinds of skills: **(a)** skills for agents/users *driving* aiur →
    `.claude/skills/` (aiur-build, aiur-run, aiur-monitor, design-import,
    aiur-agent, release); **(b)** skills installed into workspaces for agents *run by* aiur
    (compound-engineering skills symlinked in at boot). These bloat new-agent context
    if unmanaged — the refactor should make them modular and lean so freshly-spun
    agents aren't flooded with fluff, while retaining essentials like repo pre-warm.
- **Known oversized files (mess signal):** `orchestrator.ex` ~7,600 LOC; then
  `github/client.ex` ~2,600, `init.ex` ~2,250, `agent_runner.ex` ~2,200,
  `agent_list/renderer.ex` ~2,100, `codex/coding_agent.ex` ~2,000,
  `pane_manager.ex` ~1,840. Re-measure and produce the full list yourself.
- **Docs site:** `website/` — a custom Vite/TS app on Netlify (no docs framework yet).
- **Ticket ingestion (how your tickets get executed):** the Executor launches
  Aiur through `aiur-run`; Aiur polls the tracker for GitHub issues labeled
  `agent:todo` and works them through
  `agent:in-progress → agent:human-review / agent:rework → agent:merging →
  agent:done`. An optional `complexity:N` label routes hard tickets to stronger
  models; keep your tickets **low-complexity** so lesser agents suffice. Review
  `.claude/skills/aiur-run/` and `.claude/skills/aiur-agent/` yourself to confirm
  the exact conventions before finalizing ticket shape.

---

## Research you must do first (in this order)

1. **Read the aiur-run + aiur-agent skills** to lock the ticket/label conventions
   your backlog must match.
2. **Build the authoritative feature/behavior inventory** from the code and tests —
   every feature, flag, config option, skill, event, alert, and CLI command. This is
   the contract that guarantees "no feature removed."
3. **Mine history:** review historically-opened issues and merged PRs. Extract
   themes — what kinds of improvements recur, what regressions have happened, which
   bugs keep coming back. Use this to target the refactor: the messiest,
   most regression-prone areas get the most careful tickets and the most tests.
4. **Fetch ethereum-optimism/actions `CONTRIBUTING.md`** for the norms to adopt.
5. Only then design the target architecture and the phased plan.

Use compound-engineering skills throughout: **ce-brainstorm** to explore,
**ce-plan** to structure the plan, and **ce-doc-review** to self-review your planning
docs before you write tickets.

---

## Deliverable 1 — Planning documents (in `docs/refactor/`)

Write these as focused, right-sized docs (not padded):

- `00-overview.md` — problem, goals, success criteria, the phase model, and an index
  of **every ticket** with its phase + dependencies.
- `feature-inventory.md` — the authoritative, exhaustive feature/behavior map (the
  anti-regression contract).
- `current-architecture.md` — how it's built today + the theme/pain analysis from
  issue/PR history (recurring bugs, regression hotspots, duplication map,
  oversized-file list).
- `target-architecture.md` — the modular end state: module boundaries, the
  **pluggable coding-agent backend seam** (a behaviour/adapter so gemini / local /
  OSS / openrouter backends drop in as new modules, **not** new `if`/`case` branches —
  do **not** implement any new backend), how it preps the persistence layer (#609),
  and how it satisfies the size/DRY norms.
- `regression-safety.md` — the testing strategy: Phase-1 characterization tests as
  the green tripwire; the rule that tests are pruned **only** when the code they
  pinned is gone or replaced by higher-level coverage; where to lift unit tests up to
  system/integration tests as internals consolidate; the "green after every ticket"
  invariant. Net goal: **less test code, higher-value coverage** — never a red or
  broken suite.
- `phasing-and-parallelization.md` — the ≤3-phase plan, which tickets run in which
  phase, the dependency graph, and the rule that concurrent tickets never touch the
  same file.

---

## Deliverable 2 — The ticket backlog (30–60 tickets in `docs/refactor/tickets/`)

Each ticket is a standalone markdown file, **issue-ready** (it will be opened
verbatim as a GitHub issue labeled `agent:todo`). Every ticket MUST contain:

- **Title** — imperative, specific.
- **Phase** and **Depends-on** (ticket ids) — the parallelization contract.
- **Suggested labels** — `agent:todo` + `complexity:N` (keep low) + optional
  `model:<backend>`.
- **Problem / context** — why, with file references.
- **Scope (exact)** — the exact files to change and the exact approach, precise enough
  that a mechanical agent needs to make no design decisions.
- **Out of scope** — so the agent doesn't wander.
- **Acceptance criteria** — observable and checkable.
- **Verification** — the exact commands (build + tests) proving the repo is still
  green and behavior is preserved.

Ticket rules: behavior-preserving; no feature removed; leaves the repo green on its
own; small (one coherent change, not a grab-bag); independent within its phase or
explicit deps; tied to the characterization tests wherever it changes risky code.

### Worked example ticket (match this shape exactly)

```markdown
# Extract `CodingAgent` backend behaviour and migrate Codex + Claude onto it

**Phase:** 2
**Depends-on:** T-012 (characterization tests for agent lifecycle), T-015 (orchestrator dispatch extracted)
**Labels:** `agent:todo` `complexity:3`

## Problem / context
Backend-specific logic for Codex and Claude is branched inline across
`src/lib/aiur/coding_agent.ex`, `src/lib/aiur/codex/coding_agent.ex`, and
`orchestrator.ex` via `case backend do ...` clauses. Adding a backend today means
editing every one of those sites. We want a single behaviour so backends are pure
additions.

## Scope (exact)
- Define an `Aiur.CodingAgent.Backend` behaviour with callbacks: `start/2`,
  `resumable?/1`, `resume/2`, `send_message/2`, `stop/1`, `capabilities/0`.
  (Confirm the full callback set against the inline branches you're replacing.)
- Move Codex logic into `Aiur.CodingAgent.Backend.Codex` implementing the behaviour;
  move Claude / `claude-app-server` logic into `Aiur.CodingAgent.Backend.Claude`.
- Replace every `case backend do` dispatch in `coding_agent.ex` and `orchestrator.ex`
  with a behaviour call resolved from a single `backend_module/1` registry lookup.
- No behavior change; both backends work exactly as before.

## Out of scope
- Any new backend (gemini / local / etc.).
- Changes to session-persistence semantics beyond preserving current `resumable?/1`.

## Acceptance criteria
- A single registry maps backend id → module; adding a backend requires only a new
  module + one registry line (no other file edits).
- No `case`/`if` on backend id remains in `orchestrator.ex` or `coding_agent.ex`.
- Codex and Claude agents start, message, stop, and resume identically to before.
- Each new/changed file ≤200 lines; each function ≤20 lines.

## Verification
- `cd src && mix compile --warnings-as-errors`
- `cd src && mix test` (all green; T-012 characterization tests unchanged and passing)
- Manual: launch one Codex and one Claude agent per AGENTS.md recipe; confirm
  start / message / stop / resume.
```

---

## Mandated tickets (these MUST exist)

- **Phase-1 gate — feature inventory + characterization tests / CI tripwire.**
  Establish the green safety net (behavior-pinning tests + CI) before any risky
  change ships. Nothing in later phases merges until this is in.
- **Coding-agent backend seam.** Extract a clean backend behaviour/adapter and
  migrate the existing Codex + Claude (`claude-app-server`) backends onto it, so new
  backends are pure additions. (No new backend implemented.)
- **Biggest-offender decomposition.** Break up `orchestrator.ex` (~7,600 LOC) and the
  other giants into focused, ≤200-line modules — sequenced so concurrent tickets never
  collide on the same file.
- **Docs framework + pages.** Install a current, popular, agent-friendly documentation
  framework into `website/` (so future agents document features easily), and author:
  a **quick-start** (install + usage); a **configuration** page (all options + config
  files); a couple of deeper **"what aiur is / how to use it"** pages; and a
  **skills** page split into two sections — **(a) user / driver skills** and
  **(b) the skills aiur's own agents use in their workspaces.** Also update the site
  to surface the newly-catalogued features.

---

## Non-goals / out of scope

- Do **not** implement the refactor — planning + tickets only.
- Do **not** remove or alter any feature's behavior.
- Do **not** implement any new coding-agent backend (gemini / local / OSS /
  openrouter are motivating examples only — just make the seam clean).
- Do **not** bump dependencies except installing the docs framework.
- Do **not** change the agent runtime/model architecture unless a specific ticket
  scopes it.
- No unrelated refactoring or scope creep beyond consolidation.

---

## Process & delivery

1. Explore + research (above), using ce-brainstorm / ce-plan / ce-doc-review.
2. Write the planning docs; self-review with ce-doc-review; fix issues inline.
3. Generate the 30–60 tickets. Make the `00-overview.md` index, phases, and
   dependency graph internally consistent — every dependency resolves, and no two
   concurrent tickets share a file.
4. Deliver as a **single PR** on a new branch (e.g. `refactor-plan`) with a body that
   summarizes the plan, the phase model, and the ticket count. **Do not open GitHub
   issues yourself** — the human reviews the ticket docs first, then converts them to
   `agent:todo` issues.

Treat this brief as a strong starting point, not gospel — you are more capable than
the process that produced it. If your research contradicts anything here, follow the
evidence and note the deviation in `00-overview.md`.
