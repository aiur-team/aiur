# Build Orders

A Build Order turns a large feature into typed members, lanes, phases, dependencies, complexity, and optional icons.

## Pack contents

| File or field | Purpose |
| --- | --- |
| `.aiur/build_orders/<slug>.json` | Writable workspace mirror discovered by the daemon. |
| `build-order.json` | Members, lanes, phases, dependencies, complexity, and icons. |
| `status.json` | Current execution state. |
| `tickets/<ID>.md` | Draft member contract before tracker promotion. |

The canonical state-node copy lives at `~/.aiur/repo/<owner>/<repo>/builds/<slug>/`.

| Pack location | Visible to Aiur? |
| --- | --- |
| Active workspace mirror | Yes. |
| Repository state node | Yes. |
| `docs/` only | No. |
| Another inactive branch only | No. |

## The Build Order page

| Surface | Shows |
| --- | --- |
| `/build-orders` | Discovered catalog. |
| `/build-orders/:root_number` | One root's phases, lanes, graph, members, usage, and analytics. |
| `aiur build-orders [<root>]` | The same projection in a terminal. |
| `--json` | Machine-readable Build Order rows. |

The catalog's **Tickets completed** percentage counts accepted completions over all members. With partial lifecycle coverage, the percentage is a lower bound and the resolved count appears alongside it.

In a selected Build Order, **Estimated work progress** combines reported work estimates using member complexity weights. It can advance before any ticket is complete. Last-known estimates show their age; unavailable member measurements remain unknown.

Partial aggregates divide known work by the weight of all members, so unresolved members cannot inflate the percentage.

The External gates summary counts the same pack gates listed above the graph; graphs without pack gates show External dependencies instead.

Open a member's context to use **Read chat** when that member has a readable conversation in the current run. This opens the same conversation drawer as Units and does not resume the worker.

A draft says chat has not started. A member without readable current-run history shows chat as unavailable. Completed workers normally have no current-run chat handle after leaving the running roster, so their context shows chat as unavailable.

On the catalog, ticket, epic and wave counts remain numeric when resolution succeeds, including a real `0`. A count that could not be resolved never renders as `0` or as a bare dash—it names its cause instead:

| Cell | Meaning | What to do |
| --- | --- | --- |
| `Budget exhausted` | The planning query budget or a local GraphQL hold blocked the read. Shows the reset time when the hold reports one. | Wait for the reset, or raise `tracker.github.planning_page_budget` / `planning_call_budget`. |
| `Rate limited` | The tracker rate limited the read. Shows the reset time when reported. | Wait for the reset; reduce concurrent agents if it repeats. |
| `Timed out` | The request exceeded its deadline. | Usually transient; it retries on the next labelled read. |
| `Unreachable` | The connection was refused or dropped. | Check network reachability to the tracker—not latency. |
| `Not authorized` | The credential was missing or rejected. | Check the configured GitHub token. |
| `Unreadable response` | The response did not match the expected shape. | Likely an Aiur or tracker schema change; report it. |
| `Partial read` | The read succeeded but hit Aiur's own planning page limit before every member. This is an Aiur bound, not a tracker fault. | Raise `planning_page_budget`. |
| `Unresolved` | The failure could not be classified. | No cause is claimed on purpose—a wrong reason is worse than none. |

These states are intentionally not estimates. `aiur build-orders --json` reports the same cause as `count_resolution_failure`, with `count_resolution_reset_at` when a reset horizon is known.

A local planning pack remains readable when a run starts globally paused before its first membership snapshot. The selected page and `aiur build-orders` identify unavailable current-run membership or ticket status separately from plan readability; any unobserved ticket state or completion remains unresolved.

Draft members carry local ticket document paths and no invented GitHub issue URL; draft blockers cannot claim a live blocking state.

<img src="/images/dashboard/build-orders-dark.png" alt="Desktop Build Order graph with synthetic example member tickets">

## The repository state node

Aiur separates the repository's tracked code from daemon-owned state under `~/.aiur/repo/<owner>/<repo>/`.

| Path | Holds |
| --- | --- |
| `latest/` | Aiur-managed warm clone of the configured base branch. |
| `builds/` | State-node Build Order packs, daemon status projections, and cross-boot build summaries. |
| `analytics/` | Telemetry summaries, including `runs/<boot-id>/run-summary.json`. |
| `meta/` | Executor findings at `findings.ndjson` and narrative retrospectives at `retros/<boot-id>.md`. |

