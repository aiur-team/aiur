# T-057: Docs: concept pages (what aiur is / how to use)

**Phase:** 5
**Depends-on:** T-055
**Labels:** `agent:todo` `refactor` `phase:5` `complexity:2`

## Problem / context

The docs site shipped by T-055 (VitePress package building into
`website/dist/docs`, served at `aiur.team/docs`; see
`docs/refactor/research-docs-framework.md`) needs the conceptual pages that
explain what Aiur is and how it works. Today the only prose is `README.md`
(marketing-level) and the agent-facing `.claude/skills/using-aiur/` reference
docs — neither is a reader-facing "how does this system work" explanation, and
`README.md:42` already points readers at `src/README.md` for details that do
not cover the model conceptually.

This ticket writes three **plain-markdown** concept pages into the T-055 docs
package and registers them in that package's VitePress sidebar. Every claim
must be sourced from `README.md`, `.claude/skills/using-aiur/` (`SKILL.md`,
`turn-workflow.md`, `complexity-routing.md`, `dev-loop.md`), and the
feature-inventory sections `docs/refactor/feature-inventory/orc.md` and
`docs/refactor/feature-inventory/gh.md`. Invent nothing: do not document any
feature that is not present in those sources, and specifically do NOT document
the drifted/unshipped items in `docs/refactor/feature-inventory/doc.md`
(the `--record` `screen.ansi` recorder — FI-DOC-002 — and the `--debug`
`chat.<issue>.ansi` recorder — FI-DOC-001).

## Scope (exact)

The T-055 docs package root is `website/docs-app/` (the path named in
`docs/refactor/research-docs-framework.md`; T-055 created it, its
`.vitepress/` config, and its `bun.lock`). Create all three pages under
`website/docs-app/concepts/`. Make ZERO design decisions: filenames, titles,
section order, and the facts each section states are all fixed below. Each
page is plain GitHub-flavored markdown, begins with exactly one `#` H1 equal to
its stated title, and is **≤ 200 lines**. Use only Aiur's three shipped
implementation backends by name — `codex`, `claude`, `claude-repl` — and no
others.

1. **Create `website/docs-app/concepts/what-is-aiur.md`** — H1: `# What Aiur is`.
   Sections, in this order:
   1. **What it is** (one short paragraph): Aiur turns project work into
      isolated, autonomous implementation runs so teams manage work instead of
      supervising individual coding sessions; it watches a tracker for labeled
      work and starts an isolated run per selected ticket, and each run produces
      proof of work (CI status, PR review feedback, complexity analysis,
      walkthrough) and lands the PR when accepted. Source: `README.md:11-20`.
   2. **Tracker-driven** (short paragraph + list): trackers are pluggable
      adapters — a Linear board, GitHub issues, or the in-memory tracker —
      configured via `tracker.kind`; on trackers that support labels Aiur runs a
      label-based state machine. Source: `README.md:24-27`, and
      `docs/refactor/feature-inventory/doc.md` FI-DOC-003 (name all three kinds).
   3. **The label lifecycle** (ordered list, GitHub example, default label
      prefix `agent`): `agent:todo` → `agent:in-progress` → `agent:human-review`
      → (`agent:rework` on reviewer feedback, looping back through review) →
      `agent:merging` → `agent:done`; note the two terminal-error/cancel states
      `agent:error` and `agent:cancelled` (also spelled `canceled`), and that
      `agent:watch` labels a PR for monitoring and is deliberately NOT a
      dispatch state. State names must exactly match the canonical set. Source:
      `docs/refactor/feature-inventory/gh.md` FI-GH-019 (canonical label
      families) and FI-GH-015 (label-swap state machine);
      `.claude/skills/using-aiur/SKILL.md:25-33` (move to `agent:in-progress`,
      keep the workpad, flip to `agent:human-review` when the PR is ready, never
      self-merge).
   4. **Complexity routing** (short paragraph): each ticket carries a
      `complexity:1`–`complexity:5` label that routes its model, agent, and
      skill depth. Source: `docs/refactor/feature-inventory/gh.md` FI-GH-019
      (`complexity:1..5` labels), `.claude/skills/using-aiur/complexity-routing.md`,
      and `docs/refactor/feature-inventory/orc.md` FI-ORC-066
      (backend/model/effort resolve from issue labels).
   5. **Backends** (short paragraph + list of exactly three): implementation
      backends plug in behind Aiur's app-server protocol — `codex`, `claude`
      (headless), and `claude-repl` (the persistent interactive REPL that backs
      remote control); a `model:<backend>` label routes a ticket to a backend
      and `model:remote` enables remote control. Source: `README.md:24-25,31-32`,
      `docs/refactor/feature-inventory/orc.md` FI-ORC-066 (RC maps
      `claude`→`claude-repl`), `docs/refactor/feature-inventory/gh.md` FI-GH-019
      (`model:*` / `model:remote` labels).

