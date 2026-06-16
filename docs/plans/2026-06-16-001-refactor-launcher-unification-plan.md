---
title: "refactor: unify aiurdev + aiur launchers into one engine"
type: refactor
status: active
date: 2026-06-16
---

# refactor: unify aiurdev + aiur launchers into one engine

## Overview

`scripts/aiurdev` (~2270 lines, full command surface) and
`packaging/npm/aiur-cli/libexec/aiur-launch.sh` (~309 lines, only `init` + interactive run) are two
separate launcher implementations. Installed `aiur` therefore can't run `--bg`, `stop`, `list`,
`status`, `pause`, `resume`, `sweep`, or profiles — and the init wizard's final screen already
promises `aiur --bg`.

This refactor extracts a **single launcher engine** that owns every subcommand, parameterized by a
**distribution identity** (release dir + node/cookie/state/tmux naming). `aiurdev` and the installed
`aiur` become thin wrappers that set their identity and exec the shared engine. No second
command-surface copy is ever maintained again.

---

## Problem Frame

The two launchers diverge on the **distribution contract** that RPC subcommands depend on:

| | node name | cookie file | tmux session | profiles/state |
|---|---|---|---|---|
| `scripts/aiurdev` | `aiurdev-$USER@127.0.0.1` (`:822`) | `~/.local/state/aiurdev/cookie` (`:780`) | `aiurdev-$USER-$profile` (`:1458`) | `~/.config/aiurdev/` |
| `aiur-launch.sh` | `aiur-$USER@127.0.0.1` (`:110`) | `~/.config/aiur/cookie` (`:85`) | `aiur-$USER` (`:202`) | `~/.config/aiur/` |

RPC commands (`status`/`pause`/`resume`) only reach a node with the matching name **and** cookie, and
attach/sweep key on the tmux session name. So a naive "share one engine with one hardcoded contract"
would rename aiurdev's nodes/sessions — breaking running dev sessions and tests asserting
`RELEASE_NODE=aiurdev-`.

**Both launchers already honor `AIUR_RELEASE_NODE`** (`aiurdev:822`, `aiur-launch.sh:110`), which is
the seam this plan builds on: the engine reads its identity from env vars; the wrappers supply
different values. aiurdev keeps `aiurdev-` naming, installed `aiur` keeps `aiur-` naming, and the
**command logic is shared**.

---

## Requirements Trace

- R1. One engine owns every subcommand (`init`, `run`/default/`<profile>`, `--bg`, `stop`, `list`,
  `status`, `pause`, `resume`, `build`, `sweep`, `--help`); no logic is duplicated between launchers.
- R2. The engine is parameterized by a distribution identity (release dir, node prefix, cookie path,
  state dir, tmux/session prefix, profiles/config path) read from env — no hardcoded `aiur-`/`aiurdev-`.
- R3. `scripts/aiurdev` is reduced to a thin resolver: pick the local `_build` release, build-if-stale,
  set the aiurdev identity, exec the engine. Its node/cookie/session naming is unchanged (`aiurdev-…`).
- R4. Installed `aiur` execs the **same** engine with the `aiur-` identity and the installed release
  dir, gaining the full command surface (incl. `aiur --bg`).
- R5. Dev mode (`aiurdev …`) is verified end-to-end against the local build; installed-mode
  verification (which needs a cut release) is documented, not skipped silently.

---

## Scope Boundaries

- Not changing any Elixir/BEAM behavior or the `Aiur.CLI` argument contract — this is launcher-shell
  refactoring only. The engine still execs the same release `bin/aiur` with the same args.
- Not aligning the two distribution identities (NOT renaming aiurdev nodes to `aiur-`). Divergent
  naming is preserved on purpose via parameterization.
- Not changing the npm package's install layout or publish flow beyond shipping the engine file.
- Not adding new subcommands — only making the existing aiurdev surface reachable from installed `aiur`.

### Deferred to Follow-Up Work

- Cutting and publishing a release to live-verify installed `aiur <subcommand>` end-to-end: a separate
  release/QA pass (this branch is dev-verified + structurally wired).

---

## Context & Research

### Relevant Code and Patterns

