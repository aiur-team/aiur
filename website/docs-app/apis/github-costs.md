# GitHub per-caller costs

## Changes Aiur makes itself

There is a third path, and it is the cheapest one: a change Aiur makes.

Sparse merge events that omit the merger login trigger one `GET /pulls/{number}` in the merge tracker task, attributed to `merge_attribution`. Events carrying the login need no read; failed or unattributed reads retain the critical attribution alert.

Idle restacks use delivered PR facts and the agent credential file, with cached GitHub helpers cleared. Push propagation uses exact-head leases for fast-forward commits. Each direct dependent’s push advances the cascade; conflicts write rework and a path comment ([restacking](/concepts/build-orders#restacking-after-a-squash-merge)).

Stacked-base checks use held dependency edges without the dispatch-age cutoff and PR facts delivered within 24 hours. Missing evidence restores the integration base; no remote reads are added ([ticket lifecycle](/concepts/ticket-lifecycle#build-queue)). A stale queue [lists open issues](/concepts/build-orders#queue-cost) as `build_queue_open_issue_list`.

Queue progress retains existing CI and merge facts; boot CI heads bind to local PR identity. Watched approval blockers use conditional review reads once per half observation age. Closure uses delivered PR evidence, leaving poll-only mode pending. Missing identity waits for held PR evidence. No new CI polling or saving is claimed.

Build queue closure uses `build_queue_observe`. Optimistic blockers use `optimistic_guard_read` after the observation age, grace expiry or a PR event; parked dependent labels are confirmed before release. Parking uses `optimistic_guard_draft` and `optimistic_guard_comment`. Failed writes retry from the journal. No saving is claimed.

Build queue writes use `build_queue_label_post` / `build_queue_label_delete`; guard GETs use `build_queue_write_observe`. Writes are paced by `build_queue.max_writes_per_minute` (default 20). Retries schedule reconciliation without blocking the queue.

Withdrawal removes only `agent:todo` after holding dispatch and proving it unclaimed; `agent:queued` remains. See [request costs](/concepts/build-orders#queue-cost); no saving is claimed.

CI-wait recovery uses the [failure digest](/apis/ci-failure-evidence), changed paths and Actions attempts (`ci_recovery`). Fully annotated tests outside the diff and known flakes may be rerun once per head.

Cancelled runs and drafts are not rerun; changes-requested PRs get one attention. Failed CI leaves queued or auto-merging approved heads in `ci-wait`. New heads wait with blocking attention until review.

Reruns default on; limits: `agent.ci_recovery_max_per_poll` (5) and `agent.ci_recovery_max_per_hour` (20). Disable with `agent.ci_recovery_enabled: false`. Hourly cap shared across tickets and restarts.

Attempts are journaled before writes; queued PRs are left alone. Recovery does not update the base. A run GET returning 403/404 or a denied rerun POST raises one attention and permits the normal failed/rework handoff instead of holding CI wait.

Three failed CI/rework handoffs per PR raise one attention naming tests and hold further rework/fallback wakes. The Executor fixes or reruns the current head until all required checks pass, releasing the hold and resetting the cycle count. Acknowledging the alert alone does not release it.

A rerun not observed within ten minutes raises attention. Journaled attention holds avoid repeated recovery reads; normal CI polling continues. No saving is claimed.

Orphan-claim recovery reads mergeability/reviews before guarded add-before-remove state writes. It posts a reason comment and wakes the Executor ([Operating Aiur](/concepts/operating-aiur#pause-and-capacity)). Successful writes retain GitHub's returned state.

The write response supplies this state without another read. Two consequences:

| Situation | What happens |
| --- | --- |
| Feature membership changes | CLI or agent joins write `feature:<slug>`; leaves remove it. Calls, including label creation, use `build_queue.max_writes_per_minute` and a 200/hour cap. Human labels become journaled joins/leaves through History without extra reads. Imports are exempt; unconfirmed backfill waits for explicit release. |
| A view is showing the resource | It updates from the write, with no API call of its own, and before any webhook for that change could arrive. |
| The webhook for that change arrives | It is recognised as already handled and wakes nobody. An agent is never re-woken by its own comment or its own review reply. |
| A label or a close is delivered | It reconciles state rather than waking anybody, so an orchestrator label write cannot wake the agent that state belongs to. |

Suppression here is per resource **and per version**, as above. A later edit of that same comment moves its `updated_at`, so it wakes the agent normally.

Where GitHub's answer cannot name a version — the label endpoints return the label array and nothing else — Aiur keeps the state but suppresses nothing. The resource's next genuine change is never swallowed.

Such a write still records the marker of the snapshot it was applied to, rather than recording nothing. That is what keeps "a delayed delivery carrying older state is refused" true afterwards: staleness is judged against the marker on the record, so a record left unmarked would accept every late delivery instead of refusing the old ones.

A label write also corrects the labels on the issue Aiur already holds, and does so as one indivisible step. Reading the issue, changing it, and writing it back as separate steps would let a delivery that landed in between be overwritten by the older copy — including its `open` or `closed` state.

A write that fails records nothing.

Main watch debounces base Actions deliveries for two seconds. At the default 120-second cadence, commit lists use GitHub ETags (unchanged responses are free `304`s); push and merge_group run censuses continue. Run fingerprints reuse completed checks until changed, while run and commit dates bound pagination.

Main-watch matches push or merge_group runs to the landed SHA and queue base. Cold 20-SHA census: 43 reads; one changed SHA: five; startup: one permission probe (test counts, not live measurements). Reconciliation caps transport calls at 64; incomplete reads retain known state and mark it unavailable.

Failure events carry tests, flake classifications and suspects. Evidence uses existing CI callers; associations use `main_watch_suspects`, permissions `main_watch_permissions`, and reruns `main_watch_canary`. Actions write is cached until daemon restart; permission changes require a restart.

Main-watch reruns failed jobs once per commit when one test fails and its path was untouched. Digest evidence and Actions write permission are required; incomplete or changed paths skip it. Callers: `main_watch_commit_files` and `main_watch_single_test_rerun`. A pass feeds same-commit recovery; a failed rerun stays red for the fixer. No saving is claimed.

An idle completed head or any active watched run suppresses canaries; an eligible cancellation without write permission raises one persisted attention. Status distinguishes a running, unavailable or absent watcher and shows retained SHA and completed-run age after errors or poll crashes.


## Experiment window evidence

`aiur experiments events` reads merges, releases, tags, incidents and Actions through telemetry's quota-accounted transport as `experiment_window_events`. Errors and page caps mark GitHub incomplete; frozen reads are local until refresh or window/source changes.

Each of five sources permits ten pages: at most 40 GraphQL page requests and 10 REST page requests, before transport retries. GraphQL points depend on the query; `rateLimit.cost` supplies the actual charge.

Measured on aiur-team/aiur, 2026-10-12, with a 48-hour merge/Actions range: eight GraphQL pages cost 12 points (176 merges, nine releases and 137 tags across repository history, zero incidents); four REST pages returned 311 runs. This read-only census used the shipped query shapes; no saving is claimed.

## Operator PR merge command

`aiur pr merge` uses the operator's stored `gh` credential in its standalone process; it never sends that credential to the daemon. Its direct GitHub reads are outside the agent guard ledger. No quota saving is claimed.

Before and after premerge checks it reads the PR, current-head check rollup, linked-ticket labels, paginated paths and reviews, applied rules, protection and base ref. Incomplete observations fail closed.

Reviews use each reviewer's latest decision. An approval must match the current head; changes requests refuse for every identity. A requested operator approval is pinned and reread.

A merge-queue rule routes the pinned head through GraphQL enqueueing; it never authorizes a direct bypass merge. Without a queue, squash merge pins the reviewed head. The ledger distinguishes enqueueing from observed merges.

The daemon independently verifies the configured repository, PR head, base and merge SHA against GitHub before publishing `system.pr.merged`; caller-supplied actor data is replaced with GitHub's merge attribution. See [the command reference](/reference/cli#pr-merge).


## Measured feature epics

The feature worker uses the quota-accounted transport as `experiments_auto`:
one labelled-issue page hourly (100 rows; a full page is incomplete),
and one `/issues/{number}/sub_issues` page per tracked epic hourly. Merge and
membership deposits can bring the member refresh forward, bounded to five minutes.
ResourceStore labels discover epics between polls.

Closed completed members
missing RecentMergeStore evidence use a bounded linked-PR GraphQL read for merge
time and SHA. Incomplete or refused reads preserve state for retry. No saving is claimed.

## Experiment analyst tickets

Analysis requests create issues as `experiment_analysis_create`, with dispatch labels and a nonce marker in the same POST. Label definitions are ensured first.

Uncertain writes reconcile as `experiment_analysis_reconcile`, using pages of 100 open and closed issues. The window begins at the first creation attempt minus five minutes for clock skew. Older journals use the original request time.

GitHub's [`since` filter](https://docs.github.com/en/rest/issues/issues#list-repository-issues) filters update time. Results sort by creation time descending; a bounded scan ends at the first row created before the window, a match, or the last page. It can pass page ten. Legacy lookups without a usable time window retain the ten-page safety limit.

Failed or incomplete reads never authorize a POST. After backoff, a complete scan proving absence permits creation with the same request and nonce.

Attached-ticket failure detection uses the daemon's complete, fresh open-issue label snapshot through the tracker facade. It adds no per-ticket poll. The listing must have begun after the request's latest revision; its completion time cannot prove closure. Missing observation provenance also cannot prove closure. No quota saving is claimed.
