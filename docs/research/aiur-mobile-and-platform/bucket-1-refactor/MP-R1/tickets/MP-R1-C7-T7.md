---
ticket_id: MP-R1-C7-T7
feature_id: MP-R1
chunk_id: MP-R1-C7
bucket: 1-refactor
title: Route Dispatcher's candidate fetch, blocked_by hydration and revalidation retry through the tracker facade
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C7-T1, MP-R1-C7-T2, MP-R1-C7-T6, U2-lifecycle-owner, MP-E1-C1]
prior_units: [U2, U5]
prior_boundaries: [DSP, ORC, TRK, GHD, GHB]
prior_features: []
prior_findings: [codebase-09, codebase-10]
size_owner: LIFECYCLE_DISPATCH (orchestrator/dispatcher.ex 2,670 in ledger, 2,673 at base; dispatcher_test.exs 3,197). Pinned to U8 ledger 465aca643; re-resolve at ticket start (RC-23, MP-R1-C11-T2)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C7-T7 — Dispatcher tracker reads through the facade

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R1 / C7 (plan C7-T6 "remove
  `Dispatcher` direct GitHub calls", split in two: this ticket covers issue-tracker reads;
  C7-T8 covers CI readiness, the per-cycle fetch cache and preflight formatting).
- **User value:** none visible. Dispatch, the most central path, stops naming
  `Aiur.GitHub.Tracker`, `LocalHold` and the GitHub tracker kind for its issue reads, so
  a non-GitHub tracker gets the same code path and the checker can hold the line.
- **Deliverable:** three optional `IssueTracker` callbacks plus facade functions, and
  the four Dispatcher sites rewritten to use them:

| Site (base) | Today | After |
|---|---|---|
| `dispatcher.ex:537-543` `default_candidate_fetch/1` | `if tracker_kind == "github"` → `GitHubTracker.fetch_candidate_issues_conditional/1`, else `Tracker.fetch_candidate_issues/0` + cache | `Aiur.Tracker.fetch_candidate_issues_conditional/1` |
| `dispatcher.ex:1281-1288` `default_blocked_by_hydrator/1` | `if github_tracker_kind?()` → `GitHubTracker.hydrate_blocked_by/1`, else `{:ok, issue}` | `Aiur.Tracker.hydrate_blocked_by/1` |
| `dispatcher.ex:1290-1300` `github_tracker_kind?/0` | `Config.settings/0` kind check (public, `@doc false`); also called by `comment_wake.ex:220` | kept unchanged (its other caller is orchestration-internal; MP-R1-C9 retires it) |
| `dispatcher.ex:1871-1875` revalidation | `LocalHold.run(fn -> fetcher.([id]) end, LocalHold.caller_opts(opts))` | `Aiur.Tracker.with_transient_retry(fn -> … end, opts)` |

- **Non-goals:** CI readiness, `CycleFetchCache`, `AuthPreflight`, `Errors` (C7-T8);
  moving the candidate poll out of the orchestrator process (prior §7 step 9; deferred by MP-R1-C9 as a timing change gated on the gap study — not ticketed);
  any dispatch ordering or admission change; the MP-E1 hooks in `DispatchPolicy`.

## Dependencies and blockers

- **Owner gate:** DESIGN-R1 §1.
- **Predecessors:** C7-T1 (`IssueTracker` behaviour), C7-T2 (registry, so the facade
  never names GitHub), C7-T6 (`github` facades declared; `LocalHold` stays a GitHub
  facade used only by `GitHub.Tracker`).
- **U2 (single writer):** `orchestrator/dispatcher.ex` is U2-owned and in the
  `LIFECYCLE_DISPATCH` U8 package. `U2-lifecycle-owner` = U2's merged exit ("every stuck
  state has one owner … no second label writer remains"). This ticket starts only after
  U2's dispatcher PRs merge, and no other dispatcher PR may be open at the same time.
- **MP-E1-C1 (RC-19, RC-20):** E1-C1-T4 adds the `Hints` hook to
  `DispatchPolicy.sort_issues_for_dispatch/1` and `{:skip, :build_queue_hold}` to
  `dispatch_state_decision`; E1-C1-T5 adds a `ClaimProbe` implementation in
  orchestration. This ticket rebases over E1-C1 and must leave both hooks and the probe
  untouched; candidate issues returned by the new facade must still carry the
  `queued?` flag set at ingestion (`github/issues.ex`, E1-C1-T1).