- `scripts/aiurdev` — the canonical command surface. Key regions: distribution setup
  (`ensure_erlang_cookie` ~`:780`, `prepare_distribution` ~`:815-851`), `source_env_files` (`:762`),
  `run_foreground`/`run_in_tmux` (`:1365`, `:1653`), RPC subcommands (`status` `:976`/`:2179`,
  `pause`/`resume` `:2183`/`:2187`, `list` `:2175`), `--bg`/`stop`/`sweep` (`:2217`/`:2231`/`:2244`),
  `init` (`:2247`), build-if-stale (`ensure_built`, `build`), the top dispatch case (~`:2160-2300`),
  tmux session naming (`aiur_tmux_session_name` `:1458`), profiles (`~/.config/aiurdev/aiurdev.profiles`).
- `packaging/npm/aiur-cli/libexec/aiur-launch.sh` — the installed thin launcher; already a "port of
  scripts/aiurdev ensure_erlang_cookie + prepare_distribution" (comment `:79`). Reads `AIUR_RELEASE_DIR`
  (`:7`), builds the interactive run command (`:47-65`), passes the distribution env to tmux (`:270`).
- `packaging/npm/aiur-cli/bin/` (npm bin entrypoint) — resolves the platform release and execs
  `aiur-launch.sh`; today only routes init + run.
- `src/test/scripts_aiurdev_test.exs` — characterizes aiurdev launch behavior (init `--eval` boot,
  release resolution). Asserts launch-command shape; will need updates as logic moves to the engine.

### Institutional Learnings

- Memory `project-aiur-aiurdev-parity`: one launcher engine, parameterized by release dir; aiurdev is
  a thin resolver; never two command-surface copies. The "hard blocker" (divergent cookie/node) is the
  reason for the identity-parameterization approach here.
- `bin/aiur eval` is `-noinput`; the interactive `init`/TUI boots via `elixir --eval` (the
  `build_init_cmd` form). Preserve this — the engine must keep the non-eval interactive boot path.

---

## Key Technical Decisions

- **Parameterize, don't align.** The engine reads a distribution identity from env vars; wrappers set
  them. aiurdev keeps `aiurdev-$USER` + `~/.local/state/aiurdev` + `aiurdev-` sessions; installed `aiur`
  keeps `aiur-$USER` + `~/.config/aiur`. This sidesteps the rename blocker entirely (no running-session
  or test breakage) while sharing all command logic. Rationale: the only thing that *must* differ
  between dev and installed is identity + which release dir; everything else is identical.

- **Engine lives in the npm package dir** (`packaging/npm/aiur-cli/libexec/aiur-engine.sh`) so it ships
  to installed users AND is `exec`-able from the repo by `scripts/aiurdev`. One source file, two
  callers. `aiur-launch.sh` collapses into (or is replaced by) a thin wrapper that sets the `aiur-`
  identity and execs the engine.

- **Identity contract (env vars the engine reads), e.g.:** `AIUR_RELEASE_DIR`, `AIUR_NODE_PREFIX`
  (`aiur`/`aiurdev`), `AIUR_COOKIE_FILE`, `AIUR_BG_STATE_DIR`, `AIUR_SESSION_PREFIX`, `AIUR_PROFILES_FILE`,
  plus an optional `AIUR_BUILD_HOOK` (dev-only build-if-stale). Exact names finalized in U1. The engine
  defaults to the installed (`aiur`) identity when unset, so the installed wrapper stays minimal.

- **Phased + dev-verified.** Phase 1 extracts the engine and keeps aiurdev fully working against the
  local build (live-verifiable now). Phase 2 wires installed `aiur` to the engine (structurally
  complete; final live-verify deferred to a cut release).

---

## Open Questions

### Resolved During Planning

- Does unification force renaming aiurdev's nodes? No — identity parameterization preserves
  `aiurdev-` naming (both launchers already read `AIUR_RELEASE_NODE`).
- Where does the shared engine live so both repo and npm use it? In the npm package's `libexec/`,
  exec'd by `scripts/aiurdev` from the repo and shipped to installed users.

### Deferred to Implementation

- The exact identity env-var names and which aiurdev globals map to them (resolved while extracting U2).
- Whether `aiur-launch.sh` is deleted (engine subsumes it) or kept as the 5-line `aiur` wrapper —
  decided once the engine's entrypoint shape is concrete (U4).
- Final shape of `scripts/aiurdev`'s build-if-stale hook handed to the engine (U3).

---

