---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
issue: 3213
---

# Keep tracker I/O outside the orchestrator

## Contract

While a tracker poll is blocked, status, resume, reset-budget, message enqueue,
and a runner queue claim must finish within their existing budgets. Handler
execution must not perform remote tracker/GitHub work, including indirect calls.
State changes remain serialized by `Aiur.Orchestrator`; no task may return a
replacement `State` built before concurrent controls or queue changes.

This is a correctness change. No quota or measured latency saving is claimed.
No timeout increase, queue bypass, new config, or change to dispatch authority.

## Ownership checked

Inspected `origin/research/refactor-findings` on 2026-10-08:

- `docs/research/aiur-mobile-and-platform/bucket-1-refactor/MP-R1/tickets/MP-R1-C7-T07.md`
  explicitly says moving the candidate poll out of the orchestrator is deferred
  and **not ticketed**.
- `MP-R1/tickets/MP-R1-C9-T01.md` extracts firehose ownership but deliberately
  retains a synchronous `GenServer.call(..., :infinity)`. That extraction alone
  does not satisfy this ticket. Preserve its same-cycle recent-merge ordering.
- `U-units/tickets/U3-T01.md` owns event replay; U3-T02 owns Executor leases.
  Neither owns runner queue claims or asynchronous polling.
- `U-units/tickets/U4-T01.md` owns pause containment; U4-T02 owns condition-driven
  continuation. Neither removes orchestrator tracker I/O.
- #3190 / PR #3191 owns caller-side resume/reset-budget reads and writes plus
  short current-state apply transitions. Consumed validated branch
  `aiur/3190-reset-budget-and-resume` at `926b949f4` after explicit readiness.
  PR #3191 should merge first; this PR targets the authoritative `main`.
- #3203 / PR #3207 owns late-claim message-loss protection. Keep that protection;
  mailbox responsiveness does not make a timed-out claim safe by itself.

## Existing execution surface

`orchestrator.ex` delegates `:run_poll_cycle` to `Dispatcher.run_poll_cycle/1`.
Moving only the candidate fetch leaves the following inline work blocking:

| Path | Remote effects | Application constraints |
| --- | --- | --- |
| `tracker_health.ex` | GitHub auth preflight | Preserve named auth failures and poll retry scheduling. |
| `comment_polling.ex` | Firehose fetch/publish | Recent merges must be persisted before candidate reconciliation. Comment fan-out is already asynchronous. |
| `ci_lifecycle.ex` | CI batch, ticket refresh, guarded state writes, paused marker removal | Revalidate current runner generation and lifecycle/input fence before application. |
| `dispatcher.ex` | Candidate fetch, pre-dispatch refresh, blocked-by hydration, lifetime-trip write | Final slot, claim, global pause and dependency checks use current state. |
| `reconciler.ex` | Conditional refresh of missing running tickets | Results cannot resurrect an exited/replaced runner. Preserve cache on partial failure. |
| `issue_sync.ex`, `startup_claim_reconciler.ex`, `merged_ticket_reconciler.ex` | Refresh, label repair, guarded state writes, open PR lookup | Preserve expected-state checks; refresh after unknown write outcome. |
| `command_scan.ex`, `pr_anchored.ex`, `human_review.ex` | PR discovery/verdict reads, state writes | Keep verdicts fresh and trusted-author filtering intact. |
| `retry_engine.ex`, `auto_resume.ex`, `pause_resume.ex` | Retry/automatic resume reads and writes, completed-runner revalidation | #3190 covers public control paths, not every automatic call site. |
| `comment_wake.ex`, `remote_control_mode.ex`, `priority_control.ex`, `rate_limit_fallback.ex`, `lifecycle_fence.ex` | Event-driven refresh and label mutations | A poll-only fix is insufficient: handlers outside the tick also reach these effects. |
| `workspace_cleanup.ex` | Tracker reads during cleanup | Cleanup must not become a second blocking path. |

Before changing each function, inspect all callers and injected test functions.
Keep direct helper tests' synchronous shape where it remains useful; production
handler routes must use the asynchronous boundary.

