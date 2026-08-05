---
date: 2026-06-17
topic: warm-main-base-for-agent-workspaces
---

# Warm Main Base for Instant Agent Workspaces

## Problem Frame

Every per-issue agent workspace cold-boots. Workspace creation is `mkdir` + the `.aiurconfig` `after_create` hook, which today runs a full network `git clone` of the target repo plus a from-scratch dependency install and compile. When N agents are dispatched at once these run in parallel and saturate the machine, leaving agents stuck in the TUI "warming up" state for minutes before any real work.

Measured this run (`aiur-team/aiur`, mix): 8 tickets dispatched → 11 parallel cold `mix compile`s → all 12 cores saturated → ~5–6 min of warming before the first agent narrated. The cost is paid **every dispatch** and gets worse with concurrency.

We want agents to spin a workspace off an already-warm copy of the repo's **latest main** — deps installed, build warm — so they jump straight into work. The hard constraint: aiur cannot assume the target repo's language or build system, and must not impose a container runtime (Docker) on the dev's unrelated repo.

---

## Actors

- A1. Dev / operator: runs `aiur init` and `aiur`; owns the target repo.
- A2. Dev's coding agent (claude / codex / etc.): authors the repo-specific hooks from a prompt aiur supplies during init. aiur never has to know the repo's language — the agent does.
- A3. aiur warm-base maintainer: new aiur feature that keeps an up-to-date checkout of the repo's main at `~/.aiur/repo/<repo>` with deps + build warm.
- A4. Per-issue agents: the dispatched agents whose workspaces spin off from the warm base.

---

## Key Flows

- F1. **Init setup (one-time)**
  - **Trigger:** dev runs `aiur init`.
  - **Actors:** A1, A2.
  - **Steps:** aiur scaffolds `.aiurconfig` + a new `.aiurhooks` file (config points to it) → the final init step prints a ready-to-paste prompt → dev pastes it to their coding agent (A2) → A2 inspects the repo's build system and writes repo-specific hooks into `.aiurhooks`.
  - **Outcome:** `.aiurhooks` contains hooks that spin a workspace off the warm base and run the repo's own incremental build.
  - **Covered by:** R6, R7, R8, R9.

- F2. **Warm-base refresh**
  - **Trigger:** main advances (mechanism TBD — see Outstanding Questions).
  - **Actors:** A3.
  - **Steps:** aiur fetches origin/main into `~/.aiur/repo/<repo>`, resets to HEAD, and re-runs the repo's build/deps step only if HEAD or the lockfile changed.
  - **Outcome:** the warm base is at latest main with deps installed and build warm.
  - **Covered by:** R1, R2, R3, R4.

- F3. **Workspace spin-off (per dispatch)**
  - **Trigger:** an issue is dispatched to an agent.
  - **Actors:** A3, A4.
  - **Steps:** the `after_create`/`before_run` hooks (authored in F1) copy or `git worktree` from `~/.aiur/repo/<repo>`, create the `aiur/<id>` branch, and run the repo's fast incremental build.
  - **Outcome:** the per-issue workspace has deps present and a warm build; the agent starts in seconds, not minutes.
  - **Covered by:** R5, R10, R11, R12.

```
aiur init ──┬─ scaffolds .aiurconfig + empty .aiurhooks  (config points to it)
            └─ final step PRINTS a copy-paste prompt ──► dev pastes to their agent (A2)
                                                            └─ writes repo-specific hooks → .aiurhooks

aiur (A3) ── keeps  ~/.aiur/repo/<repo> @ origin/main, deps+build WARM  ◄── refresh trigger (TBD)

dispatch ─► after_create / before_run hooks (from .aiurhooks):
              copy / git-worktree from ~/.aiur/repo/<repo>  +  repo's incremental build
            └─► per-issue workspace: deps present, build warm ─► agent works in seconds
```

---

## Requirements

**Warm-base maintainer (new aiur feature)**
- R1. aiur maintains a warm base checkout per target repo at `~/.aiur/repo/<repo>/`, kept at latest `origin/main`.
- R2. The warm base has the repo's dependencies installed and build warm (the dev's hooks define *how* the build is produced/refreshed; see R8), so a workspace spun off from it skips cold install/compile.
- R3. aiur refreshes the warm base when main advances. Trigger is a decision (lazy on dispatch, background poll, dev git hook, or a combination — see Outstanding Questions).
- R4. The warm base is a shared resource; aiur guards it against corruption from concurrent spin-offs and concurrent refresh (locking or a read-consistent snapshot).
- R5. aiur exposes the warm-base location and contract to hooks via an env var (e.g. `THIS_REPO_BASE`) so hooks reference it portably instead of hardcoding paths.

**Hooks relocation (`.aiurhooks`)**
- R6. Hook definitions move out of `.aiurconfig` into a new `.aiurhooks` file; `.aiurconfig` references it.
- R7. `.aiurhooks` supports the existing hook points (`after_create`, `before_run`, `after_run`, `before_remove`) and is the file the dev's agent edits.

**Agent-authored hook bootstrap (init)**
- R8. The final step of `aiur init` outputs a ready-to-paste prompt instructing the dev's coding agent to write repo-specific hooks into `.aiurhooks` that (a) spin a per-issue workspace off `~/.aiur/repo/<repo>` (copy or `git worktree`) and (b) run the repo's own fast/incremental build so the workspace is immediately buildable.
- R9. The prompt documents the warm-base contract (the path, that it is at latest main with deps + build warm), the available hook points, and the env vars (R5) — so the agent has everything it needs without aiur knowing the repo's language.
- R10. aiur ships safe default behavior when no custom hooks exist yet: it falls back to the current cold-clone path so init is non-blocking and the optimization is progressive/opt-in.

