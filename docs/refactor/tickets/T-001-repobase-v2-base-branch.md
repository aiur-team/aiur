# T-001: RepoBase base-branch support + CI push += v2

**Phase:** 1
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:1` `complexity:2`

## Problem / context

The refactor merges every ticket PR into a long-lived `v2` integration branch, and the refactor run itself sets `tracker.base_branch: "v2"` in its `.aiur/config`. Two things block that today. First, `src/lib/aiur/repo_base.ex` hardcodes `@default_branch "main"` (line 28) and uses it in five git call sites — clone (line 248), fetch (line 258), rev-parse (line 260), reset (line 270), and ls-remote (line 359) — so the warm base would keep cloning/resetting to `main` even when the run is based on `v2`. The `tracker.base_branch` config option already exists (`src/lib/aiur/config/schema.ex:89`) and is already consumed by `src/lib/aiur/orchestrator.ex:846` and `src/lib/aiur/events/universal_subscriptions.ex:32` with a fallback to `"main"`; RepoBase is the remaining gap (see `docs/refactor/research-v2-mechanics.md`, items 2–3).

Second, `.github/workflows/ci.yml` runs `on: push` only for `main` (lines 5–7), so the post-merge state of `v2` is never re-verified. Both changes are mechanical; behavior with default config (no `tracker.base_branch` set) is IDENTICAL to today.

## Scope (exact)

All Elixir work is in `src/lib/aiur/repo_base.ex` and `src/test/aiur/repo_base_test.exs`. Do not create any new files.

1. In `src/lib/aiur/repo_base.ex`, add a public `base_branch/0` helper in the "Public API" section, immediately after the `refresh_async/0` function (after line 57) and before the `## ---- Synchronous core ...` comment. Keep the existing `@default_branch "main"` module attribute (line 28) — it becomes the fallback. Insert exactly:

   ```elixir
   @doc """
   The branch the warm base tracks: `tracker.base_branch` from config, falling
   back to `"main"` when unset, empty, or the config cannot be loaded.
   """
   @spec base_branch() :: String.t()
   def base_branch do
     case Config.settings() do
       {:ok, %{tracker: %{base_branch: name}}} when is_binary(name) and name != "" -> name
       _ -> @default_branch
     end
   end
   ```

   Use `Config.settings()` (non-raising), NOT `Config.settings!()` — RepoBase's existing `resolve/0` (line 374) already uses the non-raising form and RepoBase must never crash on a config error. `Config` is already aliased at line 25; do not add imports or aliases.

2. Replace the five `@default_branch` git call sites with `base_branch()`:

   a. `ensure_clone/2` (line 248): change
      `git(["clone", "--branch", @default_branch, repo_url, base_path], nil)`
      to
      `git(["clone", "--branch", base_branch(), repo_url, base_path], nil)`

   b. `fetch_and_reset/1` (lines 255–265): bind the branch once and use it in both git calls. The whole function becomes exactly:

      ```elixir
      defp fetch_and_reset(base_path) do
        emit(:fetching)
        branch = base_branch()

        with {_fetch, 0} <- git(["fetch", "origin", branch, "--quiet"], base_path),
             {local, 0} <- git(["rev-parse", "HEAD"], base_path),
             {remote, 0} <- git(["rev-parse", "origin/#{branch}"], base_path) do
          reset_if_changed(base_path, String.trim(local) == String.trim(remote))
        else
          {out, status} -> {:error, {:repo_base_fetch_failed, status, out}}
        end
      end
      ```

   c. `reset_if_changed/2` false clause (line 270): change
      `git(["reset", "--hard", "origin/#{@default_branch}"], base_path)`
      to
      `git(["reset", "--hard", "origin/#{base_branch()}"], base_path)`

   d. `remote_head/1` (line 359): change
      `git(["ls-remote", repo_url, "refs/heads/#{@default_branch}"], nil)`
      to
      `git(["ls-remote", repo_url, "refs/heads/#{base_branch()}"], nil)`

   After this step the only remaining `@default_branch` occurrences are its definition (line 28) and the fallback inside `base_branch/0`.

