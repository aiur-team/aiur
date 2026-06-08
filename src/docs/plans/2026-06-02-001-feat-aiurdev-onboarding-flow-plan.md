---
title: "feat: Rename dev wrapper to aiurdev + dogfoodable aiur onboarding"
type: feat
status: active
date: 2026-06-02
origin: elixir/docs/brainstorms/2026-06-02-aiurdev-onboarding-flow-requirements.md
---

# feat: Rename dev wrapper to `aiurdev` + dogfoodable `aiur` onboarding

## Overview

Rename the repo's dev/dogfood wrapper `scripts/aiur` to `scripts/aiurdev`, give it its own
isolated runtime namespace (`aiurdev-*` tmux socket/session, `~/.config/aiurdev` state), and
make it available machine-wide via a `mise run setup` task that symlinks `~/.local/bin/aiurdev`
back to the checkout. This frees the command name `aiur` for the npm-installed product, so the
genuine install + `aiur init` onboarding flow — and the full `aiurdev` command surface — can run
side by side on the same machine without colliding.

`aiurdev` carries the **full** wrapper command surface (`list`/`status`/`pause`/`resume`/`stop`/
`build`/`run`/`init`/`--test`/`--test3`/profiles/ad-hoc config) — it is a rename, not a subset.

Mental model after this change:
- **`aiur`** — npm-installed product (the thing under onboarding test)
- **`aiurdev`** — local source build, runnable from inside any target repo, full command parity

---

## Prerequisite: `src/` rename + root `mise.toml` (landed)

The prerequisite refactor has landed on this branch. Instead of a full flatten, `elixir/` was
renamed to `src/` and **only** `mise.toml` was lifted to the repo root:

- `elixir/` → `src/` (the whole Elixir app dir: `src/mix.exs`, `src/lib/`, `src/test/`,
  `src/README.md`, `src/AGENTS.md`, `src/docs/`)
- `src/mise.toml` → `mise.toml` (repo root) — lifted out so mise discovery works from root
- `scripts/`, `packaging/` live at the repo root (unaffected)

**Path note for the units below:** the plan was drafted assuming a full flatten, so it names
`test/`, `README.md`, `AGENTS.md` at the repo root. The Elixir app stayed nested, so those are
actually `src/test/`, `src/README.md`, `src/AGENTS.md`. `scripts/` and `mise.toml` are at the
repo root exactly as the plan assumes.

