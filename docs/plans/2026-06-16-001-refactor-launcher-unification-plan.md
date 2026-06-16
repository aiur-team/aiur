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

**End state (decided 2026-06-16):** there is **one** launcher — `aiur`, the engine, shipped in the npm
package. It owns every subcommand and uses a **single distribution identity** (`aiur-$USER@127.0.0.1`
node, `~/.config/aiur` cookie/state, `aiur` tmux session). `aiurdev` is **not** a second surface — it
is a ~15-line dev shim that runs the *same* engine against the local `src/_build` release (with a
build-if-stale step) instead of the npm-installed one. Its only parameter is which release directory to
run (`AIUR_RELEASE_DIR`).

```
aiur     = bin/aiur.js → engine, AIUR_RELEASE_DIR = installed platform package
aiurdev  = scripts/aiurdev → engine, AIUR_RELEASE_DIR = src/_build/dev/rel/aiur (+ build-if-stale)
```

The `aiurdev`/`aiur` distribution-identity split is **removed** (user decision: aiurdev is solo dev
testing, never run alongside a prod `aiur`, so coexistence isn't needed). This is simpler than a
parameterized identity and means one engine with one identity to maintain.

---

## Problem Frame

The command logic exists twice. aiurdev has the complete surface; `aiur-launch.sh` has a thin subset.
The two also diverge on the BEAM distribution identity (node name + cookie + tmux session) that RPC
subcommands (`status`/`pause`/`resume`) and tmux attach/sweep depend on — aiurdev uses `aiurdev-…`
under `~/.local/state/aiurdev` + `~/.config/aiurdev`, the installed launcher uses `aiur-…` under
`~/.config/aiur`. Collapsing to one engine with the single `aiur` identity removes both the duplication
and the divergence; aiurdev simply adopts the `aiur` identity.

---

## Requirements Trace

- R1. One engine owns every subcommand (`init`, `run`/default/`<profile>`, `--bg`, `stop`, `list`,
  `status`, `pause`, `resume`, `build`, `sweep`, `--help`); no logic duplicated between launchers.
- R2. The engine uses the single `aiur` distribution identity (no per-caller identity). Its only
  runtime parameter is `AIUR_RELEASE_DIR` (which release to exec).
- R3. `scripts/aiurdev` is reduced to a thin shim: resolve the local `_build` release, build-if-stale,
  set `AIUR_RELEASE_DIR`, exec the engine. No command logic remains in it.
- R4. Installed `aiur` (`bin/aiur.js`) execs the same engine with the installed release dir, gaining the
  full command surface (incl. `aiur --bg`).
- R5. Dev mode (`aiurdev …`) is verified end-to-end against the local build; installed-mode verification
  (which needs a cut release) is documented, not skipped silently.

---

## Scope Boundaries

- Not changing any Elixir/BEAM behavior or the `Aiur.CLI` arg contract — launcher-shell refactor only.
- Not preserving aiurdev's old `aiurdev-`/`~/.config/aiurdev` identity — it adopts the `aiur` identity
  (one-time change on the dev's machine; tests asserting `aiurdev-` move to `aiur-`).
- Not keeping a coexistence guarantee between a prod `aiur` and a local `aiurdev` (explicitly dropped).
- Not changing the npm install layout beyond shipping the engine file.

### Deferred to Follow-Up Work

- **Publishing** to the npm registry. The installed flow is verified *before* publishing via
  `npm pack` + local install (see "Pre-Release Install Verification"); only the registry upload itself
  is deferred.

---

## Pre-Release Install Verification

The downstream goal is to publish `0.0.1` and **know it works without iterating releases**. The install
flow has exactly two release-specific moving parts beyond the engine `aiurdev` already proves:

1. `bin/aiur.js` `resolveReleaseDir()` — `require.resolve("aiur-cli-<triple>")` → that package's
   `release/` dir, passed to the engine as `AIUR_RELEASE_DIR`.
2. The `files` allowlist shipping everything the engine needs (engine script, tmux conf).

Both are provable locally with `npm pack` (the exact published tarball, respecting `files`):

- **Layer 1 — CLI + engine from the packed artifact:** `npm pack` `aiur-cli`, install the tarball into a
  temp prefix, and run `aiur` with `AIUR_RELEASE_DIR` pointed at a locally-built release. Proves
  `bin/aiur.js` → engine → BEAM works from the *packed* files (engine ships, paths resolve), decoupled
  from platform-package download. Requires `bin/aiur.js` to honor a pre-set `AIUR_RELEASE_DIR` (U7).
- **Layer 2 — platform-package resolution:** `npm pack` a platform package whose `release/` is a real
  local build, install both tarballs together, run `aiur` with **no** `AIUR_RELEASE_DIR` → proves
  `resolveReleaseDir()` finds the package and runs its release.

If both layers pass, the only difference at publish time is the registry download (mechanical), so
`0.0.1` ships with confidence. This is a separate effort after the engine lands, but the engine design
(one engine, `AIUR_RELEASE_DIR`-parameterized) is what makes it cheap.

---

## Context & Research

### Relevant Code and Patterns

- `scripts/aiurdev` — the canonical, complete command surface. Key regions: distribution setup
  (`ensure_erlang_cookie` ~`:777`, `prepare_distribution` ~`:813`), `source_env_files` (`:762`),
  `run_foreground`/`run_in_tmux` (`:1365`, `:1653`), RPC subcommands (`status` `:933`/`:976`,
  `pause`/`resume`, `list`), `--bg`/`stop`/`sweep` (`~:2217`+), `init` (`~:2247`), build-if-stale
  (`ensure_built`/`build`), top dispatch case (`~:2150-2300`), tmux session naming
  (`aiur_tmux_session_name`), profiles.
- `packaging/npm/aiur-cli/libexec/aiur-launch.sh` — the thin installed launcher (init + interactive run
  only); already a "port of scripts/aiurdev ensure_erlang_cookie + prepare_distribution". Its logic is
  superseded by the engine.
- `packaging/npm/aiur-cli/bin/aiur.js` — the npm entrypoint; currently execs `aiur-launch.sh`. Repoints
  to the engine.
- `packaging/npm/aiur-cli/libexec/aiur-engine.sh` — the engine (started: distribution functions + the
  `aiur` identity). Grows to the full surface here.
- `src/test/scripts_aiurdev_test.exs` — characterizes aiurdev launch behavior (asserts `MISE:exec`,
  `SYSTEMCTL:` for `--bg`, `RELEASE_NODE=…`, init `--eval` boot). This **is** the characterization net;
  keep it green through the move (its `aiurdev-` node assertions become `aiur-`).
- `src/test/aiur_engine_test.exs` — engine-level tests (created in LU1).

### Institutional Learnings

- Memory `project-aiur-aiurdev-parity`: one launcher engine; aiurdev is a thin resolver; never two
  command-surface copies. (The identity-parameterization framing there is now superseded by the
  simpler single-identity decision.)
- `bin/aiur eval` is `-noinput`; interactive `init`/TUI boots via `elixir --eval`. Preserve this.

---

## Key Technical Decisions

- **Single identity, one engine.** The engine hardcodes the `aiur` identity (`aiur-$USER@127.0.0.1`,
  `~/.config/aiur/cookie`, `aiur` tmux session, `~/.config/aiur/aiur.profiles`). No `AIUR_NODE_PREFIX`
  /etc. parameterization — that was for a coexistence guarantee we dropped. Rationale: least machinery;
  one identity to reason about.

- **One real parameter: `AIUR_RELEASE_DIR`.** Installed `aiur` sets it to the platform package release;
  `aiurdev` sets it to `src/_build/dev/rel/aiur`. Everything else is identical.

- **aiurdev is a shim, not a surface.** It owns only: resolve local release dir, build-if-stale
  (`mise`/`mix release` dev step), exec the engine. All command logic lives in the engine.

- **Engine file = `aiur-engine.sh`** (shipped in the npm `files` list); `bin/aiur.js` and `scripts/aiurdev`
  both exec it. `aiur-launch.sh` is deleted once the engine absorbs its init/run logic.

- **Characterization-first.** `scripts_aiurdev_test.exs` pins per-subcommand launch behavior; keep it
  green through the extraction (updating `aiurdev-` → `aiur-` where the identity now differs).

---

## Open Questions

### Resolved During Planning

- Does aiurdev need its own identity? No — it shares `aiur`'s (user decision). No parameterization.
- Where does the engine live so both callers use it? npm package `libexec/aiur-engine.sh`, exec'd from
  the repo by `scripts/aiurdev` and shipped to installed users via `bin/aiur.js`.
- Keep `aiur-launch.sh`? No — fold its init/run into the engine and delete it.

### Deferred to Implementation

- Exact dev build-if-stale hook shape handed to aiurdev (LU3).
- Whether `bin/aiur.js` needs any change beyond the exec target (LU4).

---

## Implementation Units

- [ ] U1. **Engine skeleton + single identity** *(done; simplify from parameterized to fixed)*

**Goal:** `aiur-engine.sh` exists with the fixed `aiur` identity + the distribution functions
(`ensure_erlang_cookie`/`prepare_distribution`), shipped in the package files list.

**Requirements:** R2

**Files:**
- Modify: `packaging/npm/aiur-cli/libexec/aiur-engine.sh`
- Modify: `packaging/npm/aiur-cli/package.json`
- Test: `src/test/aiur_engine_test.exs`

**Approach:** Drop the LU1 identity-override env vars; resolve the fixed `aiur` identity directly. Keep
`AIUR_RELEASE_DIR`. Distribution functions use the fixed cookie path + node name.

**Test scenarios:**
- Happy path: engine resolves `aiur-$USER@127.0.0.1` + `~/.config/aiur/cookie`.
- Edge case: `prepare_distribution` exports `RELEASE_DISTRIBUTION/NODE/COOKIE/ERL_AFLAGS` as today.

**Verification:** `aiur_engine_test.exs` green; no identity-override env remains.

---

- [ ] U2. **Extract the command surface into the engine**

**Goal:** Move aiurdev's full command logic (dispatch + helpers) into `aiur-engine.sh`, using the fixed
identity and `AIUR_RELEASE_DIR`. Fold in `aiur-launch.sh`'s init/run.

**Requirements:** R1, R2

**Dependencies:** U1

**Files:**
- Modify: `packaging/npm/aiur-cli/libexec/aiur-engine.sh`
- Modify: `scripts/aiurdev` (temporary: source/exec the engine as logic moves)
- Delete: `packaging/npm/aiur-cli/libexec/aiur-launch.sh` (once superseded)
- Test: `src/test/scripts_aiurdev_test.exs`, `src/test/aiur_engine_test.exs`

**Approach:** Lift `source_env_files`, profile helpers, `run_foreground`/`run_in_tmux`, RPC subcommands,
`--bg`/`stop`/`sweep`/`list`/`status`/`pause`/`resume`, `init`, and the top dispatch into the engine,
reading `AIUR_RELEASE_DIR` for the release. Preserve the interactive `elixir --eval` init boot. Move in
sourced layers so the characterization suite stays green at each step.

**Execution note:** Characterization-first — `scripts_aiurdev_test.exs` is the safety net; assert
per-subcommand behavior unchanged (node name now `aiur-`).

**Test scenarios:**
- Happy path: each subcommand (`init`, run/default/`<profile>`, `--bg`, `stop`, `list`, `status`,
  `pause`, `resume`, `sweep`) produces the same launch command / RPC target as today, under the `aiur`
  identity.
- Edge case: `init` still boots via interactive `elixir --eval`.
- Error path: unknown profile prints usage + exits non-zero.

**Verification:** Both test files green; manual aiurdev subcommands behave identically (now `aiur-` node).

---

- [ ] U3. **Reduce `scripts/aiurdev` to a thin shim**

**Goal:** aiurdev only resolves the local release, builds-if-stale, sets `AIUR_RELEASE_DIR`, execs the
engine.

**Requirements:** R3

**Dependencies:** U2

**Files:**
- Modify: `scripts/aiurdev`
- Test: `src/test/scripts_aiurdev_test.exs`

**Approach:** Strip all lifted logic; keep release-dir resolution (`src/_build/dev/rel/aiur`), the
build-if-stale step, the in-tmux guard, and `exec aiur-engine.sh "$@"` with `AIUR_RELEASE_DIR` set.

**Test scenarios:**
- Happy path: `aiurdev <cmd>` execs the engine with `AIUR_RELEASE_DIR=…/_build/dev/rel/aiur`.
- Edge case: a stale build triggers a rebuild; `aiurdev build` still force-rebuilds.

**Verification:** aiurdev is ~15-20 lines; all subcommands still work in dev.

---

- [ ] U4. **Point installed `aiur` at the engine**

**Goal:** `bin/aiur.js` execs the engine with the installed release dir; full surface available.

**Requirements:** R1, R4

**Dependencies:** U2

**Files:**
- Modify: `packaging/npm/aiur-cli/bin/aiur.js`
- Test: `src/test/scripts_aiurdev_test.exs` (or a small node/bun test if the harness fits)

**Approach:** Repoint the exec from `aiur-launch.sh` to `aiur-engine.sh`, passing the resolved platform
release dir as `AIUR_RELEASE_DIR` and forwarding all args.

**Test scenarios:**
- Happy path (mocked release dir): `aiur --bg`/`stop`/`status` route to the engine with the installed
  `AIUR_RELEASE_DIR`.
- Edge case: `aiur init` still boots interactively.

**Verification:** The node entrypoint delegates every subcommand to the engine; the engine is in the
package manifest.

---

- [ ] U5. **Tests + docs for the unified structure**

**Goal:** Tests reflect the single-identity engine/shim split; docs updated.

**Requirements:** R1, R3

**Dependencies:** U2, U3, U4

**Files:**
- Modify: `src/test/scripts_aiurdev_test.exs`, `src/test/aiur_engine_test.exs`
- Modify: docs referencing the two launchers (AGENTS.md launcher notes, memory parity entry)

**Approach:** Re-point characterization assertions at the engine; change `aiurdev-` node assertions to
`aiur-`. Update the parity memory to the single-identity design.

**Verification:** Full suite green; no test assumes a monolithic `scripts/aiurdev` or `aiurdev-` identity.

---

- [ ] U6. **Dev end-to-end verification + release-verify runbook**

**Goal:** Prove dev mode end-to-end; document installed-mode verification (needs a cut release).

**Requirements:** R5

**Dependencies:** U3, U4

**Files:** none (manual + a short doc note)

**Approach:** Drive `aiurdev init`, `aiurdev` (TUI), `aiurdev --bg` + `aiurdev status`/`stop` against the
local build (real PTY). Write a runbook for verifying installed `aiur <subcommand>` after a release cut.

**Test expectation:** none — manual gate.

**Verification:** All dev subcommands work via the engine; installed-mode runbook captured.

---

- [ ] U7. **`bin/aiur.js` honors a pre-set `AIUR_RELEASE_DIR`**

**Goal:** When `AIUR_RELEASE_DIR` is already set, `bin/aiur.js` uses it and skips platform-package
resolution — enabling Layer 1 local install verification (and a dev escape hatch).

**Requirements:** R4 (enables pre-release verification)

**Dependencies:** U4

**Files:**
- Modify: `packaging/npm/aiur-cli/bin/aiur.js`
- Test: a small node/bun test, or assert via the install-verification script

**Approach:** Early-return the env's `AIUR_RELEASE_DIR` from `resolveReleaseDir()` when set and a
directory; otherwise the existing platform-package resolution. Preflight/tmux logic unchanged.

**Test scenarios:**
- Happy path: with `AIUR_RELEASE_DIR` set, the entrypoint execs the engine with that dir, no
  `require.resolve` of the platform package.
- Edge case: unset → existing platform-package resolution (and its missing-package error).

**Verification:** `AIUR_RELEASE_DIR=<local build> aiur …` works against a packed+installed CLI.

---

- [ ] U8. **Pre-release install verification harness**

**Goal:** A repeatable local verification (Layer 1 + Layer 2) that proves the packed artifact installs
and runs, so `0.0.1` ships with confidence.

**Requirements:** R5

**Dependencies:** U4, U7

**Files:**
- Create: a verification script (e.g. `packaging/npm/aiur-cli/scripts/verify-install.sh`)

**Approach:** `npm pack` the cli (Layer 1: install into a temp prefix, run with a local
`AIUR_RELEASE_DIR`); `npm pack` a platform package with a real built `release/` (Layer 2: install both,
run with no `AIUR_RELEASE_DIR`). Assert `aiur init` + a non-interactive command succeed from the
installed binary.

**Test expectation:** none — it *is* the verification harness; it runs manually / in CI pre-publish.

**Verification:** Both layers pass locally against the packed tarballs; publishing is then mechanical.

---

## Phased Delivery

### Phase 1 — Engine + dev (live-verifiable now)
U1 → U2 → U3 → U5 (dev) → U6 (dev half). aiurdev runs entirely through the engine; fully testable against
the local build.

### Phase 2 — Installed wiring (release-verified later)
U4 → U5 (installed assertions) → U6 (runbook). Structurally complete.

### Phase 3 — Pre-release install verification
U7 → U8. Prove the packed artifact installs + runs locally (`npm pack`, both layers) so `0.0.1` ships
without iterating releases. (Likely a separate follow-up effort, pre-defined here.)

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| A 2270-line bash move silently changes a subcommand | Characterization-first (U2): `scripts_aiurdev_test.exs` asserts per-subcommand launch behavior before/after. |
| aiurdev's identity change (`aiurdev-` → `aiur-`) surprises a running dev session | One-time; documented. Solo-dev usage means no coexistence to break. |
| Installed mode can't be live-verified here | Phase 2 is structurally wired + dev-proven through the shared engine; installed verify is an explicit runbook deferred to a release cut. |
| Engine not shipped in the npm package | Manifest updated (done in LU1); a test asserts the engine is present in the package file list. |
| Interactive `--eval` init path / in-tmux guard regresses | U2 preserves both with edge-case tests. |

---

## System-Wide Impact

- **Interaction graph:** RPC subcommands depend on node-name+cookie; now a single fixed `aiur` identity.
  tmux attach/sweep key on the `aiur` session prefix.
- **API surface parity:** installed `aiur` gains parity with aiurdev's surface — the goal.
- **Unchanged invariants:** the release `bin/aiur` arg contract, `Aiur.CLI` behavior, and the
  interactive `elixir --eval` init boot all stay as-is.

---

## Sources & References

- Memory: `project-aiur-aiurdev-parity`
- Prior plan deferral: `docs/plans/2026-06-15-002-feat-init-wizard-rework-plan.md` (Deferred-to-Follow-Up)
- Related code: `scripts/aiurdev`, `packaging/npm/aiur-cli/libexec/aiur-launch.sh`,
  `packaging/npm/aiur-cli/bin/aiur.js`
