---
title: "feat: Warm main base for instant agent workspaces"
type: feat
status: active
date: 2026-06-17
deepened: 2026-06-17
origin: docs/brainstorms/2026-06-17-warm-main-base-requirements.md
---

# feat: Warm main base for instant agent workspaces

## Overview

Per-issue agent workspaces cold-boot today: workspace creation runs the `.aiurconfig` `after_create` hook, which does a full network `git clone` + a from-scratch dependency install and compile. With N agents dispatched at once these run in parallel and saturate the machine — measured this session at ~5–6 min of "warming" before any agent narrated (8 tickets → 11 parallel cold `mix compile`s).

This plan makes aiur maintain a **warm base checkout of the repo's latest main** at `~/.aiur/repo/<repo>` (deps installed, build warm), and lets per-issue workspaces **spin off** from it (copy or `git worktree`) instead of cold-cloning. Because aiur can't assume the target repo's language, the repo-specific hooks (base build + spin-off) are authored by the dev's own coding agent from a prompt aiur emits at the end of `aiur init`. Hook definitions move out of `.aiurconfig` into a dedicated `.aiurhooks` file.

---

## Problem Frame

Cold per-dispatch boot wastes wall-clock, tokens, and CPU, and degrades with concurrency. The fix must (a) keep a warm, main-tracking base, (b) stay toolchain-neutral (no forced Docker, no language assumption), and (c) remain progressive — a repo with no hooks authored yet must still work via the existing clone path. See origin: `docs/brainstorms/2026-06-17-warm-main-base-requirements.md`.

---

## Requirements Trace

- R1. aiur maintains a warm base checkout per repo at `~/.aiur/repo/<repo>/`, kept at latest `origin/main`.
- R2. The base has deps installed + build warm (produced by a dev-authored base hook), so spin-offs skip cold install/compile.
- R3. aiur refreshes the base when main advances: lazy staleness check at dispatch (fetch→reset→re-run base hook when HEAD/lockfile changed) + optional background poll. *(decided)*
- R4. The shared base is guarded against corruption from concurrent spin-offs + refresh (serialized refresh).
- R5. aiur exposes the base path to hooks via `THIS_REPO_BASE`.
- R6. Hook definitions move out of `.aiurconfig` into `.aiurhooks`, referenced by path (default `.aiurhooks`); inline hooks still load for back-compat. *(decided: YAML, same keys)*
- R7. `.aiurhooks` supports the existing hook points + a new base-build hook; it is the file the dev's agent edits.
- R8. The final `aiur init` step outputs a ready-to-paste prompt telling the dev's coding agent to author repo-specific hooks (base build + spin-off-from-base + incremental build).
- R9. The prompt documents the base contract (path, "latest main, deps+build warm"), hook points, and `THIS_REPO_BASE`.
- R10. With no custom hooks yet, aiur falls back to the current cold-clone path (non-blocking, opt-in).
- R11. With hooks in place, a fresh workspace starts with deps present + warm build, eliminating per-dispatch cold clone+compile.
- R12. No language/toolchain or container runtime is imposed on the target repo.

