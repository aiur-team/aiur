# T-049: workspace wave 2: Materialize, Provisioner, Hooks, BootstrapImage, Refresh, Remove; slim

**Phase:** 4
**Depends-on:** T-048
**Labels:** `agent:todo` `refactor` `phase:4` `complexity:3`

## Problem / context

`src/lib/aiur/workspace.ex` is regression hotspot #4 ("Workspace lifecycle, git metadata & prewarm base", ~19 incidents — `docs/refactor/research-history-hotspots.md` row 4). The decomposition contract is `docs/refactor/research-arch/giant-workspace.md` §2 (the NAME MAP — binding) and §3 (wave sequencing). T-048 already extracted the leaf modules `Aiur.Workspace.Layout`, `Aiur.Workspace.Context`, `Aiur.Workspace.Remote`, `Aiur.Workspace.Checkout`, and `Aiur.Workspace.GitMetadata`.

This ticket is the FINAL workspace wave: extract the remaining six concerns into `Aiur.Workspace.Materialize`, `Aiur.Workspace.Provisioner`, `Aiur.Workspace.Hooks`, `Aiur.Workspace.BootstrapImage`, `Aiur.Workspace.Refresh`, and `Aiur.Workspace.Remove`, then slim `Aiur.Workspace` to a pure facade. **Slimmed line ceiling: `src/lib/aiur/workspace.ex` must be <= 130 lines after this ticket** (research target ~110).

Hard extraction rules for this whole ticket (no exceptions):

- Move code **verbatim** — extract, do not rewrite. Function bodies, guards, pattern-match clauses, comments, log-line text, shell-script strings, and every error-tuple shape move byte-for-byte. The ONLY permitted edits are: module wrapper, `alias`/`require` lines, `defp` → `def` where a function becomes cross-module API, the five renames named below, and qualifying calls with the new module names.
- Public function signatures and observable behavior of `Aiur.Workspace` are unchanged. External callers (`src/lib/aiur/agent_runner.ex:81,105,118`, `src/lib/aiur/orchestrator.ex:1756,4166`, `src/lib/aiur/alerts.ex:642`, `src/lib/aiur/opencode/session_writer.ex:796`, `src/lib/aiur/opencode/session_writer_registry.ex:211`) keep calling `Aiur.Workspace.*` and are NOT edited.
- The parent module delegates to the extracted modules so all existing callers keep working.
- Every extracted module gets a `@moduledoc`, `@spec` on every public `def`, and its own test file. **New modules are NOT coverage-exempt** — do not touch `ignore_modules` in `src/mix.exs` (that file is not in Files).
- After every step below, the repo compiles and the full suite passes (`mix compile --warnings-as-errors` + `mix test` from `src/`). After the final step, the full Agent gate passes.

