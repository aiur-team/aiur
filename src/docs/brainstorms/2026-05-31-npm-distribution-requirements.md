---
date: 2026-05-31
topic: npm-distribution
---

# Distribute aiur via npm / bun / pnpm / yarn

## Problem Frame

aiur is an Elixir/OTP application. Today the only way to run it is to clone the
repo and use the `scripts/aiur` bash launcher, which depends on a local
mise/mix toolchain, the source tree, and tmux. The marketing site already
advertises `npm i -g aiur-cli` (and bun/pnpm/yarn equivalents), so we need a way
to install a working `aiur` command through Node package managers without the
user having an Elixir toolchain or the aiur source checkout.

The self-contained artifact is a `mix release`, which bundles ERTS (the Erlang
runtime) so the target machine needs no Erlang/Elixir installed. A release is
compiled **per OS + architecture**. tmux remains a hard runtime dependency
because aiur orchestrates tmux panes; no package manager can provide it.

---

## Requirements

**Install experience**
- R1. `npm i -g aiur-cli` (and `bun add -g` / `pnpm add -g` / `yarn global add` equivalents) installs a working `aiur` command on a machine with no Elixir/Erlang toolchain.
- R2. The installed command is invoked as `aiur` (not `aiur-cli`), preserving existing terminal UX, via the package's `bin` mapping.
- R3. On install or first run, the launcher detects whether `tmux` is on PATH and, if missing, prints a clear platform-appropriate install hint rather than failing obscurely.
- R4. Install must succeed in environments that block install-time/postinstall network access (locked-down CI, corporate proxies, sandboxes).

**Packaging & delivery**
- R5. The user-facing `aiur-cli` package is a thin launcher; the platform-specific OTP release ships as a separate per-platform package selected automatically via `optionalDependencies` keyed on `os` + `cpu` (the esbuild/swc model).
- R6. The launcher resolves and `exec`s the `bin/aiur` from whichever platform package the package manager installed, passing through all args, stdin/stdout/stderr, and exit codes.
- R7. The launcher pins exact versions of the platform packages so the launcher and the release it runs never drift.
- R8. Releases are built with `MIX_ENV=prod` and stripped (drop dev/test deps, strip beams, drop ERTS docs/src) to keep each platform package near the measured ~20-31 MB compressed floor.

**Build & release pipeline**
- R9. A CI build matrix produces a `mix release` natively per target OS/arch and publishes the matching platform package plus the launcher package in lockstep on a version tag.
- R10. Every published platform artifact carries an integrity check (registry-native checksums are sufficient under the optionalDependencies model; no hand-rolled download verification needed).

**Naming & publishing**
- R11. The npm package name is `aiur-cli` (the bare `aiur` name is already taken on npm by an unrelated package). The name is claimed by publishing before public launch.

---

## Success Criteria

- On a clean Linux or macOS machine with tmux present and no Elixir toolchain, `npm i -g aiur-cli && aiur` launches the real orchestrator.
- The same one-liner works under bun, pnpm, and yarn with their respective global-install commands.
- `aiur-cli` installs without error in a network-restricted CI step (no postinstall fetch).
- A downstream planner can build the CI matrix and packaging without having to decide the delivery mechanism, platform set, or naming — those are settled here.

---

## Scope Boundaries

- Native Windows is out of scope. aiur requires bash + tmux, so Windows users go through WSL (a Linux target). No win32 platform package in v1.
- No Homebrew/apt/asdf/standalone-installer channels in v1. This brainstorm covers the Node package-manager channel only.
- Not removing or rewriting `scripts/aiur` for repo/dev usage — the dev launcher stays as-is; this adds a parallel end-user install path.
- Not bundling all platforms into one package (~124 MB unpacked for everyone); per-platform optionalDependencies is the explicit avoidance of that.
- Not providing/installing tmux. Detect and instruct only.
- Not a reduced "demo-grade" CLI — the install delivers the full orchestrator.

---

## Key Decisions

- **Option 1 (per-platform `optionalDependencies`) over Option 3 (postinstall download).** Rationale: postinstall network access is blocked in many CI/corporate/sandbox environments — the most common installer-failure mode. esbuild, swc, and biome all migrated from download-on-install to optionalDependencies for this reason. Measured artifact size (~31 MB compressed dev release; ~20-28 MB expected for a stripped prod release) is well within npm norms (Playwright/swc ship comparable or larger platform packages), so size does not force Option 3.
- **Command stays `aiur`, package is `aiur-cli`.** The scope/name only affects the install string; `bin: { aiur: ... }` keeps the runtime command unchanged.
- **Platform matrix v1: `linux-x64`, `linux-arm64`, `darwin-arm64`, `darwin-x64`.** darwin-x64 retained for Intel Macs (cheap to add on existing macOS runners).
- **Do not bundle the opencode binary into the release; keep it (like tmux) an external runtime dependency.** Rationale: aiur is Apache-2.0 (a derivative of openai/symphony, Apache-2.0; see `LICENSE` + `NOTICE`). opencode is MIT but is currently invoked as a separately-installed binary, not redistributed, so it imposes no obligations. Bundling opencode would make aiur an MIT redistributor (must ship opencode's MIT license + its transitive third-party notices) — avoid in v1. npm package metadata must declare `"license": "Apache-2.0"` (not MIT).
- **Claim `aiur-cli` now under the personal npm account (its-everdred).** Publish a placeholder `aiur-cli@0.0.0` immediately to lock the name; ownership can be transferred to an org later if desired.

---

## Dependencies / Assumptions

- A `mix release` (`releases()` in `elixir/mix.exs`) is already configured and builds a self-contained ERTS-bearing bundle; its post-assemble step writes a `bin/aiur` shim. Verified: release exists at `elixir/_build/dev/rel/aiur` (85 MB unpacked, 57 MB ERTS, ~31 MB gzipped).
- tmux is assumed present at runtime; it is the one unavoidable external dependency the install cannot satisfy.
- ERTS is platform-specific and is built natively per OS/arch on CI runners; cross-compiling ERTS is not attempted.
- A measured prod-stripped release size (R8) is assumed to land ~20-28 MB compressed; if a real prod build exceeds ~150 MB compressed, revisit Option 3 (GitHub Releases hosting). [unverified — only the dev release has been measured]

---

## Outstanding Questions

### Deferred to Planning

- [Affects R9][Needs research] linux-arm64 build path on GitHub Actions — native arm runner vs QEMU emulation, and the resulting build-time/cost tradeoff.
- [Affects R6][Technical] Launcher implementation language — Node shim (`#!/usr/bin/env node`) vs a tiny published binary — and how it locates the platform package across npm/bun/pnpm/yarn install layouts.
- [Affects R8][Technical] Exact `mix release` strip configuration (which ERTS apps/docs are safe to drop) to hit the size target without breaking runtime.
- [Affects R1][Technical] How the release's existing `bin/aiur` shim (mise/repo-root assumptions) is reconciled with a toolchain-free end-user install — may need a release-only launcher variant.

---

## Next Steps

All blocking questions resolved. -> /ce-plan for the CI matrix and packaging implementation. (Immediate side action: claim `aiur-cli` on npm under the personal account.)