2. **Create `website/docs-app/concepts/ticket-lifecycle.md`** — H1:
   `# How a ticket flows`. One short intro line naming the path
   `issue → workspace → agent turn → PR → review → merge`, then a numbered
   section per stage, in this order:
   1. **Issue** — a labeled `agent:todo` ticket enters the queue; the
      orchestrator orders candidates and dispatches those that pass the slot and
      blocker gates. Source: `docs/refactor/feature-inventory/orc.md` FI-ORC-008
      (dispatch ordering), FI-ORC-009 (dispatch candidate gates).
   2. **Workspace** — dispatch provisions an isolated clone/workspace for the
      run; each workspace writes a human-readable `logs/agent.md` transcript and
      a structured `logs/agent.ndjson` event stream. Source: `README.md:11-13,30-32`.
   3. **Agent turn** — the agent works on branch `aiur/<issue-number>`, running
      one or more turns while the ticket stays active (up to the configured
      `max_turns`), and keeps a single `## Agent Workpad` issue comment current.
      Source: `.claude/skills/using-aiur/SKILL.md:25-31`,
      `docs/refactor/feature-inventory/orc.md` FI-ORC-070 (turn loop),
      `docs/refactor/feature-inventory/gh.md` FI-GH-026 (`aiur/<issue>` branch).
   4. **PR** — the agent opens a pull request whose head branch is
      `aiur/<issue-number>` and whose description starts `Closes #<issue>`, then
      flips the ticket to `agent:human-review`; the human-review gate requires
      every unaddressed PR review thread to be cleared first. Source:
      `.claude/skills/using-aiur/SKILL.md:31-33`,
      `.claude/skills/using-aiur/dev-loop.md`,
      `docs/refactor/feature-inventory/gh.md` FI-GH-026 (branch→PR mapping) and
      FI-GH-033 (human-review gate).
   5. **Review** — code-owner/reviewer comments are classified; authoritative
      feedback moves the ticket to `agent:rework` and re-dispatches the agent on
      the same workspace to address it. The agent never self-merges — human
      review is required. Source: `.claude/skills/using-aiur/SKILL.md:26-28`,
      `docs/refactor/feature-inventory/orc.md` FI-ORC-026 (human-review
      deactivation) and FI-ORC-034 (comment-driven reactivation to rework),
      `docs/refactor/feature-inventory/gh.md` FI-GH-028 (CODEOWNERS-classified
      comments).
   6. **Merge** — when the PR merges, the ticket terminalizes to `agent:done`
      and the issue closes. Source:
      `docs/refactor/feature-inventory/orc.md` FI-ORC-036 (PR-merged
      terminalization), `docs/refactor/feature-inventory/gh.md` FI-GH-016
      (terminal state closes the issue).
   7. **The Agent Workpad convention** (final subsection): a single pinned
      issue comment beginning `## Agent Workpad` that the agent keeps current
      across turns; it is filtered from event polling so the agent's own workpad
      edits never wake agents or spam digests. Source:
      `.claude/skills/using-aiur/SKILL.md:25-26`,
      `docs/refactor/feature-inventory/gh.md` FI-GH-059 (workpad comment
      exclusion).

3. **Create `website/docs-app/concepts/operating-aiur.md`** — H1:
   `# Operating Aiur`. Sections, in this order:
   1. **The TUI board** — the terminal agent-list board shows running, paused,
      and idle ticket rows with runtime, turn count, backend, pinned model, work
      state, and pause reason. Source:
      `docs/refactor/feature-inventory/orc.md` FI-ORC-060 (dashboard broadcasts
      and status/snapshot surfaces).
   2. **The dashboard** — the Phoenix web dashboard supports Basic Auth and can
      be bound to a configured host/port for private access, and opens each
      run's `logs/agent.md` in a live-updating modal while the run is active.
      Source: `README.md:30-36`.
   3. **Alerts** — alerts are defined in the checked-in `.aiur/alerts.yaml`
      file, each with a `name`, `message`, and optional `sound`; agents raise
      milestone alerts via `emit_alert`. Source: `README.md:38-40`,
      `.claude/skills/using-aiur/SKILL.md:3` (milestone alerts / `emit_alert`).
   4. **Pause / resume** — operators pause and resume agents; a paused agent
      keeps its slot so polling cannot auto-claim over it; the concurrency cap
      is changed at runtime with the arrow keys or `aiur set max-agents N`, and
      the space key starts a queued ticket. Source:
      `docs/refactor/feature-inventory/orc.md` FI-ORC-011 (paused-slot
      reservation), FI-ORC-054 (pause/resume/space-key APIs), FI-ORC-012
      (`--max-agents` / runtime set).
   5. **Remote control** — remote control is opt-in per agent (the `model:remote`
      label or the `r` key); it rides the persistent `claude-repl` session and
      is local-only in v1, and the opencode chat panes let an operator type into
      the live session while the Codex/Claude runtime and transcript stay the
      source of truth. Source:
      `docs/refactor/feature-inventory/orc.md` FI-ORC-057 (remote-control
      promote/demote), `README.md:33-34` (opencode chat panes).

