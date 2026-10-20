# Build Orders

The repository has one [continuous build](./build-history), with feature
collections added over time. New features join it through collection membership,
native prerequisites, and the build queue; they do not create standalone roots.

Existing Build Orders retain their typed members, lanes, phases, dependencies,
complexity, and optional icons as readable planning history. The pack and root
commands below describe those legacy artifacts.

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

Build Order completion progress announces the highest newly reached 25%, 50%, 75% or 100% milestone on `system.build_order.<root>.progress`, independently of queue adoption.

Events use the catalog’s rounded percent and suppress milestones while provider health is unusable. A fully resolved root falling below 100% after its completion milestone starts a new durable generation.

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

The Analytics pane shows an **Optimistic starts** tile when member telemetry records early starts. It counts redone and discarded work and reports head start (the interval from dependent start to blocker merge, floored at zero), never time saved.

Missing head-start evidence is shown as unknown. A parked optimistic member stays `optimistic_parked` in the lifecycle chart until it resumes.

## The repository state node

Aiur separates the repository's tracked code from daemon-owned state under `~/.aiur/repo/<owner>/<repo>/`.

| Path | Holds |
| --- | --- |
| `latest/` | Aiur-managed warm clone of the configured base branch. |
| `builds/` | State-node Build Order packs, daemon status projections, and cross-boot build summaries. |
| `experiments/` | Experiment specs, snapshots and the capped `deploys.ndjson` boot ledger. |
| `analytics/` | Run summaries, durable `tickets/<ticket>.json`, and `repo-timeline.ndjson` facts when captured. |
| `meta/` | Executor findings at `findings.ndjson` and narrative retrospectives at `retros/<boot-id>.md`. |

From a checkout, `analytics/ledger-backfill --since 2026-09-15 --repo owner/name`
rebuilds durable ticket records from retained launches and fetches missing PR facts.
Use `--no-facts` for offline replay. Missing milestones stay unavailable; records
already materialized survive raw-log retention.

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

This detection makes no GitHub request. Retained CI and merge facts survive label regressions; issue observations must still be fresh. A boot-seeded CI head needs local PR identity before it can release a dependent. A newer open PR delivery replaces the closed body and clears the failed verdict.

## Queueing a Build Order

Dispatch starts ready work before optimistic work, then ranks optimistic candidates by open dependent-chain depth and downstream count.

`build_queue.optimistic_slot_share` defaults to 0.5 of the effective agent limit (at least one slot); zero disables optimistic starts. A merged blocker frees share on the next cycle. Existing runners keep their slots.

`aiur queue add --build-order <root> [--queue NAME] [--start-on TRIGGER]` adopts a root and tracks its open members and native prerequisite edges. A member already owned by another queue stays there; adoption reports a refusal for that member. Up to 32 roots can be adopted.

When a start trigger permits work before a blocker PR merges, dispatch binds the blocker’s events before starting the dependent. A fresh prewarmed ticket branch starts at the evaluated blocker SHA for one unmerged blocker. If fetching the head or checking its ancestry fails, checkout uses the base.

Several blockers start from the configured base. An existing remote ticket branch keeps its tip.

The optimistic-start prompt lists every blocker ref and SHA, requires an ancestry check, and covers cold or remote workspaces where hooks choose the checkout.

With one unmerged blocker, the dependent PR targets its branch; with several, it targets the configured base. The PR stays draft until the blockers merge.