## Implementation units

1. **Poll read stages.** Introduce a supervised, monitored poll worker with an
   owner/generation token and bounded lifetime. Send narrow outcomes back for
   preflight, firehose, CI and candidate reads in existing order. Only one cycle
   is in flight; repeated refreshes coalesce. Complete scheduling once, including
   failure/crash/timeout. Tasks carry inputs and outcomes, never mutable state.
   Touch `orchestrator.ex`, `dispatcher.ex`, `lifecycle.ex`, `state.ex`,
   `tracker_health.ex`, `comment_polling.ex`, `ci_lifecycle.ex` and their tests.
2. **Reconciliation and dispatch effects.** Separate each remaining read/write
   from its state application in the paths above. Use current issue/runner
   identity, generation, claims, capacity and lifecycle fences on result apply.
   Tracker writes retain expected-state guards and named/unknown outcomes.
   Never replay a write just because its completion was late. Dispatch only
   after authoritative revalidation and current-state eligibility.
3. **Controls, event routes and enforcement.** Integrate #3190's control API;
   convert remaining automatic/event/cleanup routes. Add runtime boundary
   enforcement or a compiled call-graph guard that includes aliases, injected
   callbacks and indirect helpers, and allow remote work only in workers/callers.
   Checking only source text in `orchestrator.ex` misses today's bug.

## Verification

`src/test/aiur/regression/orchestrator_tracker_io_test.exs` exercises the real
orchestrator and public APIs with a barrier-controlled Linear double. Seed a
message through the public enqueue API before the poll, hold candidate fetching,
then issue status/resume/reset/enqueue/claim. Release only after the assertions;
assert exact queue item identity/text and durable budget reset, not just timing.
The tracker process must differ from the orchestrator. GitHub stages use
`Req.Test` transport doubles; no live network or tickets. Additional real-owner
tests cover a successful new dispatch, deferred priority writes and shutdown.

Additional tests belong beside affected modules:

- Queue/send/control changes during every read stage survive the result apply.
- Pause/global pause/slot reduction during fetching prevents stale dispatch.
- Worker exits or changes generation during revalidation; no resurrection.
- Duplicate/stale result, task crash, deadline and owner shutdown clear the
  in-flight state and schedule exactly one retry; no leaked task or monitor.
- Repeated refresh/tick while a poll is in flight does not fan out more polls.
- Tracker write failure preserves named error; unknown outcome triggers fresh
  reconciliation rather than blind write replay.
- Slow firehose, CI, running-ticket refresh and pre-dispatch read demonstrate
  responsiveness beyond the candidate-only fixture.
- Runtime/call-graph guard fails when any handler's indirect path runs remote I/O.

Run compile with warnings as errors, format and the deterministic affected tests
with `--max-cases 4`. Mutation-check every new regression in an isolated clean
worktree: revert its production hunk, observe failure, restore, observe pass.
Full CI is authoritative. Agent workspaces must not run manual sandbox resets;
Executor owns any real CLI/TUI acceptance after integration.

## Risks and review

The primary risk is stale state applied after concurrent message/control/exit
events. A whole-poll task returning `%State{}` is rejected: even a three-way
merge cannot undo worker spawns, tracker writes, timer ownership or consumed
queue items. A poll-generation token alone does not fence runner replacement.
The review must follow each remote effect to its current-state apply guard.

Internal refactoring needs no user docs unless an existing documented behavior
changes. Update `website/docs-app/apis/github.md` if polling order/cadence,
cache behavior, or write semantics change. Preserve full acceptance; do not
present a candidate-only extraction as the structural fix.

## Completed local validation

The 45 directly related test files passed: 1,174 tests, zero failures. Compile
with warnings as errors, formatting and public specs passed. All 36 new tests
are checked against deliberately reverted production behavior in isolated
worktrees, with only the intended production file dirty. Full CI remains the
final gate; manual CLI sandbox resets are prohibited in this agent workspace.