Concurrency/timing semantics that must be preserved **verbatim** (from giant-workspace.md §4 — the file's regressions are semantic, not structural):

1. **Exit-65 refresh-refusal contract + non-fatal WIP skip (#569→#577→#595→#653/#656→#661).** `stale_leftover_refresh_refusal?/1` matches exactly `{:workspace_hook_failed, "before_run", 65, _output}`. Recreate is only for todo dispatches (`Context` classifies state `"todo"` OR label `"agent:todo"`); a non-todo dirty refusal must return `:ok` (skip refresh, keep WIP). The recreate path re-runs before_run exactly once.
2. **`created?` tri-state `true | false | :materialized`.** The after_create hook runs ONLY on `true`; `:materialized` and `false` skip it. Do not collapse to a boolean.
3. **Timeout envelopes and error-tuple shapes.** Every local hook and bootstrap-image run uses `Task.async` + `Task.yield(timeout_ms)` + `Task.shutdown(task, :brutal_kill)`. Tuple shapes are API and move unchanged: `{:workspace_hook_timeout, hook_name, ms}` (including the remote `"remote_command"` → `"bootstrap_image"` remap), `{:workspace_hook_failed, hook, status, output}`, `{:workspace_prepare_failed, ...}` (arity differs local/remote), `{:workspace_remove_failed, worker_host, status, output}`.
4. **Env scrubbing in local `run_hook/5`.** `Aiur.AgentEnvironment.scrub_shell_command/1` must keep wrapping the hook command, and `hook_env/0` must keep exporting `THIS_REPOSITORY_URL`.
5. **`create_for_issue/2` rescue envelope.** The `rescue [ArgumentError, ErlangError, File.Error]` stays in the facade and keeps wrapping the *delegated* provisioning calls (the raising `File.rm_rf!`/`File.mkdir_p!` now live inside `Provisioner`/`Materialize`, still invoked inside the facade's `try`). Moving work outside the `try` changes the failure mode from `{:error, e}` to a crash.
6. **Reuse/idempotency + fan-out.** Existing dir → `{:ok, ws, false}` with no deletion (WIP preserved); a stale non-dir file is replaced; `remove_issue_workspaces(id, nil)` fans out across all configured `worker.ssh_hosts`; remote scripts keep tilde expansion (`Remote.remote_shell_assign/2`, extracted in T-048).

Line ranges below cite `src/lib/aiur/workspace.ex` as of ticket authoring (1235 lines, pre-T-048). After T-048 merges the absolute numbers shift, but T-048 does not rename or rewrite any function listed here — locate each function by name and move its then-current body.

## Scope (exact)

1. **Preflight.** Verify T-048 landed: all five files `src/lib/aiur/workspace/layout.ex`, `context.ex`, `remote.ex`, `checkout.ex`, `git_metadata.ex` exist and `mix test` is green on your branch base. If any is missing, STOP and comment the blocker on the issue. Throughout this ticket, keep whatever call names T-048 established in the facade for `Layout`/`Context`/`Remote`/`Checkout`/`GitMetadata` — do not rename or edit those five modules.

2. **Step 1 (commit 1): create `Aiur.Workspace.Materialize` and `Aiur.Workspace.Provisioner`.**
   - `src/lib/aiur/workspace/materialize.ex` — module `Aiur.Workspace.Materialize`. Move verbatim:
     - `materialize_from_base/2` (lines 156–178) — public, keep the existing `@doc false` + `@spec`.
     - `materialize_from_base/3` (lines 180–200) — public, keep `@doc false` + `@spec`.
     - `copy_tree/2` (lines 290–298) — private (`defp`), comment included.
     - Branch checkout calls go to `Aiur.Workspace.Checkout` (T-048): `checkout_fresh_branch/1` and `checkout_existing_pr_branch/2` — qualify the calls, do not re-implement.
   - `src/lib/aiur/workspace/provisioner.ex` — module `Aiur.Workspace.Provisioner`. Move verbatim:
     - `@remote_workspace_marker "__AIUR_WORKSPACE__"` module attribute (line 9).
     - `ensure_workspace/3` — all three clauses (lines 45–69), public `def` with the file's existing comments.
     - `ensure_workspace/2` — local clause (lines 71–83) and remote SSH-script clause (lines 85–116), public `def`.
     - `create_workspace/1` (lines 118–122) — private.
     - `create_or_materialize/1` (lines 124–138) and `create_or_materialize/2` (lines 140–154) — private, comments included; they call `Materialize.materialize_from_base/2,3`.
     - `recreate_workspace/2` — both clauses (lines 576–596) — public, **renamed to `recreate/2`** (rename #1, per the name map).
     - `parse_remote_workspace_output/1` (lines 1133–1154) — public with `@doc false` (test seam for its malformed-output contract).
     - `maybe_install_agent_skills/2` — both clauses (lines 37–43) — public with `@doc false` (the facade calls it), comment included.
     - Remote plumbing calls go to `Aiur.Workspace.Remote` (T-048): `remote_shell_assign/2`, `run_remote_command/3`.
   - Facade edits in `src/lib/aiur/workspace.ex` this step: `create_for_issue/2` calls `Provisioner.ensure_workspace/3` inside its **unchanged** try/rescue; add `@doc false defdelegate materialize_from_base(base, workspace), to: Aiur.Workspace.Materialize` and `@doc false defdelegate materialize_from_base(base, workspace, pr_head_ref), to: Aiur.Workspace.Materialize` (the test seam — `src/test/aiur/workspace_materialize_test.exs` calls them on `Aiur.Workspace`); the refresh code still in the facade now calls `Provisioner.recreate/2`; the remote `ensure_workspace` path and `@remote_workspace_marker` leave the facade. Delete the moved definitions from the facade.
   - New tests: `src/test/aiur/workspace/provisioner_test.exs` (module `Aiur.Workspace.ProvisionerTest`) with at least these 4 tests, following the config-setup pattern of `src/test/aiur/workspace_and_config_test.exs` (`use Aiur.TestSupport`, `write_workflow_file!`) or plain tmp-dir setup where no config is needed:
     1. `parse_remote_workspace_output/1` with a valid `__AIUR_WORKSPACE__\t1\t/path` line surrounded by noise lines returns `{:ok, "/path", true}` (and `\t0\t` returns `created? == false`).
     2. `parse_remote_workspace_output/1` with malformed output returns `{:error, {:workspace_prepare_failed, :invalid_output, output}}` (unpinned gap named in giant-workspace.md §4).
     3. `ensure_workspace/2` (local, `worker_host = nil`) on an existing directory returns `{:ok, workspace, false}` and preserves a sentinel file inside it (reuse-without-deletion).
     4. `ensure_workspace/2` (local) on a path occupied by a stale plain FILE replaces it and returns `{:ok, workspace, true}` (cold path — prewarm disabled in test config).
   - New tests: `src/test/aiur/workspace/materialize_test.exs` (module `Aiur.Workspace.MaterializeTest`, `async: true`) with at least these 2 tests, reusing the tiny-git-base setup pattern from `src/test/aiur/workspace_materialize_test.exs`:
     1. `materialize_from_base/2` with a non-existent base path returns `{:error, _}` and the workspace path does NOT exist afterwards (partial copy is `rm_rf`'d).
     2. `materialize_from_base/2` into a workspace whose parent directory does not yet exist succeeds (`:ok`) — pins the `File.mkdir_p!(Path.dirname(workspace))` repo-namespaced-layout behavior.
   - Verify: from `src/`, `mix compile --warnings-as-errors && mix test` — all green, existing `workspace_and_config_test.exs` and `workspace_materialize_test.exs` untouched and passing. Commit.

3. **Step 2 (commit 2): create `Aiur.Workspace.Hooks` and `Aiur.Workspace.BootstrapImage`** (moved together so `handle_hook_command_result/4` never needs a temporary shim).
   - `src/lib/aiur/workspace/hooks.ex` — module `Aiur.Workspace.Hooks`. Move verbatim:
     - `run_hook/5` — local clause (lines 968–1012, including the full env-scrub comment block and the `aiur_perf workspace_hook` log line) and remote clause (lines 1014–1029) — public `def`.
     - `maybe_run_after_create_hook/4` (lines 879–900) — public, **renamed to `run_after_create/4`** (rename #2), keeping the `:materialized`-suppression comment and all three `case created?` branches.
     - `run_after_run_hook/3` body (lines 783–796) — public, **renamed to `run_after_run/3`** (rename #3); same parameters `(workspace, issue_or_identifier, worker_host)`, same default `worker_host \\ nil`, same `when is_binary(workspace)` guard; it builds the issue context itself via the `Context` call T-048 established.
     - `handle_hook_command_result/4` — both clauses (lines 1045–1065) — public `def` with `@doc false` (called by `BootstrapImage` and `Remove`).
     - `ignore_hook_failure/1` — both clauses (lines 965–966) — public `def` with `@doc false` (called by `Remove`).
     - `hook_env/0` (lines 1031–1043) — private, comment included.
     - `sanitize_hook_output_for_log/2` (lines 1067–1077) — private, keep the default arg `max_bytes \\ 2_048`.
   - `src/lib/aiur/workspace/bootstrap_image.ex` — module `Aiur.Workspace.BootstrapImage`. Move verbatim:
     - `@warm_cache_paths ["src/deps", "src/_build", "deps", "_build"]` attribute (line 10).
     - `maybe_seed_from_bootstrap_image/3` (lines 458–472) — public, **renamed to `maybe_seed/3`** (rename #4, per the name map).
     - `seed_from_bootstrap_image/5` — local clause (lines 474–498) and remote clause (lines 500–516, including the `{:workspace_hook_timeout, "remote_command", ^timeout_ms}` → `"bootstrap_image"` remap) — private.
     - `bootstrap_image_script/3` (lines 518–527) — public with `@doc false` (test seam).
     - `bootstrap_image_copy_script/0` (lines 529–557, including `exit 66`) — public with `@doc false` (test seam).
     - Result handling calls `Hooks.handle_hook_command_result/4`; remote execution calls `Remote.run_remote_command/3`; escaping calls `Remote.shell_escape/1`; shell assignment calls `Remote.remote_shell_assign/2`.
   - Facade edits this step: `create_for_issue/2` calls `Hooks.run_after_create/4` (inside the unchanged try); the public `run_after_run_hook/3` head stays on the facade (same `@spec`, default, guard) with its body reduced to `Hooks.run_after_run(workspace, issue_or_identifier, worker_host)`; the refresh code still in the facade calls `Hooks.run_hook/5` and `BootstrapImage.maybe_seed/3`; the before_remove code still in the facade calls `Hooks.run_hook/5`, `Hooks.handle_hook_command_result/4`, `Hooks.ignore_hook_failure/1`. Delete the moved definitions.
   - New tests: `src/test/aiur/workspace/hooks_test.exs` (module `Aiur.Workspace.HooksTest`, `use Aiur.TestSupport`) with at least these 4 tests:
     1. `run_after_create/4` with `created? == true` and an `after_create` command runs the hook (command writes a sentinel file into the workspace; assert it exists).
     2. `run_after_create/4` with `created? == :materialized` returns `:ok` and the hook does NOT run (sentinel absent) — pins FI-PW-028.
     3. `run_after_run/3` with a failing `after_run` command returns `:ok` (failure ignored — unpinned gap named in giant-workspace.md §4).
     4. Env scrub is applied: `System.put_env("RELEASE_NODE", "hooks-test")` in setup (with `on_exit` `System.delete_env`), then `run_hook/5` (local) with command `test -z "$RELEASE_NODE"` returns `:ok` — proves `scrub_shell_command/1` still wraps the command (unpinned gap; a silent drop reproduces the masked deps.get failure).
   - New tests: `src/test/aiur/workspace/bootstrap_image_test.exs` (module `Aiur.Workspace.BootstrapImageTest`, `use Aiur.TestSupport`) with at least these 3 tests:
     1. `maybe_seed/3` with no `workspace.bootstrap_image` configured returns `:ok` (no-op).
     2. `bootstrap_image_copy_script/0` contains `exit 66` and all four cache paths `src/deps`, `src/_build`, `deps`, `_build`.
     3. `bootstrap_image_script/3` includes a `docker pull` line when `pull? == true` and omits it when `pull? == false`; both variants include `docker run --rm --user`.
   - Verify: `mix compile --warnings-as-errors && mix test` green. Commit.

4. **Step 3 (commit 3): create `Aiur.Workspace.Refresh` and `Aiur.Workspace.Remove`; finalize the facade.**
   - `src/lib/aiur/workspace/refresh.ex` — module `Aiur.Workspace.Refresh`. Move verbatim:
     - `run_before_run_hook/3` body (lines 381–404) — public, **renamed to `run/3`** (rename #5); same parameters `(workspace, issue_or_identifier, worker_host)`, same default and `when is_binary(workspace)` guard.
     - `finalize_before_run_workspace/3` (lines 406–410) — private; calls `GitMetadata.ensure_git_metadata_writable/2` (T-048 name) and `BootstrapImage.maybe_seed/3`.
     - `run_before_run_command/4` — both clauses (lines 412–416) — private; calls `Hooks.run_hook/5`.
     - `maybe_recreate_stale_workspace/6` (lines 418–456, including BOTH long #577 and #653 comment blocks verbatim) — public with `@doc false` (test seam); calls `Provisioner.recreate/2`.
     - `stale_leftover_refresh_refusal?/1` — both clauses (lines 559–561) — private; the matcher stays exactly `{:workspace_hook_failed, "before_run", 65, _output}`.
     - Todo-dispatch classification and log formatting use the `Context` functions T-048 established (moved-from-here `todo_dispatch?/1`, `normalize_issue_state/1`, `issue_log_context/1`, `worker_host_for_log/1`).
   - `src/lib/aiur/workspace/remove.ex` — module `Aiur.Workspace.Remove`. Move verbatim:
     - `remove/1` (lines 302–303) and `remove/2` — local clause (lines 305–321) and remote clause (lines 323–343) — public `def` with the existing `@spec`s.
     - `remove_issue_workspaces/1` (lines 345–346) and `remove_issue_workspaces/2` — all three clauses: remote (lines 348–358), local-with-ssh-fan-out (lines 360–375), catchall no-op (lines 377–379) — public `def` with the existing `@spec`s.
     - `maybe_run_before_remove_hook/2` — local clause (lines 902–925) and remote clause (lines 927–963) — private; calls `Hooks.run_hook/5`, `Hooks.handle_hook_command_result/4`, `Hooks.ignore_hook_failure/1`, `Remote.run_remote_command/3`, `Remote.remote_shell_assign/2`.
     - Path validation and identifier sanitization use the `Layout` functions T-048 established (`validate_workspace_path/2`, `safe_identifier/1`, `workspace_path_for_issue/2`).
   - Finalize the facade `src/lib/aiur/workspace.ex` to **<= 130 lines**, containing ONLY:
     - `@moduledoc`, `require Logger`, aliases, `@type worker_host :: String.t() | nil`.
     - `create_for_issue/2` — the verbatim try/rescue envelope (lines 14–35) with its body calling `Layout`/`Context` (as T-048 left them), `Provisioner.ensure_workspace/3`, `Hooks.run_after_create/4`, `Provisioner.maybe_install_agent_skills/2`; existing `@spec` kept.
     - `run_before_run_hook/3` — public head (existing `@spec`, default `worker_host \\ nil`, `when is_binary(workspace)` guard), body: `Refresh.run(workspace, issue_or_identifier, worker_host)`.
     - `run_after_run_hook/3` — public head (existing `@spec`, default, guard), body: `Hooks.run_after_run(workspace, issue_or_identifier, worker_host)`.
     - `defdelegate remove(workspace), to: Aiur.Workspace.Remove` and `defdelegate remove(workspace, worker_host), to: Aiur.Workspace.Remove` with the existing `@spec`s.
     - `defdelegate remove_issue_workspaces(identifier), to: Aiur.Workspace.Remove` and `defdelegate remove_issue_workspaces(identifier, worker_host), to: Aiur.Workspace.Remove` with the existing `@spec`s.
     - `workspace_path_under/2` — unchanged from T-048 (existing `@doc` + `@spec`).
     - The `@doc false` test-seam delegations: `materialize_from_base/2,3` → `Materialize` (added in Step 1) and `ensure_git_metadata_writable/2` → `GitMetadata` (as T-048 left it).
     - Nothing else: no `@remote_workspace_marker`, no `@warm_cache_paths`, no `defp` bodies from the concerns extracted in this ticket.
   - New tests: `src/test/aiur/workspace/refresh_test.exs` (module `Aiur.Workspace.RefreshTest`, `use Aiur.TestSupport`) with at least these 3 tests:
     1. `maybe_recreate_stale_workspace/6` with `before_run == nil` and an arbitrary `{:error, reason}` returns that error unchanged (error passthrough — unpinned gap named in giant-workspace.md §4).
     2. `run/3` with no `before_run` configured returns `:ok` on a plain (non-git) tmp workspace.
     3. `run/3` with a `before_run` hook exiting 65 and a NON-todo issue context (state not `"todo"`, no `agent:todo` label) returns `:ok` and a pre-existing sentinel file in the workspace survives (the #653 WIP-preserving skip).
   - New tests: `src/test/aiur/workspace/remove_test.exs` (module `Aiur.Workspace.RemoveTest`, `use Aiur.TestSupport`) with at least these 3 tests:
     1. `remove/2` (local) on an existing directory (no `before_remove` hook configured) removes it and the path no longer exists.
     2. `remove_issue_workspaces/2` with a non-binary identifier (e.g. `nil` or `123`) returns `:ok` and touches nothing.
     3. `remove/2` (local) with a failing `before_remove` hook still removes the workspace (hook failures ignored).
   - Verify: full Agent gate (below) green. Commit.

5. **Dependency direction (enforce, do not deviate):** `Aiur.Workspace` (facade) → {`Refresh`, `Remove`, `Provisioner`, `Hooks`, plus the T-048 modules}. `Refresh` → {`Provisioner`, `GitMetadata`, `BootstrapImage`, `Hooks`, `Context`}. `Remove` → {`Hooks`, `Remote`, `Layout`, `Context`}. `Provisioner` → {`Materialize`, `Remote`, `Layout`} — `Provisioner` NEVER calls `Refresh`. `Materialize` → `Checkout`. `BootstrapImage` → {`Hooks`, `Remote`, `Context`}. `Hooks` → {`Remote`, `Context`}. No other intra-namespace edges; no module in this namespace calls the facade.

6. **Test authoring rules** (from `docs/refactor/regression-safety.md` §2): no `Process.sleep` synchronization; any `assert_receive` window >= 2000 ms; no exact-count assertions on shared singletons. All new tests exercise the new modules directly (they are NOT coverage-exempt) and must not require tmux, docker, ssh, or network.

## Files

- Create: src/lib/aiur/workspace/materialize.ex, src/lib/aiur/workspace/provisioner.ex, src/lib/aiur/workspace/hooks.ex, src/lib/aiur/workspace/bootstrap_image.ex, src/lib/aiur/workspace/refresh.ex, src/lib/aiur/workspace/remove.ex
- Modify: src/lib/aiur/workspace.ex
- Test: src/test/aiur/workspace/materialize_test.exs, src/test/aiur/workspace/provisioner_test.exs, src/test/aiur/workspace/hooks_test.exs, src/test/aiur/workspace/bootstrap_image_test.exs, src/test/aiur/workspace/refresh_test.exs, src/test/aiur/workspace/remove_test.exs

## Out of scope

- The T-048 modules — `src/lib/aiur/workspace/layout.ex`, `context.ex`, `remote.ex`, `checkout.ex`, `git_metadata.ex` — read-only; if a change there seems required, stop and comment on the issue.
- All external callers: `src/lib/aiur/agent_runner.ex`, `src/lib/aiur/orchestrator.ex`, `src/lib/aiur/alerts.ex`, `src/lib/aiur/opencode/session_writer.ex`, `src/lib/aiur/opencode/session_writer_registry.ex` — the facade API is unchanged, so they need no edits.
- `src/test/aiur/workspace_and_config_test.exs` and `src/test/aiur/workspace_materialize_test.exs` — must stay byte-identical and green; they are the behavior pins for this extraction.
- `src/test/aiur/regression/` — read-only, never edited.
- `src/mix.exs` — do NOT add the new modules to `ignore_modules` (the list only ever shrinks) and do not change the coverage threshold.
- `.aiur/hooks` (the checked-in exit-65 contract counterpart), `src/lib/aiur/agent_skills.ex`, `src/lib/aiur/repo_base.ex`, `src/lib/aiur/agent_environment.ex`, `src/lib/aiur/ssh.ex`, `src/lib/aiur/path_safety.ex`, `src/lib/aiur/config*` — all untouched.
- Any behavior change: no renamed error tuples, no reworded log lines, no altered shell scripts, no new features, no fixing of "weird" code you notice while moving it.

## Inventory-IDs

From `docs/refactor/feature-inventory/ws.md`: FI-WS-001, FI-WS-005, FI-WS-006, FI-WS-007, FI-WS-008, FI-WS-009, FI-WS-011, FI-WS-012, FI-WS-013, FI-WS-014, FI-WS-015, FI-WS-016.

From `docs/refactor/feature-inventory/pw.md`: FI-PW-025, FI-PW-026 (Materialize is the caller of the T-048-extracted Checkout live-tip path; the fallback-and-cleanup half lives in this ticket's files), FI-PW-027, FI-PW-028, FI-PW-031.

(FI-WS-002/003/004/010 and the checkout halves of FI-PW-026/027 belong to the T-048 modules and are out of scope here.)

## Characterization-tests

- The workspace lifecycle & git metadata characterization suite created by T-010 under `src/test/aiur/regression/` (Phase 1; exact filename per T-010's merged PR) — must pass unmodified.
- Behavior pins outside `regression/` that protect this exact extraction: `src/test/aiur/workspace_and_config_test.exs` (~40 workspace tests: after_create bootstrap + failure/timeout, exit-65 contract, #653 WIP-preserving skip, dirty-leftover recreate, bootstrap-image seed/keep, remove fan-out + tolerance, full remote lifecycle via fake `ssh` shim) and `src/test/aiur/workspace_materialize_test.exs` (CoW carry, `aiur/<id>` pinning, PR-anchored checkout + fallback, #567 live-tip). Both exercise only the `Aiur.Workspace` public API, so the facade keeps them green without edits.

## Acceptance criteria

All greps run from the repo root; all `mix` commands from `src/`.

- The six new lib files and six new test files listed in Files exist (`test -f` each).
- `wc -l < src/lib/aiur/workspace.ex` prints <= 130.
- Each new lib file: `wc -l` <= 200. Functions <= 20 logic lines (excluding comments, blank lines, `@spec`/`@doc`) applies to any NEWLY WRITTEN glue; verbatim-moved functions inherit their current size — do NOT rewrite a moved function (e.g. `run_hook/5`, `maybe_recreate_stale_workspace/6`) to satisfy this.
- Each new lib file: `grep -c "@moduledoc" <file>` prints 1, and every public `def` named in Scope has an `@spec` line.
- Facade is emptied of the moved concerns — each of these prints `0`:
  - `grep -c "defp ensure_workspace" src/lib/aiur/workspace.ex`
  - `grep -c "defp create_or_materialize" src/lib/aiur/workspace.ex`
  - `grep -c "defp run_hook" src/lib/aiur/workspace.ex`
  - `grep -c "defp seed_from_bootstrap_image" src/lib/aiur/workspace.ex`
  - `grep -c "defp maybe_recreate_stale_workspace" src/lib/aiur/workspace.ex`
  - `grep -c "defp maybe_run_before_remove_hook" src/lib/aiur/workspace.ex`
  - `grep -c "__AIUR_WORKSPACE__" src/lib/aiur/workspace.ex`
  - `grep -c "@warm_cache_paths" src/lib/aiur/workspace.ex`
- Facade API surface intact — each of these prints >= 1:
  - `grep -c "def create_for_issue" src/lib/aiur/workspace.ex`
  - `grep -c "rescue" src/lib/aiur/workspace.ex` (the envelope survived)
  - `grep -c "def run_before_run_hook" src/lib/aiur/workspace.ex`
  - `grep -c "def run_after_run_hook" src/lib/aiur/workspace.ex`
  - `grep -c "defdelegate remove" src/lib/aiur/workspace.ex`
  - `grep -c "defdelegate remove_issue_workspaces" src/lib/aiur/workspace.ex`
  - `grep -c "def workspace_path_under" src/lib/aiur/workspace.ex`
  - `grep -c "materialize_from_base" src/lib/aiur/workspace.ex`
  - `grep -c "ensure_git_metadata_writable" src/lib/aiur/workspace.ex`
- Semantics anchors moved byte-for-byte — each prints >= 1:
  - `grep -cF '{:workspace_hook_failed, "before_run", 65,' src/lib/aiur/workspace/refresh.ex`
  - `grep -cF 'exit 66' src/lib/aiur/workspace/bootstrap_image.ex`
  - `grep -cF 'scrub_shell_command' src/lib/aiur/workspace/hooks.ex`
  - `grep -cF 'THIS_REPOSITORY_URL' src/lib/aiur/workspace/hooks.ex`
  - `grep -cF ':brutal_kill' src/lib/aiur/workspace/hooks.ex` and `grep -cF ':brutal_kill' src/lib/aiur/workspace/bootstrap_image.ex`
  - `grep -cF ':materialized' src/lib/aiur/workspace/hooks.ex` and `grep -cF ':materialized' src/lib/aiur/workspace/provisioner.ex`
  - `grep -cF '__AIUR_WORKSPACE__' src/lib/aiur/workspace/provisioner.ex`
  - `grep -cF 'aiur_perf workspace_hook' src/lib/aiur/workspace/hooks.ex`
- New test files have at least the directed test counts: `grep -c 'test "' <file>` prints >= 2 (materialize), >= 4 (provisioner), >= 4 (hooks), >= 3 (bootstrap_image), >= 3 (refresh), >= 3 (remove). None contains `Process.sleep` (`grep -c "Process.sleep"` prints 0 for each).
- `git diff --name-only origin/v2...HEAD` lists exactly the 13 paths in Files — in particular NOT `src/mix.exs`, NOT `src/test/aiur/workspace_and_config_test.exs`, NOT `src/test/aiur/workspace_materialize_test.exs`, NOT any `src/test/aiur/regression/` file, NOT the five T-048 module files.
- `mix test test/aiur/workspace_and_config_test.exs test/aiur/workspace_materialize_test.exs test/aiur/workspace/` passes (0 failures).
- The full Agent gate below passes.

## Verification

### Agent gate (run all, from src/)
```
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
```

### At-merge (reviewer)

- Run every grep in Acceptance criteria verbatim; all must match.
- Confirm the PR diff touches exactly the 13 Files paths; `src/lib/aiur/workspace.ex` shows only deletions plus thin delegation bodies (no logic rewrites), and each new module's function bodies match the deleted facade bodies byte-for-byte modulo the module-qualification and rename edits named in Scope (spot-check `run_hook/5`, `maybe_recreate_stale_workspace/6`, the remote `ensure_workspace/2` script, and `bootstrap_image_copy_script/0`).
- From `src/`: `mix test test/aiur/ --seed 0` and `mix test test/aiur/ --seed 1` — both green.
- Check: FI-PW-028 — with a ready warm base and `hooks.after_create` set to `touch /tmp/hook-ran`, dispatch a ticket and confirm the sentinel does NOT appear for the materialized workspace.
- Check: FI-WS-009 — in the merged tree, `grep -rF '{:workspace_hook_failed, "before_run", 65,' src/lib/` hits exactly one file (`workspace/refresh.ex`); the checked-in `.aiur/hooks` exit-65 half is unchanged (`git diff origin/v2...HEAD -- .aiur/hooks` empty).
- Check: FI-WS-015 — `grep -rF '__AIUR_WORKSPACE__' src/lib/` hits exactly one file (`workspace/provisioner.ex`), and the fake-ssh remote lifecycle test in `workspace_and_config_test.exs` passed unmodified.
- Confirm `src/mix.exs` is untouched (new modules are coverage-counted) and coverage still meets the threshold in the CI run.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