**Spin-off behavior**
- R11. With hooks in place, a fresh per-issue workspace starts with deps present and a warm build, eliminating the per-dispatch cold clone + compile.
- R12. The mechanism imposes no specific language, toolchain, or container runtime on the target repo (explicitly: no forced Docker).

---

## Acceptance Examples

- AE1. **Covers R8, R11.** Given a dev ran `aiur init` and pasted the prompt to their agent, which wrote `.aiurhooks` for their mix repo; when an issue is dispatched, the workspace is created by spinning off `~/.aiur/repo/aiur` and the build step is a near-no-op (no full cold compile), and the agent begins work in seconds.
- AE2. **Covers R3.** Given main advanced upstream since the last dispatch; when the next issue is dispatched, the warm base has been brought to the new main HEAD before the workspace is spun off.
- AE3. **Covers R10.** Given a dev who ran init but has not authored hooks yet; when an issue is dispatched, aiur uses the existing clone path (slower but functional), not an error.

---

## Success Criteria

- The per-dispatch cold "warming" window drops from minutes to seconds for a repo with hooks authored (measured on the aiur-self mix repo: ~5 min → seconds).
- No Docker, container runtime, or language assumption is imposed on the dev's repo.
- A downstream planner can implement without inventing product behavior: the warm-base location and contract, the `.aiurhooks` format + config pointer, the init-prompt behavior, and the cold-clone fallback are all specified. Only the refresh trigger and the spin-off mechanics remain as flagged decisions.

---

## Scope Boundaries

- **No CI-built artifact or Docker-image pipeline as the shipped mechanism.** Rejected because it forces CI wiring or a container runtime onto the dev's unrelated repo. May be *recommended* as an optional path for teams who already containerize, but it is out of scope for this feature.
- **aiur does not author the hooks or detect the toolchain itself** — that is deliberately delegated to the dev's coding agent (A2).
- **No change to opencode pre-warm / pane behavior** — separate concern (see #376).
- **Distributed / remote workers:** the warm base is local-machine-first; multi-host warm-base sync is deferred.

---

## Key Decisions

- **Delegate hook authoring to the dev's coding agent via a canned init prompt.** aiur can't assume the repo's language; the agent writes correct repo-specific build + spin-off steps. This is what makes the feature toolchain-generic without aiur detection logic.
- **Warm base lives at `~/.aiur/repo/<repo>` (home, not `/tmp`)** so it persists across sessions and reboots and is cheap to refresh incrementally.
- **Hooks live in a dedicated `.aiurhooks` file, not inline in `.aiurconfig`** — keeps config clean, supports multi-line scripts, and lets the agent regenerate hooks independently of other config.
- **Anchor on Option 2 (aiur-managed warm base) + agent-authored recipe (hooks).** Reject Docker/CI as defaults per the scope boundary above.

---

## Dependencies / Assumptions

- aiur already has the hook points (`after_create` / `before_run` / `after_run` / `before_remove`, `Config.Schema.Hooks`) and a workspace-create seam (`Workspace.create_for_issue` → `maybe_run_after_create_hook` in `src/lib/aiur/agent_environment.ex`) — **verified**.
- The current cold boot is a config-level `after_create` hook in `.aiurconfig` (`.aiurconfig:35`), not hardcoded — **verified**. This is the seam the feature plugs into.
- Assumes that starting from a warm base at a near-identical commit, the repo's top-up build is fast (true for mix incremental compile; pnpm offline install). Feature-branch divergence from main yields a partial rebuild, not a full one.
- This box is ext4 → no reflink/CoW, so a `cp` of the base is a full byte copy (still far cheaper than compiling). A `git worktree` spin-off avoids copying tracked files but still needs `_build`/deps seeded — **verified** ext4.

---

## Outstanding Questions

### Resolve Before Planning

- [Affects R3][User decision] What triggers warm-base refresh — lazy on dispatch, a background poll/watcher, a dev git hook, or a combination? Drives the freshness-vs-overhead tradeoff.
- [Affects R6, R7][User decision] `.aiurhooks` format and reference: YAML mirroring the current hook keys, or an executable script / directory of scripts? And does `.aiurconfig` point to it by explicit path or a fixed default filename?

### Deferred to Planning

- [Affects R4][Technical] Concurrency model for the shared base during parallel spin-offs + refresh (lock, snapshot, or per-dispatch freeze).
- [Affects R11][Technical] Spin-off mechanism: `git worktree` (shares objects; must seed `_build`/deps) vs `cp -a` of the base (includes build; full copy on ext4). Likely left to the agent-authored hook, but aiur's base layout must support both.
- [Affects R6][Technical] Migration / back-compat for existing inline `.aiurconfig` hooks.
- [Affects R3][Needs research] Multi-host / distributed-worker warm base.

---

## Next Steps

`Resolve Before Planning` is non-empty (2 product decisions). Resolve those, then `-> /ce-plan`. Alternatively, the dev may choose to carry them into planning explicitly as assumptions.

Related: this is the chosen concrete direction for #368 (pre-installed-dependencies environment); it supersedes the Docker-image framing in that issue with a no-coupling, agent-authored-hooks approach.
