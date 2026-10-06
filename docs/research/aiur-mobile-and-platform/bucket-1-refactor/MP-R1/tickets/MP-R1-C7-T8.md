---
ticket_id: MP-R1-C7-T8
feature_id: MP-R1
chunk_id: MP-R1-C7
bucket: 1-refactor
title: Extract Dispatcher's CI-readiness gate and remove its remaining direct GitHub calls
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C7-T7, MP-R1-C7-T6, U2-lifecycle-owner, U5-typed-outcomes, MP-E1-C1]
prior_units: [U2, U5, U8]
prior_boundaries: [DSP, PRL, GHD, GHB]
prior_features: []
prior_findings: [codebase-04, codebase-09]
size_owner: LIFECYCLE_DISPATCH (orchestrator/dispatcher.ex 2,673 at base; dispatcher_test.exs 3,197); GH_ACCESS (github/ci_readiness.ex 1,149 — gains only @behaviour/@impl lines). Pinned to U8 ledger 465aca643; re-resolve at ticket start (RC-23, MP-R1-C11-T2)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C7-T8 — CI-readiness gate out of Dispatcher; last direct GitHub calls

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R1 / C7 (second half of plan C7-T6).
- **User value:** none visible. After this ticket `orchestrator/dispatcher.ex` names no
  `Aiur.GitHub.*` module; the advisory CI-readiness check becomes an orchestration
  module that asks the code host for a readiness provider; `dispatcher.ex` shrinks by
  about 200 lines (helps U8 `LIFECYCLE_DISPATCH`).
- **Deliverable:**
  1. `Aiur.Orchestrator.CiReadinessGate` (PROPOSED,
     `src/lib/aiur/orchestrator/ci_readiness_gate.ex`) holding the moved functions
     `maybe_warn_ci_readiness/1`, `start_initial_ci_readiness_check/4`,
     `check_initial_ci_readiness/5`, `handle_ci_readiness_result/3`,
     `handle_ci_readiness_timeout/2` and their private helpers, verbatim apart from
     provider lookups. Dispatcher keeps one-line delegates with the same names and
     arities (they are called by `orchestrator.ex:65-72` and many tests).
  2. Behaviour `Aiur.CodeHost.CiReadiness` (PROPOSED) implemented by
     `Aiur.GitHub.CiReadiness`; facade `Aiur.CodeHost.ci_readiness/0 :: module() | nil`.
  3. `CycleFetchCache` start/end wrapped by `Aiur.Tracker.with_poll_cycle/1`
     (optional `IssueTracker` callback; GitHub implements it).
  4. Auth-preflight error formatting via optional `IssueTracker` callback
     `format_preflight_error/1`.
- **Non-goals:** changing readiness semantics (it stays advisory, never holds tickets —
  comment `dispatcher.ex:248-251`); moving `ci_readiness_*` fields out of
  `Orchestrator.State` (MP-R1-C9-T7 assigns field owners); the `{:github, :rate_limited,
  detail}` error-shape match in `ci_readiness_retry_delay_ms/1` (`:431-437`) — it names
  no module, it is a data shape the code host returns; it moves verbatim and is listed
  for MP-R1-C9-T7 to type (open item G-2); replacing `Alerts.emit_system/2` defaults (C5-T3 / plan-refresh
  row PR-07 decides).

## Dependencies and blockers

- **Owner gate:** DESIGN-R1 §1.
- **Predecessors:** C7-T7 (same file, lands first); C7-T6 (`CiReadiness`,
  `CycleFetchCache`, `AuthPreflight`, `Errors` declared as GitHub facades or internals).
- **U2:** same single-writer rule as C7-T7 (`U2-lifecycle-owner`).
- **U8:** moving ~200 lines out of `dispatcher.ex` is a semantic split inside the
  `LIFECYCLE_DISPATCH` package. The U8 package worker must accept it as that
  responsibility's split (not a parallel writer). Coordinate through the U8 ledger
  before starting.
- **U5:** `github/ci_readiness.ex` is `GH_ACCESS`; only `@behaviour`/`@impl` lines are
  added; wait for U5's exit so the readiness result shape is final.
- **MP-E1-C1 (RC-19):** no E1-C1 file is edited; rebase over it; E1's
  `DispatchPolicy` hooks and `ClaimProbe` stay untouched.
- **Concurrent with:** C7-T3/T4/T5. Not with C7-T7.

## Verified starting point (base `45a290e3`)

- Aliases `dispatcher.ex:23` (`AuthPreflight, CiReadiness, CycleFetchCache, Errors,
  LocalHold`; `LocalHold` and the `GitHubTracker` alias go in C7-T7).
