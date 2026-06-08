---
title: "feat: Distribute aiur via npm/bun/pnpm/yarn"
type: feat
status: active
date: 2026-05-31
deepened: 2026-05-31
origin: elixir/docs/brainstorms/2026-05-31-npm-distribution-requirements.md
---

# feat: Distribute aiur via npm/bun/pnpm/yarn

## Overview

Make the Elixir/OTP `aiur` orchestrator installable on a machine with no Elixir
toolchain via `npm i -g aiur-cli` (and bun/pnpm/yarn equivalents). A thin Node
`bin` shim (`aiur-cli`) selects a per-platform OTP-release package through
`optionalDependencies` (the esbuild/swc model), then hands off to a **bundled
distribution bash launcher** that reproduces what `scripts/aiur` does today:
set the BEAM distribution env contract, start the release backgrounded, and
attach the user to a tmux session that hosts the TUI and opencode panes. A CI
matrix builds `mix release` natively per OS/arch and publishes all packages in
lockstep on a version tag. Everything stays Apache-2.0; tmux and opencode remain
external runtime dependencies.

> **Why a bundled bash launcher, not a one-shot `eval`:** the interactive
> orchestrator is *not* a foreground BEAM process. `Aiur.CLI.main/1` blocks in
> `wait_for_shutdown()` and paints no TTY; `scripts/aiur` backgrounds the BEAM
> (`nohup … & disown`) and the foreground UI is a separate `tmux attach`. The
> BEAM spawns opencode panes *inside* that tmux session and depends on a full
> env contract (`RELEASE_DISTRIBUTION`, `RELEASE_NODE`, `RELEASE_COOKIE`,
> `ERL_AFLAGS`, the erlang cookie file, `AIUR_TMUX_*`) plus `aiur.tmux.conf`.
> A `node spawnSync(..., {stdio:"inherit"})` of `bin/aiur eval` would boot the
> supervisor against a TTY it never paints and block forever. Reusing the proven
> bash orchestration (all targets — Linux/macOS/WSL — ship bash) is the
> lowest-risk path and avoids re-deriving hundreds of lines of working logic.

---

## Problem Frame

Today the only entry point is the repo-local `scripts/aiur` bash launcher, which
needs a mise/mix toolchain, the source tree, and tmux. The marketing site already
advertises `npm i -g aiur-cli`. We need a toolchain-free install path. The
self-contained artifact is a `mix release` (bundles ERTS), but it is compiled
**per OS+arch**, the current post-assemble shim hardcodes an absolute release
path (not relocatable), and — critically — the release alone is not runnable as
the product: the interactive launch sequence in `scripts/aiur` must be reproduced
in a toolchain-free, repo-free form. (see origin: elixir/docs/brainstorms/2026-05-31-npm-distribution-requirements.md)

---

## Requirements Trace

- R1. `npm i -g aiur-cli` (+ bun/pnpm/yarn) installs a working `aiur` on a machine with no Elixir/Erlang toolchain.
- R2. The installed command is `aiur` (not `aiur-cli`), via the launcher package's `bin` mapping.
- R3. Launcher detects missing `tmux` on PATH and prints a platform-appropriate install hint instead of failing obscurely.
- R4. Install succeeds in environments that block install-time/postinstall network access.
- R5. `aiur-cli` is a thin launcher; the per-platform OTP release ships as separate packages selected via `optionalDependencies` keyed on `os`+`cpu`.
- R6. The launcher resolves and runs the platform package's release, passing through all args, stdio, and exit codes, and reproduces the interactive launch (background BEAM + tmux attach) — not a one-shot eval.
- R7. The launcher pins exact versions of the platform packages so launcher and release never drift.
- R8. Releases are built `MIX_ENV=prod` and stripped to stay near the ~20-31 MB compressed floor.
- R9. A CI matrix builds `mix release` natively per OS/arch and publishes the platform packages + launcher in lockstep on a version tag.
- R10. Published artifacts rely on registry-native integrity (no hand-rolled download verification).
- R11. Package name is `aiur-cli` (claimed; `aiur-cli@0.0.0` placeholder already published under the personal account).

**Origin acceptance examples:** none defined in origin (requirements-only doc).

---

## Scope Boundaries