- **Concurrent with:** C7-T3/T4/T5 (disjoint). **Not** with C7-T8 (same file):
  T7 then T8.

## Verified starting point (base `45a290e3`)

- `dispatcher.ex:23-24` aliases `Aiur.GitHub.{AuthPreflight, CiReadiness,
  CycleFetchCache, Errors, LocalHold}` and `Aiur.GitHub.Tracker, as: GitHubTracker`.
- `default_candidate_fetch/1` at `:537-543` (quoted above); used with
  `candidate_list_cache/1` (`:545-547`) stored in `state.ci_lifecycle.poll_cache`.
- `GitHub.Tracker.fetch_candidate_issues_conditional/1` (`github/tracker.ex:36-49`)
  applies `TestTicketScope.filter_result/1` itself (`:48`); the non-GitHub branch gets
  the same filter from `Tracker.fetch_candidate_issues/0` (`tracker.ex:35-37`). Both
  branches are therefore filtered exactly once.
- `default_blocked_by_hydrator/1` (`:1281-1288`) and its comment (`:1276-1280`): other
  trackers "already carry hydrated blockers from their poll response, so hydration is a
  passthrough". `GitHub.Tracker.hydrate_blocked_by/1` (`github/tracker.ex:115-116`).
- `github_tracker_kind?/0` (`:1290-…`) deliberately uses `Config.settings/0`, not
  `tracker_kind/0`, so "no config" means passthrough, never a crash (comment `:1290-1295`).
