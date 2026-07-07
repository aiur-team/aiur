# T-009: Characterization: engine identity, reap & control RPC

**Phase:** 1
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:1` `complexity:3` `model:claude`

## Problem / context

Hotspot #3 in `docs/refactor/research-history-hotspots.md` (~21 incidents) is the shell engine `packaging/npm/aiur-cli/libexec/aiur-engine.sh` and its control plane into `src/lib/aiur/agent_control_cli.ex`: the instance-identity collision chain (#431→#443→#592), reaper friendly-fire on sibling and live instances (#495, #498), silent control-RPC failures, and startup failures that exited 0 (#534). Phases 2–4 will consolidate the engine↔BEAM mirrored reap stack and the marker protocol (`docs/refactor/research-arch/dup-infra.md` clusters 7 and 8), so the current behavior must be pinned in the guarded regression suite first — `src/test/aiur_engine_test.exs` covers much of this, but that file is editable; the regression copies under `src/test/aiur/regression/` are the immutable tripwire.

This ticket writes one new characterization-test file that pins five contracts exactly as they behave today: (a) control commands from another cwd must never cross-target a different instance (#592); (b) reap paths are node-name/pidfile-scoped and never kill siblings or the live run (#495/#498); (c) the `__AIUR_CONTROL_EXIT__:<code>` stdout marker is the only success/failure channel and its exit codes surface (FI-CLI-029); (d) a startup whose control plane never becomes ready exits non-zero (#534); (e) the `--bg` stale-session preflight is idempotent (live ⇒ no-op exit 0, stale ⇒ reap then relaunch).

## Scope (exact)

Create exactly one file: `src/test/aiur/regression/engine_control_test.exs`, module `Aiur.Regression.EngineControlTest`, `use ExUnit.Case, async: true`. Do not modify any other file. Duplication with assertions already in `src/test/aiur_engine_test.exs` is intentional — the regression copy is the frozen tripwire.

Authoring constraints (binding, from `docs/refactor/regression-safety.md`):

1. Never assert exact counts on shared singletons (assert on your own fixtures only).
2. Any `assert_receive` window must be >= 2000 ms (this file likely needs none).
3. Every test that sources or executes the engine pins a unique `AIUR_RELEASE_NODE` — copy the `run_sourced_engine/2` helper from `src/test/aiur_engine_test.exs:300-317` verbatim except: the injected fallback node is `"aiur-engctl-#{System.unique_integer([:positive])}@127.0.0.1"`. Direct `System.cmd(@engine, ...)` calls must pass `{"AIUR_RELEASE_NODE", nil}` plus a redirected `{"AIUR_BG_STATE_DIR", tmp}` so no test ever resolves the host's real identity or state dir.
4. Nothing here touches `src/lib/aiur/events`, so no `:log_file` isolation is needed (do not add it).
5. No `Process.sleep` synchronization. The single allowed occurrence is inside a copied `wait_dead/2` deadline-poll helper (from `src/test/aiur_engine_test.exs:286-296`) for OS-pid liveness, where no BEAM synchronization primitive exists.
6. No census-style resource fan-out assertions are needed in this file.
7. Snapshot support (`src/test/support/snapshot_support.exs`) is NOT used here — all assertions are on strings/exit codes.

Steps:

1. Create the file with these module attributes and private helpers, copied from `src/test/aiur_engine_test.exs` (they are private; regression files carry their own copies — precedent: `src/test/aiur/regression/instance_identity_test.exs`):
   - `@engine Path.expand("../../../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)`
   - `@pgrep_skip_reason Aiur.TestSupport.pgrep_skip_reason()`
   - `run_sourced_engine/2` (lines 300-317, with the `aiur-engctl-` fallback node per constraint 3)
   - `fake_release/0` (lines 87-100), `fake_tmux_script/1` (lines 319-327), `tmp_state/0` (line 271), `realpath/1` (lines 273-276), `spawn_sleeper/1` (lines 278-282), `os_pid_alive?/1` (line 284), `wait_dead/2` (lines 286-296), `kill_pid/1` (line 298).

2. `describe "control-command identity isolation (#592)"` — one test:
   - **"a control RPC from an unrelated cwd never adopts another instance's record"**: build under `System.tmp_dir!()` a base dir holding `home/`, `project/` (instance A's root) and `other/` (caller cwd, NOT under `project/`). Use `fake_release/0` and overwrite `bin/aiur` with a script that appends `"NODE:$RELEASE_NODE"` to an `$EVENTS` file and exits 42 (transport failure). Via `run_sourced_engine/2` with `HOME` pointed at `home/`: (i) set `AIUR_RELEASE_NODE=aiur-tester-live592@127.0.0.1`, `AIUR_INSTANCE_KEY=live592`, `AIUR_PROJECT_ROOT="$LAUNCH_ROOT"`, `AIUR_PROJECT_ROOT_SOURCE=cwd` and call `write_aiur_instance_record aiur-tester-live592-default aiur-tester-live592`; (ii) `cd "$OTHER"`, `unset AIUR_RELEASE_NODE AIUR_INSTANCE_KEY AIUR_PROJECT_ROOT AIUR_PROJECT_ROOT_SOURCE`, set `AIUR_REPO_ROOT=`, stub `probe_node_liveness() { case "$RELEASE_NODE" in "aiur-tester-live592@127.0.0.1") printf up ;; *) printf down ;; esac; }`; (iii) run `run_control_rpc "Aiur.AgentControlCLI.status()"` capturing `$?` into `CODE`. Assert: output contains `CODE=1`, `no running aiur node at aiur-`, and `run control commands from the launch directory` (the `print_global_config_control_hint` path, engine :1447-1457); the `$EVENTS` file does NOT contain `live592` (the RPC was aimed at the caller-cwd-derived node — `resolve_control_identity_from_records`, engine :1391-1445, must not adopt a record whose root does not contain the caller's cwd).

3. `describe "reap scoping — never siblings, never the live run (#495/#498)"` — three tests:
   - **"kill_beams_matching reaps only the named node, sparing a sibling node-name"** (tag `@tag skip: @pgrep_skip_reason`): follow the script-file pattern of `src/test/aiur_engine_test.exs:135-191` exactly (write the script to a tmp file so markers are not in the launching shell's argv; `on_exit` pkill both markers). Spawn TWO fake BEAMs via `bash -c 'exec -a "beam.smp -name <marker> extra" sleep 10'` with distinct unique markers `aiur-reapa-<unique>@127.0.0.1` and `aiur-reapb-<unique>@127.0.0.1`; wait for both to be pgrep-visible; call `kill_beams_matching '-name <marker_a>'` (engine :626-639); assert marker_a's process is gone (`REAPED`) and marker_b's process still answers `pgrep -f` (`SIBLING_ALIVE` echoed by the script when pgrep still matches marker_b).
   - **"reap_aiur_agents honors the pid-reuse comm guard and ignores pane lines"**: create two sleepers via `spawn_sleeper/1` in tmp dirs. Write a pidfile containing exactly three lines: `pid <p1> sleep` (comm matches — `agent_pid_matches`, engine :890-896, sees `sleep` in the command), `pid <p2> beam.smp` (comm mismatch — simulated pid reuse), and `pane %5`. Via `run_sourced_engine/2`, call `reap_aiur_agents "" "$PIDFILE"` (empty socket arg so no tmux server is touched; engine :909-941). Assert `wait_dead(p1)` is true and `os_pid_alive?(p2)` is true; `on_exit` kills both pids.
   - **"reap_aiur_agents is a no-op for a missing pidfile"**: via `run_sourced_engine/2`, run `reap_aiur_agents "" /nonexistent-pidfile-#{System.unique_integer([:positive])}; echo "CODE=$?"`; assert output contains `CODE=0`.

4. `describe "control RPC exit-marker protocol (FI-CLI-029)"` — five tests. For the first four, use `fake_release/0` and overwrite `bin/aiur` (the `rpc` transport, engine :1484-1526) with the described script; run via `run_sourced_engine/2` with `AIUR_RELEASE_DIR` set to the fake release, `AIUR_BG_STATE_DIR` set to `tmp_state()`, and the body `set +e; run_control_rpc "Aiur.AgentControlCLI.status()"; code=$?; set -e; echo "CODE=$code"`:
   - **"a zero marker yields exit 0 and :ok/blank noise lines are filtered"**: `bin/aiur` prints `:ok`, an empty line, `row1`, then `__AIUR_CONTROL_EXIT__:0`, exit 0. Assert `CODE=0`, output contains `row1`, and does not contain `:ok`.
   - **"a nonzero marker propagates as the exit code"**: `bin/aiur` prints `__AIUR_CONTROL_EXIT__:1`, exit 0. Assert `CODE=1` and output does NOT contain `returned no exit marker` and does NOT contain `no running aiur node` (marker-path failure, not transport failure — engine :1588-1604).
   - **"a missing marker is an error"**: `bin/aiur` prints `hello`, exit 0. Assert `CODE=1` and output contains `returned no exit marker`.
   - **"a hung rpc is killed and surfaces exit 124"**: `bin/aiur` is `#!/usr/bin/env bash\nsleep 5\n`; env adds `{"AIUR_CONTROL_RPC_TIMEOUT_SECONDS", "1"}`. Assert `CODE=124` and output contains `timed out after 1s` (engine :1459-1465, :1548-1552). Do NOT stub `sleep` in this test.
   - **"the marker and readiness literals are pinned across both languages"** (dup-infra cluster 8; precedent FI-ENG-064): read `src/lib/aiur/agent_control_cli.ex` and the engine with `File.read!/1`; assert the CLI contains `@exit_marker "__AIUR_CONTROL_EXIT__:"` (`src/lib/aiur/agent_control_cli.ex:8`), the engine contains `marker="__AIUR_CONTROL_EXIT__:"` (engine :1539), and the engine contains both `__AIUR_CONTROL_READY__` and `__AIUR_CONTROL_NOT_READY__` (engine :1192, `probe_control_liveness` :1190-1204).

5. `describe "startup failure exits non-zero (#534)"` — one test:
   - **"a background start whose control plane never becomes ready exits 1"**: `fake_tmux_script/1` with a state-file `has-session`/`new-session` case body (copy the shape from `src/test/aiur_engine_test.exs:641-649`); script stubs `sleep() { :; }`, `probe_control_liveness() { printf down; }`, `reap_aiur_agents() { echo "REAP:$*" >> "$EVENTS"; }`, `kill_beams_matching() { echo "KILL_BEAM:$*" >> "$EVENTS"; }`; env sets `AIUR_RELEASE_DIR` (fake release), `AIUR_BG_STATE_DIR` (tmp), `AIUR_NODE_GRACE_TICKS=2`, `PATH` prefixed with the fake tmux dir; body runs `set +e; ( run_session background ); code=$?; set -e; echo "CODE=$code"`. Assert `CODE=1`, output contains `aiur control plane did not become ready`, and the events file contains `KILL_BEAM:-name aiur-` (failed bg start reaps its own node — engine :552-561, `wait_for_session_startup` :1206-1240).

6. `describe "stale-session preflight (--bg idempotency)"` — two tests (engine :491-526):
   - **"a live session with a responsive control plane is a no-op exit 0"**: fake tmux whose `has-session` always exits 0 and which appends `NEW_SESSION` to `$EVENTS` on `new-session`; stub `probe_control_liveness() { printf up; }` and `sleep() { :; }`; run `run_session background; echo "CODE=$?"`. Assert `CODE=0`, output contains `already running in the background`, events file does NOT contain `NEW_SESSION`, and the instance record file exists (`test -f "$(aiur_instance_record_path)" && echo RECORD_OK` in the script; assert `RECORD_OK`).
   - **"a stale session (control plane down) is reaped before relaunch"**: fake tmux with a pre-created state file (`has-session` succeeds while it exists; `new-session` touches it and appends `NEW_SESSION` to `$EVENTS`); stub `probe_control_liveness` with a counter file so the FIRST call prints `down` and later calls print `up`; stub `reap_aiur_agents`/`kill_beams_matching` to append `REAP:`/`KILL_BEAM:` to `$EVENTS`; stub `start_beam_death_watchdog() { printf '424242\n'; }` and `disown() { :; }` and `sleep() { :; }`. Run `run_session background; echo "CODE=$?"`. Assert `CODE=0`, output contains `found stale tmux session`, and the events file contains `REAP:` before `NEW_SESSION` (assert with `assert [_, _] = String.split(events_log, "REAP:")` style ordering: `String.contains?` for both plus index comparison via `:binary.match/2`).

7. Run the Agent gate (below). Every test must pass twice in a row locally: `cd src && mix test test/aiur/regression/engine_control_test.exs && mix test test/aiur/regression/engine_control_test.exs`.

## Files

- Create: `src/test/aiur/regression/engine_control_test.exs`
- Modify: (none)
- Test: `src/test/aiur/regression/engine_control_test.exs` (this ticket IS the test)

## Out of scope

- Any edit to `packaging/npm/aiur-cli/libexec/aiur-engine.sh`, `src/lib/aiur/agent_control_cli.ex`, `scripts/aiurdev`, or any file under `src/lib/` — this ticket changes zero production behavior.
- Any edit to existing tests, including `src/test/aiur_engine_test.exs`, `src/test/scripts_aiurdev_test.exs`, and the existing 19 files under `src/test/aiur/regression/`.
- Consolidating the shell↔Elixir reap mirror or the marker literal (dup-infra clusters 7/8) — later-phase work; this ticket only pins today's behavior.
- `aiur stop` full-teardown coverage (already pinned by `src/test/aiur/regression/shutdown_cleanup_test.exs`) and identity-derivation coverage (already pinned by `src/test/aiur/regression/instance_identity_test.exs`) — do not duplicate those files' assertions.
- The workspace cwd-sweep shallow-root guard (covered at `src/test/aiur_engine_test.exs:193`).
- Anything under `website/`.

## Inventory-IDs

FI-CLI-017, FI-CLI-026, FI-CLI-029, FI-CLI-030, FI-ENG-003, FI-ENG-011, FI-ENG-019, FI-ENG-020, FI-ENG-021, FI-ENG-022, FI-ENG-025, FI-ENG-026, FI-ENG-027, FI-ENG-041

## Characterization-tests

- Created by this ticket: `src/test/aiur/regression/engine_control_test.exs` (12 tests across 5 describe blocks, as specified in Scope).
- Existing protection in this area (unchanged): `src/test/aiur/regression/instance_identity_test.exs`, `src/test/aiur/regression/shutdown_cleanup_test.exs`, `src/test/aiur_engine_test.exs`, `src/test/scripts_aiurdev_test.exs`, `packaging/npm/aiur-cli/test/launcher.test.mjs`.

## Acceptance criteria

- `src/test/aiur/regression/engine_control_test.exs` exists; `grep -c "defmodule Aiur.Regression.EngineControlTest" src/test/aiur/regression/engine_control_test.exs` = 1; `grep -c "async: true"` = 1.
- The file contains exactly 5 `describe` blocks and 12 `test` blocks (`grep -c '  describe "'` = 5; `grep -c '    test "'` = 12), covering: identity isolation (1), reap scoping (3), marker protocol (5), startup failure (1), stale-session preflight (2).
- `grep -c "Process.sleep" src/test/aiur/regression/engine_control_test.exs` = 1, and that occurrence is inside `defp wait_dead`.
- `grep -c "aiur-engctl-" src/test/aiur/regression/engine_control_test.exs` >= 1 (unique-node injection in `run_sourced_engine/2`); `grep -c "AIUR_BG_STATE_DIR"` >= 1 (no test writes to `~/.config/aiur`).
- `grep -c "__AIUR_CONTROL_EXIT__" src/test/aiur/regression/engine_control_test.exs` >= 2 (protocol tests + cross-language pin) and `grep -c "__AIUR_CONTROL_READY__"` >= 1.
- The file is <= 600 lines (test-harness file; the <=200-line norm applies to `src/lib/` files, none of which this ticket creates); no single test block exceeds 80 lines.
- `cd src && mix test test/aiur/regression/engine_control_test.exs` passes with 0 failures, twice consecutively.
- `git diff --stat` for the PR shows exactly one file changed (the new test file).

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

- **NOTE:** this PR touches the guarded regression path (`src/test/aiur/regression/`) by design — apply the `regression-suite-change` override label so the tripwire CI guard passes.
- Check: PR diff contains exactly one added file and zero modified/deleted files (`gh pr diff <n> --name-only` prints only `src/test/aiur/regression/engine_control_test.exs`).
- Check: from `src/`, run `mix test test/aiur/regression/engine_control_test.exs` twice back-to-back on the PR branch — 12 tests, 0 failures both runs (flake probe; the pgrep-gated sibling test may report 1 skipped on hosts without pgrep).
- Check: `grep -n "kill_beams_matching\|run_control_rpc\|reap_aiur_agents\|run_session\|write_aiur_instance_record" src/test/aiur/regression/engine_control_test.exs` shows the tests drive real engine functions (sourced), not reimplementations.
- Check: `git diff v2...HEAD -- packaging/ src/lib/` is empty (behavior-preserving).

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
