# Daemon read-budget projection — 20-agent steady state (2026-07-30)

This records the before/after request budget for the incident configuration:
20 active agents and a five-second poll interval (720 cycles/hour). The
baseline is the call-budget audit on #678. **The after column is a projection
from call-site arithmetic over the implemented request paths — it is not a
measured live run.** It intentionally excludes the first materializing read
and change-driven cache invalidations, which must continue to consume their
normal request budget.

| Source | Before REST req/hr | After REST req/hr, projected steady state | After GraphQL calls/hr, projected |
| --- | ---: | ---: | ---: |
| Comment fan-out | ~45,000 | 0 | 720 |
| CI fan-out | ~21,600 | 0 | 720 |
| Fixed issue lists | ~4,300 | ~0 (304) | 0 |
| Command scan | ~1,440 | ~0 (304) | 0 |
| **Total** | **~72,340** | **~0** | **1,440** |

Both fan-outs are per-target aliased GraphQL operations keyed by each
target's head branch name (`pullRequests(headRefName:)`), never a scan of the
repository's open pull request list. The CI batch fits 100 targets per call
and the comment batch 50 (two aliases per target), so 20 agents is one call
per fan-out per cycle. More targets than one call covers deliberately issues
additional calls and emits an overflow warning; a result is never silently
truncated. A target whose branch lookup is inconclusive (unknown suffixed
branch, overflowed connection) is omitted from the batch so the poller's
complete REST fallback reads it. Conditional REST lists retain every cached
page and reuse all of them after a 304.

The 304 rows are rate-budget costs, not network-call counts: GitHub still
receives the conditional request. Quiet sources progressively widen their own
target-discovery cadence while active runs bypass that delay, preserving the
configured comment-wake and CI-detection interval for active work.

## Post-merge measurement plan

The projection is verified after merge from the live daemon, not before:

1. Run a normal multi-agent session at the incident poll interval.
2. Every REST/GraphQL response already surfaces its budget headers through the
   `github_rate_budget_pressure resource=<core|graphql> remaining=<n> limit=<n>
   reset_at=<t>` warning in `Aiur.GitHub.Transport`; sample
   `x-ratelimit-remaining` deltas per hour from those log lines (or from debug
   logging of the same headers) for the `core` and `graphql` resources.
3. Compare the hourly consumption against the table above; the acceptance
   signal is that `core` consumption no longer scales with agent count and
   `graphql` stays at roughly two calls per dispatch cycle.

The Executor accepted this projection plus post-merge measurement in lieu of
pre-merge live numbers (recorded on #1384); this document does not claim a
substitute live run.