3. Update the now-stale doc mentions of `main` in the same file. Each edit below is a verbatim OLD substring and its verbatim NEW replacement (the backticks inside the fences are part of the docstring text); change nothing else in each docstring:

   a. Moduledoc (line 3):
      ```
      OLD: base checkout of the target repo's `main` at
      NEW: base checkout of the target repo's base branch (`tracker.base_branch`, default `main`) at
      ```
   b. Moduledoc (line 11):
      ```
      OLD: `reset --hard origin/main` updates tracked
      NEW: `reset --hard origin/<base>` updates tracked
      ```
   c. Moduledoc (line 14):
      ```
      OLD: On every `main` advance the base is rebuilt
      NEW: On every base-branch advance the base is rebuilt
      ```
   d. `refresh_async/0` doc (line 51):
      ```
      OLD: toward latest `origin/main`.
      NEW: toward the latest remote base branch.
      ```
   e. `refresh_async/0` doc (line 53):
      ```
      OLD: rebuilds only when `main` advanced
      NEW: rebuilds only when the base branch advanced
      ```
   f. `refresh/3` doc (line 62):
      ```
      OLD: at latest `origin/main`, running
      NEW: at the latest remote base branch, running
      ```
   g. `refresh/3` doc (line 63):
      ```
      OLD: after every `main` advance.
      NEW: after every base-branch advance.
      ```

   Re-wrap the affected doc lines only as `mix format` requires. Do not rewrite any other prose.

4. In `.github/workflows/ci.yml`, add `v2` to the push trigger. Lines 3–7 become exactly:

   ```yaml
   on:
     pull_request:
     push:
       branches:
         - main
         - v2
   ```

   Change nothing else in the workflow (no job, step, or action-version edits).

5. In `src/test/aiur/repo_base_test.exs`, insert a new `describe "base_branch/0"` block between the existing `describe "base_path/1"` block (ends line 124) and the `describe "status/0"` block (starts line 126). Insert exactly:

   ```elixir
   describe "base_branch/0" do
     # Pins the workflow config per test (same pattern as the "server state
     # machine" setup below) so resolution never depends on ambient config.
     setup do
       tmp = Path.join(System.tmp_dir!(), "rb_bb_#{System.unique_integer([:positive])}")
       File.mkdir_p!(tmp)
       cfg = Path.join(tmp, "config")
       prev_path = Application.get_env(:aiur, :workflow_file_path)

       on_exit(fn ->
         case prev_path do
           nil -> Aiur.Workflow.clear_workflow_file_path()
           p -> Aiur.Workflow.set_workflow_file_path(p)
         end

         File.rm_rf!(tmp)
       end)

       {:ok, cfg: cfg}
     end

     test "defaults to main when tracker.base_branch is unset", %{cfg: cfg} do
       File.write!(cfg, "tracker:\n  kind: memory\n")
       Aiur.Workflow.set_workflow_file_path(cfg)

       assert RepoBase.base_branch() == "main"
     end

     test "returns the configured tracker.base_branch", %{cfg: cfg} do
       File.write!(cfg, "tracker:\n  kind: memory\n  base_branch: v2\n")
       Aiur.Workflow.set_workflow_file_path(cfg)

       assert RepoBase.base_branch() == "v2"
     end

     test "falls back to main when tracker.base_branch is empty", %{cfg: cfg} do
       File.write!(cfg, ~s(tracker:\n  kind: memory\n  base_branch: ""\n))
       Aiur.Workflow.set_workflow_file_path(cfg)

       assert RepoBase.base_branch() == "main"
     end
   end
   ```

   Test-by-test contract:
   - Test 1 — input: pinned config with no `base_branch` key; action: call `RepoBase.base_branch()`; expected: `"main"`.
   - Test 2 — input: pinned config with `base_branch: v2`; action: call `RepoBase.base_branch()`; expected: `"v2"`.
   - Test 3 — input: pinned config with `base_branch: ""`; action: call `RepoBase.base_branch()`; expected: `"main"` (empty string is treated as unset, matching the orchestrator/universal-subscriptions guard `is_binary(name) and name != ""`).

   The module is already `async: false`; `Aiur.Workflow.set_workflow_file_path/1` reloads the WorkflowStore cache, so no extra cache handling is needed. Do not modify any existing test in this file.

6. Run the Agent gate (below) from `src/`. All five commands must pass with zero changes beyond the three files listed.

## Files

- Create: none
- Modify: `src/lib/aiur/repo_base.ex`, `.github/workflows/ci.yml`
- Test: `src/test/aiur/repo_base_test.exs`

## Out of scope