- Native Windows is out of scope; Windows users go through WSL (a Linux target). No win32 platform package in v1.
- No Homebrew/apt/asdf/standalone-installer channels in v1 — Node package-manager channel only.
- `scripts/aiur` (repo/dev launcher) is not removed or rewritten; this adds a parallel end-user path. The distribution bash launcher (U2) is a *new, trimmed* sibling derived from it, not a replacement.
- tmux and opencode are not bundled or installed — detected/documented only (keeps aiur a non-redistributor of opencode's MIT code; see origin Key Decisions). Both are required for the product to function; the launcher preflights and instructs.
- Not bundling all platforms into one package; per-platform `optionalDependencies` is the explicit avoidance.

### Deferred to Follow-Up Work

- Real first functional release version bump (`0.1.x`): handled when the pipeline is green; this plan delivers the mechanism, not the version cut.
- Updating the npm-displayed README to site copy: the README exists at `packaging/npm/aiur-cli/README.md` but ships only on the next published version (held off per user).
- macOS code signing / notarization of bundled ERTS binaries: observed in the U7 smoke test; deferred to a hardening pass unless it blocks install.

---

## Context & Research

### Relevant Code and Patterns

- `scripts/aiur` `prepare_distribution` (lines ~823-852) — the **BEAM distribution env contract** the launcher must set: `RELEASE_DISTRIBUTION=name`, `RELEASE_NODE`, `RELEASE_COOKIE`, `ERL_AFLAGS`, `ERL_EPMD_ADDRESS`, `AIUR_NODE`, `AIUR_ERLANG_COOKIE`, backed by `ensure_erlang_cookie` (lines ~800-821). Runtime code reads these (e.g. `lib/aiur/pane_manager.ex` `AIUR_ERLANG_COOKIE`, `lib/aiur/agent_environment.ex` `ERL_AFLAGS`/`RELEASE_NODE`/`RELEASE_COOKIE`).
- `scripts/aiur` interactive launch: BEAM is **backgrounded** (`nohup … & disown`, ~line 1196) with logs to a file; the foreground is a separate **`tmux attach`** (session teardown ~line 1629). tmux is **fatal** (`die "tmux >= 3.3 is required"`, ~line 1327) with a version floor of 3.3.
- `scripts/aiur` tmux naming/conf: `aiur_tmux_session_name`/`aiur_tmux_socket_name` (~lines 1390-1397) and `resolve_aiur_tmux_conf` (~lines 1399-1413) — the conf resolver already falls back to `$script_dir/aiur.tmux.conf`, so a packaged launcher that ships the conf next to itself resolves it for free (or via `AIUR_TMUX_CONF` / `$XDG_CONFIG_HOME/aiur/tmux.conf`).
- `scripts/aiur.tmux.conf` — required runtime asset; must ship in the package.
- `elixir/mix.exs` `releases/0` (lines ~179-187) — existing OTP release `aiur`, `include_executables_for: [:unix]`, post-assemble step `copy_cli_launcher/1`.
- `elixir/mix.exs` `copy_cli_launcher/1` (lines ~208-249) — **writes a project-root `bin/aiur` shim with the absolute `release.path` hardcoded** (NOT relocatable; bypass for distribution). Documents the CLI entry contract: `bin/aiur eval "Aiur.CLI.main(Aiur.CLI.argv_from_file())"` with argv via the `AIUR_ARGV_FILE` temp file (one arg per line). The release's *own* `<release_root>/bin/aiur` (standard Mix script, `RELEASE_ROOT` discovery) **is** relocatable — this is the binary the bash launcher drives.
- `lib/aiur/cli.ex` `main/1` (~lines 36-48) — blocks in `wait_for_shutdown()`; `--version` (~line 41) is a one-shot that exits before any orchestration boots, so it **cannot** validate the interactive path.
- `exqlite` dependency (`elixir/mix.exs:159`) ships a C NIF (`sqlite3_nif.so`) — releases must be built natively per platform; `mix release` (ships `priv/`) is required, not escript.
- `packaging/npm/aiur-cli/` — existing placeholder: `package.json` (Apache-2.0, `bin: {aiur: bin/aiur.js}`, version 0.0.0), `bin/aiur.js` (placeholder stub), `README.md`.
- `LICENSE` (Apache-2.0) and `NOTICE` (Symphony attribution) at repo root — must be included in every published package.

### External References

- GitHub Actions Linux arm64 hosted runners are GA and free for public repos via `ubuntu-24.04-arm` — linux-arm64 builds natively, no QEMU.
- esbuild's `npm/esbuild` launcher handles the `optionalDependencies`-missing case explicitly (clear error, not a raw `MODULE_NOT_FOUND`) — the reference pattern for U3's failure handling.
- Burrito (single-binary BEAM packager) v1.5.0 supports up to Elixir 1.18.4-otp-28; Elixir 1.19 not confirmed, exqlite C NIF cross-compile unproven. Rejected as baseline (see Alternatives).

### Institutional Learnings

- None in `docs/solutions/` specific to packaging/distribution (no prior npm-distribution work in repo).

---

## Key Technical Decisions

- **Bundled distribution bash launcher reproduces the interactive run; Node `bin` is only a resolver/preflight shim.** Rationale: the product is a backgrounded BEAM + tmux-attach session with a full env contract, not a foreground `eval`. `scripts/aiur` already implements this correctly in bash; all supported targets ship bash. The dist launcher is a trimmed, repo-free variant. (User-selected approach.)
- **Native `mix release` per runner, not cross-compilation.** The exqlite C NIF must be compiled for the target; native runners (incl. free arm64) make this reliable. Reuses existing `releases/0`.
- **Bypass the hardcoded project-root shim; the bash launcher drives `<platform-pkg>/release/bin/aiur`.** The project-root shim from `copy_cli_launcher/1` embeds an absolute build path; the release-internal launcher is relocatable.
- **Platform packages carry the assembled release tree + license files; no `bin`.** Only `aiur-cli` declares `bin`. Avoids competing `aiur` commands on PATH.
- **Lockstep exact-version publishing driven by the git tag, with `latest` moved only after all 5 succeed.** R7: launcher `optionalDependencies` pin `=<tag-version>`. Publish the four platform packages, then the launcher, all under the version; only after all five succeed advance the `latest` dist-tag. A mid-publish failure leaves an un-`latest`-ed version users never resolve (npm versions are immutable — true atomicity is impossible).
- **Apache-2.0 throughout; bundle `LICENSE`+`NOTICE` in each package.** opencode/tmux stay external (no redistribution obligations).
- **tmux preflight is fatal (version floor ≥ 3.3); opencode preflight warns.** tmux is required to render anything; opencode is required for the headline agent workflow but not for every invocation, so its absence warns with an install hint rather than aborting.

---

## Open Questions

### Resolved During Planning

- Launcher model → bundled distribution bash launcher (reproduces background-BEAM + tmux-attach + env contract); Node `bin` shim only resolves the platform package and preflights. (User-selected.)
- linux-arm64 runner strategy → native `ubuntu-24.04-arm` GHA runner (free, GA).
- Reconciling the release `bin/aiur` shim with a toolchain-free install → bypass the project-root shim; the bash launcher drives the relocatable release-internal launcher.
- ERTS strip approach → `MIX_ENV=prod` + `strip_beams` (default) + drop ERTS `doc`/`src`; gzip handles the rest. Measured dev release ~31 MB compressed; prod expected lower.
- `optionalDependencies`-none-installed failure → U3 detects the missing platform package and prints a clear, actionable message (not a raw stack trace), mirroring esbuild.
- Partial-publish recoverability → publish under version first, advance `latest` only after all five succeed.

### Deferred to Implementation

- Exact set of env-contract lines the dist bash launcher must port from `prepare_distribution`/`run_in_tmux` vs. what the release-internal launcher already sets — pin down during the Phase 0 spike against a relocated release.
- Whether any `priv/` path or config in aiur assumes a repo checkout (e.g., reads relative to `AIUR_REPO_ROOT`) and needs a release-safe default — surface during the Phase 0 spike / U1.
- macOS code signing / Gatekeeper quarantine on downloaded ERTS binaries — observe during U7 smoke test; may defer to a hardening pass.
- Whether `npm i -g` (and bun/pnpm/yarn) truly downloads only the matching platform package or fetches all four — measure in U7 and assert single-platform footprint.

---

## Output Structure

    packaging/npm/
      aiur-cli/                 # launcher package (exists; extended in U2/U3)
        package.json            # bin: {aiur}, optionalDependencies (generated versions)
        bin/aiur.js             # Node resolver/preflight shim (replaces placeholder stub)
        libexec/aiur-launch.sh  # distribution bash launcher (trimmed scripts/aiur)
        share/aiur.tmux.conf    # copied from scripts/aiur.tmux.conf
        README.md               # exists
        LICENSE, NOTICE         # copied at publish time
      platform/                 # per-platform package staging (U4, generated)
        aiur-cli-linux-x64/
          package.json          # os:[linux] cpu:[x64]
          release/              # assembled mix release tree (bin/ lib/ erts-*/ releases/)
          LICENSE, NOTICE
        aiur-cli-linux-arm64/
        aiur-cli-darwin-arm64/
        aiur-cli-darwin-x64/
      scripts/
        build-release.sh                # MIX_ENV=prod mix release + strip/cleanup (U1)
        assemble-platform-package.mjs   # build a platform pkg dir from a release (U4)
        stamp-versions.mjs              # set all package versions from the tag (U6)

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification.*

Install-time resolution and runtime launch:

```
npm i -g aiur-cli
  └─ installs aiur-cli (launcher) + the ONE optionalDependency whose
     os/cpu match the host (e.g. aiur-cli-darwin-arm64)

$ aiur <args>
  └─ aiur-cli/bin/aiur.js (Node):
       1. resolve aiur-cli-<os>-<arch> via require.resolve(pkg + "/package.json")
            → MODULE_NOT_FOUND? print "no platform package installed for
              <os>/<arch>; see <repo>" and exit non-zero (NOT a raw stack trace)
       2. tmux preflight: missing or < 3.3 → fatal, platform-appropriate hint (R3)
          opencode preflight: missing → warn + hint, continue
       3. exec the bundled bash launcher:
            AIUR_RELEASE_DIR=<platform-pkg>/release \
            AIUR_TMUX_CONF=<pkg>/share/aiur.tmux.conf \
            libexec/aiur-launch.sh <args...>          (stdio inherited, args passed through)
       4. propagate the launcher's exit code (R6)

  libexec/aiur-launch.sh (bash, trimmed scripts/aiur):
       a. prepare_distribution: ensure ~/.erlang.cookie; export RELEASE_DISTRIBUTION,
          RELEASE_NODE, RELEASE_COOKIE, ERL_AFLAGS, ERL_EPMD_ADDRESS, AIUR_*
       b. start "$AIUR_RELEASE_DIR/bin/aiur" backgrounded (nohup … & disown), log to file
       c. tmux new-session (named) + attach → foreground TUI + opencode panes
       d. teardown on detach; propagate exit code
```

CI matrix (one job per row), fan-in to publish:

```
runner             target            artifact
ubuntu-latest      linux-x64    →    aiur-cli-linux-x64    ┐
ubuntu-24.04-arm   linux-arm64  →    aiur-cli-linux-arm64  │  upload
macos-14           darwin-arm64 →    aiur-cli-darwin-arm64 │  artifacts
macos-13           darwin-x64   →    aiur-cli-darwin-x64    ┘
                                          │
                  publish job (on tag): stamp versions → npm publish 4 platform
                  pkgs → npm publish aiur-cli launcher → advance `latest` only
                  after all 5 succeed (R7/R9)
```

---

## Implementation Units

> **Phase 0 spike precedes U1–U7** — see Phased Delivery. It validates the bundled-bash-launcher model against a relocated release on linux-x64 before the rest is built, because that model is the load-bearing assumption.

- [ ] U1. **Distribution-ready release build**

**Goal:** Produce a relocatable, prod, stripped `mix release` that boots from an arbitrary unpack location without a toolchain or the repo.

**Requirements:** R1, R8

**Dependencies:** None (informed by the Phase 0 spike)

**Files:**
- Modify: `elixir/mix.exs` (release config — ensure the dist build does not depend on the hardcoded project-root shim; add prod strip options)
- Create: `packaging/scripts/build-release.sh` (wraps `MIX_ENV=prod mix release aiur` with strip/cleanup, emits the release tree path)

**Approach:**
- Keep `copy_cli_launcher/1` for dev convenience but ensure the distribution build does not rely on the project-root shim it writes (absolute path). The distributable artifact is the assembled `<release>/bin/aiur` tree.
- Set release options for size: confirm `strip_beams` active under prod; remove ERTS `doc/` and `src/` from the assembled tree in the build script.
- Verify the release boots from a directory other than the build dir.

**Execution note:** Characterization-first — capture current `mix release` output and confirm a representative command works from the build dir before relocation changes, so changes are measured against a known-good baseline.

**Patterns to follow:** `elixir/mix.exs` `releases/0`.

**Test scenarios:**
- Happy path: built release copied to a fresh temp dir boots and runs a representative one-shot, exit 0, no Elixir toolchain on PATH.
- Edge case: release run from a path containing spaces resolves and boots.
- Integration: exqlite NIF loads from `priv/` in the relocated release (a DB-touching command succeeds), proving `mix release` (not escript) was required.
- Edge case: any `priv`/config path that assumed `AIUR_REPO_ROOT` has a release-safe default (or is documented as needing one).

**Verification:** A tarred-and-relocated release runs a representative `aiur` command end-to-end on the build platform with only tmux present.

---

- [ ] U2. **Distribution bash launcher + tmux.conf**

**Goal:** A trimmed, repo-free bash launcher that reproduces the interactive run (env contract + backgrounded BEAM + tmux attach) against a relocated release, plus the bundled tmux conf.

**Requirements:** R6

**Dependencies:** U1 (defines the relocated release layout/boot), Phase 0 spike (validates the model)

**Files:**
- Create: `packaging/npm/aiur-cli/libexec/aiur-launch.sh`
- Create: `packaging/npm/aiur-cli/share/aiur.tmux.conf` (copied from `scripts/aiur.tmux.conf`; keep in sync)

**Approach:**
- Port the minimal slice of `scripts/aiur` needed for an end-user launch: `ensure_erlang_cookie` + `prepare_distribution` (the env contract), tmux session/socket naming, conf resolution (defaulting to the bundled `share/aiur.tmux.conf`), backgrounded BEAM start against `$AIUR_RELEASE_DIR/bin/aiur`, tmux attach, and teardown/exit-code propagation.
- Drive the relocatable release-internal launcher, not the hardcoded project-root shim. Pass through all user args.
- Drop dev/repo-only concerns (mise, source-tree assumptions, dev-only flags). Read the release dir from `AIUR_RELEASE_DIR` and the conf from `AIUR_TMUX_CONF` (set by U3).

**Patterns to follow:** `scripts/aiur` `prepare_distribution` (~823-852), `resolve_aiur_tmux_conf` (~1399-1413), backgrounded-BEAM + tmux-attach launch (~1196, ~1629), tmux version floor (~1327).

**Test scenarios:**
- Happy path: against a relocated release + a real tmux, launcher starts the BEAM backgrounded, attaches a named tmux session, and a representative interactive command renders (validated via tmux send-keys / capture, per the manual TUI driver pattern).
- Integration: the env contract is exported (assert `RELEASE_NODE`/`RELEASE_COOKIE`/`ERL_AFLAGS` are set in the BEAM's environment), so opencode pane spawning can connect.
- Edge case: conf resolution falls back to the bundled `share/aiur.tmux.conf` when no override/user conf exists.
- Error path: BEAM fails to boot → launcher surfaces the captured startup log and exits non-zero (no silent hang).

**Verification:** From a relocated release, the bash launcher drives a real interactive `aiur` session (TUI visible, an opencode pane spawns) on linux-x64 with only tmux + opencode present.

---

- [ ] U3. **Node `bin` resolver/preflight shim**

**Goal:** Replace the placeholder stub: resolve the platform package, preflight tmux (fatal) and opencode (warn), then exec the bundled bash launcher with full passthrough.

**Requirements:** R2, R3, R6

**Dependencies:** U2 (the launcher it execs), U4 (platform-package layout/name)

**Files:**
- Modify: `packaging/npm/aiur-cli/bin/aiur.js`
- Modify: `packaging/npm/aiur-cli/package.json` (engines, files include `libexec/`, `share/`; `optionalDependencies` added in U6)
- Create: `packaging/npm/aiur-cli/test/launcher.test.mjs`

**Approach:**
- Resolve `aiur-cli-<os>-<arch>` via `require.resolve(pkg + "/package.json")`; map `process.platform`/`process.arch` → triple (`darwin/linux`, `arm64/x64`). Unknown combo → clear "unsupported platform" message, exit non-zero. **`MODULE_NOT_FOUND` for a known triple** (optionalDependencies silently skipped — known npm bug / cross-platform lockfile / `--no-optional`) → distinct, actionable message ("platform package not installed; reinstall or see <repo>"), exit non-zero. Never surface a raw stack trace.
- tmux preflight: missing on PATH **or version < 3.3** → fatal with a platform-appropriate hint (`brew install tmux` / `apt install tmux`). opencode preflight: missing → warn + hint to stderr, continue.
- Compute `AIUR_RELEASE_DIR=<platform-pkg>/release` and `AIUR_TMUX_CONF=<pkg>/share/aiur.tmux.conf`; `spawnSync` the bundled `libexec/aiur-launch.sh` with `stdio:"inherit"`, all args passed through, propagate `status`/signal as exit code.

**Patterns to follow:** esbuild's `npm/esbuild/bin` resolution + missing-package handling; the env vars consumed by U2's launcher.

**Test scenarios:**
- Happy path: stubbed platform package on disk → shim resolves it and execs `aiur-launch.sh` with `AIUR_RELEASE_DIR`/`AIUR_TMUX_CONF` set and args forwarded.
- Error path: unknown platform triple → unsupported-platform message, non-zero, does not exec.
- Error path: known triple but platform package not installed (`MODULE_NOT_FOUND`) → distinct actionable message, non-zero, no raw stack trace.
- Error path: launcher exits 3 → shim exits 3 (exit-code propagation).
- Edge case (R3): tmux absent or < 3.3 → fatal hint; opencode absent → warning, still proceeds.

**Verification:** `aiur --version` (one-shot, exits fast) and a real interactive `aiur` run both work via the shim against a locally-installed platform package.

---

- [ ] U4. **Per-platform package assembler**

**Goal:** Turn a built release tree + a target triple into a publishable platform package directory.

**Requirements:** R5, R8, R10

**Dependencies:** U1

**Files:**
- Create: `packaging/scripts/assemble-platform-package.mjs`
- Create: `packaging/npm/platform/.gitignore` (ignore generated `release/` trees)
- Create: `packaging/npm/platform/README.md` (explains these are generated)

**Approach:**
- Input: release tree path, target (`linux-x64` etc.), version. Output: `packaging/npm/platform/aiur-cli-<target>/` with `release/` (assembled tree), a generated `package.json` (`name`, `version`, `os`, `cpu`, `files: ["release"]`, `license: "Apache-2.0"`), and copied `LICENSE`+`NOTICE`.
- `os`/`cpu` map: `linux→linux`, `darwin→darwin`; `x64→x64`, `arm64→arm64`.
- No `bin` field, no postinstall (R4 — nothing runs at install time).

**Patterns to follow:** esbuild platform package `package.json` shape (`os`, `cpu`, `files`).

**Test scenarios:**
- Happy path: fixture release dir → package dir whose `package.json` has correct `os`/`cpu` and `files: ["release"]`.
- Edge case: unknown target triple → errors clearly, writes nothing.
- Integration: `npm pack --dry-run` in the generated dir lists `release/bin/aiur`, `LICENSE`, `NOTICE`.

**Verification:** Running the assembler for the host triple yields a dir that, when `npm pack`ed, contains the full release and license files.

---

- [ ] U5. **CI build matrix**

**Goal:** Build a native release per OS/arch on every tag and upload each as a CI artifact.

**Requirements:** R8, R9

**Dependencies:** U1, U4

**Files:**
- Create: `.github/workflows/release-npm.yml`

**Approach:**
- Trigger on tag push matching `v*` (and `workflow_dispatch` for dry runs).
- Matrix: `{runner: ubuntu-latest, target: linux-x64}`, `{ubuntu-24.04-arm, linux-arm64}`, `{macos-14, darwin-arm64}`, `{macos-13, darwin-x64}`.
- Each job: install Erlang/Elixir via **one** installer (`erlef/setup-beam`) with **exact pinned** `otp-version`/`elixir-version` strings matching the repo (`elixir/mix.exs` `~> 1.19`, OTP 28.x) — verify the chosen versions are available on all four runner images (ubuntu x64/arm, macos-13 x64, macos-14 arm); fall back to mise only if a version is image-unavailable. `MIX_ENV=prod` deps + `build-release.sh`, run `assemble-platform-package.mjs`, `npm pack`, upload the tarball artifact.

**Test scenarios:** none for the workflow YAML itself; correctness is proven by the U7 smoke job and the artifacts produced.

**Verification:** A `workflow_dispatch` run produces four platform tarballs as artifacts, each containing a bootable release for its target.

---

- [ ] U6. **Lockstep versioning + publish job**

**Goal:** Stamp all package versions from the tag and publish platform packages then the launcher, advancing `latest` only after all five succeed.

**Requirements:** R7, R9, R11

**Dependencies:** U3, U4, U5

**Files:**
- Create: `packaging/scripts/stamp-versions.mjs`
- Modify: `.github/workflows/release-npm.yml` (add a `publish` job depending on the matrix)
- Modify: `packaging/npm/aiur-cli/package.json` (add `optionalDependencies` entries, versions stamped at publish)

**Approach:**
- `stamp-versions.mjs <version>`: set `aiur-cli` version, each platform package version, and `aiur-cli.optionalDependencies["aiur-cli-<target>"] = "<version>"` (exact pin).
- `publish` job (needs the matrix): download artifacts; `npm publish --tag next` (or a holding tag) for each platform package, then the launcher — so the five versions exist but `latest` is unchanged. Only after **all five** publishes succeed, advance the `latest` dist-tag for `aiur-cli` (and platform packages). Auth via `NODE_AUTH_TOKEN`/`NPM_TOKEN` (publish-automation token; interactive OTP can't run in CI).
- Guard: publish only on tag events; fail loudly if any platform artifact is missing (never start a partial publish). A mid-publish failure leaves un-`latest`-ed versions users never resolve; the next attempt uses a fresh version.

**Test scenarios:**
- Happy path: `stamp-versions.mjs 0.1.0` sets all five package versions to `0.1.0` and the launcher's four `optionalDependencies` to exact `0.1.0`.
- Edge case: a missing platform artifact aborts the publish job before any `npm publish` runs.
- Error path: bad/empty version arg → script errors, mutates nothing.
- Ordering: `latest` is advanced only in a final step gated on all five publishes succeeding (assert via dry-run/job-graph).

**Verification:** A dry-run publish (`npm publish --dry-run`) for all five packages shows matching versions and the launcher pinning the exact platform versions.

---

- [ ] U7. **Cross-platform interactive smoke test**

**Goal:** Prove a real `npm i -g` from the produced tarballs yields a working interactive `aiur` on each target — not just `--version`.

**Requirements:** R1, R2, R4

**Dependencies:** U5, U6

**Files:**
- Modify: `.github/workflows/release-npm.yml` (add a post-build `smoke` matrix job)

**Approach:**
- On each platform runner: install tmux (+ opencode where feasible), `npm i -g` the locally-packed launcher + matching platform tarball (local file refs so no registry round-trip).
- Drive a **real interactive run** under tmux (send-keys + capture-pane, per the manual TUI driver pattern), asserting the TUI renders — not only `aiur --version`. Keep `--version` as a fast pre-check.
- Assert the **single-platform footprint**: the global install pulled only the matching platform package (measure installed size / inspect `node_modules`), confirming os/cpu filtering works for npm and at least one of bun/pnpm/yarn.
- Run the install step with network egress disabled where feasible to assert R4 (no postinstall fetch).

**Test scenarios:**
- Happy path: a real interactive `aiur` session renders its TUI after global install on each of the four targets.
- Edge case: bun and pnpm global installs of the same tarballs resolve and run (at least one non-npm manager exercised), and pull only the matching platform package.
- Error path (R4): install with network disabled still succeeds (no install-time download).
- Footprint: total installed size ≈ one platform package (not all four).

**Verification:** The smoke matrix is green on all four targets, drives a real interactive run, and confirms single-platform install footprint.

---

## System-Wide Impact

- **Interaction graph:** New artifacts only (`packaging/**`, `.github/workflows/release-npm.yml`, release config in `elixir/mix.exs`). No change to runtime orchestration, `scripts/aiur`, or the dev workflow.
- **Contract parity (load-bearing):** The dist bash launcher (U2) must stay faithful to `scripts/aiur`'s env contract (`prepare_distribution`) and the release CLI contract (`Aiur.CLI.main` + `AIUR_ARGV_FILE` where used). If `scripts/aiur`'s distribution env or `copy_cli_launcher/1`'s contract changes, U2 must change in lockstep. `share/aiur.tmux.conf` is a copy of `scripts/aiur.tmux.conf` and must be kept in sync.
- **State lifecycle risks:** Backgrounded BEAM + tmux session must tear down cleanly on detach; stale sessions handled as `scripts/aiur` does. Partial publish (some platform packages live, launcher missing/mismatched, or `latest` advanced too early) must be prevented (U6 guard).
- **Unchanged invariants:** `scripts/aiur`, mise/mix dev flow, and the dev `bin/aiur` shim are untouched.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| **Launch model wrong** — `eval`/foreground assumption disproven; product is background-BEAM + tmux attach | Phase 0 spike validates the bundled bash launcher against a relocated release before building U1–U7; U2/U7 verification drive a *real interactive run*, not `--version`. |
| Dist launcher drifts from `scripts/aiur` env contract | U2 ports `prepare_distribution` verbatim-in-spirit; System-Wide Impact flags the lockstep dependency; U2 integration test asserts env vars reach the BEAM. |
| `aiur.tmux.conf` missing at runtime | Bundled at `aiur-cli/share/aiur.tmux.conf`; conf resolver fallback already targets it; U3 sets `AIUR_TMUX_CONF`. |
| tmux absent / too old (< 3.3) | U3 preflight is fatal with version check + install hint (matches `scripts/aiur` floor). |
| opencode absent → headline feature broken silently | U3 preflights opencode and warns with an install hint. |
| `optionalDependencies` silently skipped (npm bug / cross-platform lockfile / `--no-optional`) | U3 catches `MODULE_NOT_FOUND` for a known triple and prints an actionable message; U7 asserts resolution across managers. |
| exqlite C NIF mismatch on a target | Native per-runner builds (no cross-compile); U1 integration test loads the NIF from a relocated release. |
| Release assumes repo checkout (`AIUR_REPO_ROOT`, priv paths) | Phase 0 spike + U1 deferred check; add release-safe defaults if found. |
| CI publish needs non-interactive npm auth (2FA) | npm automation/publish token in `NPM_TOKEN`; documented that interactive OTP can't run in CI. |
| Partial/mismatched publish burns immutable versions | U6 publishes under a holding tag, advances `latest` only after all five succeed; aborts pre-publish if any artifact missing; next attempt uses a fresh version. |
| All four platform packages downloaded on install (size blowup) | U7 asserts single-platform footprint across npm + an alternate manager. |
| Release size creeps past npm comfort | U1 strips ERTS doc/src + prod beams; measured ~31 MB dev, expect lower; revisit Burrito only if it balloons. |
| macOS Gatekeeper quarantine on ERTS binaries | Observe in U7 macOS smoke; defer signing/notarization to a hardening pass if it blocks. |

---

## Alternative Approaches Considered

- **Node-only launcher (port orchestration to JS).** Rejected: re-derives hundreds of lines of working bash (`prepare_distribution`, tmux session/attach/teardown) and risks drift from `scripts/aiur`. Bash is available on all supported targets.
- **Elixir release-mode foreground command (BEAM does its own tmux orchestration).** Rejected for v1: largest code change, still needs the distribution env set externally, and duplicates logic that already lives correctly in bash.
- **Burrito single self-extracting binary (Zig cross-compile).** Rejected for v1: v1.5.0 confirms only up to Elixir 1.18-otp-28 (aiur is `~> 1.19`), and cross-compiling the exqlite C NIF is unproven.
- **Option 3: thin launcher + postinstall download from GitHub Releases.** Rejected per origin: postinstall network is blocked in many CI/corp/sandbox environments (R4); adds hand-rolled checksum/cache code. Measured size doesn't force it.
- **escript instead of mix release.** Rejected: escript doesn't ship `priv/`, so the exqlite NIF won't load. The repo retains escript only as a non-NIF fallback (`elixir/mix.exs:189-198`).

---

## Phased Delivery

### Phase 0 — De-risk spike (do first)
- On linux-x64, by hand: build a relocatable release (rough U1), write a minimal `aiur-launch.sh` that sets the env contract and drives the release under tmux, and **prove a real interactive `aiur` session renders from a relocated release with no repo/toolchain** (tmux + opencode present). This validates the single load-bearing assumption before investing in the matrix. If it fails, revisit the launch model (Node-port or Elixir-foreground alternatives) before proceeding.

### Phase 1 — Local, no CI
- U1 (relocatable release) + U2 (dist bash launcher + conf) + U3 (Node shim) + U4 (assembler), verified by hand on linux-x64 with a *real interactive run*. Proves the core mechanism end-to-end before touching CI.

### Phase 2 — Pipeline
- U5 (matrix build) + U6 (versioning/publish with safe `latest` advance) + U7 (interactive smoke). Proves all four targets and the lockstep publish, ending in a `--dry-run` publish ready for the first real `0.1.x` tag.

---

## Sources & References

- **Origin document:** [elixir/docs/brainstorms/2026-05-31-npm-distribution-requirements.md](elixir/docs/brainstorms/2026-05-31-npm-distribution-requirements.md)
- Interactive launch + env contract: `scripts/aiur` (`prepare_distribution` ~823-852, `resolve_aiur_tmux_conf` ~1399-1413, backgrounded-BEAM + tmux attach ~1196/~1629, tmux floor ~1327), `scripts/aiur.tmux.conf`
- Release config & CLI contract: `elixir/mix.exs` (`releases/0`, `copy_cli_launcher/1`), `lib/aiur/cli.ex` (`main/1`)
- Env consumed at runtime: `lib/aiur/pane_manager.ex`, `lib/aiur/agent_environment.ex`
- Placeholder package: `packaging/npm/aiur-cli/`
- License/attribution: `LICENSE`, `NOTICE`
- GitHub Actions arm64 runners: https://github.blog/changelog/2025-08-07-arm64-hosted-runners-for-public-repositories-are-now-generally-available/
- Burrito: https://github.com/burrito-elixir/burrito
