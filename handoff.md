# HANDOFF — aiur `.aiur/` layout shipped; next up: prewarm measurement + #377

_Last updated: 2026-06-22. Main is green at the `.aiur/`-consolidation + dogfood + cleanup merges._

> Note: this file is tracked as `handoff.md` (lowercase) — on a case-insensitive macOS FS
> `HANDOFF.md` resolves to the same file. Edit this one.

## TL;DR for the next session

aiur now stores its config in a **`.aiur/` folder** (`.aiur/config`, `.aiur/hooks`,
`.aiur/prompt.md`), replacing the root `.aiurconfig`/`.aiurhooks`/`AIUR.md`. The feature
(#391), aiur's own dogfood migration (#393), and a cleanup (#394) are all merged to main.
**Not yet released to npm** (still 0.0.2). Next: run the migration on the other machine,
then measure warm-base prewarm before designing #377.

## What shipped (all merged to main)

- **#392** — `feat: Consolidate aiur files into a .aiur/ folder` (issue #391). 4-step
  discovery (`./.aiur/config` → `./.aiurconfig` → `~/.aiur/config` → `~/.aiurconfig`),
  init-driven migration of legacy layouts (settings preserved, `git mv` renames),
  repo-local `.gitignore` opt-in. Backward compatible — legacy root `.aiurconfig` still loads.
- **#393** — `chore: dogfood .aiur/ in aiur's own repo`. Migrated this repo's config to
  `.aiur/`. Surfaced + fixed a real bug: `init.ex` embeds `*.example` templates at compile
  time; the migration moved them, so embed paths now point at `.aiur/examples/`. Also:
  fresh `aiur init` no longer copies `*.example` into user repos (aiur-repo-only source).
- **#394** — `fix: untrack stale elixir/ build cruft`. A `git add -A` in #393 accidentally
  committed 4063 stale `elixir/` files; untracked + gitignored (`/elixir/`).

Origin docs: `docs/brainstorms/2026-06-21-aiur-folder-consolidation-requirements.md`,
`docs/plans/2026-06-21-001-feat-aiur-folder-consolidation-plan.md`.

## ⚠️ Gotchas (read before running anything)

- **`aiurdev` vs `aiur`.** `aiur` is the **published npm binary (0.0.2)** — it predates the
  `.aiur/` migration and will NOT prompt to migrate. Use **`aiurdev`** (local build from
  `main`) to exercise the new code. Force a fresh build with `cd src && aiurdev build` first.
- **`aiurdev` auto-rebuilds** when `src/` changed, so first launch may pause to recompile.
- **Never `git add -A`** at repo root — `elixir/` is gitignored now, but stage paths
  explicitly anyway.
- **CI before merge:** watch the actual run to completion (`gh run watch <id> --exit-status`);
  a single `gh pr checks` snapshot gave a false-green earlier. **Don't merge without operator
  go-ahead.** Run all checks from `src/` via `mise exec -- mix …` (or `make build|lint|coverage|dialyzer`).

## TODO: upgrade the other machine

1. `git pull` main (gets the `.aiur/` layout already; aiur's own config is at `.aiur/config`).
2. If that machine still has a **legacy root `.aiurconfig`** (its own, un-migrated), run
   `cd src && aiurdev build && aiurdev init` → it should print:
   _"aiur now keeps its files in a .aiur/ folder; yours use the legacy root layout. Migrate
   them into .aiur/ now?"_ → yes → then the `.gitignore` opt-in (say **no** for aiur's repo;
   you commit the config).

### What to test for
- Migration prompt fires for a legacy layout; **declining** leaves the old layout working.
- After migration: `git status` shows clean **renames**; `aiurdev` (or `mix`) still **builds**
  (the embed-path fix); `.aiur/config` loads.
- Fresh init in a scratch repo creates `.aiur/{config,hooks,prompt.md}` and **no** `examples/`.
- Repo root is clean (no `.aiur*`/`AIUR.md` files; only `.env` stays at root).

## NEXT WORK: warm-base prewarm (#377) — MEASURE FIRST

Operator's call: **measure before designing.** The shipped warm-base (#377 branch
`feat/warm-main-base`, U1–U6, NOT merged) refreshes the base lazily per-dispatch, so the
base build happens *during* the first dispatch instead of before agents start. The follow-up
is "eager prewarm + a loading bar in the agent list" — but it's **undesigned** (braindump at
`docs/brainstorms/2026-06-17-warm-base-prewarm-braindump.md` on the #377 branch, 3 open UX
decisions). A fresh `/ce-brainstorm` was started and is mid-flight.

**Operator wants measurements first** (run `aiurdev --debug` with many agents):
- **Startup phase timing** per agent — parse timestamped events in
  `~/code/aiur-workspaces/<id>/logs/agent.md`: workspace spin-off/clone → `before_run` hook →
  agent boot → first `turn/started` → first `agentMessage`. Goal: all agents start working
  immediately; confirm whether clone/fetch already happens before agent activation.
- **Token redundancy** (the real cost win): N agents doing the same task N× = N× spend. Log
  which tasks are duplicated and could be done once + shared.
- **CPU bottleneck**: raw processor contention as agent count climbs — worth discussing.
- Operator answered the framing question "is this observability or throughput?" → **throughput**
  (a real win exists), so measurement should locate where the time/cost actually goes.

Use **`/aiur-status`** to monitor (`bash .claude/skills/aiur-status/scripts/tail-agents.sh`;
or `/loop 60s /aiur-status` for a live feed). It reads each workspace's `logs/agent.md`, safe
anytime.

## Other open agent:todo tickets (GitHub, label `agent:todo`)

#387 `aiur message <issue>` CLI · #385 outdated-CLI notice · #384 reap stale artifacts
(handoff/.context/elixir — partly done: elixir/ now gitignored) · #383 `.aiurconfig` debug
setting · #382 agents use /aiur-agent skill · #379 reactivate on PR comments · #375 arrow-key
slot adjust · #371 read-only dashboard · #370 slim agent pre-prompt · #369 tmux pane titles ·
#366 agent-list theme · #365 RC chat title · #344 upstream issue sync · #341 max-duration pauses.

## Skills

`/aiur-status` = operator monitor (tail agent logs). `/aiur-agent` = cross-ticket event pub/sub.
`/aiur-agent` is what dispatched agents use. `release` skill cuts an npm release (needed before
the `.aiur/` migration reaches the published `aiur` command).