- Do NOT set `tracker.base_branch: "v2"` in any config file (`.aiur/config`, `.aiurconfig`, examples, fixtures) — that is an operator setup step, not code.
- Do NOT touch `src/lib/aiur/orchestrator.ex` (`default_branch_name/0`) or `src/lib/aiur/events/universal_subscriptions.ex` (`base_branch_name/0`) — they already read `tracker.base_branch`. Do not consolidate the three helpers into one module.
- Do NOT touch `src/lib/aiur/config.ex`, `src/lib/aiur/config/schema.ex` (the `base_branch` field already exists), or `src/lib/aiur/workspace.ex`.
- Do NOT modify `src/test/test_helper.exs` or `src/test/fixtures/test.aiurconfig`.
- Do NOT change anything else in `.github/workflows/ci.yml` (jobs, steps, action SHAs, the `pull_request` trigger) or any other workflow file.
- Do NOT remove the `@default_branch` module attribute.

## Inventory-IDs

Primary (behavior sites this ticket edits):
- FI-PW-015 — `RepoBase.refresh/3` clone-fetch-build core; its entry explicitly notes the hardcoded default branch this ticket removes.
- FI-PW-018 — async build worker's `ls-remote` probe (`remote_head/1`) now probes the configured base branch.
- FI-CFG-018 — `tracker.base_branch` config option; RepoBase becomes a consumer alongside orchestrator/events.

Same-file, must-not-regress (protected by `src/test/aiur/repo_base_test.exs`):
- FI-PW-014 (base_path/slug), FI-PW-016 (base_build execution env), FI-PW-017 (git auth env-config extraheader), FI-PW-019 (resolve/0 gating), FI-PW-020 (poll timer), FI-PW-021 (phase events), FI-PW-022 (loud failure logging).

Adjacent, unchanged but base-branch-relevant:
- FI-WS-006 / FI-PW-025 — warm-base materialize branches off the live `origin/<base>` tip (workspace.ex; untouched here).
- FI-ENG-073 — Makefile/CI entry points; `.github/workflows/ci.yml` push trigger is the touched surface.

## Characterization-tests

- `src/test/aiur/repo_base_test.exs` — existing suite protects FI-PW-014..022 (refresh idempotency, rebuild-on-advance, build-failure marker skip, auth-env hygiene, phase events, server state machine). This ticket extends it with the `describe "base_branch/0"` block (3 tests) it creates.
- `src/test/aiur/orchestrator_prewarm_gate_test.exs` and `src/test/aiur/workspace_materialize_test.exs` protect the adjacent dispatch-gate and materialize behavior; they must pass unmodified.

## Acceptance criteria

- `grep -c '@default_branch' src/lib/aiur/repo_base.ex` prints `2` (the definition and the fallback in `base_branch/0`).
- `grep -n 'def base_branch' src/lib/aiur/repo_base.ex` shows exactly one public function, preceded by `@spec base_branch() :: String.t()`.
- `grep -c 'base_branch()' src/lib/aiur/repo_base.ex` prints `5` (the `@spec` line plus 4 call sites: ensure_clone, fetch_and_reset, reset_if_changed, remote_head).
- `grep -n 'origin/main' src/lib/aiur/repo_base.ex` prints nothing.
- `grep -A4 'push:' .github/workflows/ci.yml` shows `branches:` containing both `- main` and `- v2`; `git diff` on the workflow file is exactly one added line.
- `cd src && mix test test/aiur/repo_base_test.exs` passes with 3 new tests: "defaults to main when tracker.base_branch is unset", "returns the configured tracker.base_branch", "falls back to main when tracker.base_branch is empty".
- No new files created (size norms n/a); `base_branch/0` is <=20 logic lines; every modified function stays <=20 logic lines.
- `git diff --stat` touches exactly 3 files: `src/lib/aiur/repo_base.ex`, `.github/workflows/ci.yml`, `src/test/aiur/repo_base_test.exs`.
- With no `tracker.base_branch` in config, every git invocation RepoBase makes is byte-identical to before (default behavior unchanged).

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

- Confirm the PR diff touches only the 3 listed files and the ci.yml change is the single `- v2` line.
- Run the grep checks from Acceptance criteria against the merge commit.
- After merging to `v2`: `gh run list --branch v2 --workflow ci.yml --limit 3` shows a `push`-triggered run for the merge commit and it completes green — this proves the ci.yml change.
- Check: `cd src && mix test test/aiur/repo_base_test.exs` on `v2` passes, including the three `base_branch/0` tests.
- Check: `git -C src grep -n 'origin/main' -- lib/aiur/repo_base.ex` returns nothing.
- Confirm no test under `src/test/aiur/regression/` was modified (`git diff --name-only <merge-base>..HEAD | grep 'test/aiur/regression/'` is empty).

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