**Origin actors:** A1 (dev/operator), A2 (dev's coding agent — authors hooks), A3 (aiur warm-base maintainer), A4 (per-issue agents).
**Origin flows:** F1 (init setup), F2 (warm-base refresh), F3 (workspace spin-off).
**Origin acceptance examples:** AE1 (covers R8, R11 — spin-off skips cold compile), AE2 (covers R3 — base advanced before spin-off), AE3 (covers R10 — fallback when no hooks).

---

## Scope Boundaries

- No CI-built artifact or Docker-image pipeline as the shipped mechanism (rejected: forces infra/containers on the dev's repo). Recommend-only, out of scope here.
- aiur does not author hooks or detect the toolchain — delegated to the dev's coding agent.
- No change to opencode pre-warm / pane behavior (separate; see #376).

### Deferred to Follow-Up Work

- Multi-host / distributed-worker warm-base sync: deferred to a later iteration (local-machine-first for v1).

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/config/schema.ex:352` — `Config.Schema.Hooks` embedded schema (`after_create`/`before_run`/`after_run`/`before_remove`/`timeout_ms`). Top-level Settings `embedded_schema` at `:445` (where a `hooks_file` field is added).
- `src/lib/aiur/config.ex:151` — `Config.workspace_hooks/0` builds the hook map from `settings!().hooks`; `:30`/`:43` `settings`/`settings!`. Config is parsed from `.aiurconfig` YAML via `YamlElixir` (`workflow.ex`). `.aiurhooks` loads the same way and merges into the `hooks` subtree.
- `src/lib/aiur/workspace.ex` — workspace lifecycle: `create_for_issue/2` (`:15`) → `ensure_workspace` → `maybe_run_after_create_hook` (`:24`); `run_before_run_hook`/`run_after_run_hook`/`run_hook`. This is where base-ensure is invoked before the after_create hook.
- `src/lib/aiur/agent_environment.ex:42` — `workspace_env/1` injects `HEX_HOME`/`MIX_HOME`/`AIUR_AGENT_WORKSPACE` into hook/agent execution; `workspace_env_export_prefix/1` (`:69`) is the SSH-launch shell-export twin. `THIS_REPO_BASE` is added to both.
- `src/lib/aiur/init.ex` — wizard: `run/2` (`:96`), `final_screen` (`:197`/`:211`/`:217`), `ensure_prompt_file` (the pattern to mirror as `ensure_hooks_file`). `@config_file_name ".aiurconfig"` (`:19`); scaffolds from `.aiurconfig.example` / `AIUR.md.example` (`@external_resource` pattern).
- `THIS_REPOSITORY_URL` is already provided to hooks (#361) — reuse as the base's clone source.

### Institutional Learnings

- The current cold boot is a **config-level `after_create` hook** (`.aiurconfig:35`), not hardcoded — verified. This is the seam; nothing in the engine hardcodes clone/compile.
- ext4 on the dev box → no reflink/CoW; a `cp` of the base is a full byte copy (still far cheaper than compiling). `git worktree` avoids copying tracked files but must seed `_build`/deps. The plan supports both and leaves the choice to the dev-authored hook.
- Existing test patterns: `src/test/aiur/init_test.exs`, `src/test/aiur/workspace_and_config_test.exs` (config + scaffold), `src/test/aiur/codex/config_test.exs` (schema changeset tests) — mirror these.

### External References

- None needed — local patterns (Ecto embedded-schema config, injected-`io`/`deps` init wizard, hook seam) are well-established in-repo.

---

## Key Technical Decisions

- **Warm base at `~/.aiur/repo/<repo>` owned by a serialized maintainer (`Aiur.RepoBase` GenServer).** Home (not `/tmp`) so it survives reboots; a GenServer serializes refresh so parallel dispatches can't read a half-updated base (R4).
- **Lazy-on-dispatch refresh + optional background poll.** Lazy guarantees freshness exactly when a spin-off needs it; the poll hides refresh latency from the first dispatch. Git-hook-driven refresh rejected (per-clone, doesn't fire on *remote* main advancing).
- **Base build is itself a dev-authored hook (`base_setup`), not aiur logic.** Keeps aiur toolchain-neutral (R12) and symmetrical with the spin-off hook — both written by the dev's agent.
- **`.aiurhooks` is YAML with the same hook keys, referenced by `hooks_file` (default `.aiurhooks`); inline `.aiurconfig` hooks remain a fallback.** Reuses the existing `Hooks` changeset and migration is a file move, not a parser rewrite (R6).
- **Spin-off mechanism (worktree vs copy) is the hook's choice, not aiur's.** aiur only guarantees the base contract + `THIS_REPO_BASE`; the hook decides how to derive a workspace from it.

---

## Open Questions

### Resolved During Planning

- Refresh trigger (origin Resolve-Before-Planning): lazy-on-dispatch staleness + optional background poll. *(user-decided)*
- `.aiurhooks` format/reference (origin Resolve-Before-Planning): YAML, same hook keys, `hooks_file` path pointer (default `.aiurhooks`), inline fallback. *(user-decided)*
- Base build ownership: a new dev-authored `base_setup` hook, run by `RepoBase` in the base dir on HEAD/lockfile change.

### Deferred to Implementation

- Exact staleness signal beyond `origin/main` HEAD movement (whether to also hash the lockfile, and which lockfile — repo-declared vs heuristic). Start with HEAD-moved OR `base_setup` never-run; refine if needed.
- Concurrency mechanics: whether spin-offs block during an in-flight refresh or proceed against last-good state. Default: caller awaits `ensure_fresh/1` return before spin-off; document if revisited.
- Whether the background poll lives inside `RepoBase` (self-scheduling) or a thin separate ticker. Decide when wiring supervision.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

```
DISPATCH (per issue)
  Workspace.create_for_issue/2
    └─ RepoBase.ensure_fresh(repo_url)         ── serialized GenServer (A3) ───────────┐
         if origin/main moved OR base_setup never ran:                                 │
           git -C ~/.aiur/repo/<repo> fetch + reset --hard origin/main                 │  R1,R2,R3,R4
           run `.aiurhooks: base_setup` IN the base dir  (dev-authored: deps + build)  │
         returns base_path ───────────────────────────────────────────────────────────┘
    └─ env adds THIS_REPO_BASE=base_path   (AgentEnvironment.workspace_env/1)            R5
    └─ maybe_run_after_create_hook  →  `.aiurhooks: after_create` (dev-authored):
         spin off workspace FROM $THIS_REPO_BASE (worktree or copy) + incremental build  R11,R12
    └─ (no hooks configured) → existing cold-clone after_create path unchanged           R10

CONFIG LOAD
  .aiurconfig (YAML)  ── hooks_file: .aiurhooks ──►  merge .aiurhooks hooks subtree       R6,R7
                         (absent → inline .aiurconfig `hooks:` fallback)

INIT (one-time)
  aiur init … → scaffold .aiurhooks + set hooks_file → final_screen prints PASTE-PROMPT   R8,R9
                                                          └─ dev pastes to their agent (A2)
                                                               └─ writes base_setup + after_create
```

---

## Implementation Units

- [ ] U1. **`.aiurhooks` config plumbing + `base_setup` hook key**

**Goal:** Add a `hooks_file` pointer to the config, load hook definitions from `.aiurhooks` (YAML, same keys) when present, fall back to inline `.aiurconfig` `hooks:`, and extend the `Hooks` schema with a `base_setup` hook.

**Requirements:** R6, R7

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur/config/schema.ex` (add `field(:hooks_file, :string)` to top-level Settings; add `field(:base_setup, :string)` to `Hooks` + its `cast` list)
- Modify: `src/lib/aiur/config.ex` (resolve `hooks_file` relative to the config dir, read+parse the YAML, merge its hook keys into the `hooks` subtree before `Schema.parse`; extend `workspace_hooks/0` to surface `base_setup`)
- Test: `src/test/aiur/workspace_and_config_test.exs`

**Approach:**
- `.aiurhooks` is the `hooks:` subtree as a standalone YAML doc. When `hooks_file` is set, its contents win; when absent, inline `hooks:` is used unchanged (back-compat).
- Keep `base_setup` optional (nil when unset) so existing configs and the fallback path are unaffected.

**Execution note:** Test-first — config parsing/merge/fallback is pure and well-suited to characterization + new-behavior tests before the change.

**Patterns to follow:**
- `Config.Schema.Hooks` changeset (`schema.ex:366`); `src/test/aiur/codex/config_test.exs` for changeset-level tests; `workspace_and_config_test.exs` for file-load tests.

**Test scenarios:**
- Happy path: `.aiurconfig` with `hooks_file: .aiurhooks` + a `.aiurhooks` defining `after_create`/`base_setup` → `workspace_hooks/0` returns those values.
- Edge case: `hooks_file` set but file missing → clear error (or documented fallback), not a crash.
- Edge case (back-compat): no `hooks_file`, inline `hooks:` present → loads exactly as today.
- Edge case: both `hooks_file` and inline `hooks:` present → `.aiurhooks` takes precedence (documented), inline ignored.
- Edge case: `base_setup` absent → surfaced as nil; `workspace_hooks/0` shape stable.
- Covers AE3 partial: empty/absent hooks → map with nil values, enabling the U3 fallback.

**Verification:** Config with a `.aiurhooks` file round-trips through `Config.workspace_hooks/0`; inline-hooks configs behave identically to before; `base_setup` is readable.

---

- [ ] U2. **`Aiur.RepoBase` warm-base maintainer (GenServer)**

**Goal:** Maintain `~/.aiur/repo/<repo>` at latest `origin/main` with deps+build warm, refreshing lazily and serialized.

**Requirements:** R1, R2, R3, R4

**Dependencies:** U1 (reads `base_setup` from config)

**Files:**
- Create: `src/lib/aiur/repo_base.ex` (`Aiur.RepoBase`)
- Modify: `src/lib/aiur/application.ex` (add to supervision tree)
- Test: `src/test/aiur/repo_base_test.exs`

**Approach:**
- `ensure_fresh(repo_url)` (GenServer `call`, serialized): ensure `~/.aiur/repo/<repo>` exists (clone once if not); `git fetch` + compare `origin/main` HEAD to the base HEAD; if moved (or `base_setup` never ran), `reset --hard origin/main` and run the `base_setup` hook in the base dir; return `{:ok, base_path}`.
- Derive `<repo>` from the repo URL (owner/name slug). Use `THIS_REPOSITORY_URL`/tracker repo as the source.
- Serialization via the single GenServer process is the concurrency guard (R4) — no two refreshes interleave; spin-off callers await the return.
- **Warm build survives refresh:** `_build`/deps are gitignored, so `reset --hard origin/main` updates *tracked source* but leaves build artifacts in place. The base's own `base_setup` run is therefore incremental, and so is every later refresh — the warm state persists across main advances.
- Run the `base_setup` hook through the **same hook runner** used for workspace hooks (reuse `Workspace.run_hook`-style execution), but with **base-scoped env** — `AgentEnvironment.workspace_env(base_path)` so `HEX_HOME`/`MIX_HOME` resolve under the base (its own `.aiur-hex`/`.aiur-mix`), not a workspace. Spin-off hooks can then copy those caches too.

**Execution note:** Test-first for the staleness decision (HEAD-moved / never-built) against a local temp git repo.

**Patterns to follow:**
- GenServer + supervision registration like `src/lib/aiur/opencode/*` servers; hook execution via `workspace.ex run_hook`.

**Test scenarios:**
- Happy path: fresh machine, no base → clones, runs `base_setup`, returns path; base HEAD == origin/main.
- Happy path: base already current (HEAD == origin/main, base_setup ran) → no fetch-reset/rebuild work performed (idempotent fast path).
- Edge case (R3/AE2): origin/main advanced → fetch+reset to new HEAD and re-run `base_setup` before returning.
- Edge case: `base_setup` unset → maintain the checkout but skip the build step (base still usable for worktree; deps/build left to the spin-off hook).
- Error path: `base_setup` hook exits non-zero → surfaced/logged; `ensure_fresh` returns an error, callers fall back (ties to R10/U3).
- Integration (R4): two concurrent `ensure_fresh` calls → serialized, no interleaved git state; both observe a consistent base.

**Verification:** Repeated `ensure_fresh` is idempotent when main hasn't moved; advances + rebuilds when it has; concurrent calls don't corrupt the base.

---

- [ ] U3. **Dispatch integration + `THIS_REPO_BASE` + cold-clone fallback**

**Goal:** Call `RepoBase.ensure_fresh/1` before the `after_create` hook, expose `THIS_REPO_BASE` to hooks, and keep the existing cold-clone path when no warm-base/hooks are configured.

**Requirements:** R5, R10, R11, R12

**Dependencies:** U1, U2

**Files:**
- Modify: `src/lib/aiur/workspace.ex` (`create_for_issue`/`maybe_run_after_create_hook`: ensure base fresh, pass base path)
- Modify: `src/lib/aiur/agent_environment.ex` (`workspace_env/1` + `workspace_env_export_prefix/1`: add `THIS_REPO_BASE`)
- Test: `src/test/aiur/agent_environment_test.exs`, `src/test/aiur/workspace_and_config_test.exs`

**Approach:**
- Gate base-ensure on configuration: only ensure/refresh + set `THIS_REPO_BASE` when a warm-base-capable hook setup exists (e.g. `base_setup` present). Otherwise skip straight to the existing after_create path (R10) — zero behavior change for unconfigured repos.
- **Local dispatch only in v1:** `THIS_REPO_BASE` points at a path on the operator machine. For SSH/remote workers that path does not exist, so do **not** export it remotely — remote dispatch falls back to cold clone (multi-host base is deferred follow-up). The local Port.open env gets `THIS_REPO_BASE`; the SSH export prefix omits it.

**Execution note:** Add a failing integration-style test asserting `THIS_REPO_BASE` reaches the hook env before wiring.

**Patterns to follow:**
- `agent_environment.ex:42` env-list shape; the `AIUR_AGENT_WORKSPACE` precedent for a per-run path var.

**Test scenarios:**
- Happy path (R5): `workspace_env/1` includes `THIS_REPO_BASE` = the base path when a base is configured.
- Edge case (R10/AE3): no `base_setup`/warm base configured → `ensure_fresh` not invoked; `THIS_REPO_BASE` absent; existing cold-clone after_create runs unchanged.
- Edge case: SSH-launch export prefix **omits** `THIS_REPO_BASE` (local-only path; remote falls back to cold clone).
- Error path: `ensure_fresh` errors (U2) → dispatch falls back to cold clone, not a hard failure.
- Integration (R11): with a base + spin-off hook, the created workspace references `$THIS_REPO_BASE` (assert env presence + hook invocation; full spin-off is a dev-hook concern).

**Verification:** Configured repos get `THIS_REPO_BASE` and a base-ensure before after_create; unconfigured repos behave exactly as today.

---

- [ ] U4. **Optional background base poll**

**Goal:** Keep the base warm proactively (config-gated) so the first dispatch doesn't eat the refresh latency.

**Requirements:** R3

**Dependencies:** U2

**Files:**
- Modify: `src/lib/aiur/repo_base.ex` (self-scheduling tick calling `ensure_fresh/1`) or Create a thin ticker module
- Modify: `src/lib/aiur/config/schema.ex` (a poll-interval setting; `0`/absent = disabled)
- Test: `src/test/aiur/repo_base_test.exs`

**Approach:**
- A periodic `ensure_fresh/1` while aiur runs, disabled by default (opt-in interval). Reuses U2's serialized path, so a poll and a dispatch can't collide.

**Patterns to follow:**
- `Process.send_after/3` self-tick pattern used elsewhere (e.g. progress/check-in workers, `chat_completions.ex` watchdog timer).

**Test scenarios:**
- Happy path: interval configured → tick triggers `ensure_fresh` (assert via a stubbed/observable refresh).
- Edge case: interval `0`/absent → no polling scheduled.
- Integration (R4): a poll tick during a dispatch is serialized through the GenServer (no concurrent git ops).

**Test expectation:** behavioral — cover scheduling on/off + serialization.

**Verification:** With polling on, the base trends fresh without a dispatch; with it off, no background git activity.

---

- [ ] U5. **Init wizard: scaffold `.aiurhooks` + agent-authoring prompt**

**Goal:** `aiur init` scaffolds a `.aiurhooks` template, sets `hooks_file`, and the final step prints a ready-to-paste prompt instructing the dev's coding agent to author the repo-specific hooks.

**Requirements:** R8, R9

**Dependencies:** U1

**Files:**
- Modify: `src/lib/aiur/init.ex` (`ensure_hooks_file` mirroring `ensure_prompt_file`; write `hooks_file: .aiurhooks` into the config; extend `final_screen` to print the paste-prompt)
- Create: `.aiurhooks.example` (commented template with the four hook points + `base_setup`, documenting `THIS_REPO_BASE`)
- Test: `src/test/aiur/init_test.exs`

**Approach:**
- The paste-prompt is a static string (with the repo's tracker URL interpolated) describing the base contract, hook points, `THIS_REPO_BASE`, and the two hooks to write (`base_setup`: deps+build in the base; `after_create`: spin off from `$THIS_REPO_BASE` + incremental build). aiur never writes the hook bodies — only the template + prompt.
- **The prompt must require a defensive `after_create`:** when `$THIS_REPO_BASE` is empty/missing (unconfigured, remote worker, or a failed base refresh), the hook must fall back to a normal `git clone` instead of erroring. This is what keeps R10 true *after* hooks are authored — without it, a base-dependent hook would break the no-base path.
- Scaffolding is non-blocking: init succeeds whether or not the dev runs the prompt (R10 holds — empty hooks → fallback).

**Execution note:** Use the injected `io`/`deps` test harness already in `init.ex` — assert on captured output, no real FS/network.

**Patterns to follow:**
- `init.ex` `ensure_prompt_file` + `@external_resource` template loading; `final_screen` output; `init_test.exs` injected-io assertions.

**Test scenarios:**
- Happy path (R8): running init creates `.aiurhooks` and writes `hooks_file: .aiurhooks` into the config.
- Happy path (R9): `final_screen` output contains the paste-prompt with the base contract, `THIS_REPO_BASE`, and both hook names.
- Edge case: `.aiurhooks` already exists → not clobbered (`:exists` like `ensure_prompt_file`).
- Edge case: global config location → repo-specific hooks omitted/handled like `prompt_file` is for global.
- Covers AE1 (setup half): post-init state is exactly what a dev pastes to their agent to reach the warm-spin-off path.

**Verification:** A fresh `aiur init` yields `.aiurhooks` + `hooks_file` set + a final-screen prompt an agent can act on.

---

- [ ] U6. **Migration + docs: move repo hooks to `.aiurhooks`**

**Goal:** Migrate this repo's own inline `.aiurconfig` hooks to `.aiurhooks`, and document the move + the warm-base feature.

**Requirements:** R6, R12

**Dependencies:** U1

**Files:**
- Create: `.aiurhooks` (this repo's hooks, incl. a `base_setup` for mix and a base-spin-off `after_create`)
- Modify: `.aiurconfig` (replace inline `hooks:` with `hooks_file: .aiurhooks`)
- Modify: `.aiurconfig.example`, and `AIUR.md.example`/`README` as needed (document `.aiurhooks` + `THIS_REPO_BASE`)
- Test: none (config/docs) — covered by U1's load tests

**Approach:**
- Dogfood the feature on aiur itself: author the mix `base_setup` (`mix deps.get && mix compile` in the base) and an `after_create` that spins a workspace off `$THIS_REPO_BASE` with an incremental `mix compile`.
- Keep the change reversible — inline fallback (U1) means a bad `.aiurhooks` can be deleted to restore prior behavior.

**Patterns to follow:**
- Existing `.aiurconfig.example` hook comments; the current `after_create` body as the migration source.

**Test scenarios:**
- Test expectation: none — pure config/doc move; behavior is exercised by U1's file-load tests and a manual dogfood run.

**Verification:** aiur runs against its own repo using `.aiurhooks`; deleting `.aiurhooks` cleanly reverts to inline/cold behavior.

---

## System-Wide Impact

- **Interaction graph:** Dispatch path (`Workspace.create_for_issue` → `RepoBase.ensure_fresh` → `maybe_run_after_create_hook`); config load (`.aiurconfig` → `.aiurhooks` merge); init wizard final step; supervision tree gains `Aiur.RepoBase`.
- **Error propagation:** `ensure_fresh` / `base_setup` failures must degrade to the cold-clone fallback (R10), never hard-fail a dispatch. Surface as logged warnings.
- **State lifecycle risks:** The shared base is the main hazard — concurrent refresh/spin-off, a half-applied `reset --hard`, or a failed `base_setup` leaving a dirty base. Serialize refresh (U2) and treat a failed base as "fall back to cold clone," not "use a broken base."
- **API surface parity:** `THIS_REPO_BASE` is local-dispatch only — present in the Port.open env (`workspace_env/1`), deliberately **absent** from the SSH export prefix (`workspace_env_export_prefix/1`) since the base path is not valid on a remote host.
- **Integration coverage:** U3's "env var reaches the hook" and U2's "concurrent ensure_fresh" are the cross-layer scenarios unit mocks won't prove.
- **Unchanged invariants:** Unconfigured repos (no `base_setup`/`hooks_file`) must behave byte-for-byte as today. The existing `Hooks` keys, `workspace_hooks/0` shape, and inline-`hooks:` parsing remain valid.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Shared base corrupted by concurrent refresh/spin-off | Serialize all refresh through the `RepoBase` GenServer; spin-offs await `ensure_fresh` return (R4, U2) |
| `base_setup` failure leaves a broken/dirty base | On non-zero `base_setup`, return error → dispatch falls back to cold clone (R10); don't hand out a broken base |
| Feature-branch checkout diverges from main base | Base tracks main; the dev's `after_create` runs an *incremental* build on top — partial recompile, not full. Acceptable; documented |
| ext4 (no reflink) makes `cp` of base a full copy | Spin-off mechanism is the hook's choice; `git worktree` avoids copying tracked files. Plan supports both |
| Back-compat break for existing inline-hooks configs | Inline `hooks:` remains a fallback when `hooks_file` is unset (U1); migration is opt-in |
| Staleness check too weak (serves stale deps after lockfile change) | Start with HEAD-moved trigger; allow lockfile-hash as a follow-up refinement (deferred-to-impl) |
| Base-dependent `after_create` breaks the no-base / remote / failed-refresh path | The init paste-prompt mandates a **defensive** hook that falls back to `git clone` when `$THIS_REPO_BASE` is absent (U5) — preserves R10 even after hooks exist |
| `git worktree` spin-off interacting with a concurrent base refresh | Refresh is serialized and only touches the base's `main`; worktrees live on their own `aiur/<id>` branch. Worktree pruning/cleanup mechanics deferred-to-impl |

---

## Documentation / Operational Notes

- Document `.aiurhooks` + `hooks_file` + `THIS_REPO_BASE` in `.aiurconfig.example` and the README/AIUR docs (U6).
- The paste-prompt (U5) is itself the primary "operator doc" — it must be self-contained enough that a coding agent writes correct hooks from it alone.

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-06-17-warm-main-base-requirements.md](docs/brainstorms/2026-06-17-warm-main-base-requirements.md)
- Related code: `src/lib/aiur/config/schema.ex:352`, `src/lib/aiur/config.ex:151`, `src/lib/aiur/workspace.ex`, `src/lib/aiur/agent_environment.ex:42`, `src/lib/aiur/init.ex`
- Related issues: #368 (pre-installed-dependencies environment — this is its chosen no-coupling direction)
