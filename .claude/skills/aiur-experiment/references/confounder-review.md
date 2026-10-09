# Review every collected event

Give every frozen event id exactly one ledger row. Preserve kind, timestamp or
interval, ref and title as evidence, then classify it. Populate `affects` with
actual pack metric ids; an empty list needs an irrelevance explanation.
Severity is metric-dependent. The delivery examples below apply only when
those outcomes exist in the pack.

| Event | Classification | Severity and mechanism |
| --- | --- | --- |
| Feature-epic merged PR | treatment | none: change under test; still list it |
| CI, test-runner, build-gate or review-flow PR | unrelated-change | high inside the after-window when a primary measures the affected flow |
| Dispatch, retry, review or CI lifecycle fix | bug-fix | high when the repaired fault existed in only one window |
| Release/version change | release | high inside a line window rather than on its boundary |
| Config hash change | config | high when cap, routing or review settings change relevant outcomes |
| Critical alert or incident issue | incident | low below 1 hour; high at or above 1 hour for affected outcomes |
| Daemon outage/restart | outage | high above 1 hour for wall-clock flow metrics unless paused time is excluded |
| Base branch red interval | main-red | high above 2 hours total in a window for merge/CI/throughput outcomes |
| Cap/effective-cap change or global pause | capacity | high when capacity differs by at least 25% between windows |

For an unrecognized event, explain the evidence and seek its collector's
classification; do not silently omit it or force a known cause. For a config
hash with unknown changed keys, record uncertainty rather than infer routing.

Bias describes the **metric value**, not whether the treatment looks good:
`inflates` or `deflates`, with a mechanism. Example: after-window main red
prevents merges, inflating PR-open-to-merge time. Use `unknown` only with a
reason; heterogeneous effects must not be collapsed into a confident cause.

Prefer `excluded` when an engine-supported exclusion removes under 20% of the
sample, otherwise `sensitivity`, otherwise `noted`. Preserve excluded counts
and the selection risk exclusion introduces. Every high event gets a proposed
sensitivity rerun; if unavailable, record why it is only noted. Each
`sensitivity` row must identify its matching sensitivity entry and affected
metrics. A high/noted row forces `confounded` on every affected metric.
A robustness check that leaves the conclusion unstable warrants a downgrade
or `confounded`, never an upgrade. Explicitly account for zero collected
events and missing collection coverage; zero events does not prove no history
threat.