These paths are machine-local. Do not commit them, and do not expect copying a repository to copy its run state.

`aiur init` and the first run create this state as needed. Aiur does not create `executor/handoff.md`: the durable narrative is `meta/retros/<boot-id>.md`, and the shareable artifact is the generated `docs/executor/open-findings.md` digest.

## Executor handoff and findings

| Durable record | Location or command |
| --- | --- |
| Accepted boundary, run identity, decisions, evidence | Executor handoff. |
| Hourly retrospective | `meta/retros/` under the repository state node. |
| Deferred finding | `aiur findings --record` into `meta/findings.ndjson`. |
| Current bottleneck | Named in the hourly filing with evidence-supported follow-up. |

Git history and an old Dashboard capture are not substitutes for current Build Order state.

## Closed prerequisite pull requests

The build queue detects a prerequisite PR closed without merging from its latest fresh GitHub webhook delivery. Its dependents fail readiness with `pr_closed_unmerged` and remain waiting.

Each newly observed closed-unmerged PR version publishes the live event `ticket.<id>.pr.closed_unmerged` with ticket and PR-number references; queue readiness uses stored evidence, independently of event delivery.

This detection makes no GitHub request. In poll-only mode, or with missing, stale, or malformed delivery evidence, the open prerequisite stays pending. A newer open PR delivery replaces the closed body and clears the failed verdict.

## Queueing a Build Order

The optional Build Order queue source adopts a root and tracks its open members and native prerequisite edges. A member already owned by another queue stays there; adoption reports a refusal for that member. Up to 32 roots can be adopted.

Adoption brings pre-labelled blocked members under queue control: the queue holds dispatch, checks claims, then removes `agent:todo` only from unclaimed members with known unmet prerequisites. Claimed members keep their labels. Unadoption removes queue membership and `agent:queued`, preserving other labels.

Stale, partial or unavailable graph evidence makes that root's items unknown and suppresses writes, while independent lists continue reconciling. External dependencies remain unknown. A closed root stops writes.

The queue read model reports each source under `sources["build_order:<root>"]` and whether the projection is available under `build_queue.build_order_source`.

The instance capability report distinguishes queue availability from source availability:

| Capability | State and reason |
| --- | --- |
| `build_queue` | `available` when running; `unavailable` with `disabled`, `unsupported_tracker`, or `store_unavailable`; `degraded` with `writes_paused` when queue writes are paused. |
| `build_queue.build_order_source` | `available` when the queue is available or degraded and its Build Order projection is available. Otherwise `unavailable/dependency_unavailable`, depending on `build_queue` if the queue cannot run, or `build_orders` if the projection is absent. |

An unrecognised queue status or source flag reports `unknown/unknown` for that capability. A failed provider read reports both capabilities as `unknown/unknown`.

These capability states describe whether the integration is available; each adopted root still carries its own evidence freshness. Builds without the provider report both IDs as `unavailable/not_installed`.

## Merged PRs with open issues

A merged prerequisite PR does not complete its issue. Dependents stay pending until tracker observations confirm closure. The build queue starts a grace timer at the first `pr.merged` hint or merged PR delivery it observes.

If the issue is still open after `build_queue.merged_open_grace_seconds` (default 600), `ticket.<id>.queue.attention.merged_issue_open` asks the Executor to close it or explain why it stays open. The attention emits once and resolves when closure is observed; Aiur never closes the issue for this rule.

Merge times are held in memory. After a restart, a fresh merge observation starts the timer again. If the live hint is lost and no fresh PR delivery is available, poll-only mode keeps dependents waiting without this attention.

## Queueing a Build Order

The optional Build Order queue source adopts a root and tracks its open members and native prerequisite edges. A member already owned by another queue stays there; adoption reports a refusal for that member. Up to 32 roots can be adopted.

Adoption brings pre-labelled blocked members under queue control: the queue holds dispatch, checks claims, then removes `agent:todo` only from unclaimed members with known unmet prerequisites. Claimed members keep their labels. Unadoption removes queue membership and `agent:queued`, preserving other labels.

Stale, partial or unavailable graph evidence makes that root's items unknown and suppresses writes, while independent lists continue reconciling. External dependencies remain unknown. A closed root stops writes.

The queue read model reports each source under `sources["build_order:<root>"]` and whether the projection is available under `build_queue.build_order_source`.