## Implementation Units

- [ ] U1. **Define the distribution-identity contract**

**Goal:** A documented set of env vars that fully parameterize the engine's identity + release dir,
with installed-`aiur` defaults baked in.

**Requirements:** R2

**Files:**
- Create: `packaging/npm/aiur-cli/libexec/aiur-engine.sh` (header + identity resolution only)
- Test: `src/test/scripts_aiurdev_test.exs` (assert identity resolution from env)

**Approach:** Enumerate every place aiurdev/aiur-launch.sh hardcode identity (node, cookie, state,
session, profiles) and replace with reads of a single `resolve_identity` block. Defaults = installed
`aiur` identity so an unset env yields the installed contract.

**Test scenarios:**
- Happy path: with the aiurdev identity env set, resolution yields `aiurdev-$USER@127.0.0.1`, the
  aiurdev cookie path, and `aiurdev-` session prefix.
- Edge case: with no identity env, resolution yields the installed `aiur-$USER` defaults.

**Verification:** A single function/block produces the full identity; no `aiur-`/`aiurdev-` literals
remain outside it.

---

- [ ] U2. **Extract the command engine**

**Goal:** Move aiurdev's full command surface (dispatch + all helpers) into `aiur-engine.sh`, reading
identity from U1 — no behavior change for dev.

**Requirements:** R1, R2

**Dependencies:** U1

**Files:**
- Modify: `packaging/npm/aiur-cli/libexec/aiur-engine.sh`
- Modify: `scripts/aiurdev` (temporary: source/exec the engine)
- Test: `src/test/scripts_aiurdev_test.exs`