- `revalidate_issue_for_dispatch/4` (`:1858-…`) wraps the fetch in `LocalHold.run/2`
  (`:1871-1875`; #2444 comment `:1863-1869`). `LocalHold.run/2` retries only on local
  budget holds with `reset_at` and `:github_budget_broker_timeout`
  (`github/local_hold.ex:1-20, 103-109`); `caller_opts/1` maps the
  `local_hold_*` test options (`:116-124`).
- Tests: `dispatcher_test.exs:321` ("skips dispatch when revalidation hydration reveals
  a non-terminal blocker"), `:462` (fail-closed on hydration error), `:488`, `:506`,
  `:1041` ("GitHub candidate state is fetched authoritatively every configured poll
  interval"), `:138`; `dispatcher_stale_blocked_by_test.exs`,
  `dispatcher_blocked_by_cost_test.exs`; `tracker_github_test.exs:60-90`.

## Chosen design

New optional callbacks on `Aiur.Tracker.IssueTracker` and facade functions on
`Aiur.Tracker` (pattern of `fetch_issue_states_by_ids_conditional/2`, `tracker.ex:54-67`):

```elixir
@callback fetch_candidate_issues_conditional(map()) :: {:ok, [term()], map()} | {:error, term()}
@callback hydrate_blocked_by(Issue.t()) :: {:ok, Issue.t()} | {:error, term()}
@callback with_transient_retry((-> term()), keyword()) :: term()

# Aiur.Tracker
def fetch_candidate_issues_conditional(cache)
  # adapter exports it -> adapter result (adapter filters, as GitHub does today)
  # else -> with {:ok, issues} <- fetch_candidate_issues(), do: {:ok, issues, cache}
def hydrate_blocked_by(issue)
  # Config.settings/0 error -> {:ok, issue}   (preserves the "no config" passthrough)
  # adapter exports it -> adapter result; else {:ok, issue}
def with_transient_retry(fun, opts)
  # adapter exports it -> adapter.with_transient_retry(fun, opts); else fun.()
```

`Aiur.GitHub.Tracker.with_transient_retry/2` = `LocalHold.run(fun, LocalHold.caller_opts(opts))`
— the exact base expression, so the `local_hold_*` test options keep working.

**Equivalence argument (non-GitHub trackers):** at base the revalidation for Linear or
memory also went through `LocalHold.run/2`, but that only retries on a local-hold
reason or `:github_budget_broker_timeout`, which neither adapter can return; it
therefore reduced to `fun.()`. The new default `fun.()` is identical.

**Invariant:** for each tracker kind, the candidate list, the cache value, the
hydration result, and the revalidation retry/timing behaviour are identical to base.

## Implementation steps

1. Add the three callbacks to `IssueTracker` (optional) and the three facade functions
   to `tracker.ex`, each with `Code.ensure_loaded?/1` before `function_exported?/3`
   (the release lazy-loading pitfall documented at `github/tracker.ex:93-96`).
2. Add `@impl` for the existing GitHub functions; add `with_transient_retry/2` to
   `GitHub.Tracker`.
3. Rewrite the four Dispatcher sites; drop `GitHubTracker` and `LocalHold` from the
   alias line `:23-24`.
4. Keep `default_blocked_by_hydrator/1` by name (now one line calling the facade): it is
   the default argument in `push_routing.ex:97,145`. Keep `github_tracker_kind?/0`
   (used by `comment_wake.ex:220`); it names no GitHub module, only a config string.
5. Manifest: remove the corresponding `orchestration → github` allowlist rows.

Estimated production change: ~70 lines added, ~30 removed. `dispatcher.ex` must not
grow.

## Non-happy paths

- **Config unavailable:** `hydrate_blocked_by/1` facade answers passthrough exactly as
  `github_tracker_kind?/0` did; test 2.
- **Hydration failure:** GitHub's `{:error, reason}` reaches Dispatcher unchanged, so the
  fail-closed hold (`dispatcher_test.exs:462`) still applies.
- **Local budget hold during revalidation:** still waited out (#2444); test 3.
- **Lazy module loading in a release:** `Code.ensure_loaded?/1` first (step 1), or the
  GitHub conditional fetch would silently fall back and lose the ETag saving.
- **MP-E1 hooks (RC-19):** the facade must not drop or rebuild `Issue` structs; the
  `queued?` field set at ingestion survives (test 4).

## Compatibility and rollout

- No config, flag or CLI change. `Aiur.Tracker` gains three public functions.
- Rollback: revert.

## Verification

```bash
env -C src mise exec -- mix test test/aiur/orchestrator/dispatcher_test.exs \
  test/aiur/orchestrator/dispatcher_stale_blocked_by_test.exs \
  test/aiur/orchestrator/dispatcher_blocked_by_cost_test.exs \
  test/aiur/tracker_github_test.exs test/aiur/tracker/facade_conditional_test.exs \
  test/aiur/orchestrator/dispatch_policy_test.exs
make -C src fmt-check && make -C src lint
python3 scripts/check-components.py   # MP-R1-C1 (PROPOSED)
```

New tests (`tracker/facade_conditional_test.exs`):

1. "memory tracker candidate fetch returns the cache unchanged and filters once" —
   **Mutation:** return `{:ok, issues, %{}}` (drop cache); fails.
2. "hydrate_blocked_by is a passthrough when config is unavailable" — no workflow file;
   assert `{:ok, issue}` and no raise. **Mutation:** call `Config.settings!/0`; raises → fails.
3. "github with_transient_retry waits out a local hold and retries" — GitHub tracker
   config, fetch fun returning a local-hold error once then `{:ok, [issue]}`,
   `local_hold_sleep_fun` recording sleeps; assert one sleep and the issue. **Mutation:**
   make GitHub's `with_transient_retry/2` call `fun.()` directly; fails.
4. RC-19 guard: a candidate `%Issue{queued?: true}` (field from MP-E1-C1-T1) returned by a
   stub adapter keeps `queued?: true` after `Tracker.fetch_candidate_issues_conditional/1`.
   (Guard; passes before and after — labelled as such.)
5. Existing `dispatcher_test.exs:321,462,488,506,1041` green unchanged.

Manual: foreground `scripts/aiurdev --test`; confirm agents dispatch (rows move past
`Queueing agent…`), open one chat pane; `aiurdev status` shows the usual poll countdown.

## Completion and handoff

- [ ] `git grep -nE 'GitHubTracker|LocalHold' -- src/lib/aiur/orchestrator/dispatcher.ex` empty.
- [ ] `dispatcher.ex` line count not increased (PR body).
- [ ] Mutation results for tests 1–3.
- **Docs:** none.
- **Dependents:** C7-T8, MP-R1-C9 deferred candidate-poll move (not ticketed; if later scheduled it calls the
  same facade), MP-E1 (queue reads candidates through the same facade if it needs them).
