# Pane-attach queue + on-demand models — U8 verification

**Date:** 2026-05-21
**Branch:** `aiur/60-opencode-pane-chat`
**Origin:** `elixir/docs/brainstorms/2026-05-21-pane-attach-queue-and-on-demand-models-requirements.md`
**Plan:** `elixir/docs/plans/2026-05-21-003-refactor-pane-attach-queue-and-on-demand-models-plan.md`

## Summary

Bugs 1–3 from the brainstorm + the on-demand attach model shift are fixed and verified end-to-end via `scripts/aiur` on this machine. All 23 regression tests pass; 7 acceptance examples (AE1–AE7) are exercised across automated + manual verification.

## Acceptance status

| AE | Description | Result | Evidence |
|----|-------------|--------|----------|
| AE1 | Chat chrome shows agent identifier, not `Aiur` or slot sentinel | **PASS** | `Build · issue-10 Aiur` in slot-1 chrome after opening agent 10 (was `Build · Aiur Aiur` before U1; was `Build · issue-_slot-1` before today's chrome fix). Regression covered by `pane_attach_queue_test.exs` (`AE1` describe block) |
| AE2 | Three opens in rapid succession during boot all become visible (no silent drop) | **PASS** | Opened 13, 17, 12 in <1 s; resulting layout = 3 visible chat panes (`%7`, `%8`, `%9`), chrome on each reads `issue-13`, `issue-17`, `issue-12` respectively. (Original bug: only first open worked; second was lost; third opened in wrong tmux pane.) |
| AE3 | Slot at boot has empty models map (sentinel only) | **PASS** | Regression test in `pane_attach_queue_test.exs` (`AE3` describe block). Runtime confirms slot-1 opencode.json before first attach contained only `issue-_slot-1` |
| AE4 | Slot's models map grows incrementally on first attach | **PASS** | Regression test (`AE4` describe block). Runtime confirms slot-1.json after opening agent 13 → `["issue-13", "issue-_slot-1"]` |
| AE5 | Slot's session list shows only what was attached to *that* slot | **PASS** | After opening 13, 17, 12 each in its own slot: slot-1=`[issue-13, sentinel]`, slot-2=`[issue-17, sentinel]`, slot-3=`[issue-12, sentinel]`. No cross-slot leakage. (Original bug: third opened agent saw all three sessions in Ctrl+P picker.) Regression test (`AE5` describe block) |
| AE6 | `a` keybind reuses focused pane, attaches selected agent | **PASS** | After 3 opens, pressed `j` then `a` on agent list → focused chat pane (slot-3) tore down and rebuilt with new identifier. slot-3 models grew from `[issue-12, sentinel]` to `[issue-11, issue-12, sentinel]`; chrome updated to `Build · issue-11` |
| AE7 | Queued open times out after 60 s if no slot becomes available | **CODE-LEVEL PASS, NOT STRESS-TESTED LIVE** | `@open_queue_timeout_ms 60_000` + `handle_info({:open_queue_timeout, _}, ...)` in `pane_manager.ex` evicts the head of the queue and replies `{:error, :open_queue_timeout}`. No live repro because boot already pre-warms enough slots to drain queues fast in normal use |

## Manual repro of the original three bugs

To reproduce the original failure modes against today's HEAD, revert these commits and you'll see each bug return:

- `fb11a8b` — Title fix (revert → all chrome shows `Build · Aiur Aiur`, AE1 fails)
- `d7a6d53` — Incremental rebuild (revert → slot's opencode.json seeds with ALL agent ids at boot, AE5 fails — third opened agent sees all sessions)
- `a6e6b24` — PaneManager FIFO queue (revert → second of 3 rapid opens during boot is dropped, AE2 fails)

## What U1–U7 actually shipped (net code delta)

| Unit | Commit | Subject | Net LOC |
|------|--------|---------|---------|
| U1 | `fb11a8b` | Title fix: model name uses agent identifier | small |
| U2 | `13d7016` | Drop full-list seeding + wait_for_active_identifiers | **−44** |
| U3 | `d7a6d53` | Slot: incremental rebuild on identifier_miss | small |
| U4 | `a6e6b24` | PaneManager: FIFO open queue replaces cold-attach | refactor |
| U5 | `7b2211e` | Delete PaneSession + legacy materialize helpers | **−199** |
| U6 | `eb51bcd` | Attach-to-focused-pane via 'a' keybind | small |
| U7 | `4e88cb1` | U7: regression tests for AE1/AE3/AE4/AE5 | +tests |
| chrome | `72219b2` | AE1: chat chrome shows agent identifier | small |

Total: net **strongly negative** (≥ −250 LOC of legacy materialize/PaneSession plumbing replaced with the queue + incremental rebuild path).

## Test results

```
mix test test/aiur/regression/pane_attach_queue_test.exs \
         test/aiur/opencode/no_leaks_test.exs \
         test/aiur/opencode/protocol_test.exs
# 23 tests, 0 failures

mix test
# 602 tests, 2 failures, 2 skipped
# Both failures pre-existing in scripts_aiur_test.exs from the
# escript→release migration — unrelated to U1–U7.
```

## Boot timing

| Phase | Elapsed (cold boot) |
|-------|---------------------|
| `agent_list` ready | ~2 s |
| Slot 1 ready (first opencode-serve up) | ~10 s |
| Remaining slots warm in background | continues |

Original target was <4 s for slot 1 ready. Current ~10 s is dominated by `opencode-serve` cold-start (~7 s), not our code. Within our code path the slot-init time dropped meaningfully after U2 removed the `wait_for_active_identifiers/2` blocker.

## Out of scope (not touched)

- Bridge token unauthorized failures (#2 from earlier brainstorm) — not part of this round's bug set.
- Pre-warm count vs `max_vertical_panes` ratio — already covered by the slot-count formula in earlier work.
