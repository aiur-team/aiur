# Daemon read-budget measurement — 20-agent steady state (2026-07-30)

This records the before/after request budget for the incident configuration:
20 active agents and a five-second poll interval (720 cycles/hour). The
baseline is the call-budget audit on #678. The after figure is a steady-state
calculation from the implemented request paths: it intentionally excludes the
first materializing read and change-driven cache invalidations, which must
continue to consume their normal request budget.

| Source | Before REST req/hr | After REST req/hr in steady state | After GraphQL calls/hr |
| --- | ---: | ---: | ---: |
| Comment fan-out | ~45,000 | 0 | 720 |
| CI fan-out | ~21,600 | 0 | 720 |
| Fixed issue lists | ~4,300 | ~0 (304) | 0 |
| Command scan | ~1,440 | ~0 (304) | 0 |
| **Total** | **~72,340** | **~0** | **1,440** |

At up to 100 targets, each fan-out is one aliased GraphQL operation per cycle,
so the bound is two calls/cycle. More than 100 targets deliberately paginates
with further GraphQL calls and emits an overflow warning; the result is never
silently truncated. Conditional REST lists retain every cached page and reuse
all of them after a 304.

The 304 rows are rate-budget costs, not network-call counts: GitHub still
receives the conditional request. Quiet sources progressively widen their own
target-discovery cadence while active runs bypass that delay, preserving the
configured comment-wake and CI-detection interval for active work.

The final live verification remains CI/dogfood work because the ticket
workspace's local Mix runtime currently terminates before startup while
resolving a stale release bootfile; this document does not claim a substitute
live run.
