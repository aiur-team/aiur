# T-048: workspace wave 1: Layout, Context, Remote, Checkout, GitMetadata

**Phase:** 4
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:4` `complexity:3`

## Problem / context

`src/lib/aiur/workspace.ex` is a 1,235-line module interleaving eleven concerns
(path layout, issue-context normalization, SSH plumbing, git checkout, `.git`
writability probes, provisioning, hooks, bootstrap-image seeding, refresh
policy, removal). It is regression hotspot #4 (~19 incidents), and its two most
regression-prone behaviors — the refresh/recreate decision table and the `.git`
writability invariant — are pinned by the T-010 characterization tests, which
this ticket must keep green unmodified.

This is wave 1 of 2 for this file, per the binding name map in
`docs/refactor/research-arch/giant-workspace.md` §2: extract the five
leaf/probe modules `Aiur.Workspace.Layout`, `Aiur.Workspace.Context`,
`Aiur.Workspace.Remote`, `Aiur.Workspace.Checkout`,
`Aiur.Workspace.GitMetadata`. `Aiur.Workspace` stays the public facade — every
existing caller (`src/lib/aiur/agent_runner.ex:81,105,118`,
`src/lib/aiur/orchestrator.ex:1756,4166`, `src/lib/aiur/alerts.ex:642`,
`src/lib/aiur/opencode/session_writer.ex:796`,
`src/lib/aiur/opencode/session_writer_registry.ex:211`, both workspace test
files) keeps working with zero edits. Wave 2 (T-049) extracts the rest.

## Scope (exact)

Move code **verbatim** (extract, do not rewrite). Public function signatures
and observable behavior are unchanged. Comments move with their functions,
verbatim — including the repo-namespacing rationale, the tilde-expansion case
comment, the FETCH_HEAD-vs-`--track` rationale, the #567 live-origin-tip
comment, and the `pr_anchored_ref_lock_paths` comment. Error-tuple shapes,
log-line text, and the remote shell scripts stay **byte-identical** — callers
and tests pattern-match them. Line ranges below refer to
`src/lib/aiur/workspace.ex` as of this ticket's writing; the function names are
authoritative if lines have drifted.

Drift guard: if, at execution time, `shell_escape/1` or `safe_identifier/1` no
longer exists in `workspace.ex` because a Phase-2 consolidation ticket
(T-018/T-019) replaced it with a shared-helper call, skip moving that function
and keep the shared-helper call sites as-is; everything else below is
unaffected.

Each new module: `@moduledoc` (text given below), `@spec` on every public
`def`, and — where its specs need it — its own local
`@type worker_host :: String.t() | nil` (do not reference the facade's type;
leaves must not point back at the facade). New modules are NOT added to
`ignore_modules` in `src/mix.exs` (that list only shrinks; do not touch
`mix.exs` at all).

1. Create `src/lib/aiur/workspace/remote.ex` — `Aiur.Workspace.Remote`.
   `@moduledoc "SSH execution plumbing shared by every remote workspace clause: hard-timeout command runner, tilde-expanding shell assignment, escaping."`
   Move from `workspace.ex`, all **public** with `@spec`:
   - `run_remote_command/3` (lines 1156–1171; keeps `alias Aiur.SSH`, the
     `Task.async` + `Task.yield(timeout_ms)` + `Task.shutdown(:brutal_kill)`
     envelope, and the `{:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}`
     shape — verbatim)
   - `remote_shell_assign/2` (lines 1121–1131)
   - `shell_escape/1` (lines 1173–1175)

2. Create `src/lib/aiur/workspace/context.ex` — `Aiur.Workspace.Context`.
   `@moduledoc "Pure policy normalizing an issue-or-identifier into the workspace issue-context map: pr- leaf naming, todo-dispatch classification, log formatting."`
   Move from `workspace.ex`:
   - `issue_context/1` (all 3 clauses, lines 1180–1214) — **renamed to
     `build/1`** (public); body unchanged including the `pr-` leaf comment
   - `issue_log_context/1` (lines 1232–1234) — **renamed to `log_context/1`**
     (public)
   - `worker_host_for_log/1` (lines 1177–1178) — public
   - `todo_dispatch?/1` (lines 563–566) — public
   - `pr_head_ref_from/1` (lines 1216–1225), `workspace_identifier/2` (lines
     1227–1230), `normalize_issue_state/1` (lines 568–574) — private (`defp`),
     names unchanged
   No renames beyond the two stated. This module has no aliases (pure).

3. Create `src/lib/aiur/workspace/layout.ex` — `Aiur.Workspace.Layout`.
   `@moduledoc "Pure path policy: where a workspace lives (repo-namespaced layout) and whether a path is legal under the configured root."`
   `alias Aiur.{Config, PathSafety}`. Move from `workspace.ex`:
   - `workspace_path_for_issue/2` (both clauses, lines 811–819) — public
   - `issue_workspace_path/2` (lines 821–841) — public, with its idempotent-append
     comment
   - `safe_identifier/1` (lines 875–877) — public
   - `validate_workspace_path/2` (local clause lines 1079–1105, remote clause
     lines 1107–1119) — public; all six error-tuple shapes
     (`:workspace_equals_root`, `:workspace_symlink_escape`,
     `:workspace_outside_root`, `:workspace_path_unreadable` ×2 remote,
     canonicalize remap) byte-identical
   - `pr_anchored_workspace?/1` (lines 754–756) — public (GitMetadata calls it)
   - `repo_segment/0` (lines 848–862), `safe_repo_segment/1` (lines 864–873) —
     private, with the forks-never-collide comment

4. Create `src/lib/aiur/workspace/checkout.ex` — `Aiur.Workspace.Checkout`.
   `@moduledoc "Git branch selection for a freshly materialized workspace: live-origin-tip aiur/<id> vs PR-anchored head ref, plus the shared branch query."`
   No aiur aliases (only `System.cmd`). Move from `workspace.ex`:
   - `checkout_fresh_branch/1` (lines 202–216) — public, with the #567 comment
   - `checkout_existing_pr_branch/2` (lines 218–232) — public, with its comment
   - `current_branch/1` (lines 283–288) — public (its ONE home; GitMetadata and
     `fresh_base_start_point/1` both call it here — no duplicate copy anywhere)
   - `fetch_pr_head_branch/2` (lines 234–243), `checkout_tracking_pr_branch/2`
     (lines 245–259, FETCH_HEAD comment verbatim), `checkout_local_pr_branch/2`
     (lines 261–270), `fresh_base_start_point/1` (lines 272–281),
     `branch_for/1` (line 300) — private

5. Create `src/lib/aiur/workspace/git_metadata.ex` —
   `Aiur.Workspace.GitMetadata`.
   `@moduledoc ".git writability probes and stale-lock repair, local and remote, including the git-dir-inside-workspace containment guard."`
   `require Logger` not needed; `alias Aiur.{Config, PathSafety}` and
   `alias Aiur.Workspace.{Checkout, Layout, Remote}`. Move from `workspace.ex`:
   - `ensure_git_metadata_writable/2` (default-arg header line 600, local
     clause lines 602–613, remote clause lines 615–660) — public, `@spec` as
     today. The remote SSH script (the list literal, lines 617–648) stays
     **byte-identical**, including exit 31 and the four `probe_lock` lines.
     Drop the `@doc false` on the GitMetadata copy (here it is an ordinary
     documented public function); `@doc false` stays on the facade seam
     defined in step 6.
   - Private, names unchanged: `local_git_metadata_probe_paths/1` (662–667),
     `probe_lock_files/1` (669–676), `local_git_metadata_dir/1` (678–692),
     `expand_git_dir/2` (694–699), `ensure_git_dir_inside_workspace/2`
     (701–714), `git_metadata_probe_paths/2` (716–727) — exact lock list
     `index.lock`, `FETCH_HEAD.lock`, `ORIG_HEAD.lock`,
     `refs/remotes/origin/aiur/<id>.lock` — `pr_anchored_ref_lock_paths/2`
     (729–747, comment verbatim), `ref_lock_segments/1` (749–752),
     `probe_lock_file/1` (758–768, rm → `O_EXCL`-create → rm sequence),
     `remove_stale_lock/1` (770–781)
   - Inside the moved code, update exactly three intra-file references:
     `remote_shell_assign(...)` → `Remote.remote_shell_assign(...)` and
     `run_remote_command(...)` → `Remote.run_remote_command(...)` (remote
     clause), `pr_anchored_workspace?(workspace)` →
     `Layout.pr_anchored_workspace?(workspace)` and
     `current_branch(workspace)` → `Checkout.current_branch(workspace)` (in
     `pr_anchored_ref_lock_paths/2`). All error-tuple shapes
     (`{:workspace_git_metadata_unwritable, ...}` 3-tuple local vs 4/5-tuple
     remote, `:not_git → :ok`, `{:git_dir_outside_workspace, _}`) unchanged.

6. Rewire the facade `src/lib/aiur/workspace.ex`:
   - Delete every function moved in steps 1–5 from `workspace.ex`. Nothing
     else is deleted; `@remote_workspace_marker`, `@warm_cache_paths`,
     `@type worker_host`, and all wave-2 functions (`ensure_workspace`,
     `create_workspace`, `create_or_materialize`, `materialize_from_base`,
     `copy_tree`, `remove*`, `run_before_run_hook` chain,
     `maybe_recreate_stale_workspace/6`, `stale_leftover_refresh_refusal?/1`,
     bootstrap-image functions, `run_hook/5`, `hook_env/0`,
     `handle_hook_command_result/4`, `sanitize_hook_output_for_log/2`,
     `ignore_hook_failure/1`, `maybe_run_after_create_hook/4`,
     `maybe_run_before_remove_hook/2`, `parse_remote_workspace_output/1`,
     `run_after_run_hook/3`, `workspace_path_under/2`,
     `maybe_install_agent_skills/2`) stay in place, bodies unchanged except
     the call-site substitutions below.
   - Update aliases: `alias Aiur.{Config, RepoBase}` and
     `alias Aiur.Workspace.{Checkout, Context, GitMetadata, Layout, Remote}`.
     Drop `PathSafety` and `SSH` from the facade alias list (both now unused
     there — `mix compile --warnings-as-errors` enforces this).
   - Substitute call sites in the remaining facade code (mechanical,
     one-for-one; argument lists unchanged):
     - `issue_context(` → `Context.build(` (3 sites: `create_for_issue/2`,
       `run_before_run_hook/3`, `run_after_run_hook/3`)
     - `issue_log_context(` → `Context.log_context(` (every remaining site:
       `create_for_issue` rescue log, `maybe_recreate_stale_workspace`,
       `seed_from_bootstrap_image` ×2, `run_hook` ×2 (multiple lines),
       `handle_hook_command_result` ×2)
     - `worker_host_for_log(` → `Context.worker_host_for_log(` (3 sites)
     - `todo_dispatch?(` → `Context.todo_dispatch?(` (1 site, in
       `maybe_recreate_stale_workspace/6`)
     - `safe_identifier(` → `Layout.safe_identifier(` (3 sites:
       `create_for_issue`, `remove_issue_workspaces` ×2)
     - `workspace_path_for_issue(` → `Layout.workspace_path_for_issue(` (3 sites)
     - `validate_workspace_path(` → `Layout.validate_workspace_path(` (2 sites:
       `create_for_issue`, `remove/2` local)
     - `issue_workspace_path(` → `Layout.issue_workspace_path(` (1 site, in
       `workspace_path_under/2`)
     - `remote_shell_assign(` → `Remote.remote_shell_assign(` (remaining
       facade sites: `ensure_workspace` remote, `remove/2` remote,
       `bootstrap_image_script`, `recreate_workspace` remote,
       `maybe_run_before_remove_hook` remote)
     - `run_remote_command(` → `Remote.run_remote_command(` (remaining facade
       sites: `ensure_workspace` remote, `remove/2` remote,
       `seed_from_bootstrap_image` remote, `recreate_workspace` remote,
       `maybe_run_before_remove_hook` remote, `run_hook` remote)
     - `shell_escape(` → `Remote.shell_escape(` (remaining facade sites:
       `bootstrap_image_script`, `bootstrap_image_copy_script`, `run_hook`
       remote)
     - `checkout_fresh_branch(` → `Checkout.checkout_fresh_branch(` (1 site,
       `materialize_from_base/2`)
     - `checkout_existing_pr_branch(` → `Checkout.checkout_existing_pr_branch(`
       (1 site, `materialize_from_base/3`)
     - In `finalize_before_run_workspace/3`: `ensure_git_metadata_writable(` →
       `GitMetadata.ensure_git_metadata_writable(`
   - Keep the public test seam on the facade
     (`src/test/aiur/workspace_materialize_test.exs:130` calls it on
     `Aiur.Workspace`): replace the moved definition with exactly

     ```elixir
     @doc false
     @spec ensure_git_metadata_writable(Path.t(), worker_host()) :: :ok | {:error, term()}
     def ensure_git_metadata_writable(workspace, worker_host \\ nil),
       do: GitMetadata.ensure_git_metadata_writable(workspace, worker_host)
     ```

     (a plain `def`, not `defdelegate` — `defdelegate` cannot carry the
     default argument.)
   - Do NOT change `create_for_issue/2`'s `try/rescue` envelope or move any
     work out of the `try` block.

7. Write one test file per extracted module (new modules are NOT
   coverage-exempt). Crib setup patterns from
   `src/test/aiur/workspace_and_config_test.exs` (`use Aiur.TestSupport`) and
   `src/test/aiur/workspace_materialize_test.exs` (temp git repos) — read
   those files, never edit them. Required cases, exactly these at minimum:
   - `src/test/aiur/workspace/remote_test.exs`: `shell_escape/1` wraps in
     single quotes and escapes an embedded `'`; `remote_shell_assign/2` output
     contains the escaped assignment plus both tilde case branches (`'~'` and
     `'~/'*`).
   - `src/test/aiur/workspace/context_test.exs` (`async: true`): `build/1`
     with an issue map carrying non-empty `pr_head_ref` → identifier prefixed
     `pr-` and `pr_head_ref` set; with empty/absent `pr_head_ref` → no prefix,
     `pr_head_ref: nil`; `build/1` with a binary → identifier map with nil
     id/state and `[]` labels; `build/1` with any other term → identifier
     `"issue"`; `todo_dispatch?/1` true for state `"todo"` (case- and
     whitespace-insensitive) and for label `"agent:todo"`, false otherwise
     (including nil state, `[]` labels); `log_context/1` renders
     `issue_id=n/a` fallback; `worker_host_for_log(nil) == "local"`.
   - `src/test/aiur/workspace/layout_test.exs`: `issue_workspace_path/2`
     nests the github `owner/repo` segment; idempotent append when the root
     already ends with the segment; flat `<root>/<issue>` for the memory
     tracker; `safe_identifier/1` maps disallowed chars to `_` and nil to
     `"issue"`; local `validate_workspace_path/2` returns
     `{:error, {:workspace_equals_root, _, _}}` and
     `{:error, {:workspace_outside_root, _, _}}`; remote
     `validate_workspace_path/2` rejects `""` (`:empty`) and a path containing
     `"\n"` or `<<0>>` (`:invalid_characters`) — this pins the previously
     untested remote-reject branch named in giant-workspace.md §4;
     `pr_anchored_workspace?/1` true only for a `pr-` leaf.
   - `src/test/aiur/workspace/checkout_test.exs`: `current_branch/1` returns
     the checked-out branch of a temp git repo and nil for a non-git dir;
     `checkout_fresh_branch/1` on a repo with no usable remote creates branch
     `aiur/<basename>` off the copied HEAD (the fallback leg);
     `checkout_existing_pr_branch/2` with no remote falls back to a local
     branch named exactly the given ref.
   - `src/test/aiur/workspace/git_metadata_test.exs`:
     `ensure_git_metadata_writable/2` on a temp git repo returns `:ok` and
     removes a pre-seeded stale `.git/index.lock`; returns `:ok` for a non-git
     dir; on a `pr-`-leaf workspace with a checked-out branch, removes a
     pre-seeded stale `refs/remotes/origin/<branch>.lock`; with a `.git` file
     whose gitdir points outside the workspace, returns
     `{:error, {:workspace_git_metadata_unwritable, _, {:git_dir_outside_workspace, _}}}`.
   Follow the authoring rules in `docs/refactor/regression-safety.md` §2 (no
   `Process.sleep`, `assert_receive` ≥ 2000 ms if used, tmp-dir isolation).

8. Run the full Agent gate (below). The repo compiles and the full suite —
   including `src/test/aiur/regression/`, `workspace_and_config_test.exs`, and
   `workspace_materialize_test.exs`, all unmodified — passes.

## Files

- Create: `src/lib/aiur/workspace/layout.ex`, `src/lib/aiur/workspace/context.ex`, `src/lib/aiur/workspace/remote.ex`, `src/lib/aiur/workspace/checkout.ex`, `src/lib/aiur/workspace/git_metadata.ex`
- Modify: `src/lib/aiur/workspace.ex`
- Test: `src/test/aiur/workspace/layout_test.exs`, `src/test/aiur/workspace/context_test.exs`, `src/test/aiur/workspace/remote_test.exs`, `src/test/aiur/workspace/checkout_test.exs`, `src/test/aiur/workspace/git_metadata_test.exs`

## Out of scope

- Wave 2 (T-049): extracting `Materialize`, `Provisioner`, `Hooks`,
  `BootstrapImage`, `Refresh`, `Remove`, and slimming the facade. Do not
  create those modules or move any of their functions.
- Any edit to callers: `src/lib/aiur/agent_runner.ex`,
  `src/lib/aiur/orchestrator.ex` (including its stale
  `Workspace.workspace_identifier/2` comment at ~line 1745 — leave it),
  `src/lib/aiur/alerts.ex`, `src/lib/aiur/opencode/session_writer.ex`,
  `src/lib/aiur/opencode/session_writer_registry.ex`.
- Any edit to `src/test/aiur/workspace_and_config_test.exs`,
  `src/test/aiur/workspace_materialize_test.exs`, or anything under
  `src/test/aiur/regression/` (read-only tripwire).
- `src/mix.exs` (coverage `ignore_modules` — `Aiur.Workspace` stays listed
  until the T-049 slim; new modules are simply not added).
- Any behavior change to the refresh/recreate decision table
  (`maybe_recreate_stale_workspace/6` — stays in the facade untouched this
  wave) or the `.git` writability invariant — both pinned by T-010.
- Rewriting shell scripts, log lines, error-tuple shapes, or renaming any
  function beyond the two renames stated (`build/1`, `log_context/1`).

## Inventory-IDs

From `docs/refactor/feature-inventory/ws.md`. Behavior physically moved by
this ticket: FI-WS-002, FI-WS-003, FI-WS-004, FI-WS-006 (checkout/branch
portion), FI-WS-007 (pr- leaf naming + PR-anchored checkout), FI-WS-009
(todo-dispatch classification only), FI-WS-010, FI-WS-015 (shell-plumbing
portion). Call-site-only edits inside the same file (behavior unchanged):
FI-WS-001, FI-WS-005, FI-WS-008, FI-WS-011, FI-WS-012, FI-WS-013, FI-WS-014,
FI-WS-016.

## Characterization-tests

The T-010 workspace lifecycle & git metadata characterization tests under
`src/test/aiur/regression/` (T-010 is a Phase-1 ticket; its exact filenames
are fixed at its merge — identify them at execution time with
`ls src/test/aiur/regression/ | grep -i -e workspace -e git`; they run inside
`mix test`). Additionally protective, though outside `regression/`:
`src/test/aiur/workspace_and_config_test.exs` and
`src/test/aiur/workspace_materialize_test.exs` pin the entire public API this
ticket must preserve — both must pass with zero modifications.

## Acceptance criteria

- All 5 new lib files and 5 new test files from **Files** exist; `git diff
  --name-only` against the merge base shows exactly the 11 files in **Files**
  and nothing else.
- `wc -l src/lib/aiur/workspace/*.ex` — every file ≤ 200 lines.
- Module names match the name map exactly: `grep -l "defmodule
  Aiur.Workspace.Layout\b" src/lib/aiur/workspace/layout.ex` (and likewise
  `Context`, `Remote`, `Checkout`, `GitMetadata` in their files) each hit.
- Facade no longer defines the moved functions:
  `grep -nE "defp? (issue_context|issue_log_context|worker_host_for_log|todo_dispatch\?|normalize_issue_state|pr_head_ref_from|workspace_identifier|safe_identifier|safe_repo_segment|repo_segment|issue_workspace_path|workspace_path_for_issue|validate_workspace_path|pr_anchored_workspace\?|remote_shell_assign|run_remote_command|shell_escape|checkout_fresh_branch|checkout_existing_pr_branch|fetch_pr_head_branch|checkout_tracking_pr_branch|checkout_local_pr_branch|fresh_base_start_point|current_branch|branch_for|local_git_metadata_probe_paths|probe_lock_files|local_git_metadata_dir|expand_git_dir|ensure_git_dir_inside_workspace|git_metadata_probe_paths|pr_anchored_ref_lock_paths|ref_lock_segments|probe_lock_file|remove_stale_lock)\(" src/lib/aiur/workspace.ex`
  returns nothing (the one-line `ensure_git_metadata_writable/2` delegation
  `def` is the only survivor of the moved set and is not in this list).
- Facade still exports the full public API:
  `grep -cE "def (create_for_issue|run_before_run_hook|run_after_run_hook|remove|remove_issue_workspaces|workspace_path_under|materialize_from_base|ensure_git_metadata_writable)\(" src/lib/aiur/workspace.ex`
  ≥ 8.
- Every new module: `grep -c "@moduledoc" <file>` = 1, and each public `def`
  has a `@spec` (reviewer eyeball + `mix dialyzer` clean).
- Functions ≤ 20 logic lines each in new files; multi-line shell-script /
  path-list literals count as data, not logic — the remote git-metadata SSH
  script and `remote_shell_assign/2` case script are moved byte-identical, not
  restructured (`git diff` on those string lists shows pure relocation).
- New test files each contain the minimum cases enumerated in Scope step 7
  (reviewer checks test names), and `mix test test/aiur/workspace/` passes.
- `git diff` shows no hunks in `src/test/aiur/regression/`,
  `src/test/aiur/workspace_and_config_test.exs`,
  `src/test/aiur/workspace_materialize_test.exs`, or `src/mix.exs`.
- Full Agent gate passes.

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
- Check: `cd src && mix test test/aiur/workspace_and_config_test.exs test/aiur/workspace_materialize_test.exs` green, and `git diff origin/v2...HEAD --name-only | grep -E "test/aiur/(regression/|workspace_and_config_test|workspace_materialize_test)"` prints nothing.
- Check: `git diff origin/v2...HEAD --name-only` equals exactly the 11 files listed under **Files**.
- Check: `wc -l src/lib/aiur/workspace/*.ex` — all ≤ 200; `wc -l src/lib/aiur/workspace.ex` shrank by roughly 450–550 lines (to ~700–790).
- Check: the remote git-metadata SSH script lines (exit 31 guard, four `probe_lock` calls) appear byte-identical in `git_metadata.ex` — compare against the pre-move `workspace.ex` with `git show origin/v2:src/lib/aiur/workspace.ex | grep -n "exit 31"` vs `grep -n "exit 31" src/lib/aiur/workspace/git_metadata.ex`.
- Check: `grep -rn "Aiur.Workspace.Layout\|Aiur.Workspace.Context\|Aiur.Workspace.Remote\|Aiur.Workspace.Checkout\|Aiur.Workspace.GitMetadata" src/lib/ --include="*.ex" | grep -v "lib/aiur/workspace"` prints nothing (no caller outside the workspace namespace reaches past the facade).
- Behavior spot-check: during the phase-4 fleet run on `v2`, confirm a dispatched agent's workspace lands at the repo-namespaced path `<root>/<owner>/<repo>/<issue>` and its `logs/agent.md` alert artifacts appear inside it (FI-WS-002/FI-WS-003 drift check per #708).

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
