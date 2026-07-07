# T-003: Fix SlotPolicyTest flake with deterministic sync

**Phase:** 1
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:1` `complexity:2` `model:claude`

## Problem / context

`src/test/aiur/opencode/slot_policy_test.exs` (issue #506) historically flaked under full-suite CI load because it synchronized with `Process.sleep(20)`/`Process.sleep(50)`. PR #528 (commit 48e79315, "Deflake slot policy tests") already removed every `Process.sleep` call and rewrote the tests around `start_supervised!`, a per-test isolated `Phoenix.PubSub`, a sentinel broadcast, `:sys.get_state/1`, and monitor-based `dead_pid/0`. Issue #506 is closed.

Two timing sites remain out of compliance with the flake authoring rules in `docs/refactor/regression-safety.md` §2 ("`assert_receive` windows ≥ 2000 ms — 500 ms flakes under `--cover` load"): both `assert_receive` calls in this file use a 500 ms window (lines 52 and 138). This is the Phase-1 prerequisite #4 from `docs/refactor/regression-safety.md` §3 — the deflake must be fully complete before decomposition tickets ship, because a lesser agent cannot distinguish a known flake from its own regression. No production code changes: `src/lib/aiur/opencode/slot_policy.ex` is untouched.

## Scope (exact)

Sleep-site enumeration (required by this ticket's brief): after reading the current file, there are ZERO `Process.sleep` sites left — all were removed by PR #528. The only remaining non-deterministic-under-load sync sites are the two sub-2000 ms `assert_receive` windows below. Fix exactly those two lines.

1. Open `src/test/aiur/opencode/slot_policy_test.exs`. Verify no `Process.sleep` exists anywhere in the file (`grep -c "Process.sleep" src/test/aiur/opencode/slot_policy_test.exs` must print `0`). If it prints anything else, stop and comment on the issue — the file has drifted from this ticket's analysis.
2. In the test `"subscribes to the Slot slots_topic and tolerates noise"` (describe block `"PubSub topic subscription"`), change line 52 exactly:
   - From: `assert_receive {:slot_policy_test_sync, _}, 500`
   - To: `assert_receive {:slot_policy_test_sync, _}, 2_000`
   Keep the immediately following `:sys.get_state(pid)` and `assert Process.alive?(pid)` lines unchanged — the sentinel-then-`get_state` pair is the deterministic sync and must stay.
3. In the private helper `dead_pid/0`, change line 138 exactly:
   - From: `assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500`
   - To: `assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000`
4. Change nothing else in the file: same 10 test cases, same `async: false`, same `setup` block, same `start_policy!/3` and `dead_pid/0` helpers, same assertions. Do not touch `src/lib/aiur/opencode/slot_policy.ex` or any other file.
5. Stability check (run from `src/`, after the Agent gate passes):
   ```
   for i in $(seq 1 20); do mix test test/aiur/opencode/slot_policy_test.exs --seed $RANDOM || exit 1; done
   ```
   All 20 runs must pass (each run: 10 tests, 0 failures). Paste the final run's summary line into the PR description.

## Files

- Create: none
- Modify: src/test/aiur/opencode/slot_policy_test.exs
- Test: src/test/aiur/opencode/slot_policy_test.exs

## Out of scope

- `src/lib/aiur/opencode/slot_policy.ex` — no production code changes of any kind.
- `src/lib/aiur/opencode/slot.ex`, `slot_supervisor.ex`, `attach_pool.ex` and their tests — slot lifecycle characterization is T-011.
- `src/test/aiur/regression/` — read-only; this ticket must not add or edit anything there.
- Any restructuring of the test (renaming tests, merging describe blocks, changing the PubSub isolation pattern) — the PR #528 structure is the accepted pattern; only the two timeout literals change.
- `src/test/test_helper.exs` / global test isolation — that is T-002.

## Inventory-IDs

No FI-OC entry in `docs/refactor/feature-inventory/oc.md` covers `slot_policy.ex` or this test file; the covering entries live in sibling section files:

- FI-EVT-110 (`docs/refactor/feature-inventory/evt.md`) — PubSub topic `opencode:slots`; names the #506 SlotPolicy flake explicitly and cites `src/lib/aiur/opencode/slot_policy.ex`.
- FI-CFG-010 (`docs/refactor/feature-inventory/cfg.md`) — `pre_warmed_sessions`; lists `src/test/aiur/opencode/slot_policy_test.exs` as covering test.
- FI-TUI-032 (`docs/refactor/feature-inventory/tui.md`) — lazy slot-expansion `SlotPolicy.bump()` call site.

## Characterization-tests

- `src/test/aiur/opencode/slot_policy_test.exs` — this ticket hardens it; it is the behavior pin for SlotPolicy's public API (`bump/1`, `grow_slot/1`, `highest_started/1`, `target_count/1`, `max_slots/1`) and its dead-pid tolerance.
- Broader opencode slot/attach/FD-budget characterization is created by T-011 (`src/test/aiur/regression/`), not this ticket.

## Acceptance criteria

- `grep -c "Process.sleep" src/test/aiur/opencode/slot_policy_test.exs` prints `0`.
- `grep -c "assert_receive" src/test/aiur/opencode/slot_policy_test.exs` prints `2`, and `grep -n "assert_receive" src/test/aiur/opencode/slot_policy_test.exs` shows both lines ending in `, 2_000`.
- `grep -cE "assert_receive.*, (500|1_?000|1_?500)\b" src/test/aiur/opencode/slot_policy_test.exs` prints `0`.
- `grep -c '    test "' src/test/aiur/opencode/slot_policy_test.exs` prints `10` (no tests added or removed).
- `git diff --name-only origin/v2...HEAD` lists exactly one file: `src/test/aiur/opencode/slot_policy_test.exs`.
- The 20-iteration seed loop in Scope step 5 passes with 0 failures on every run.
- No new files created (size norms N/A; had any file been created it would be <=200 lines with functions <=20 logic lines).

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

- Confirm the PR diff touches only `src/test/aiur/opencode/slot_policy_test.exs` and contains exactly two hunks (the two timeout literals).
- Confirm the diff does not touch `src/test/aiur/regression/` (no `regression-suite-change` override label needed).
- Run the acceptance-criteria greps above verbatim; all must match.
- Run from `src/`: `mix test test/aiur/opencode/ --seed 0` and `mix test test/aiur/opencode/ --seed 1` — both green.
- Check: FI-EVT-110 — after merge, `mix test test/aiur/opencode/slot_policy_test.exs` inside a full `mix test --cover` run stays green (the load condition that produced #506).
- Apply no new labels; close the issue via the PR's `Closes #<issue-number>` line.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