4. **Register the three pages in the T-055 VitePress sidebar.** Edit the
   sidebar config T-055 created at `website/docs-app/.vitepress/config.mts`
   (if T-055 wrote the config as `.mjs`/`.ts`, edit that same file — do not
   create a second config). Add ONE sidebar group titled exactly `Concepts`,
   with these three links in this exact order:
   - `What Aiur is` → `/concepts/what-is-aiur`
   - `How a ticket flows` → `/concepts/ticket-lifecycle`
   - `Operating Aiur` → `/concepts/operating-aiur`
   Do not reorder or rename any existing sidebar groups T-055 or T-056 added.

5. From `website/docs-app/`, run the docs package's own build (the command
   T-055 wired) and confirm it emits the three pages under
   `website/dist/docs/concepts/`. From `website/`, confirm the marketing guards
   still pass unchanged (`npm run typecheck`, `npm run build`, `npm run assert`).

## Files

- Create: `website/docs-app/concepts/what-is-aiur.md`,
  `website/docs-app/concepts/ticket-lifecycle.md`,
  `website/docs-app/concepts/operating-aiur.md`
- Modify: `website/docs-app/.vitepress/config.mts` (the sidebar config created
  by T-055 — add only the `Concepts` group; if T-055 used a `.mjs`/`.ts`
  extension, edit that file instead)
- Test: None (prose docs; no Elixir/JS units) — see Characterization-tests

## Out of scope

- Any file under `src/` — this ticket writes no Elixir and runs no `mix`.
- `README.md`, `src/README.md`, `.claude/skills/**`, and everything under
  `docs/refactor/` — these are the SOURCES for the prose; read them, do not
  edit them.
- The VitePress theme, `website/docs-app/index.md` / landing, `nav`, search, or
  build wiring — all owned by T-055; touch only the sidebar `Concepts` group.
- The quick-start / configuration pages (T-056) and the skills page (T-058) —
  do not create, reorder, or edit their pages or sidebar groups.
- The marketing site: `website/src/**` (`dashboard.ts`, `simData.ts`,
  `terminal.ts`, `styles.css`), `website/netlify.toml`, and the golden snapshot
  / `scripts/gen-golden.ts` — must stay byte-identical (`npm run assert`
  unaffected).
- Documenting any feature not present in the listed sources — in particular the
  FI-DOC-001 `chat.<issue>.ansi` recorder and the FI-DOC-002 `--record`
  `screen.ansi` recorder (both unshipped doc-drift).

## Inventory-IDs

These concept pages DOCUMENT (do not implement) the following features; each
statement in the pages must match the cited behavior.

From `docs/refactor/feature-inventory/orc.md`:
- FI-ORC-008 — dispatch ordering (ticket-lifecycle: Issue)
- FI-ORC-009 — dispatch candidate gates (ticket-lifecycle: Issue)
- FI-ORC-011 — global cap with paused-slot reservation (operating: pause/resume)
- FI-ORC-012 — `--max-agents` override + runtime set (operating: pause/resume)
- FI-ORC-026 — human-review deactivation (ticket-lifecycle: Review)
- FI-ORC-034 — trusted-comment reactivation to rework (ticket-lifecycle: Review)
- FI-ORC-036 — PR-merged terminalization (ticket-lifecycle: Merge)
- FI-ORC-054 — pause/resume/space-key control APIs (operating: pause/resume)
- FI-ORC-057 — remote-control promote/demote toggle (operating: remote control)
- FI-ORC-060 — dashboard broadcasts and status surfaces (operating: TUI board)
- FI-ORC-066 — backend/model/effort resolution + RC decision (what-is-aiur:
  complexity routing, backends)
- FI-ORC-070 — turn loop (ticket-lifecycle: Agent turn)

From `docs/refactor/feature-inventory/gh.md`:
- FI-GH-015 — `update_issue_state` label-swap lifecycle (what-is-aiur: label
  lifecycle)
- FI-GH-016 — terminal state closes the issue (ticket-lifecycle: Merge)
- FI-GH-019 — canonical label families (state + `complexity:*` + `model:*` +
  `agent:watch`) (what-is-aiur: label lifecycle, complexity, backends)
- FI-GH-026 — canonical `aiur/<issue>` branch → open-PR mapping
  (ticket-lifecycle: Agent turn, PR)