**Approach:** Lift `source_env_files`, distribution setup, `run_foreground`/`run_in_tmux`, RPC
subcommands, `--bg`/`stop`/`sweep`/`list`/`status`/`pause`/`resume`, `init`, and the top dispatch case
into the engine. Replace identity literals with U1 reads. Keep the interactive `elixir --eval` init
boot path intact. The build-if-stale step becomes an optional `AIUR_BUILD_HOOK` the engine calls before
exec (dev sets it; installed doesn't).

**Execution note:** Characterization-first — capture aiurdev's current launch-command output for each
subcommand (via the existing test harness) before moving code, then assert byte-equivalence after.

**Test scenarios:**
- Happy path: each subcommand (`init`, `run`/default, `--bg`, `stop`, `list`, `status`, `pause`,
  `resume`, `sweep`) produces the same launch command / node target as before under the aiurdev identity.
- Edge case: `init` still boots via interactive `elixir --eval` (not `bin/aiur eval`).
- Error path: unknown subcommand prints usage and exits non-zero, as today.

**Verification:** `scripts_aiurdev_test.exs` green with assertions now exercising the engine; manual
aiurdev subcommands behave identically.

---

- [ ] U3. **Reduce `scripts/aiurdev` to a thin resolver**

**Goal:** `aiurdev` only resolves the local `_build` release, runs build-if-stale, sets the aiurdev
identity, and execs the engine.

**Requirements:** R3

**Dependencies:** U2

**Files:**
- Modify: `scripts/aiurdev`
- Test: `src/test/scripts_aiurdev_test.exs`

**Approach:** Strip the lifted command logic; keep only release-dir resolution
(`src/_build/dev/rel/aiur`), the `build`/build-if-stale hook, the aiurdev identity exports, the
in-tmux guard, and `exec aiur-engine.sh "$@"`.

**Test scenarios:**
- Happy path: `aiurdev <cmd>` execs the engine with `AIUR_RELEASE_DIR=…/_build/dev/rel/aiur` and the
  aiurdev identity; `RELEASE_NODE` still resolves `aiurdev-$USER@127.0.0.1`.
- Edge case: a stale build triggers the build hook before exec; `aiurdev build` still force-rebuilds.

**Verification:** aiurdev is a small resolver (no command logic); all subcommands still work in dev.

---

- [ ] U4. **Wire installed `aiur` to the engine**

**Goal:** Installed `aiur` execs the engine with the `aiur-` identity + installed release dir, gaining
the full command surface.

**Requirements:** R1, R4

**Dependencies:** U2

**Files:**
- Modify: `packaging/npm/aiur-cli/libexec/aiur-launch.sh` (collapse to the thin `aiur` wrapper, or
  delete in favor of the engine entrypoint)
- Modify: `packaging/npm/aiur-cli/bin/` entrypoint (route all subcommands to the engine, not just init/run)
- Modify: `packaging/npm/aiur-cli/` packaging manifest if needed (ship `aiur-engine.sh`)

**Approach:** The installed bin resolves the platform release dir, sets the `aiur-` identity (engine
defaults), and execs `aiur-engine.sh "$@"`. Remove the init/run-only routing.

**Test scenarios:**
- Happy path (mocked release dir): `aiur --bg`/`stop`/`status` route to the engine with the `aiur-`
  identity and the installed `AIUR_RELEASE_DIR`.
- Edge case: `aiur init` still boots interactively (engine init path), matching dev.

**Verification:** Installed entrypoint delegates every subcommand to the engine; the engine file is in
the package manifest.

---

- [ ] U5. **Update tests + docs for the unified structure**

**Goal:** Tests reflect the engine/wrapper split; aiurdev identity assertions still pass.

**Requirements:** R1, R3

**Dependencies:** U2, U3, U4

**Files:**
- Modify: `src/test/scripts_aiurdev_test.exs`
- Modify: any docs referencing the two launchers (e.g. AGENTS.md launcher notes)

**Approach:** Re-point characterization assertions at the engine; keep `aiurdev-` node/cookie assertions
(identity preserved). Add an assertion that installed-identity defaults yield `aiur-`.

**Test scenarios:**
- Happy path: aiurdev launch assertions green against the engine; `aiurdev-` node name preserved.
- Edge case: engine with no identity env asserts the `aiur-` installed defaults.

**Verification:** Full suite green; no test still assumes a monolithic `scripts/aiurdev`.

---

- [ ] U6. **Dev end-to-end verification + release-verify runbook**

**Goal:** Prove dev mode end-to-end; document the installed-mode verification that needs a cut release.

**Requirements:** R5

**Dependencies:** U3, U4

**Files:** none (manual + a short doc note)

**Approach:** Drive `aiurdev init`, `aiurdev` (TUI), `aiurdev --bg` + `aiurdev status`/`stop` against the
local build (real PTY). Write a runbook entry for verifying installed `aiur <subcommand>` after the
next release cut.

**Test expectation:** none — manual verification gate.

**Verification:** All dev subcommands work via the engine; the installed-mode runbook is captured for
the release pass.

---

## Phased Delivery

### Phase 1 — Engine + dev (live-verifiable now)
U1 → U2 → U3 → U5 (dev assertions) → U6 (dev half). aiurdev runs entirely through the engine; fully
testable against the local build.

### Phase 2 — Installed wiring (release-verified later)
U4 → U5 (installed-default assertions) → U6 (runbook). Structurally complete; final live-verify deferred
to a cut release.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Renaming aiurdev nodes/sessions breaks running sessions + tests | Identity is parameterized; aiurdev keeps `aiurdev-` naming. No rename. |
| A 2270-line bash refactor silently changes a subcommand | Characterization-first (U2): assert per-subcommand launch-command byte-equivalence before/after. |
| Installed mode can't be live-verified here | Phase 2 is structurally wired + dev-proven through the shared engine; installed verify is an explicit runbook deferred to a release cut. |
| Engine file not shipped in the npm package | U4 updates the package manifest; a test asserts the engine is present in the package file list. |
| In-tmux guard / interactive `--eval` init path regresses | U2 preserves both explicitly with edge-case tests. |

---

## System-Wide Impact

- **Interaction graph:** RPC subcommands depend on node-name+cookie matching; the identity contract is
  the single source of those values. tmux attach/sweep depend on the session prefix (also identity).
- **API surface parity:** the whole point — installed `aiur` gains parity with aiurdev's surface.
- **Unchanged invariants:** the release `bin/aiur` arg contract, `Aiur.CLI` behavior, aiurdev's
  `aiurdev-` distribution identity, and the interactive `elixir --eval` init boot all stay as-is.

---

## Sources & References

- Memory: `project-aiur-aiurdev-parity`
- Prior plan deferral: `docs/plans/2026-06-15-002-feat-init-wizard-rework-plan.md` (Deferred-to-Follow-Up)
- Related code: `scripts/aiurdev`, `packaging/npm/aiur-cli/libexec/aiur-launch.sh`
