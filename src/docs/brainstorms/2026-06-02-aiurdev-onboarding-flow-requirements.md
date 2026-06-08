# Requirements: `aiurdev` dev command + dogfoodable `aiur` onboarding flow

Created: 2026-06-02
Branch: `fix/onboarding-flow`

## Problem

The repo's dev/dogfood wrapper (`scripts/aiur`) and the npm-published product
(`packaging/npm/aiur-cli`, installs `aiur` on PATH) both claim the command name
`aiur`. The current Quickstart puts the repo's `scripts/` dir on PATH
(`export PATH="$PWD/scripts:$PATH"`), which **shadows** any real installed `aiur`.

Consequence: a maintainer working in the aiur checkout cannot run the genuine
npm-installed `aiur` — so the real install + `aiur init` onboarding path can't be
dogfooded from the same machine that develops aiur.

## Goal / End State

- The repo dev wrapper is renamed to **`aiurdev`** and is available **machine-wide**,
  always pointing back at the local aiur checkout's source build.
- The name `aiur` is freed for the **npm-installed product**, so the real install
  and `aiur init` onboarding flow can be tested on the dev machine.
- A contributor going through the local dev flow gets `aiurdev` "for free" via a
  one-time `mise run setup` bootstrap.

Mental model:
- **`aiur`** = npm-installed product (the thing under onboarding test).
- **`aiurdev`** = local source build, runnable from inside any target repo.

## Decisions

1. **Rename** `scripts/aiur` → `scripts/aiurdev`.
2. **PATH mechanism:** machine-wide symlink, not a repo-scoped PATH entry.
   `aiurdev` must work from inside *any* repo (the target project being onboarded),
   while running the local aiur source against that repo's `.aiurconfig`.
   - The wrapper already resolves symlinks to the checkout (`while [ -L "$src" ]`
     loop) and computes `repo_root` from the script's true location, with an
     `AIUR_REPO_ROOT` override — so a global symlink behaves correctly.
3. **Install mechanism:** a `mise run setup` task in `elixir/mise.toml` that creates/
   refreshes `~/.local/bin/aiurdev` → `$MISE_PROJECT_ROOT/scripts/aiurdev`.
   Quickstart already runs `mise install`, so this is a one-time bootstrap during
   onboarding.
4. **Rename scope = minimal.** Change the command/file name, usage strings, docs, and
   the wrapper test. **Keep** the internal runtime namespace (`~/.config/aiur/`,
   `~/.local/state/aiur`, tmux `aiur-$USER`) unchanged.
   - Rationale: the wrapper's `stop`/pkill is path-scoped to the source checkout
     (`$elixir_dir.*bin/aiur` and config-path patterns), so `aiurdev stop` does not
     match the npm release (different install path). The two coexist by path.

## Sequence (per user)

1. Do the `aiurdev` rename + mise setup task first.
2. Install via npm; verify the real `aiur` command works end to end.
3. Test the `aiur init` onboarding flow in a fresh repo.
4. Expect to find bugs along the way — fix them on this branch.

## Scope / Blast Radius

In scope (rename references):
- `scripts/aiur` → `scripts/aiurdev` (file + internal usage/help text mentioning the
  command name).
- `elixir/test/scripts_aiur_test.exs` (wrapper test; may also rename the file).
- Docs: `AGENTS.md`, `elixir/AGENTS.md`, `README.md`, `elixir/README.md` (Quickstart
  `export PATH` line → `mise run setup`; `../scripts/aiur init` → `aiurdev init`).
- `elixir/mise.toml`: add the `setup` task.
- The manual TUI driver recipe / tmux session references in `AGENTS.md` that name the
  `aiur-$USER` session — update command name, but session name stays `aiur-$USER`
  under the minimal-rename decision (confirm the documented recipe still resolves).

Out of scope / deferred:
- Renaming the internal state namespace (`~/.config/aiur/`, `~/.local/state/aiur`,
  tmux session/socket `aiur-$USER`) to `aiurdev-*`. Only revisit if running `aiurdev`
  and npm `aiur` *live simultaneously* proves to collide in practice.

## Known Risks / Watch-list (bugs likely surfaced during testing)

- **tmux session/socket collision:** both `aiurdev` and npm `aiur` derive the tmux
  socket from `aiur-$USER`. Running both interactive UIs at once could collide.
  Not exercised by the `aiur init` one-shot, but watch for it.
- **Arbitrary-cwd behavior:** the wrapper's profiles set `root=$repo_root` (the aiur
  checkout). Confirm that invoking `aiurdev` (esp. no-arg / explicit-config) from a
  *different* repo operates on the current repo's `.aiurconfig`, not the aiur repo.
- **npm `aiur init` parity:** `init` runs as a foreground one-shot in the release
  (`isForegroundOneShot`), skipping tmux/opencode preflight. Verify it scaffolds
  `.aiurconfig` + prompt template correctly in a fresh, mise-less target repo.
- **`~/.local/bin` on PATH:** the mise setup task assumes `~/.local/bin` is already on
  PATH; if not, `aiurdev` won't resolve. Decide whether setup warns when it isn't.

## Success Criteria

- `mise run setup` creates a working `~/.local/bin/aiurdev` symlink; `aiurdev` runs
  from inside an unrelated repo and operates on that repo.
- `npm install` (or local pack/install) yields a working `aiur` on PATH that runs the
  release, with `aiurdev` and `aiur` no longer shadowing each other.
- `aiur init` scaffolds a valid `.aiurconfig` (+ prompt template) in a fresh repo and
  that repo can then boot under `aiur`.
- Docs reflect the new flow; `scripts_aiur_test.exs` passes against `aiurdev`.
