# Daemon read-budget projection — 20-agent steady state (2026-07-30)

This records the before/after request budget for the incident configuration:
20 active agents and a five-second poll interval (720 cycles/hour). The
baseline is the call-budget audit on #678.

> **The after column is a projection from call-site arithmetic over the
> implemented request paths. It is not a measured live run.** See
> "What the projection excludes" and "Post-merge measurement plan" below.

| Source | Before REST req/hr | After REST req/hr, projected steady state | After GraphQL calls/hr, projected |
| --- | ---: | ---: | ---: |
| Comment fan-out | ~45,000 | 0 in the batch path; REST only for targets the batch could not resolve | 720 |
| CI fan-out | ~21,600 | 0 in the batch path; REST only for targets the batch could not resolve | 720 |
| Fixed issue lists | ~4,300 | ~4,300 conditional requests, ~0 rate-budget cost (304) | 0 |
| Command scan | ~1,440 | ~1,440 conditional requests, ~0 rate-budget cost (304) | 0 |
| **Total** | **~72,340** | **~0 rate-budget cost in steady state** | **1,440** |

The structural claim, which is what actually matters for the incident: after
this change the daemon's steady-state REST *rate-budget* consumption no longer
scales with agent count. It scales with the number of targets the GraphQL batch
could not resolve, plus the mutation paths, neither of which is a function of
the poll interval.

## What the projection excludes

The `~0` figures are steady-state read costs only. They are **not** the daemon's
total REST consumption. Excluded, and still charged at full rate:

- **First materializing read** of every conditional list, and every re-read
  after the underlying data changes (a 200, not a 304). At 20 agents with
  frequent label churn, the fixed lists change often enough that a meaningful
  share of cycles pay a 200.
- **Cache invalidations** — any cycle where the ETag no longer matches.
- **Every mutation path**: label transitions, comment creation, issue state
  updates, PR operations. These were never in scope for #1384 and are unchanged.
- **REST fallback targets.** A target whose branch lookup is inconclusive
  (unknown suffixed branch, overflowed `headRefName` connection) is deliberately
  omitted from the batch so the poller reads it over REST, completely. Those
  targets cost the old per-target REST price.
- **Dependency BFS** invocations, now GraphQL, but not free.

## Design notes

Both fan-outs are per-target aliased GraphQL operations keyed by each target's
head branch name (`pullRequests(headRefName:)`), never a scan of the
repository's open pull request list. The CI batch fits 100 targets per call and
the comment batch 50 (two aliases per target), so 20 agents is one call per
fan-out per cycle. More targets than one call covers deliberately issues
additional calls and emits an overflow warning; a result is never silently
truncated.

Comment tails are read as `comments(last: 100)` — the *newest* 100. A
long-running ticket with several hundred comments therefore stays in the batch:
the poller only wants comments newer than its `since` cursor, and the newest-100
window covers that cursor unless more than 100 comments arrived inside a single
poll interval. Only that case (or an unknown cursor) falls back to REST.

Conditional REST lists retain every cached page and reuse all of them after a
304. The 304 rows above are rate-budget costs, not network-call counts: GitHub
still receives the conditional request, it just does not charge for it.

`pullRequests(headRefName:)` is ordered `CREATED_AT DESC` so that a branch with
more than one open PR resolves to the same, newest PR every cycle.

## Not implemented: widen-on-quiet backoff

#1384 scoped a per-source widen-on-quiet backoff (direction (d)). It is
deliberately **not** implemented. A global quiet gate is inert whenever any
agent is running — which is exactly the incident scenario — and a per-target
gate would delay a newly created ticket's first comment poll, contradicting the
ticket's own non-goal that "latency characteristics must hold at the same
interval." Comment and CI polling therefore keep the configured cadence, and all
of the saving in this document comes from 304s and the GraphQL batches.

## Post-merge measurement plan

The projection is verified from the live daemon:

1. Run a normal multi-agent session at the incident poll interval.
2. Every REST/GraphQL response already surfaces its budget headers through the
   `github_rate_budget_pressure resource=<core|graphql> remaining=<n> limit=<n>
   reset_at=<t>` warning in `Aiur.GitHub.Transport`; sample
   `x-ratelimit-remaining` deltas per hour from those log lines for the `core`
   and `graphql` resources.
3. Compare the hourly consumption against the table above; the acceptance
   signal is that `core` consumption no longer scales with agent count and
   `graphql` stays at roughly two calls per dispatch cycle.
