---
status: completed
type: fix
created: 2026-06-22
github_issue: its-everdred/aiur#432
---

# fix: Trust the prewarm base mise.toml and surface base_build failures (resolves #432)

## Summary

Prewarm clones the target repo's base at `~/.aiur/repo/<owner>/<name>` and runs the configured `base_build` there, but it never tells `mise` to trust the freshly-cloned base `mise.toml`. For any repo whose toolchain comes from `mise` (e.g. a pnpm/nx JS repo, where `mise exec -- pnpm …` or shell-activated `pnpm` is used), `base_build` fails immediately with `Config files … are not trusted`, the base is never built, and `prewarm` provides zero benefit — every workspace falls back to a cold clone. Two small changes fix it: (1) inject `MISE_TRUSTED_CONFIG_PATHS` for the base when running `base_build` (the same trust mechanism `AgentEnvironment` already uses for agent workspaces), and (2) log the failure at `error` so a broken base is loud at the source instead of an intermittent orchestrator warning.

## Problem Frame

- **Confirmed root cause (non-sandbox):** `RepoBase.run_base_build/2` (`src/lib/aiur/repo_base.ex`) runs `System.cmd("sh", ["-lc", scrubbed], cd: base_path, stderr_to_stdout: true)` with **no `env:`**. The base checkout's `mise.toml` is untrusted, so `mise` refuses to run. Verified directly: `sh -lc 'cd <base> && mise exec -- pnpm --version'` errors `not trusted`; prepending `mise trust` (or exporting `MISE_TRUSTED_CONFIG_PATHS`) fixes it and a full `base_build` then succeeds.
- **Asymmetry:** `AgentEnvironment.workspace_env/1` (`src/lib/aiur/agent_environment.ex`) already sets `MISE_TRUSTED_CONFIG_PATHS` for agent **workspaces**; the prewarm **base** gets none of that env. The base path varies per repo, so the robust target is the base **root directory** (mise trusts any config under a trusted path), not a hardcoded sub-path.
- **Current-main mitigation (do not undo):** `Orchestrator.prewarm_gate/2` already maps `{:error, _} -> :dispatch` with a `Logger.warning("prewarm base unavailable … cold clone")` (`src/lib/aiur/orchestrator.ex`). So on current `main` the original "agents idle forever" symptom is softened to "always cold-clone + a warning." This fix restores prewarm's actual benefit and makes the failure loud at its source; it must keep the cold-clone fallback intact.

## Scope Boundaries

In scope:
- Trust the base `mise.toml` when running `base_build`.
- Log prewarm `{:error, _}` outcomes (including the captured `base_build` output) at `error` level at the source.
- Regression tests in `src/test/aiur/repo_base_test.exs`.

### Deferred to Follow-Up Work
- `AgentEnvironment.workspace_env/1` hardcodes the workspace trust path to `<workspace>/elixir/mise.toml`, but repos (including aiur itself) keep `mise.toml` at the root — the workspace trust path is likely wrong for every repo. File as a separate `agent:todo` bug; do not fix here (different surface, different blast radius).
- Changing the orchestrator gate or the `poll_seconds` semantics — out of scope; the gate's cold-clone fallback is correct and stays.

---

## Implementation Units

### U1. Trust the base mise.toml when running base_build

**Goal:** `base_build` runs with the base's `mise.toml` trusted, so mise-provided toolchains work and the base actually builds.

**Files:**
- `src/lib/aiur/agent_environment.ex` — add `base_env/1`.
- `src/lib/aiur/repo_base.ex` — pass the env into `run_base_build/2`'s `System.cmd`.
- `src/test/aiur/repo_base_test.exs` — integration test (trust var reaches `base_build`).
- `src/test/aiur/agent_environment_test.exs` — unit test for `base_env/1` (create if absent; otherwise extend).

**Approach:**
- Add `AgentEnvironment.base_env/1` returning Port-compatible env tuples for a base path — at minimum `{~c"MISE_TRUSTED_CONFIG_PATHS", base_path_as_charlist}`. Point it at the base **root directory** (trusts any `mise.toml` under the base regardless of layout), and return `[]` for a non-binary arg so callers can splat unconditionally — mirror the shape/docstring style of `workspace_env/1`. Do **not** override `HEX_HOME`/`MIX_HOME`: the moduledoc states the detected `base_build` command owns those, and `System.cmd` `env:` merges (it won't clobber the inherited env or the command's own exports).
- In `RepoBase.run_base_build/2`, add `env: AgentEnvironment.base_env(base_path)` to the existing `System.cmd("sh", ["-lc", scrubbed], …)` call. No other behavior change.