- `CycleFetchCache.start_cycle/0` / `end_cycle/0` wrap every dispatch pass
  (`:90-99`, `maybe_dispatch/1`). The cache is process-dictionary ETS
  (`github/cycle_fetch_cache.ex:7-30`), created for every tracker kind today.
- CI-readiness block: `:248-460` — `maybe_warn_ci_readiness/1` (`:253-256`), retry
  timing, scope reset on config change (`:281-…`), `reconcile_completed_ci_readiness/1`
  (`:304-317`), `start_initial_ci_readiness_check/4` with the `"github"` clause
  (`:323-339`) and the non-GitHub clause marking checked (`:341`),
  `handle_ci_readiness_result/3` (`:344-351`), timeout (`:354-363`),
  `check_initial_ci_readiness/5` (`:368-375`), `record_ci_readiness_result/3`
  (`:377-411`), cached acceptance (`:413-425`), `retryable_ci_readiness_error?/1` using
  `Errors.retryable_github_error?/1` (`:428-429`), retry delay (`:431-449`),
  `maybe_emit_ci_readiness_unavailable/3` (`:451-460`).
  Constants `@ci_readiness_timeout_ms 5_000`, `@ci_readiness_retry_ms 60_000` (`:50-51`).
- `CiReadiness` functions used: `check_fun/0` (`github/ci_readiness.ex:64`),
  `readiness_scope/1` (`:172`), `cached_result/1` (`:116`), `cache_result/1` (`:108`),
  `format/1` (`:526`), `unavailable/2` (`:89`), `error_message/1` (`:93`), type
  `result/0`. `Errors.retryable_github_error?/1` (`github/errors.ex:189`).
- `Orchestrator.State` types `ci_readiness_result` as `Aiur.GitHub.CiReadiness.result()`
  (`orchestrator/state.ex:178`) — a type-only edge; change the type to
  `Aiur.CodeHost.CiReadiness.result()`.
- Auth preflight formatting: `tracker_preflight_alert_context/1` calls
  `AuthPreflight.format_auth_preflight_error/1` (`dispatcher.ex:841-848`); pattern on
  `{:github_auth_preflight_failed, diagnostic}`.
- Callers of the public CI functions: `orchestrator.ex:65-72`;
  `dispatcher_test.exs:71-86` (app env `:ci_readiness_check_fun`), `:876-1007`;
  `agent_control_cli_test.exs`, `alerts_test.exs` reference ci_readiness (verify).

## Chosen design

```elixir
defmodule Aiur.CodeHost.CiReadiness do
  @type result :: map()
  @callback check_fun() :: (keyword() -> {:ok, result()} | {:error, term()})
  @callback readiness_scope(keyword()) :: term()
  @callback cached_result(keyword()) :: result() | :unavailable
  @callback cache_result(result()) :: :ok
  @callback format(result()) :: String.t()
  @callback unavailable(String.t(), term()) :: result()
  @callback error_message(term()) :: String.t()
  @callback retryable_error?(term()) :: boolean()
end
```

- `Aiur.CodeHost.ci_readiness/0` returns `Aiur.GitHub.CiReadiness` when the code host
  adapter (C7-T1/T2) exports `ci_readiness/0`, else nil.
- In `CiReadinessGate`, every `Config.tracker_kind() == "github"` / `"github"` clause
  test becomes `provider = CodeHost.ci_readiness()` non-nil. The public functions keep
  their `kind` argument for compatibility: the `"github"` clause is retained as
  "kind with a provider", i.e. `start_initial_ci_readiness_check(state, kind, …)` checks
  `provider_for(kind)` which consults the registry (C7-T2) — so the existing tests that
  pass `"github"` keep passing unchanged.
- `retryable_ci_readiness_error?(:timeout) -> true` stays; otherwise
  `provider.retryable_error?/1` (GitHub delegates to `Errors.retryable_github_error?/1`).
- `maybe_dispatch/1` uses `Aiur.Tracker.with_poll_cycle(fn -> … end)`; GitHub's
  implementation is the exact `start_cycle` / `try … after end_cycle` at `:91-98`; the
  default runs the fun directly. Equivalence: for non-GitHub trackers the cycle ETS was
  created and never read (only GitHub reads consult it), so skipping it is
  unobservable.
- `tracker_preflight_alert_context/1`: `Aiur.Tracker.format_preflight_error(reason)`;
  GitHub's implementation calls `AuthPreflight.format_auth_preflight_error/1`; the
  surrounding pattern match and dedupe key `"github-auth:…"` stay as data.

