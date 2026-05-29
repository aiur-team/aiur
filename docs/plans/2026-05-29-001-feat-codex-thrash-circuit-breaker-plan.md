# Codex thrash circuit breaker (#176 / #179)

**Date:** 2026-05-29
**Branch:** `kevin/e2e-pubsub-test`
**Status:** in progress

## Problem

When the codex API repeatedly fails fast (e.g. `usageLimitExceeded` returns
instantly with `willRetry: false`), a turn "completes" in ~1.5s having done no
useful work. `AgentRunner.run` returns `:ok`, the orchestrator's `:DOWN`
handler treats the `:normal` reason as a successful turn and schedules a
`:continuation` retry at +1s. Continuations bypass the `max_retry_attempts`
cap (`failure_retry?/1` returns false for `:delay_type == :continuation`), so
this is an **uncapped 1-second respawn loop**. Run #11 produced 97 such
sessions for one ticket.

### Root-cause locations (verified)

- `orchestrator.ex:283-293` — `:normal` `:DOWN` schedules `:continuation`, `attempt: 1`.
- `orchestrator.ex:2040-2046` — continuation delay is hardcoded `@continuation_retry_delay_ms = 1_000`.
- `orchestrator.ex:1847-1849` — `failure_retry?/1` returns false for continuations → cap at `orchestrator.ex:1807` is bypassed.
- `coding_agent.ex:617-652` — error-class notifications (`usageLimitExceeded`) hit the `:unhandled` path and return `{:continue, ...}`; the turn keeps going and completes normally.

## Fix — two independent layers (both wanted)

### Layer 1 — Respect `willRetry: false`

In `coding_agent.ex` `:unhandled` notification branch: when
`codex_error_method?(method)` AND `get_in(payload, ["params", "willRetry"]) == false`,
return `{:error, {:turn_unretryable, reason}}` instead of `{:continue, ...}`.

Propagation (verified end-to-end):
`run_turn` returns `{:error, ...}` (receive_loop ends at `coding_agent.ex:405-440`)
→ `do_run_codex_turns` returns `{:error, reason}` (`agent_runner.ex:438-442`)
→ `run/3` raises (`agent_runner.ex:46-48`)
→ Task `:DOWN` reason is **non-`:normal`**
→ orchestrator failure-retry path (`orchestrator.ex:295-306`) where
`failure_retry?/1` is true → `max_retry_attempts` cap (default 3) with
exponential backoff (10s/20s/40s) applies → gives up. No more 97× thrash.

**Files:** `coding_agent.ex` only. Test: `coding_agent_test.exs`.

### Layer 2 — Time-windowed restart budget (defense in depth)

Catches thrash that does NOT surface `willRetry` cleanly (transport timeouts,
sandbox refusals, future error classes that still return `:ok`/`:normal`).

- Add `codex_thrash_budget: %{}` to `State` (`orchestrator.ex:41-90`) —
  `%{issue_id => %{count: int, window_start_ms: int}}`.
- New config keys on `Agent` schema (`config/schema.ex:154-193`):
  `codex_thrash_max_per_window` (default 6), `codex_thrash_window_seconds`
  (default 60). Add `Config` accessors mirroring `max_retry_attempts/0`.
- Pure helper `check_thrash_budget(state, issue_id, now_ms) :: {:ok, state} | {:trip, state}`:
  increment count within the window; reset count when the window has elapsed;
  return `{:trip, state}` when `count > max`.
- Gate in `do_dispatch_issue/4` BEFORE `spawn_issue_on_worker_host/5` so a
  tripped attempt does not pay the workspace-clone cost. On `{:trip, _}`:
  `Logger.warning("Codex thrash detected: ...")` + `Alerts.emit_system` +
  return state without spawning (the loop stops; nothing reschedules).
- Reset the budget on resume/reactivate — mirror the `reset_last_codex_timestamp`
  refresh in `send_resume_control_message` (`orchestrator.ex:3194-3205`) and the
  reactivate path (`orchestrator.ex:3164`).
- `apply_thrash_check_for_test/3` shim next to `apply_stall_check_for_test/2`
  (`orchestrator.ex:836`) for unit testing without a live codex.

**Files:** `orchestrator.ex`, `config/schema.ex`, `config.ex`. Tests:
`orchestrator_test.exs` (or a focused thrash test), `config_test.exs` if schema
defaults are asserted there.

## Out of scope

- #152 (subscription-floor event replay) — separate plan.
- Changing the continuation mechanism itself — Layer 2 bounds it without
  redesigning the happy-path continuation loop.

## Verification

- `mix test` green (new Layer 1 + Layer 2 unit tests).
- `mix format --check-formatted`, `mix credo` clean.
- Manual: not runnable until codex quota resets (2026-05-30 14:07); Layer 2 is
  fully unit-testable via the `_for_test` shim with no live codex.