Members receive `agent:queued`; readiness and item states follow the [build queue model](/concepts/ticket-lifecycle#build-queue).

For a list queue, if `queue add` finds `agent:todo` already present, the saved marker request records that provenance. When fresh evidence shows prerequisites are unmet, the queue holds dispatch, checks claims, then withdraws `agent:todo` only for an unclaimed item. A later manual promotion remains an override.

Adoption brings pre-labelled blocked members under queue control: the queue holds dispatch, checks claims, then removes `agent:todo` only from unclaimed members with known unmet prerequisites. Claimed members keep their labels. Unadoption removes queue membership and `agent:queued`, preserving other labels.

Stale, partial or unavailable graph evidence makes that root's items unknown and suppresses writes, while independent lists continue reconciling. External dependencies remain unknown. A closed root stops writes.

### Feature sets

A queue is a feature set: dispatch fills capacity in set rank order. Spare capacity spreads into the next set so one deliverable can finish while another starts.

`build_queue.set_order` selects `ranked` (default) or `none`; `max_active_sets` caps unfinished sets, and `spill_reserve_slots` reserves slots for the earliest unfinished set. `aiur queue order` adjusts ranks; holds stop sets. `NEXT` marks dispatch's selected set.

Queue summaries show ready and startable counts plus the largest blocker by downstream count. Cached GitHub blockers appear as `waiting on #N (github)`; cache misses do not fetch. `queue order` compares ranks with Build Order root dependency order.

The queue read model reports each source under `sources["build_order:<root>"]` and whether the projection is available under `build_queue.build_order_source`.

The instance capability report distinguishes queue availability from source availability:

| Capability | State and reason |
| --- | --- |
| `build_queue` | `available` when running; `unavailable` with `disabled`, `unsupported_tracker`, or `store_unavailable`; `degraded` with `writes_paused` when queue writes are paused. |
| `build_queue.build_order_source` | `available` when the queue is available or degraded and its Build Order projection is available. Otherwise `unavailable/dependency_unavailable`, depending on `build_queue` if the queue cannot run, or `build_orders` if the projection is absent. |

An unrecognised queue status or source flag reports `unknown/unknown` for that capability. A failed provider read reports both capabilities as `unknown/unknown`.

These capability states describe whether the integration is available; each adopted root still carries its own evidence freshness. Builds without the provider report both IDs as `unavailable/not_installed`.

## Start trigger

Queue promotion and native dependency dispatch use `build_queue.start_trigger` (default `pr_merged`); later stages satisfy earlier triggers.

| Trigger | Starts when | Evidence |
| --- | --- | --- |
| `pr_opened` | The blocker has a ready, non-draft PR | Delivered PR facts or `ci-wait` and later labels |
| `pr_ci_green` | Required CI has passed | Retained CI verdict or `human-review`/`rework` and later labels |
| `pr_approved` | Human review approves | Standing review verdict or `merging` and later labels |
| `pr_merged` | The blocker PR merges (default) | Merge facts, `done`, or completed issue closure |
| `issue_closed` | The blocker issue closes completed | Confirmed closure and reason |

Choose an override with `aiur queue add 12 13 --queue roadmap --start-on pr_opened` or `aiur queue add --build-order 12 --start-on pr_opened`. Change it with `aiur queue set roadmap --start-on pr_ci_green`; `--start-on default` returns to config. Tightening the trigger withdraws unclaimed queue-owned `todo`; running agents continue.

`queue show` shows the trigger, the needed stage and the observed stage. `(default)` means the queue follows config. Missing or stale evidence stays unknown.

`optimistic` means the dependent starts before its blocker merges; its worker follows the [optimistic dependent workflow](/concepts/ticket-lifecycle#build-queue) and keeps its PR draft until blockers merge.

Linear supports only `issue_closed` and `pr_merged` for dependency dispatch; build queue management currently requires GitHub. `pr_approved` adds one conditional review read per watched blocker; other stages reuse held lifecycle and PR evidence. See [GitHub API costs](/apis/github).

## Restacking after a squash merge

When a blocker merges, Aiur restacks idle dependents with a fast-forward merge commit. It subtracts the original blocker changes using the blocker PR’s retained head ref, so the PR diff contains the dependent’s changes. Merge events trigger the task; CI polling reconciles missed events using delivered PR facts.

The task holds the workspace lock and leaves the checkout and index untouched. A live dependent receives the merge wake and follows the agent skill’s restack recipe. A moved remote rejects the push; a textual conflict pushes nothing and produces `agent:rework`, a comment with paths, and `ticket.<id>.restack.conflict`.

`tracker.restack_after_blocker_merge` defaults to `true`. Set it to `false` to leave restacking to agents. Automatic restacking requires git 2.40 or newer. CI still checks clean textual merges for semantic failures; a restack push may dismiss approval and require review again.

## Merge order

The Executor runs `check-stack-order.sh` before every merge. It refuses a dependent PR unless its base is the integration branch and each `blocked_by` blocker has landed in the dependent's head.

A blocker has landed when it is closed `completed`, or its PR is merged and the merge commit is contained in the dependent's head. Exit 2 means refuse and exit 3 means it could not decide; neither merges.

A blocker closed `not_planned` or `duplicate`, a closed-unmerged blocker PR, or an ambiguous PR refuses. Remove the `blocked_by` edge to proceed.

With `--approved <sha>` it prints `RESTACK-ONLY` when the only change since that approved head is a verified Aiur restack, so the Executor can re-approve without a new review.

If a PR merges anyway, the daemon raises a critical `merge.out-of-order` alert naming the PR and blockers. It is detective and undoes nothing; missing blocker facts raise a warning, never a silent pass.

## Queue cost

Transient label failures retry after 1, 4 and 16 seconds through scheduled reconciliation; the queue remains responsive and rechecks current readiness.

Membership commands report the first marker failure immediately, retain the pending marker and retry it in the background.

Queue label requests use the `github-cost` callers `build_queue_label_post` and `build_queue_label_delete`. Promotion guard GETs use `build_queue_write_observe`. The daemon request ledger uses the same names. Shared open-list reads remain shared cost, and cached reads make no request.

The dispatch poll normally renews the open-issue snapshot the queue plans from. When that snapshot is older than the observation age, a non-empty queue lists open issues itself with caller `build_queue_open_issue_list`: at most once per observation age, starting one observation age after boot. The listing selects and authorizes no dispatch candidates.

The listing is conditional on the queue's own page cache: an unchanged page answers `304` and renews the snapshot. It runs whenever the dispatch cadence is wider than the observation age, never while the previous one is still running. It needs the daemon scheduled and GitHub reachable, so a saturated host or failed listing can leave freshness `unknown`.

Before pacing, each reconcile logs `build_queue_reconcile` JSON with the `ready` backlog and `newly_ready`: items now ready that were not ready in the previous pass, including the initial population. Both measure demand, not successful writes.

## Merged PRs with open issues

A merged prerequisite PR releases dependents under the default `pr_merged` trigger, even while its issue stays open. An explicit `issue_closed` queue waits for completed closure. Only under `issue_closed`, the build queue starts a grace timer at the first `pr.merged` hint or merged PR delivery it observes.

For `issue_closed` queues, if the issue is still open after `build_queue.merged_open_grace_seconds` (default 600), `ticket.<id>.queue.attention.merged_issue_open` asks the Executor to close it or explain why it stays open. The attention emits once and resolves on closure or when no dependent requires `issue_closed`; Aiur never closes the issue for this rule.

Merge times are held in memory. After a restart, a fresh merge observation starts the timer again. If the live hint is lost and no fresh PR delivery is available, poll-only mode keeps dependents waiting without this attention.

## Queue attentions

Queue faults emit once per cause and subject, then emit `.resolved` when cleared.

| Cause | Opens | Clears |
| --- | --- | --- |
| `prerequisite_failed` | Agent error, closed-unmerged PR, not-planned or duplicate closure | No dependent edge still has that cause; unknown evidence retains the latch |
| `dependency_changed_after_start` | A promoted, claimed non-optimistic ticket becomes unready | Readiness returns or the ticket completes |
| `optimistic_blocker_failed` | An optimistic blocker fails terminally; persistent trouble or integration churn emits info only | Executor unparks/closes the dependent, its ledger record closes, or non-terminal trouble recovers |
| `promoted_unauthorized` | Dispatch declines authorization (requires a free slot) | Decline clears or ticket is claimed; an unavailable probe retains it |
| `write_failed` | Five consecutive queue-label write failures | Next successful write |
| `merged_issue_open` | An `issue_closed` prerequisite PR merged and its issue remains open past grace | Issue closes or no dependent requires `issue_closed` |
| `inputs_unavailable` | Inputs remain unknown for twice the observation age | All inputs become current |
| `store_unavailable` | Queue store cannot load or save | Store recovers |

A prerequisite failure names the prerequisite and lists direct dependents before
transitive dependents. Changing that set does not re-fire; changing the failure
cause does. Durable latches survive restarts.

For optimistic dependents, terminal blocker failure pauses running work, parks the dependent, and marks its PR draft while keeping its branch and PR. Parked dependents release their fleet slot and their place in the optimistic share.

A closed-unmerged blocker PR has a replacement grace of `build_queue.optimistic_failure_grace_seconds` (600 seconds by default); not-planned/duplicate closure or removal of the dependency edge parks immediately.

This works without an adopted queue. Reopening or replacing the blocker within the grace updates the ledger without parking. Recovery after parking never auto-resumes work: the Executor chooses to wait for a replacement, re-base on the default branch and resume, or close the dependent.

Agent error, pause, parking, or a reset to todo keeps optimistic dependents running; persistent trouble past the grace raises an informational attention.

Approval on the current mergeable blocker head clears earlier conflict churn; later conflicts can raise the attention again. If a blocker merges, Aiur tells its dependents to rebase on the default branch and resume.

`build_queue.optimistic_churn_attention_threshold` (default 3, 0 disables) raises info after repeated conflicting integrations since that approval.

`prerequisite_failed` lists ledgered dependents as already started; `dependency_changed_after_start` is suppressed for ledgered optimistic starts. The guard owns the new attention, so queue readiness alone cannot clear a terminal park.

Ticket topics use `ticket.<id>.queue.attention.<cause>`; input and store faults
use `system.queue.attention.<cause>`. The store fault uses an in-memory latch:
a restart with a still-broken store emits once again per boot. Queue promotion
stays paused while the store is unavailable.

## Downgrading

Before running a release without build queue support, stop the current run and
set `build_queue.enabled: false` for its next launch. Review `aiur queue show`
before stopping: existing `agent:todo` labels remain dispatchable without queue
holds.

Remove `todo` from work that must wait, and retain the local queue store for a
later upgrade. Releases without the marker read `agent:queued` as a state, so
also remove it from open issues before you downgrade.

## Build queue dashboard panel

The `/build-orders` catalog includes a read-only Build queue panel. It uses the same held read model as `aiur queue show`: queues, completion progress, items in start order, prerequisite verdicts, rank, and open attentions. Manage membership and holds through the CLI.

Every source shows its observation timestamp, age and freshness. Stale readiness is dimmed; unavailable readings show Unknown rather than zero or ready. Disabled queues, unsupported trackers, store failures and paused writes have distinct notices.

Queue and progress notifications arrive in batches spaced at least 500 ms apart, then coalesce for 500 ms before the panel rereads local state. Each subscription group can hold only one unacknowledged batch; newer notifications replace older ones by event type.

A local refresh every five seconds updates freshness without tracker requests. Resolved attentions remain visible for 60 seconds; connection loss uses the dashboard’s existing disconnected indicator.

Build Order roots appear as features named `bo-<number>`. Membership follows
direct sub-issues, and build lanes become feature epics. The import writes no
GitHub labels and sets no baseline.

Explicit feature ownership and an operator’s
removal of an imported member are preserved. Imports wait for history backfill;
unknown start, end, and join times remain unknown.

Optimistic dispatches persist their attempt, trigger, blocker PR facts and counters in `optimistic-starts.json` under the repository’s state node. Records survive restarts, close on merge or discard, and remain for 14 days after closure. A ledger failure warns and alerts without stopping dispatch.

Run telemetry joins the `optimistic_start` point to the dispatch using the same attempt ID.

### Cascading blocker pushes

With `tracker.propagate_blocker_pushes`, an idle dependent incorporates only its direct blocker’s new push. The default enables this for members of queues with optimistic start triggers (`pr_opened`, `pr_ci_green`, `pr_approved`); an explicit boolean overrides it.

In A ← B ← C, C updates only after B pushes. A live dependent pulls itself. Every blocker history rewrite dispatches agent rework (`upstream_rewrite`); the daemon never rebases draft or reviewed dependents.

A conflict dispatches rework with `upstream_conflict`, the blocker PR and paths, and leaves descendants untouched until the fixed branch pushes.

Pushes coalesce per dependent for two seconds, with two propagations at most in flight; a newer dependent push supersedes older pending work. Every successful propagation may trigger CI on its PR; existing draft workflow rules still apply.

Add `experiment:feature` to a root issue to [measure the feature](/concepts/experiments#measuring-a-feature) from its first member merge through go-live.