**Patterns to follow:** `AgentEnvironment.workspace_env/1` (env-tuple shape, empty-list fallback) and its call sites in `src/lib/aiur/claude/coding_agent.ex` / `src/lib/aiur/codex/coding_agent.ex`.

**Test scenarios:**
- `base_env/1` returns a list containing `{~c"MISE_TRUSTED_CONFIG_PATHS", <charlist of base path>}` for a binary base path.
- `base_env/1` returns `[]` for a non-binary argument (nil) so it splats safely.
- Integration via `refresh/3`: run `RepoBase.refresh(base, origin, base_build)` where `base_build` writes `$MISE_TRUSTED_CONFIG_PATHS` to a file in the base (e.g. `printf '%s' "$MISE_TRUSTED_CONFIG_PATHS" > trust_path`); assert the file content equals the base path. This proves the trust var is actually present in the `base_build` shell, exercising the real `System.cmd` env path (no mock).
- Existing `refresh/3` tests (clone+build, idempotent, rebuild-on-advance, error-skips-marker, ordered phase events) still pass unchanged.

### U2. Surface prewarm base failures at error level

**Goal:** A failing/looping base build is logged loudly at the source (with the captured output), not just an intermittent orchestrator warning.

**Files:**
- `src/lib/aiur/repo_base.ex` — log on the `{:error, reason}` resolution.
- `src/test/aiur/repo_base_test.exs` — assert the error is logged.

**Approach:**
- Where `RepoBase` resolves a refresh to `{:error, reason}` — the sync `refresh/3` error branch and the async `build_worker/4` error branch both already `emit({:error, reason})` — also `Logger.error/1` a single clear line including `reason` (which carries `{:base_build_failed, status, out}` / clone / fetch / reset / crash detail and the captured stdout+stderr). Prefer a small shared private helper (e.g. `log_and_emit_error/1`) so both paths log identically and the pubsub `emit({:error, …})` behavior is unchanged. Truncate extremely long captured output if it would flood logs, but keep enough to diagnose (the "not trusted" line is short and near the top).
- Keep `Logger` already required (it is). Do not change phase values, the marker logic, or the orchestrator gate.

**Patterns to follow:** existing `Logger.error(...)` usage in `src/lib/aiur/orchestrator.ex`; the existing `emit/1` calls in `repo_base.ex`.

**Test scenarios:**
- `ExUnit.CaptureLog.capture_log/1` around `RepoBase.refresh(base, origin, "echo boom 1>&2; exit 3")` contains an `[error]` line mentioning the base-build failure and includes the captured output (`boom`) and/or the exit status. Pairs with the existing "returns an error and skips the marker" test, which still asserts the `{:error, {:base_build_failed, 3, _}}` return and absent marker.
- A successful `refresh/3` (`base_build` = `true`) logs **no** `[error]` line (no false alarms).

---

## Verification

- `make -C src MIX='mise exec -- mix' all` passes (compile + full ExUnit + lint/format gate) from the worktree.
- New trust integration test fails on `main` (no env passed) and passes with U1.
- New error-log test fails on `main` (failure is silent in `RepoBase`) and passes with U2.
- Manual sanity (only in a coordinated window — see Constraints): against a pnpm/nx tracker with `prewarm.enabled`, `~/.aiur/repo/<owner>/<repo>` gets `node_modules` + build artifacts and `aiur.log` shows `prewarm:phase` reaching `:ready`; agents dispatch from the warm base rather than cold-cloning.

## Constraints & Coordination

- Work stays on branch `fix/432-prewarm-base-trust` in the worktree `~/github/everdred/aiur-432-prewarm-trust` (the main checkout is in use by a running aiur).
- **Singleton (#431):** before launching `aiurdev`/`aiur` for any manual verification, run `pgrep -f 'rel/aiur/.*beam'` and never start a second instance while one is up — another agent is working #431 and will launch aiur. `mix compile` / `mix test` do not launch the orchestrator and are safe.
- End: open a PR off `main`; file the `workspace_env` trust-path bug (and any other findings) as `agent:todo` on `its-everdred/aiur`.