**Invariant:** for the GitHub tracker, the sequence of readiness checks, cached results,
alerts (`system.ci_readiness.not_ready`, `system.ci_readiness.unavailable`), retry
times and state field values is identical to base; for other trackers,
`ci_readiness_checked` becomes true and nothing else happens, as at base.

## Implementation steps

1. Add the behaviour, `@behaviour`/`@impl` in `github/ci_readiness.ex`, and
   `retryable_error?/1` delegating to `Errors`.
2. Create `CiReadinessGate` by moving `:248-460` and the two constants; replace
   `CiReadiness.`/`Errors.` with `provider.` calls; leave delegates in Dispatcher.
3. Add `with_poll_cycle/1` and `format_preflight_error/1` optional callbacks + facades;
   implement in `GitHub.Tracker`; rewrite `:90-99` and `:841-848`.
4. Change the type at `state.ex:178`.
5. Drop the `Aiur.GitHub.*` alias line from Dispatcher; manifest allowlist rows removed.

Estimated production change: ~230 lines moved, ~60 new; `dispatcher.ex` −200 net.

## Non-happy paths

- **Readiness check crashes or times out:** unchanged — task under
  `Aiur.TaskSupervisor`, 5 s timeout message, `{:error, :timeout}` retryable path.
- **Config change mid-check:** scope reset kills the in-flight pid as at base
  (`reset_ci_readiness_for_config_change/1`).
- **No provider (Linear/memory):** marked checked, no alert (base `:341`, `:375`).
- **Provider returns an unknown error shape:** falls to the non-retryable branch exactly
  as at base (classification moved, not changed).
- **Rate-limited detail shape:** `{:github, :rate_limited, detail}` delay logic moves
  verbatim (test 3).
- **MP-E1 hooks:** untouched (RC-19 guard test in C7-T7 re-run).

## Compatibility and rollout

- No config/CLI change. App env `:ci_readiness_check_fun` (test seam, read by
  `CiReadiness.check_fun/0`) keeps working.
- Rollback: revert.

## Verification

```bash
env -C src mise exec -- mix test test/aiur/orchestrator/dispatcher_test.exs \
  test/aiur/orchestrator/ci_readiness_gate_test.exs test/aiur/github/ci_readiness_test.exs \
  test/aiur/alerts_test.exs test/aiur/agent_control_cli_test.exs \
  test/aiur/orchestrator/tracker_health_preflight_test.exs
make -C src fmt-check && make -C src lint
python3 scripts/check-components.py   # MP-R1-C1 (PROPOSED)
```

Tests:

1. Existing `dispatcher_test.exs:876-1007` pass unchanged through the delegates
   (behaviour evidence).
2. `ci_readiness_gate_test.exs` "a tracker without a provider marks readiness checked and
   emits nothing" (memory config). **Mutation:** treat nil provider as "github"
   (start a check); the test sees a task and fails.
3. `ci_readiness_gate_test.exs` "rate-limited retry waits retry_after seconds" —
   `{:error, {:github, :rate_limited, %{retry_after: 7}}}` → `ci_readiness_retry_at_ms`
   ≈ now + 7000. **Mutation:** drop the `retry_after` clause; fails (60 s used).
4. `ci_readiness_gate_test.exs` "retryable classification comes from the provider" —
   stub provider whose `retryable_error?/1` returns true for `:x`; assert retry path.
   **Mutation:** call `Errors.retryable_github_error?/1` directly; fails.
5. `dispatcher_test.exs` new case "poll cycle cache is opened and closed around a GitHub
   dispatch pass" — stub GitHub `with_poll_cycle/1` records calls. **Mutation:** call the
   fun without the wrapper; fails.
6. Size check in PR body: `wc -l src/lib/aiur/orchestrator/dispatcher.ex` before/after.

Manual: foreground `scripts/aiurdev --test` on a repo whose CI readiness is incomplete
(the sandbox repo the `--test` flow uses); confirm the same `system.ci_readiness.*`
attention appears once in `aiurdev agents`/dashboard attentions and dispatch is not held.

## Completion and handoff

- [ ] `git grep -n 'Aiur.GitHub' -- src/lib/aiur/orchestrator/dispatcher.ex` empty.
- [ ] `dispatcher.ex` reduced by ≈200 lines; no new file > 500 lines.
- [ ] Mutation results for tests 2–5.
- **Docs:** none (behaviour unchanged).
- **Dependents:** MP-R1-C9-T7 (State field owner table includes `ci_readiness_*`),
  MP-R1-C9-T9 (effects return), MP-R1-C11 plan refresh (row PR-13/PR-12 paths).
