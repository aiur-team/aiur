# T-010: Characterization: workspace lifecycle & git metadata

**Phase:** 1
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:1` `complexity:3` `model:claude`

## Problem / context

`src/lib/aiur/workspace.ex` (1,235 lines) is regression hotspot #4 (~19 incidents, `docs/refactor/research-history-hotspots.md` row 4): `.git` writability regressed 4+ times (#493→#542→#561→#565→#616), and the stale-workspace refresh chain took 5 fixes (#569→#577→#595→#653→#661) — including the #653 regression where the dirty-refresh guard from PR #569 turned every PR merge into a retry-exhausting failure that killed every other in-flight agent's uncommitted WIP. Phases 3–4 will split this file into 12 modules (T-048/T-049, name map in `docs/refactor/research-arch/giant-workspace.md`), so its load-bearing semantics must first be pinned in the guarded regression suite (`src/test/aiur/regression/` — tests there may never be edited by executors, per the tripwire guard).

Existing coverage in `src/test/aiur/workspace_and_config_test.exs` and `src/test/aiur/workspace_materialize_test.exs` pins much of this, but those files are ordinary tests an executor could (wrongly) modify. This ticket copies the four highest-risk invariants into one guarded regression file: the before_run refresh/recreate decision table, the git-metadata writability invariant after materialize, the prewarm-materialize→cold-clone fallback, and the repo-namespaced root layout `<root>/<repo>/<issue>/`.

## Scope (exact)

Create exactly one new file: `src/test/aiur/regression/workspace_lifecycle_test.exs`, module `Aiur.Regression.WorkspaceLifecycleTest`. **This ticket changes no production code.** Do not modify `src/lib/aiur/workspace.ex`, `src/lib/aiur/repo_base.ex`, or any existing test.

Authoring constraints (all mandatory):

- `use Aiur.TestSupport` at the top (NOT `use ExUnit.Case, async: true` — every test below rewrites the global config via `write_workflow_file!/2`, which TestSupport isolates per-test; async would race it).
- No `Process.sleep` anywhere. All flows here are synchronous public-API calls (`Workspace.create_for_issue/1`, `Workspace.run_before_run_hook/2`, `Workspace.materialize_from_base/2,3`, `Workspace.ensure_git_metadata_writable/1`) — no waiting is needed. If you think you need to wait, you are testing the wrong seam; stop and comment on the issue.
- Never assert exact counts on shared singletons (e.g. never assert `Aiur.RepoBase`'s exact phase history). Trace-line counts on per-test tmp files (steps 1–6 below) are fine — those files are test-owned, not shared.
- Every test creates its fixtures under a unique tmp root: `Path.join(System.tmp_dir!(), "aiur-reg-wslc-<short-name>-#{System.unique_integer([:positive])}")`, wrapped in `try ... after File.rm_rf(test_root) end` (copy the shape of `src/test/aiur/workspace_and_config_test.exs:317-343`).
- Copy these two private helpers into the new file verbatim from `src/test/aiur/workspace_and_config_test.exs` (they are private there; do NOT make them public there, do NOT import): `bootstrap_dirty_refresh_workspace!/3` (lines 2635 onward — the source-repo + bare-remote + after_create-clone + exit-65 before_run fixture) and its `git!/1` and `shell_quote/1` helpers. Also copy the warm-base git-repo setup recipe from `src/test/aiur/workspace_materialize_test.exs:6-26` into a private `build_warm_base!/1` helper (git init -b main, user config, README v1, gitignored `_build/sentinel`, commit).
- Each `%Aiur.Issue{}` used below is available as `%Issue{}` via the TestSupport aliases.

Write these test cases, grouped in the five `describe` blocks named below, in this order:

### describe "before_run refresh/recreate decision table (#569→#577→#653→#661)"

All six use `bootstrap_dirty_refresh_workspace!(test_root, identifier)` (which creates the workspace via `Workspace.create_for_issue(identifier)` with an exit-65 dirty-guard before_run hook, then writes `README.md` = `"dirty\n"`), except step 1 which must restore `README.md` to `"initial\n"` (via `git!(["-C", workspace, "checkout", "--", "README.md"])`) before acting, and step 6 which overrides the hook.

1. `test "clean workspace: before_run refreshes and returns :ok without recreate"` — Input: fixture workspace with the dirty file reverted (clean tree). Action: `Workspace.run_before_run_hook(workspace, %Issue{id: "issue-clean-1", identifier: <fixture id>, title: "t", state: "in-progress", labels: ["agent:in-progress"]})`. Expected: returns `:ok`; `README.md` still `"initial\n"`; `git status --short` output trims to `""`; trace file has exactly 1 line (before_run ran once, no recreate).
2. `test "dirty leftover + todo state: recreated clean, before_run re-runs exactly once (#577)"` — Input: dirty fixture. Action: `run_before_run_hook` with `%Issue{state: "todo", labels: ["agent:todo"], ...}`. Expected: `:ok`; `README.md` == `"initial\n"` (recreated clean); `git status --short` clean; trace file exactly 2 lines.
3. `test "dirty leftover + agent:todo label on in-progress retry: still recreated (#577 retry path)"` — Same as 2 but `%Issue{state: "in-progress", labels: ["agent:todo"], ...}`. Expected: identical to 2 (pins that `todo_dispatch?` honors the label, not just the state — the retry path carries the label).
4. `test "dirty in-flight WIP: refresh skipped non-fatally, WIP preserved (#653)"` — Input: dirty fixture. Action: `run_before_run_hook` with `%Issue{state: "in-progress", labels: ["agent:in-progress"], ...}`. Expected: returns `:ok` (NOT `{:error, _}`); `README.md` still == `"dirty\n"`; trace file exactly 1 line (no recreate, no re-run). Add a comment block stating WHY: before #656, this exit-65 propagated as an error → 3 retries → retry_exhausted, so every PR merge (base-branch push fires before_run on live agents) killed every other in-flight agent's uncommitted WIP.
5. `test "refusal is recognized by exit 65, never by output wording"` — Input: `bootstrap_dirty_refresh_workspace!(test_root, id, refusal_output: "completely different refusal text")`, dirty. Action: `run_before_run_hook` with the todo-state issue from step 2. Expected: still recreated — `:ok`, `README.md` == `"initial\n"`, trace 2 lines.
6. `test "non-65 before_run failure is fatal and never recreates, even for a todo dispatch"` — Input: do NOT call the copied helper here; inline its setup steps (source repo, bare remote, `write_workflow_file!` with the same `hook_after_create:` clone script) but with `hook_before_run:` set to exactly `printf 'attempt\n' >> <shell_quote(trace_file)>\nexit 7`; then `create_for_issue`, then write `README.md` = `"dirty\n"`. Action: `run_before_run_hook` with the todo-state issue. Expected: `{:error, {:workspace_hook_failed, "before_run", 7, _output}}`; `README.md` still `"dirty\n"`; trace exactly 1 line.
7. `test "checked-in .aiur/hooks pins exit 65 as the refresh-refusal contract"` — Read `Path.expand("../../../../.aiur/hooks", __DIR__)` (repo root is 4 levels up from `src/test/aiur/regression/`). Expected: contents `=~ "exit 65"`.

### describe "create/reuse/recreate at ensure_workspace"

8. `test "existing workspace dir is reused as-is; local changes survive"` — Input: `write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root, hook_after_create: "echo first > README.md")`; `create_for_issue("REG-REUSE")`; then write `README.md` = `"changed\n"` and `local-progress.txt` into it. Action: `create_for_issue("REG-REUSE")` again. Expected: same path returned; `README.md` == `"changed\n"`; `local-progress.txt` intact (reuse never deletes — the resume contract).
9. `test "stale non-directory path is replaced with a fresh workspace dir"` — Input: default (linear/`project`) config with `workspace_root: root`; pre-create a regular FILE at `Path.join([root, "project", "REG-STALE"])` (mkdir_p the parent first). Action: `create_for_issue("REG-STALE")`. Expected: `{:ok, workspace}` where `workspace == PathSafety.canonicalize`d stale path and `File.dir?(workspace)`.

### describe "git metadata writability after materialize (#493→#542→#561→#565→#616)"

10. `test "materialized workspace repairs all four canonical stale locks"` — Input: `build_warm_base!` base; `Workspace.materialize_from_base(base, Path.join(tmp, "561"))`; then create stale lock files (content `"stale\n"`, mkdir_p parents) at exactly: `.git/index.lock`, `.git/FETCH_HEAD.lock`, `.git/ORIG_HEAD.lock`, `.git/refs/remotes/origin/aiur/561.lock`. Action: `Workspace.ensure_git_metadata_writable(workspace)`. Expected: `:ok` and all four lock files gone.
11. `test "pr- workspace additionally probes the checked-out head-ref lock"` — Input: `build_warm_base!` base; `Workspace.materialize_from_base(base, Path.join(tmp, "pr-88"), "feature/x")` (falls back to a local `feature/x` branch — no remote needed); plant stale lock at exactly `.git/refs/remotes/origin/feature/x.lock`. Action: `ensure_git_metadata_writable(workspace)`. Expected: `:ok` and that lock file gone.
12. `test "git metadata outside the workspace is rejected with the shaped error"` — Input: replicate `src/test/aiur/workspace_and_config_test.exs:279-315`: `File.mkdir_p!(workspace)` under a configured `workspace_root`, then `git init --quiet -b main --separate-git-dir <test_root>/external.git <workspace>`. Action: `Workspace.run_before_run_hook(workspace, "REG-BAD-1")` (no hooks configured). Expected: `{:error, {:workspace_git_metadata_unwritable, ^workspace, {:git_dir_outside_workspace, rejected}}}` where `rejected == PathSafety.canonicalize`d external git dir.
13. `test "non-git workspace passes the writability check (:not_git passthrough)"` — Input: a plain `File.mkdir_p!`'d dir, no git. Action: `ensure_git_metadata_writable(dir)`. Expected: `:ok`.

### describe "prewarm materialize fallback to cold clone"

14. `test "non-copyable base errors and removes the partial workspace"` — Action: `Workspace.materialize_from_base(Path.join(tmp, "missing-base"), Path.join(tmp, "ws"))`. Expected: `{:error, _}` and `refute File.exists?(Path.join(tmp, "ws"))` (the partial copy is rm_rf'd; this error is what `create_or_materialize` converts into the cold fallback).
15. `test "materialize branches off the live origin tip, not the stale base HEAD (#567)"` — Input: replicate `src/test/aiur/workspace_materialize_test.exs:139-176` exactly: bare origin (`git init --quiet --bare -b main`), a seed clone that commits README `"v1\n"` and pushes `main`, a warm base cloned from origin at v1 with gitignored `_build/sentinel`, then the seed advances origin to `"v2\n"` (the merge the stale base never fetched) and records `v2 = rev-parse HEAD`. Action: `Workspace.materialize_from_base(base, Path.join(tmp, "777"))`. Expected: `:ok`; workspace branch == `"aiur/777"`; workspace `rev-parse HEAD` == `v2`; `README.md` == `"v2\n"`; `_build/sentinel` carried.
16. `test "prewarm enabled but base not ready: create_for_issue cold-creates and runs after_create"` — Input: `write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: root, hook_after_create: "touch cold-marker")`; then append the prewarm block the generator cannot render: `path = Workflow.workflow_file_path(); File.write!(path, File.read!(path) <> "prewarm:\n  enabled: true\n  base_build: \"true\"\n"); if Process.whereis(Aiur.WorkflowStore), do: Aiur.WorkflowStore.force_reload()`. Precondition: `{phase, _} = Aiur.RepoBase.status(); refute phase == :ready` (memory tracker ⇒ RepoBase resolves to disabled ⇒ never ready). Action: `create_for_issue("REG-GATE-1")`. Expected: `{:ok, workspace}` and `File.exists?(Path.join(workspace, "cold-marker"))` — the after_create hook ran, proving the COLD path (`created? == true`); a warm materialize returns `:materialized`, which suppresses after_create (FI-PW-028), so this assertion fails if the gate ever stops falling back.

### describe "workspace root layout <root>/<repo>/<issue>"

17. `test "github repo namespaces the path as <root>/<owner>/<repo>/<issue>"` — Input: `write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "octo/widgets", workspace_root: root)`. Action: `create_for_issue("10")`. Expected: result equals `PathSafety.canonicalize`d `Path.join([root, "octo", "widgets", "10"])` and `Path.basename(ws) == "10"`.
18. `test "repo segment append is idempotent when the root already ends with it"` — Input: same github config but `workspace_root: Path.join([root, "octo", "widgets"])`. Action: `create_for_issue("10")`. Expected: equals canonicalized `Path.join([root, "octo", "widgets", "10"])` — never `.../octo/widgets/octo/widgets/10`.
19. `test "memory tracker falls back to the flat <root>/<issue> layout"` — Input: `tracker_kind: "memory"`. Action: `create_for_issue("MEM-1")`. Expected: equals canonicalized `Path.join(root, "MEM-1")`.
20. `test "workspace_path_under/2 derives the identical layout without touching disk"` — Input: the github `octo/widgets` config from 17 (no FS fixtures). Action/Expected: `Workspace.workspace_path_under("/x/root", "10") == "/x/root/octo/widgets/10"` and `Workspace.workspace_path_under("/x/root", "we ird/id") == "/x/root/octo/widgets/we_ird_id"` (identifier sanitization: non-`[a-zA-Z0-9._-]` → `_`).
21. `test "PR-anchored unit gets a pr-<pr#> leaf"` — Input: memory-tracker config; `pr_issue = %Issue{id: "pr-77", identifier: "77", title: "Human PR", description: "", state: "pr-watch", branch_name: "feature/login", pr_head_ref: "feature/login", labels: []}`. Action: `create_for_issue(pr_issue)`. Expected: `Path.basename(workspace) == "pr-77"`.

Rules that apply to this file even though its tests don't hit them (state them here so the executor doesn't "improve" toward them): no engine-path tests are written here, so no `AIUR_RELEASE_NODE` pinning is needed; nothing here touches `src/lib/aiur/events`, so no `:log_file` tmp-dir isolation beyond what `Aiur.TestSupport` already does (its setup re-points `:log_file` per test — do not add another layer); no `assert_receive` is needed (all calls are synchronous), but if you add one anyway its timeout must be >= 2000ms; there is no resource fan-out here, so no census-style count assertions are required.

Finally: run `mix test test/aiur/regression/workspace_lifecycle_test.exs` from `src/` and confirm every test passes against unmodified production code. A characterization test that fails against current `main` is wrong by definition — fix the test, never the production code.

## Files

- Create: `src/test/aiur/regression/workspace_lifecycle_test.exs`
- Modify: (none)
- Test: `src/test/aiur/regression/workspace_lifecycle_test.exs`

## Out of scope

- Any change to `src/lib/aiur/workspace.ex`, `src/lib/aiur/repo_base.ex`, or any other production module — this ticket is test-only.
- Editing or moving `src/test/aiur/workspace_and_config_test.exs` or `src/test/aiur/workspace_materialize_test.exs` (duplication with them is intended: the regression copy is the guarded one).
- Remote/SSH clauses (fake-`ssh` shim lifecycle, `parse_remote_workspace_output` malformed-output shape, remote exit-31 containment) — deferred to the T-048/T-049 wave per `giant-workspace.md` §"Characterization coverage missing".
- Bootstrap-image seeding (`FI-WS-011`), `after_run`/`before_remove` hooks, workspace removal fan-out, agent-skills install, hook env scrubbing.
- The workspace module split itself (T-048/T-049) and any `Aiur.Workspace.*` submodule creation.
- `.aiur/hooks`, `.aiur/config`, or anything under `.github/`.

## Inventory-IDs

FI-WS-001, FI-WS-002, FI-WS-003, FI-WS-004, FI-WS-005, FI-WS-006, FI-WS-007, FI-WS-008, FI-WS-009, FI-WS-010, FI-PW-025, FI-PW-026, FI-PW-027, FI-PW-028

## Characterization-tests

- Created by this ticket: `src/test/aiur/regression/workspace_lifecycle_test.exs` (the guarded pin for hotspot #4).
- Pre-existing (unguarded) coverage this file mirrors: `src/test/aiur/workspace_and_config_test.exs`, `src/test/aiur/workspace_materialize_test.exs`.

## Acceptance criteria

- `src/test/aiur/regression/workspace_lifecycle_test.exs` exists; `git diff --stat` shows it as the ONLY changed file.
- The file defines module `Aiur.Regression.WorkspaceLifecycleTest` (`grep -n "defmodule Aiur.Regression.WorkspaceLifecycleTest" src/test/aiur/regression/workspace_lifecycle_test.exs` hits) and `grep -n "use Aiur.TestSupport" src/test/aiur/regression/workspace_lifecycle_test.exs` hits.
- Exactly the 5 `describe` blocks named in Scope (`grep -c 'describe "' src/test/aiur/regression/workspace_lifecycle_test.exs` == 5) and at least the 21 named tests (`grep -c '    test "' ...` >= 21).
- These regression anchors appear verbatim in the file: `#653`, `#577`, `#567`, `exit 65`, `pr-77`, `git_dir_outside_workspace`, `cold-marker`.
- `grep -c "Process.sleep" src/test/aiur/regression/workspace_lifecycle_test.exs` == 0.
- `grep -n "async: true" src/test/aiur/regression/workspace_lifecycle_test.exs` has no hits (TestSupport tests are serial).
- File size: <= 800 lines (test fixtures are verbose; this is the ceiling, not a target). Any non-test private helper <= 60 lines.
- `cd src && mix test test/aiur/regression/workspace_lifecycle_test.exs` — all tests pass, 0 failures, 0 skipped, against unmodified production code.
- Full Agent gate below passes.

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

- **This PR touches the guarded regression path by design** — apply the regression-suite-change override label so the tripwire CI guard (T-005) passes; verify the diff adds ONE new file under `src/test/aiur/regression/` and edits none of the existing 19 regression tests.
- Check: `git diff --stat origin/v2...HEAD` lists exactly `src/test/aiur/regression/workspace_lifecycle_test.exs`.
- Check: `cd src && mix test test/aiur/regression/workspace_lifecycle_test.exs --seed 0` and once more with `--seed 1` (order-independence; TestSupport isolation working).
- Check: revert-probe one pinned behavior to prove the tests bite: in a scratch worktree, change `stale_leftover_refresh_refusal?` in `src/lib/aiur/workspace.ex:559` from exit `65` to `64` and confirm decision-table tests 2/3/5 FAIL; discard the worktree.
- Check: `grep -n "exit 65" .aiur/hooks` still hits (test 7's other half of the contract).

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
