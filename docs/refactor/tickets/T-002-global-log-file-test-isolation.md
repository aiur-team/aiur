# T-002: Global :log_file test isolation + purge src/log

**Phase:** 1
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:1` `complexity:2`

## Problem / context

Per-issue persistent state (`<repo>.<id>.subscriptions.json`, `<repo>.<id>.log`, `<repo>.event_id`) lives under `Aiur.Config.Paths.log_root_dir/0` (`src/lib/aiur/config/paths.ex:28-34`), which falls back to `<cwd>/log` — i.e. `src/log` during `mix test` — whenever the `:aiur` `:log_file` app env is unset. `src/test/test_helper.exs` isolates `HOME` (lines 17-23) but not `:log_file`. Isolation exists only per-test: `Aiur.TestSupport.__using__` sets `:log_file` per test (`src/test/support/test_support.exs:58,74,84-87`), and `src/test/aiur/events/subscription_store_test.exs:8-37` does the same manually (the #687 fix — one file only). Every test that uses neither pattern, plus the app's own boot, leaks files into `src/log` across runs; because per-test identifiers are built from `System.unique_integer/1`, which restarts per VM boot, a later run's identifier can collide with a leaked file from an earlier run and resurrect stale subscription state — the ghost auto-resume flake class (`docs/refactor/regression-safety.md` §3 item 3, feature-inventory FI-ART-016 "Known seed-dependent test flakes").

A `put_env` at the top of `test_helper.exs` is NOT sufficient, and this is the load-bearing fact of this ticket: `mix test` starts the `:aiur` application **before** requiring `test_helper.exs`, and `Aiur.Events.IdGenerator` (supervised child, `src/lib/aiur.ex:107`) writes `<log_root>/<repo>.event_id` during boot (`init/1` + `handle_continue(:load)` → `reserve_next_batch/1` → `persist/1`, `src/lib/aiur/events/id_generator.ex:80-97,169-190`), with its `state.path` frozen at init (`default_path/0`, lines 204-206). The only hook that runs before app boot is `src/config/config.exs`, whose `if config_env() == :test do` block (line 20) already exists for exactly this kind of pre-boot test wiring. Therefore the global `:log_file` value is set there (a deliberate, evidence-driven deviation from "in test_helper"; `test_helper.exs` verifies and cleans it up). Additionally, `src/test/aiur/config_paths_test.exs:7-17` currently **deletes** `:log_file` instead of restoring it (an `after` clause and a test with no restore at all), which would silently disable the global isolation for the rest of the suite — this ticket fixes that restore bug too.

## Scope (exact)

1. **Modify `src/config/config.exs`.** Inside the existing `if config_env() == :test do` block, insert the following immediately after line 28 (`config :aiur, :resolve_github_token_on_boot, false`), separated by one blank line:

   ```elixir
   # Suite-global :log_file isolation. The :aiur app boots BEFORE
   # test/test_helper.exs runs (mix test starts apps first), and
   # Aiur.Events.IdGenerator persists <log_root>/<repo>.event_id during
   # init — so this is the only hook early enough to keep boot-time and
   # non-TestSupport test writes out of the shared <cwd>/log. Per-test
   # overrides (Aiur.TestSupport, subscription_store_test) still win;
   # test_helper.exs verifies this value and removes the directory in
   # after_suite.
   test_log_root =
     Path.join(
       System.tmp_dir!(),
       "aiur-test-logs-#{System.os_time(:millisecond)}-#{System.pid()}"
     )

   config :aiur, :log_file, Path.join(test_log_root, "aiur.log")
   ```

   Do not create the directory here (`Aiur.JsonStore.write!/2` already does `File.mkdir_p!` at `src/lib/aiur/json_store.ex:32`; `test_helper.exs` adds a defensive `mkdir_p!` below). Do not change anything else in this file.

2. **Modify `src/test/test_helper.exs`** in three places, nothing else:

   a. Add `"AIUR_LOGS_ROOT"` to the `contaminating_env_vars` list (after `"XDG_RUNTIME_DIR"`, line 10). Rationale: a `mix test` run from inside an aiurdev shell exports it, and `Aiur.LogFile.ensure_session_log_file/0` (`src/lib/aiur/log_file.ex:47-71`) would otherwise pin test writes into a real session root. Tests that need it (`src/test/aiur/log_file_test.exs:107-113`) set and restore it themselves.

   b. Immediately after the `cond do ... end` that resolves `workflow_file` (i.e. after line 41, before the `real_proc_exclude` block), insert:

   ```elixir
   # The suite-global :log_file isolation root is set in config/config.exs
   # (test block) so it is in force before the app boots. Fail loudly if it
   # is ever missing — without it, boot-time and non-TestSupport writes leak
   # into the shared <cwd>/log and unique_integer id reuse across VM boots
   # resurrects stale subscription state (ghost auto-resume flakes).
   global_log_file = Application.get_env(:aiur, :log_file)

   unless is_binary(global_log_file) and
            String.starts_with?(global_log_file, System.tmp_dir!()) do
     raise "config/config.exs must isolate :log_file under the system tmp dir " <>
             "for the test env; got: #{inspect(global_log_file)}"
   end

   File.mkdir_p!(Path.dirname(global_log_file))
   ```

   c. Inside the existing `ExUnit.after_suite(fn _result -> ... end)` block, add as the last line before `end)` (after `File.rm_rf(test_home)`):

   ```elixir
   # Best-effort: IdGenerator's terminate/2 flush at VM shutdown may
   # recreate the counter file after this — a small leftover under the
   # system tmp dir is harmless and tolerated.
   File.rm_rf(Path.dirname(global_log_file))
   ```

3. **Modify `src/test/aiur/config_paths_test.exs`.** Replace the entire `describe "log_root_dir/0" do ... end` block (lines 6-18) with the following — this converts the delete-instead-of-restore teardown to the capture-and-restore pattern used in `src/test/aiur/log_file_test.exs:88-105`, so these tests no longer strip the suite-global value:

   ```elixir
   describe "log_root_dir/0" do
     setup do
       original = Application.get_env(:aiur, :log_file)

       on_exit(fn ->
         case original do
           nil -> Application.delete_env(:aiur, :log_file)
           value -> Application.put_env(:aiur, :log_file, value)
         end
       end)

       :ok
     end

     test "uses Application env when :log_file is set" do
       Application.put_env(:aiur, :log_file, "/tmp/aiur_paths_test/aiur.log")
       assert Paths.log_root_dir() == "/tmp/aiur_paths_test"
     end

     test "falls back to <cwd>/log when env unset" do
       Application.delete_env(:aiur, :log_file)
       assert Paths.log_root_dir() == Path.join(File.cwd!(), "log")
     end
   end
   ```

   Change nothing else in this file (the `sanitize/1` and `repo_name/0` describes stay as-is).

4. **Modify `src/lib/aiur/log_file.ex`** — documentation text only, no code. In the `ensure_session_log_file/0` `@doc` (lines 44-45), replace:

   ```
   Skipped in the test environment so unit tests keep the `<cwd>/log`
   fallback and never write into `~/.aiur/logs`.
   ```

   with:

   ```
   Skipped in the test environment so unit tests never write into
   `~/.aiur/logs` (the test suite pins `:log_file` to a per-run tmp dir in
   `config/config.exs` instead).
   ```

5. **Create `src/test/aiur/global_log_isolation_test.exs`** with exactly this content:

   ```elixir
   defmodule Aiur.GlobalLogIsolationTest do
     @moduledoc """
     Pins the suite-global `:log_file` isolation set in `config/config.exs`
     (test block). Without it, tests that never `use Aiur.TestSupport` — and
     the app's own boot (`Aiur.Events.IdGenerator` writes
     `<log_root>/<repo>.event_id` during init, before test_helper.exs runs) —
     persist into the shared `<cwd>/log`, where `System.unique_integer/1`
     identifier reuse across VM boots resurrects stale subscription state
     (the #687 ghost auto-resume flake class). Companion to the per-test
     guard in `Aiur.TestSupportIsolationTest`.
     """
     use ExUnit.Case, async: false

     alias Aiur.Config.Paths

     test "global :log_file default lives under the per-run tmp root, not <cwd>/log" do
       log_file = Application.get_env(:aiur, :log_file)

       assert is_binary(log_file)
       assert String.starts_with?(log_file, System.tmp_dir!())
       assert log_file |> Path.dirname() |> Path.basename() =~ "aiur-test-logs-"
       refute String.starts_with?(log_file, File.cwd!())
     end

     test "log_root_dir/0 resolves under the system tmp dir, never <cwd>/log" do
       log_root = Paths.log_root_dir()

       assert String.starts_with?(log_root, System.tmp_dir!())
       refute log_root == Path.join(File.cwd!(), "log")
     end

     test "boot-time IdGenerator counter write landed in the isolation root" do
       dir = Path.dirname(Application.get_env(:aiur, :log_file))

       assert {:ok, entries} = File.ls(dir)
       assert Enum.any?(entries, &String.ends_with?(&1, ".event_id"))
     end
   end
   ```

   Test cases, stated as input/action/expected:
   - Test 1 — input: none (suite-global state); action: read `Application.get_env(:aiur, :log_file)`; expected: a binary path under `System.tmp_dir!()` whose parent directory basename contains `aiur-test-logs-`, and not under `File.cwd!()`.
   - Test 2 — input: none; action: call `Paths.log_root_dir()`; expected: a path under `System.tmp_dir!()` that is not `<cwd>/log` (holds under both the global value and any per-test override, since both live in tmp).
   - Test 3 — input: the app booted normally under `mix test`; action: `File.ls` the global isolation directory; expected: it contains a file ending in `.event_id` (proves the boot-time `IdGenerator` write was redirected out of `src/log`).

   All three are `async: false`; no test in `src/test/` that mutates `:log_file` is `async: true` (verified), so no interleaving can flip these assertions.

6. **Purge `src/log` (verify-then-delete; no `.gitignore` change).** Already checked for you: `src/.gitignore` lines 19-21 already ignore `/log/` and `/logs/`, and `git ls-files -- log` from `src/` is empty — do NOT add `src/log/.gitignore` or edit `src/.gitignore`. In your workspace: run `git -C src ls-files -- log` and confirm empty output; then, if `src/log/` exists at all (a fresh clone will not have it), run `rm -rf src/log` — every file there is untracked test/run leakage.

7. **Verify no re-leak.** From `src/`: run `mix test`, then `test ! -e log && echo LOG_CLEAN`. It must print `LOG_CLEAN`. If `src/log` reappears, run `ls log` to capture the leaked filenames, and comment them on the issue (they identify a test writing with `:log_file` transiently unset) — do NOT edit any file not listed under Files to chase it; end your turn per the executor rules.

## Files

- Create: `src/test/aiur/global_log_isolation_test.exs`
- Modify: `src/config/config.exs`, `src/test/test_helper.exs`, `src/test/aiur/config_paths_test.exs`, `src/lib/aiur/log_file.ex` (doc text only)
- Test: `src/test/aiur/global_log_isolation_test.exs` (new), `src/test/aiur/config_paths_test.exs` (modified), plus these must stay green unmodified: `src/test/aiur/test_support_isolation_test.exs`, `src/test/aiur/events/subscription_store_test.exs`, `src/test/aiur/log_file_test.exs`, `src/test/aiur/events/id_generator_test.exs`

## Out of scope

- Any change to `src/lib/aiur/events/` (`id_generator.ex`, `subscription_store.ex`, etc.) — runtime behavior is untouched; only where tests point `:log_file`.
- Any code change to `src/lib/aiur/log_file.ex` or `src/lib/aiur/config/paths.ex` — the `<cwd>/log` fallback and the production `~/.aiur/logs` session-root minting (FI-ART-008) stay exactly as they are. The `log_file.ex` edit in Scope step 4 is doc text only.
- The per-test isolation in `Aiur.TestSupport` (`src/test/support/test_support.exs:36-112`) and in `subscription_store_test.exs:8-37` — do not modify either; they must keep overriding the global value per test (that is what `src/test/aiur/test_support_isolation_test.exs:19-25` pins).
- `src/.gitignore` — already covers `/log/`; do not edit.
- `src/test/aiur/regression/` — never edit (executor rules).
- Other flaky tests: SlotPolicyTest #506 is T-003; do not touch it here.
- `Aiur.Logs.Retention`, `scripts/aiurdev`, and anything under `~/.aiur/logs` (FI-ART-012, FI-ART-035).

## Inventory-IDs

- FI-ART-008 — unified session log root; `Paths.log_root_dir/0` as single source of truth; test env skips minting (`src/lib/aiur/log_file.ex:35-76`, `src/lib/aiur/config/paths.ex:28-35`)
- FI-ART-016 — per-issue `<repo>.<id>.subscriptions.json` persistence; the "known seed-dependent test flakes from subs files persisting across mix-test runs" this ticket eliminates
- FI-EVT-016 — subscription persistence to `<log_root>/<repo>.<id>.subscriptions.json`
- FI-EVT-026 — restart-safe monotonic event IDs persisted to `<log_root>/<repo>.event_id` (the boot-time writer that forces the config.exs placement)
- FI-EVT-027 — IdGenerator cold-boot fallback (scans `*.log` in `log_root_dir`; a shared dirty `src/log` polluted this scan)

## Characterization-tests

- Created by this ticket: `src/test/aiur/global_log_isolation_test.exs` (3 tests above).
- Existing protectors that must pass unmodified: `src/test/aiur/test_support_isolation_test.exs` (per-test override wins), `src/test/aiur/events/subscription_store_test.exs` (the never-prune per-test isolation pattern, `regression-safety.md` §5), `src/test/aiur/log_file_test.exs` (`ensure_session_log_file/0` test-env behavior), `src/test/aiur/events/id_generator_test.exs` (counter persistence semantics).

## Acceptance criteria

- `grep -c 'config :aiur, :log_file' src/config/config.exs` outputs `1`, and `grep -n 'aiur-test-logs-' src/config/config.exs` matches inside the `if config_env() == :test do` block.
- `grep -n '"AIUR_LOGS_ROOT"' src/test/test_helper.exs` matches inside `contaminating_env_vars`.
- `grep -n 'File.rm_rf(Path.dirname(global_log_file))' src/test/test_helper.exs` matches inside the `ExUnit.after_suite` block.
- `grep -c 'defmodule Aiur.GlobalLogIsolationTest' src/test/aiur/global_log_isolation_test.exs` outputs `1`; `cd src && mix test test/aiur/global_log_isolation_test.exs` reports 3 tests, 0 failures.
- `grep -c 'on_exit' src/test/aiur/config_paths_test.exs` outputs `1` (the restore block); the file contains no `after` clause (`grep -c '    after' src/test/aiur/config_paths_test.exs` outputs `0`).
- `cd src && rm -rf log && mix test && test ! -e log && echo LOG_CLEAN` prints `LOG_CLEAN` (full suite green AND `src/log` not recreated).
- `git -C src ls-files -- log` outputs nothing; `git diff --name-only <base>` lists exactly the five files under Files and nothing else (in particular not `src/.gitignore`, not anything under `src/test/aiur/regression/`).
- `grep -c 'Process.sleep' src/test/aiur/global_log_isolation_test.exs` outputs `0`.
- Size norms: `src/test/aiur/global_log_isolation_test.exs` is <= 200 lines; no function in any touched file exceeds 20 logic lines.
- `cd src && mix test test/aiur/config_paths_test.exs test/aiur/test_support_isolation_test.exs test/aiur/events/subscription_store_test.exs test/aiur/log_file_test.exs test/aiur/events/id_generator_test.exs` — all green.

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

- Cross-VM-boot probe (the flake shape this ticket kills): from `src/`, run `rm -rf log && mix test --seed 0 && mix test --seed 1 && test ! -e log && echo ISOLATED` — two full back-to-back suite runs in the same clone, both green, no `src/log` afterward. Before this ticket the second run could inherit the first run's subscription files.
- Check (FI-ART-016): `cd src && mix test test/aiur/events/subscription_store_test.exs && mix test test/aiur/events/subscription_store_test.exs` — green twice in a row.
- Check (FI-ART-008): `grep -n 'log_root' src/lib/aiur/log_file.ex src/lib/aiur/config/paths.ex` — confirm no code change landed in either resolution path (doc text only in `log_file.ex`).
- Confirm `ls /tmp | grep aiur-test-logs-` after the probe shows at most small leftover dirs (the documented IdGenerator terminate-flush recreation; tolerated).
- No label applications or TUI checks — this ticket has no runtime surface.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