- FI-GH-028 — CODEOWNERS-classified review/issue comments (ticket-lifecycle:
  Review)
- FI-GH-033 — human-review gate on unaddressed review threads
  (ticket-lifecycle: PR)
- FI-GH-059 — Agent Workpad comment exclusion (ticket-lifecycle: workpad
  convention)

Cross-referenced for the "do not invent" guard (must NOT be documented):
`docs/refactor/feature-inventory/doc.md` FI-DOC-001, FI-DOC-002.

## Characterization-tests

None under `src/test/aiur/regression/` — this ticket adds only markdown prose
under `website/docs-app/`, which no regression test exercises. The protection
is the docs package build succeeding and the marketing golden snapshot
(`website` `npm run assert`) staying byte-identical.

## Acceptance criteria

- The three pages exist at the exact paths in Files;
  `test $(ls website/docs-app/concepts/what-is-aiur.md website/docs-app/concepts/ticket-lifecycle.md website/docs-app/concepts/operating-aiur.md | wc -l) -eq 3`.
- Each page is ≤ 200 lines: `awk 'END{exit NR>200}' <file>` succeeds for each.
- Each page begins with exactly its H1:
  `head -1 website/docs-app/concepts/what-is-aiur.md` == `# What Aiur is`;
  `ticket-lifecycle.md` == `# How a ticket flows`;
  `operating-aiur.md` == `# Operating Aiur`.
- Every canonical state label appears in `what-is-aiur.md`:
  `grep -q 'agent:todo' … 'agent:in-progress' … 'agent:human-review' …
  'agent:rework' … 'agent:merging' … 'agent:done'` (all six present); the page
  also names `agent:error`, `agent:cancelled`, and `agent:watch`.
- Only the three shipped backends are named — `codex`, `claude`, `claude-repl`
  — and no other backend name appears in the pages.
- No unshipped/doc-drift feature is documented:
  `grep -rIE 'screen\.ansi|chat\.[^ ]*\.ansi|--record' website/docs-app/concepts/`
  prints nothing (guards FI-DOC-001/FI-DOC-002).
- The sidebar config gains one `Concepts` group linking all three pages in
  order: `grep -c '/concepts/' website/docs-app/.vitepress/config.mts` ≥ 3 and
  the string `Concepts` is present; the three links resolve to
  `/concepts/what-is-aiur`, `/concepts/ticket-lifecycle`, `/concepts/operating-aiur`.
- The docs package build succeeds and emits all three pages:
  `website/dist/docs/concepts/what-is-aiur.html`,
  `website/dist/docs/concepts/ticket-lifecycle.html`, and
  `website/dist/docs/concepts/operating-aiur.html` all exist after the build.
- The marketing golden snapshot is unchanged:
  `git diff --name-only origin/v2...HEAD` lists none of `website/src/**`,
  `website/netlify.toml`, or `website/scripts/gen-golden.ts`, and
  `npm run assert` (from `website/`) passes.
- `git diff --name-only origin/v2...HEAD` lists ONLY the files in the Files
  section — in particular nothing under `src/`, `README.md`, `.claude/`, or
  `docs/refactor/`.

## Verification

### Agent gate (run all, from src/)
```
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
```
(This ticket changes no Elixir; the gate must still be green — it validates the
inherited `v2` state, not this diff.)

### Website / docs package
```
cd website && npm run typecheck && npm run build && npm run assert
cd website/docs-app && bun install --frozen-lockfile && bun run build
```
(The `website/docs-app` build command is the one T-055 wired; the bun form
above is its expected shape per `docs/refactor/research-docs-framework.md`. It
must emit `website/dist/docs/concepts/{what-is-aiur,ticket-lifecycle,operating-aiur}.html`.)

### At-merge (reviewer)
- Check: `bun run docs:dev` (or the T-055 preview command) and open
  `/docs/concepts/what-is-aiur`, `/docs/concepts/ticket-lifecycle`, and
  `/docs/concepts/operating-aiur` — each renders, appears in the `Concepts`
  sidebar group in order, and the in-page search finds "label lifecycle",
  "Agent Workpad", and "remote control".
- Check: spot-read each page against `README.md`, `.claude/skills/using-aiur/`,
  and the cited FI-ORC/FI-GH entries — every factual claim traces to a source;
  the label lifecycle matches FI-GH-019 exactly; no feature outside the sources
  is described.
- Check: `grep -rIE 'screen\.ansi|chat\.[^ ]*\.ansi|--record' website/docs-app/concepts/`
  is empty (no doc-drift feature resurrected).
- Check: `git diff origin/v2...HEAD -- website/src website/netlify.toml` is
  empty and `npm run assert` passes (marketing bundle untouched).

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