**mise discovery is resolved.** `mise.toml` is at the repo root, so `$MISE_PROJECT_ROOT` equals
the repo root and the `mise run setup` task can target `$MISE_PROJECT_ROOT/scripts/aiurdev`
directly with no `..` traversal. Quickstart `mise install` works from the clone root. (The
Elixir build still runs under `src/` via mise's ancestor search — CI uses `working-directory:
src` and finds the root config.)

---

## Problem Frame

The dev wrapper (`scripts/aiur`) and the npm product (`packaging/npm/aiur-cli`, installs
`aiur` on PATH) both claim the name `aiur`. Today's Quickstart prepends the repo `scripts/`
dir to PATH (`export PATH="$PWD/scripts:$PATH"`), which shadows any real installed `aiur`.
A maintainer therefore cannot dogfood the real install or the `aiur init` onboarding path
from the aiur checkout. Renaming the wrapper to `aiurdev` removes the collision.
(see origin: elixir/docs/brainstorms/2026-06-02-aiurdev-onboarding-flow-requirements.md)

---

## Requirements Trace

- R1. The repo dev wrapper is renamed to `aiurdev`; `scripts/aiur` no longer exists.
- R2. `aiurdev` is available machine-wide (works from inside any target repo) via a
  one-time `mise run setup` bootstrap that symlinks into `~/.local/bin`.
- R3. Invoking `aiurdev` runs the local aiur source build against the *current* repo's
  `.aiurconfig` (symlink resolves to the checkout; `repo_root` derives from script location).
- R4. The name `aiur` is no longer shadowed by the repo, so the npm-installed `aiur` and
  its `aiur init` onboarding flow can run on the dev machine.
- R5. Docs reflect the new flow; the wrapper test passes against `aiurdev`.
- R6. `aiurdev` uses an isolated runtime namespace (`aiurdev-$USER` tmux socket/session,
  `~/.config/aiurdev` state) so its full TUI can run **simultaneously** with npm `aiur`
  without one's `kill-session`/state-write clobbering the other.

**Origin actors:** maintainer/contributor (dogfooding aiur from the checkout); end user (npm `aiur init`).

---

## Scope Boundaries

- Not renaming the compiled release binary `bin/aiur` (and its `_build/.../rel/aiur/bin/aiur`
  shim) — the product is still named `aiur`; only the *dev wrapper* command and its runtime
  namespace change.
- Not changing wrapper behavior, flags, profiles semantics, or `--test`/`--test3` semantics
  (the command surface is identical; only resource *names* are namespaced).
- Not publishing to the npm registry — install verification uses a local pack/install or
  the already-built platform package.
- Not migrating any existing `~/.config/aiur/*` dev state to the new `~/.config/aiurdev/`
  location — a contributor re-runs `mise run setup` and reconfigures; old state is left in place.

### Deferred to Follow-Up Work

- None for the runtime namespace — isolation is **in scope** this change (R6, U2).

---

## Context & Research

### Relevant Code and Patterns

- `scripts/aiur` — the 67KB bash dev wrapper to rename. Already resolves symlinks back to the
  checkout (header `while [ -L "$src" ]` loop) and computes `repo_root` from script location
  with an `AIUR_REPO_ROOT` override — so a global symlink already behaves correctly (R3).
- `scripts/aiur` usage banner (~line 330) and `Profiles are loaded from ~/.config/aiur/...`
  (~line 401) contain user-facing `aiur` command-name mentions to update (U1).
- **Runtime-namespace tokens to isolate** (U2) — these are the exact lines that share state with
  npm `aiur`:
  - L49 `config_file` default `~/.config/aiur/aiur.profiles`
  - L50 `env_file` default `~/.config/aiur-dashboard.env`
  - L57 `bg_state_dir` default `~/.local/state/aiur` (cookie lives here, L766)
  - L808 `node_name` default `aiur-${USER}@127.0.0.1` (+ error echo L928)
  - L991 `mkdir ~/.config/aiur`
  - L1368 tmux session `aiur-%s-%s`; L1372 tmux socket `aiur-%s`
  - L1515 state write `~/.config/aiur/state` ← **npm launcher writes/reads/kills on this exact
    path + socket** (`aiur-launch.sh` L180/181/203/224/297), so this is the collision core.
- **`stop`/pkill patterns** (L1062-1109): L1080 and the BEAM-reap at L1092 are path-anchored to
  `$elixir_dir` (checkout-safe). But L1064/1068/1069/1073/1077 match `bin/aiur .*--interactive.*
  <config>` with **no path anchor** — an npm `aiur ./.aiurconfig` run on the same config path
  would match, so `aiurdev stop` could kill the product. U2 must anchor these to `$elixir_dir`.
- References that must **stay `aiur`**: the release binary `bin/aiur` (~lines 671/683/734/847)
  and `$elixir_dir/_build/.../rel/aiur/...` — the product binary name does not change.
- `mise.toml` (repo root, post-flatten) — currently `[tools]` only; add a `[tasks.setup]` task.
  Post-flatten `$MISE_PROJECT_ROOT` == repo root, so the symlink target is
  `$MISE_PROJECT_ROOT/scripts/aiurdev` directly.
- `test/scripts_aiur_test.exs` — `@script Path.expand(".../scripts/aiur", __DIR__)`, asserts
  `"Usage: aiur"`. Its `./bin/aiur` and `.aiurconfig` assertions reference the release binary /
  config and must **stay**.
- **Other files that hard-reference `scripts/aiur` and break on `git mv`** (must be updated, U4):
  - `test/aiur/regression/shutdown_cleanup_test.exs:26` — `File.read!(@scripts_aiur)`
  - `test/aiur/regression/warm_state_transitions_test.exs:126` — `File.read!(@script_path)`
  - `scripts/verify-u11.sh:66` — invokes `scripts/aiur`
  - `test/regression/aiur-shutdown.sh:39` — execs the absolute `scripts/aiur` path
  - (plus log-message/comment mentions in other regression tests — cosmetic, update opportunistically)
- `packaging/npm/aiur-cli/libexec/aiur-launch.sh` — the npm launcher. Has a dedicated
  distribution-free, tmux-free `init` branch (interactive `--eval`, inherits stdin), so
  `aiur init` via npm is the onboarding path to verify. Shares socket/session/state with the
  pre-isolation dev wrapper — the basis for the U2 isolation work.
- Quickstart in `README.md` (post-flatten): `export PATH="$PWD/scripts:$PATH"` +
  `../scripts/aiur init` — the lines to rewrite to the `mise run setup` + `aiurdev` flow.

### Institutional Learnings

- `docs/solutions/` is empty / no applicable prior learnings.
- Memory: drive features through the wrapper end-to-end before declaring done (manual CLI
  verification); the manual onboarding test is part of "done" here, not optional.

### External References

- None needed — internal bash/mise/npm tooling with strong local patterns.

---

## Key Technical Decisions

- **Isolate the dev runtime namespace to `aiurdev-*` / `~/.config/aiurdev`** (R6). Rationale:
  the npm launcher writes/reads/`kill-session`es on the exact `aiur-$USER` socket + session and
  `~/.config/aiur/state`. A stale backgrounded dev session on that shared socket gets killed by
  a later npm `aiur` run, and `state` is last-writer-wins. Since this change is *specifically* to
  let both run on one machine — and the user requires the full `aiurdev` TUI for local testing,
  not just the tmux-free `init` path — isolation is required, not deferrable.
- **Keep the env var *names* `AIUR_*`** (e.g. `AIUR_BG_STATE_DIR`, `AIUR_RELEASE_NODE`,
  `AIUR_CONFIG_FILE`) — only their **default values** move to the `aiurdev` namespace. Rationale:
  changing override env var names is needless churn; the collision is in the runtime resources the
  defaults point at, not the override knobs.
- **Anchor the `stop` pkill patterns to `$elixir_dir`.** Rationale: today's L1064/1068/1069/1073/
  1077 match `bin/aiur .*--interactive.*<config>` unanchored, so `aiurdev stop` could kill an npm
  `aiur` run on the same config path. Anchoring to the checkout dir (mirroring the safe L1080)
  keeps `stop` scoped to dev processes.
- **Machine-wide symlink via mise task**, not a repo-scoped PATH entry. Rationale: `aiurdev`
  must work from inside *other* repos being onboarded (R2/R3); a repo-dir PATH inject would
  only work inside the aiur checkout.
- **mise task targets `$MISE_PROJECT_ROOT/scripts/aiurdev`** (post-flatten `mise.toml` is at the
  repo root, so `$MISE_PROJECT_ROOT` is the repo root). No `..` traversal needed once flattened.
- **`git mv` for the rename** to preserve file history on `scripts/aiur` and the wrapper test.

---

## Open Questions

### Resolved During Planning

- Does renaming the wrapper affect `bin/aiur`? No — `bin/aiur` is the compiled release binary;
  only the dev wrapper command name and runtime namespace change. All `bin/aiur` references stay.
- Where does the mise task live? `mise.toml` at the repo root (post-flatten), targeting
  `$MISE_PROJECT_ROOT/scripts/aiurdev`.
- Should the usage/help banner text change? Yes — user-facing command-name mentions become
  `aiurdev`; the release binary token `bin/aiur` stays.
- Is the runtime namespace isolated or shared? Isolated (R6, U2) — decided this round.

### Deferred to Implementation

- Exact `npm` install-verification mechanism (local `npm pack` + global install vs. running
  the prebuilt platform package directly) — settle when actually testing R4. Confirm a concrete
  local-install path yields a runnable `aiur` before merge (package version is `0.0.0`).
- Whether the `setup` task should hard-fail or just warn when `~/.local/bin` is not on PATH.
- Whether the Erlang **node name** is fully wrapper-controlled (`AIUR_RELEASE_NODE` default at
  L808) or also set inside the release `rel/env` — investigate during U2; if the release also
  hard-codes `aiur-$USER`, isolation needs a release-side change too.
- Whether to also rename `~/.config/aiur-dashboard.env` → `aiurdev-dashboard.env` and the
  profiles file — not collision-critical (npm `aiur` doesn't read them); default to renaming
  for namespace coherence, confirm during U2.
- Bugs surfaced during manual onboarding testing become new implementation units.

---

## Implementation Units

- [ ] U1. **Rename `scripts/aiur` → `scripts/aiurdev` and update in-script command name**

**Goal:** The dev wrapper exists as `scripts/aiurdev`; user-facing help/usage text uses the
`aiurdev` command name. (Runtime-namespace tokens are handled in U2, release binary stays `aiur`.)

**Requirements:** R1, R3

**Dependencies:** None

**Files:**
- Rename: `scripts/aiur` → `scripts/aiurdev` (via `git mv`)
- Modify: `scripts/aiurdev` (usage banner ~line 330; profiles help text ~line 401; any other
  help/echo strings that name the command `aiur`)

**Approach:**
- Update only command-name occurrences in human-facing strings (usage line, help prose, hints).
- Leave unchanged in this unit: `bin/aiur`, `_build/.../rel/aiur/bin/aiur`, and the runtime
  namespace tokens (those move in U2). `AIUR_*` env var *names* stay.
- The symlink-resolution loop and `repo_root` derivation already support being invoked via a
  global symlink — no change needed there (R3).

**Patterns to follow:**
- The existing usage/echo string style in `scripts/aiur`.

**Test scenarios:**
- Covered by U4 (the wrapper test). No separate test here.

**Verification:**
- `scripts/aiurdev` runs usage and prints `Usage: aiurdev ...`.
- `grep -c '\baiur\b' scripts/aiurdev` before/after diff is reviewed: every remaining bare
  `aiur` is an intentional keep (`bin/aiur`, release paths) — no human-facing command mention left.

---

- [ ] U2. **Isolate the `aiurdev` runtime namespace from npm `aiur`**

**Goal:** `aiurdev` uses `aiurdev-$USER` tmux socket/session, `~/.config/aiurdev` + `~/.local/
state/aiurdev` state, and an `aiurdev-$USER@127.0.0.1` node, so its full TUI runs simultaneously
with npm `aiur` without either one's `kill-session`/state-write/node-name clobbering the other.

**Requirements:** R6, R4

**Dependencies:** U1

**Files:**
- Modify: `scripts/aiurdev` — change the **default values** at the enumerated lines:
  - L49 `config_file` default → `~/.config/aiurdev/aiurdev.profiles`
  - L57 `bg_state_dir` default → `~/.local/state/aiurdev` (cookie follows it)
  - L808 `node_name` default → `aiurdev-${USER}@127.0.0.1` (+ L928 error echo)
  - L991 `mkdir` → `~/.config/aiurdev`
  - L1368 session `aiurdev-%s-%s`; L1372 socket `aiurdev-%s`
  - L1515 state write → `~/.config/aiurdev/state`
  - L401 profiles help text path
- Modify: `scripts/aiurdev` `stop` block — anchor L1064/1068/1069/1073/1077 `bin/aiur
  .*--interactive` patterns to `$elixir_dir` (mirror the safe L1080) so `aiurdev stop` cannot
  match an npm `aiur` run on the same `.aiurconfig` path.

**Approach:**
- Move only the **default values**; keep the `AIUR_*` env override names.
- Investigate whether the node name is also set in the release `rel/env.sh.eex` / `vm.args`; if
  the release hard-codes `aiur-$USER`, add a matching release-side override (deferred-question).
- Profiles/dashboard-env file relocation (`aiurdev.profiles`, `aiurdev-dashboard.env`) is
  namespace-coherence, not collision-critical — apply it here for cleanliness.

**Patterns to follow:**
- The existing path-anchored pkill at L1080 / BEAM-reap at L1092 as the template for `stop` scoping.

**Test scenarios:**
- Happy path (U4 + manual): wrapper emits `aiurdev-$USER` socket/session and `~/.config/aiurdev`
  state references; no bare `aiur-$USER`/`~/.config/aiur` runtime tokens remain.
- Coexistence (manual, Post-Impl): a backgrounded `aiurdev` TUI survives a subsequent npm
  `aiur` run, and vice versa — neither `kill-session` reaches the other's socket.
- `aiurdev stop` does not terminate a concurrently-running npm `aiur` on the same config path.

**Verification:**
- `grep -n 'aiur-%s\|config/aiur/\|local/state/aiur\b\|aiur-${USER}@' scripts/aiurdev` returns
  only `aiurdev-`-prefixed forms (no bare `aiur` runtime tokens).
- Manual coexistence check passes (Post-Impl Verification step 4).

---

- [ ] U3. **Add `mise run setup` task that symlinks `~/.local/bin/aiurdev`**

**Goal:** A one-time bootstrap puts `aiurdev` on PATH machine-wide, pointing at the checkout.

**Requirements:** R2, R3

**Dependencies:** U1 (symlink target must be `scripts/aiurdev`)

**Files:**
- Modify: `mise.toml` (repo root, post-flatten — add `[tasks.setup]`)

**Approach:**
- Task creates `~/.local/bin` if missing and `ln -sf "$MISE_PROJECT_ROOT/scripts/aiurdev"
  ~/.local/bin/aiurdev`, then echoes the linked path. Post-flatten `$MISE_PROJECT_ROOT` is the
  repo root, so no `..` traversal is needed.
- Detect whether `~/.local/bin` is on PATH; if not, print a clear note telling the user to add
  it (decision on warn-vs-fail deferred to implementation).

**Patterns to follow:**
- mise `[tasks.*]` TOML syntax; keep the task POSIX-sh portable (macOS + Linux).

**Test scenarios:**
- Test expectation: none — `mise.toml` task config has no Elixir-level behavior to unit-test.
  Validated manually in U3 verification and the Phase-level onboarding test.

**Verification:**
- `mise run setup` creates `~/.local/bin/aiurdev` as a symlink to `<repo-root>/scripts/aiurdev`.
- From an unrelated directory, `aiurdev` resolves and prints `Usage: aiurdev ...`.
- Re-running `setup` is idempotent (refreshes the link without error).

---

- [ ] U4. **Update tests + helper scripts for the renamed command**

**Goal:** Every file that references `scripts/aiur` is updated to `scripts/aiurdev`; the wrapper
test asserts the new command name and (post-U2) the new namespace, while preserving all
release-binary/config assertions. No `git mv`-orphaned path reference remains anywhere in the repo.

**Requirements:** R5

**Dependencies:** U1, U2

**Files:**
- Rename: `test/scripts_aiur_test.exs` → `test/scripts_aiurdev_test.exs` (via `git mv`)
- Modify: the renamed test — `@script` path → `.../scripts/aiurdev`; `"Usage: aiur"` →
  `"Usage: aiurdev"`; any banner/namespace assertion that legitimately changed (e.g. socket/
  session/state strings if asserted).
- Modify: `test/aiur/regression/shutdown_cleanup_test.exs:26` — `@scripts_aiur` path →
  `scripts/aiurdev`.
- Modify: `test/aiur/regression/warm_state_transitions_test.exs:126` — `@script_path` →
  `scripts/aiurdev`.
- Modify: `scripts/verify-u11.sh` (~L66 invocation; comments) → `scripts/aiurdev`.
- Modify: `test/regression/aiur-shutdown.sh:39` — exec path → `scripts/aiurdev`.

**Approach:**
- Change wrapper-path, command-name-banner, and (where present) namespace assertions only.
- Leave unchanged: `MISE:exec -- ./bin/aiur`, `🔨 rebuilding bin/aiur`, `bin/aiur`/release-path
  pkill assertions, and `.aiurconfig` workflow-path assertions — these reference the release
  binary and config, not the dev command.
- For the regression tests that `File.read!` the wrapper for source assertions, only the path
  attribute changes; the asserted source substrings change only if U2 renamed the matched token.

**Execution note:** Characterization-style — run each affected test against the rename and adjust
only assertions that legitimately changed; an unchanged `bin/aiur` assertion that newly fails
signals an over-broad rename in U1/U2.

**Patterns to follow:**
- Existing `run_aiur/2` helper and assertion style in the wrapper test.

**Test scenarios:**
- Happy path: `aiurdev` with no args / a profile prints `Usage: aiurdev` and the expected
  `MISE:exec -- ./bin/aiur` command log (unchanged binary reference).
- Edge case: a `bin/aiur` / `.aiurconfig` assertion remaining green confirms the rename did not
  bleed into release-binary or config tokens.
- Namespace: the two regression tests reading the wrapper source still find their guarded
  patterns (cleanup-trap re-entry guard, signal isolation) under the renamed/namespaced wrapper.

**Verification:**
- `mise exec -- mix test test/scripts_aiurdev_test.exs` passes.
- `mise exec -- mix test test/aiur/regression/shutdown_cleanup_test.exs
  test/aiur/regression/warm_state_transitions_test.exs` passes.
- Full `mise exec -- mix test` stays green.

---

- [ ] U5. **Update docs to the `aiurdev` + npm `aiur` flow**

**Goal:** Quickstart and contributor docs describe `mise run setup` → `aiurdev`, the `aiur` =
product / `aiurdev` = dev split (full command parity), and the isolated namespace; no stale
`scripts/aiur` dev-command references remain repo-wide.

**Requirements:** R1, R2, R4, R6

**Dependencies:** U1, U2, U3

**Files:**
- Modify: `README.md` (post-flatten merged Quickstart: replace `export PATH="$PWD/scripts:$PATH"`
  and `../scripts/aiur init` with `mise run setup` + `aiurdev`; "Operating with `aiur`" section
  → `aiurdev`; `scripts/aiur` repo-layout bullet; profiles path `~/.config/aiur` →
  `~/.config/aiurdev`)
- Modify: `AGENTS.md` (post-flatten merged — repo-layout bullet; manual-test commands; manual
  TUI driver recipe — command becomes `aiurdev` **and** the tmux session is now `aiurdev-$USER`)
- Modify: any `~/.config/aiur` / `aiur-$USER` operator references in docs that name the dev
  namespace specifically (not the product).

**Approach:**
- Replace the dev-wrapper command name `scripts/aiur` / `./scripts/aiur` with `aiurdev`.
- Add a one-line note distinguishing `aiur` (npm product) from `aiurdev` (local dev build).
- **Update** the manual-driver tmux session name to `aiurdev-$USER` (it changed in U2) — and
  update the corresponding auto-memory recipe after merge.
- Walk the AGENTS.md manual-driver recipe end-to-end with the new command + session name.

**Patterns to follow:**
- Existing doc tone/structure; repo-relative paths only.

**Test scenarios:**
- Test expectation: none — documentation. Validated by review + the manual onboarding test.

**Verification:**
- `grep -rn 'scripts/aiur\b' . --include='*.md' --include='*.sh' --include='*.exs'
  --include='*.toml'` (excluding `docs/plans` + `docs/brainstorms`) returns no stale dev-command
  references — only intentional `scripts/aiurdev`.
- `grep -rn 'aiur-\$USER\|\.config/aiur/' AGENTS.md README.md` shows only product-context or
  `aiurdev-` forms in dev-command contexts.
- Quickstart, read top-to-bottom, yields a working `aiurdev` without the old `export PATH` step.

---

## Post-Implementation Verification (manual onboarding test)

Not a code unit — the maintainer-driven dogfooding pass the whole change exists to enable.
Bugs found here become new implementation units on this branch.

1. `mise run setup`; confirm `aiurdev` works from an unrelated repo (R2/R3).
2. Install the npm product locally (mechanism TBD: `npm pack` + global install, or run the
   prebuilt platform package); confirm `aiur` resolves to the product, no longer shadowed (R4).
3. Run `aiur init` in a fresh repo; confirm it scaffolds a valid `.aiurconfig` (+ prompt
   template) and that repo can then boot under `aiur`.
4. **Coexistence (R6):** start a full `aiurdev` TUI, then start npm `aiur` (or vice versa) on
   the same machine; confirm neither tears down the other's tmux session and that
   `~/.config/aiurdev/state` vs `~/.config/aiur/state` stay separate. Confirm `aiurdev stop`
   leaves a concurrent npm `aiur` running.

---

## System-Wide Impact

- **Interaction graph:** the change touches the wrapper command surface + runtime namespace, the
  mise task, the wrapper test, two regression tests, two helper shell scripts, and docs. No
  Elixir application runtime code changes (the regression tests read the wrapper *as source*).
- **API surface parity:** the npm launcher (`aiur-launch.sh`) and the dev wrapper both expose an
  `aiur`-style CLI; this change renames the *dev* command and namespaces its runtime resources,
  leaving the product CLI and `bin/aiur` intact.
- **State lifecycle (now isolated):** `aiurdev` writes `aiurdev-$USER` tmux socket/session,
  `~/.config/aiurdev` + `~/.local/state/aiurdev`, node `aiurdev-$USER@127.0.0.1`; npm `aiur`
  keeps `aiur-$USER` / `~/.config/aiur`. The two no longer share a `kill-session` target or a
  `state` file, so simultaneous full-TUI runs are safe (R6).
- **Unchanged invariants:** `bin/aiur` release binary, all wrapper flags/profiles/`--test`
  semantics and the full command surface, `AIUR_*` env override names.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Over-broad rename mangles `bin/aiur` release-binary token | U1 changes command-name strings only; U4 keeps `bin/aiur` assertions green as a tripwire; before/after `grep -c` review in U1. |
| Namespace isolation misses a token → partial collision still possible | U2 enumerates the exact lines (L49/57/808/928/991/1368/1372/1515); verification greps for any residual bare `aiur` runtime token; manual coexistence check in Post-Impl step 4. |
| Erlang node name also hard-coded in the release → node clash despite wrapper change | U2 deferred-question investigates `rel/env`/`vm.args`; add release-side override if needed. |
| `aiurdev stop` kills a concurrent npm `aiur` on the same config path | U2 anchors the unanchored `bin/aiur .*--interactive` pkill patterns (L1064/1068/1069/1073/1077) to `$elixir_dir`. |
| `git mv` orphans path references outside the 5 doc files (regression tests + shell scripts) | U4 explicitly updates `shutdown_cleanup_test.exs`, `warm_state_transitions_test.exs`, `verify-u11.sh`, `aiur-shutdown.sh`; U5 verification is a repo-wide grep, not 4-file. |
| `~/.local/bin` not on user PATH → `aiurdev` not found | U3 detects and warns (warn-vs-fail decision deferred). |
| Flatten hasn't landed when work starts → wrong paths / mise not found from root | Prerequisite section documents the path prefix + `cd elixir` fallback; confirm flatten merged before starting U3/U4/U5. |
| Stale `scripts/aiur` references linger in docs/CI | U5 repo-wide grep verification; manual Quickstart walk-through. |
| npm install verification hand-waved (package version `0.0.0`) | Post-Impl step 2 + deferred question require confirming a concrete local-install path yields a runnable `aiur` before merge. |

---

## Documentation / Operational Notes

- The Quickstart change is the primary user-visible impact: contributors switch from a manual
  `export PATH` to `mise run setup`.
- After merge, the manual-driver memory/recipe in `AGENTS.md` invokes `aiurdev` **and** targets
  the new `aiurdev-$USER` tmux session (the session name changed in U2) — update the auto-memory
  manual-TUI-driver recipe to match.

---

## Sources & References

- **Origin document:** [elixir/docs/brainstorms/2026-06-02-aiurdev-onboarding-flow-requirements.md](elixir/docs/brainstorms/2026-06-02-aiurdev-onboarding-flow-requirements.md)
  (paths in the origin predate the repo flatten — see Prerequisite section)
- Related code: `scripts/aiur`, `mise.toml`, `test/scripts_aiur_test.exs`,
  `test/aiur/regression/shutdown_cleanup_test.exs`, `test/aiur/regression/warm_state_transitions_test.exs`,
  `scripts/verify-u11.sh`, `test/regression/aiur-shutdown.sh`,
  `packaging/npm/aiur-cli/libexec/aiur-launch.sh`, `packaging/npm/aiur-cli/bin/aiur.js`
- Related docs: `README.md` (Quickstart), `AGENTS.md` (all post-flatten / merged)
