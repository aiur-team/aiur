# GitHub polling

## Repository setup from global defaults

A new run using `~/.aiur/config` bootstraps the current GitHub repository before starting supervision or dispatch. It resolves the repository from `origin` and rejects conflicting explicit `tracker.github.repo`.

Setup uses normal App/PAT/keyring credential resolution after launcher dotenv loading: repository `.env`, then `~/.aiur/.env`, filling only unset variables. Repository GitHub credential groups exclude global credentials.

Setup reads repository labels through the governed transport in pages of 100, bounded to ten pages. It creates only missing workflow lifecycle, marker, and complexity labels through the existing idempotent label API.

No model/effort/alias labels are seeded and existing labels are neither deleted nor changed. Requests are attributed normally; no quota saving is claimed.

Label read/create failures stop startup before agents start and explain the required Issues permissions. Repository-local configurations keep the explicit init flow.


## What Aiur polls
| Poll | What it tracks | Why it exists |
| --- | --- | --- |
| Tracker state | Issue labels, active tickets, blockers, and pull requests | Keeps dispatch and the Units page aligned with GitHub. |
| Ticket branches | Validated refs and commits; subscribed known-ref changes trigger async compare (`per_page=1`, caller `ticket_branch_rewrite`) | `behind`/`diverged` or 404 emits `ticket.N.branch.force-push` (404: `previous_missing`). Errors/holds log and count `[:aiur, :events, :branch_rewrite, :error]`; new/unsubscribed refs skip compare. |
| Comments and reviews | Trusted issue comments, PR comments, reviews, unresolved threads, and cached PR approval/merge-queue/ready timestamps | Wakes the correct agent for operator direction or rework; the five-minute Executor sweep reuses these fields and raises durable wakes without its own GitHub request. It looks up findings against cached PR bodies or merge-group entries and reports their cache age; entries older than five minutes (or with unknown age) remain visible as `unverified`. Oversized merge-group pages use a compact per-run age index; at the body-byte cap, `ResourceStore.Memory.enforce/2` sheds least-recently-written bodies until they fit. |
| CI | Terminal checks and mergeability while a ticket is in `agent:ci-wait` or `agent:human-review` | Required-check configuration (branch rules and protection) is shared through the repository-configuration cache; CI verdicts remain uncached. A green current head already marked ready and not reviewed moves directly to human review and publishes the ready wake; a draft or a head that still needs agent work returns to the agent. Approved landing PRs with current-head PR-caused failures have auto-merge disabled or are removed from the queue, then route to rework with failed job names; inherited and unknown failures stay held. Cancelled and infrastructure failures get one bounded rerun before repair routing. Two consecutive `CONFLICTING` observations on the same PR head move the ticket to rework with instructions to merge `main`; `UNKNOWN` breaks the streak. |
| Base-branch CI (main watch enabled) | Completed watched workflow runs for up to 20 recent base commits | Detects failures through check webhooks, base pushes and polling; retains state across restarts. Fixer mode is opt-in (`on_red: dispatch_fixer`). Governed callers `main_fixer_open_issues` and `main_fixer_create` list/file tickets; shared comment and PR readers reconcile evidence/recovery. At default 120s, a single-page listing adds at most 30 calls/hr; pagination and comment/PR reads add calls (mechanism budget, not measured savings). [Fixer dispatch](/reference/merge-policy). |
| Quarantine expiry | Hourly: up to 20 scheduled main CI runs, plus job details for each run | Determines whether expired test-quarantine entries can be lifted or their fix tickets need a priority escalation. |
| Experiment release lines | Boot/hourly warm-clone `git ls-remote --tags --refs origin`; eligible tags are fetched and dated locally. | Creates [release experiments](/concepts/experiments#version-and-release-lines) without GitHub API calls. |
| Repository events | Default-branch pushes and opened, reopened, merged or closed-unmerged pull requests | Refreshes work whose base or review state changed. Merged PR bodies also supply `Post-deploy check:` lines for the Executor checklist. |
| Analytics facts | Terminal and on-demand backfill PR facts; boot/hourly base history and tags | Body-free `pr_facts` and `analytics/repo-timeline.ndjson`; callers `analytics_facts` and `analytics_repo_timeline`. |

Once per repository and history query version, the daemon reads every issue for build history (caller `build_order_history_backfill`). It starts after a 60-second boot delay, spaces pages by 10 seconds, holds below 20% remaining GraphQL budget and pauses further reads after 300 reported points in a rolling hour.

Rows and the resume checkpoint share the history file; a restart resumes unfinished work and skips a completed walk. This is a one-time read, not a poll or a page-view request.

The predicted cost is about 3 points per 100 issues; `rateLimit.cost` and `aiur github-cost` report the actual spend. Blocker overflow is paged; label and timeline overflow is marked incomplete. A page costing more than 5 reported points is saved, then the job stops with `page_cost_exceeded`, including after restart.

Polling remains the webhook fallback. Delivery-speed cost evaluation resolves eligible merged-ticket identities (`issue_by_id`, plus tracker authorization reads). Review census on 2026-10-12: 526 merged PRs in 14 days, potentially 526 identities per evaluation; these lookups are not polling. Accounting is then queried once for the ticket set.

`observability.capture_github_facts` gates both analytics readers. Missing credentials and non-GitHub trackers disable history capture. Budget holds defer queued tickets; three failed PR reads record unavailable coverage. Other timeline failures back off from one minute to one hour.

Measured on aiur-team/aiur on 2026-10-11: facts cost 4 points before bounding branch candidates to five, then 1 point for #3797 (1,610 nodes). Timeline pages cost 1 point; 146 tags require at least two requests per hourly capture. Actual costs appear in `aiur github-cost`; no fleet saving is claimed.

The development `scripts/aiurdev --test` and `--test3` harnesses read GitHub issues but authorize only pinned tickets. Each scoped run gets private budget and state directories, and remote agents receive no GitHub credential. Ordinary runs keep normal discovery and remote credentials.

CI batches and landing require all ruleset checks on PR heads. Startup readiness uses operator-only `AIUR_CI_READINESS_TOKEN` (`ci gate` here) and reports unavailable without it. On a 401, main-watch names the applied credential; logs show a token fingerprint, never the token. Missing/skipped checks fail; lookup errors keep green aggregates pending.

Only required checks decide a failure: a red check that nothing requires does not send the ticket to rework. With no required list, every failure still decides.

Canceled runs get one exact-head rerun through the recovery journal. Landing watcher requeues approved PRs for infrastructure, inherited-base, or known non-PR failures. It requeues tests linked to an open flake issue or base failure in 24h; other failures route to rework with job details. It checks attribution and cancels stale groups.

An approved, clean PR whose queue head remains `UNMERGEABLE` for 20 minutes, or whose second failed merge-group run is at least 20 minutes old, is considered for one recovery.

The watcher accepts an observed `mergeable: UNKNOWN` while it gathers evidence, but the live queue read must still confirm a clean, mergeable PR and the same `UNMERGEABLE` entry before dequeueing.

Recovery requires evidence that the failure is infrastructure, inherited, or known non-PR; a failure selected by the PR diff is left for rework. Per-head verdicts are cached by workflow run ID: the first classification reads that run's jobs, failed-job logs, and PR changed paths; later polls reuse its stored verdict.

The recovery attention names failing tests and counts completed group rebuild runs for PRs that were behind the stuck head during the observed window.

The landing watcher quarantines a flaky test within 24 hours (caller `landing_watch_flake_gate` for the age check):

- **Qualifies:** a failure in two merge groups whose PRs did not touch the test, or one base-branch failure when that commit did not touch the test or its mirrored `src/lib` file.
- **Never counts:** a failure where the failing commit or the group's PRs changed the test file or the `src/lib` file it mirrors; a merge-group failure while the newest base-branch run fails that test (a regression for the main-watch fixer).
- **Actions:** each ExUnit row in `src/test/quarantine.txt` has four tab-separated fields: module, full test name, owner fix-ticket number, and ISO expiry date. The ticket owns that test's quarantine and carries its run links. A generated row defaults to a 90-day expiry. An auto-merging `aiur/quarantine/` PR adds the row; browser quarantine entries remain whole Playwright spec files in `src/browser/quarantine.txt`, as the shared `aiur-test-failure` reporter names them. Approved PRs whose merge group was dropped are requeued. No ticket is filed when every failing run is over 12 hours old or a newer base-branch commit changed the test file.
- **OrchestratorGuard:** the guard names the last test to finish, not the cause, so its failures only add run evidence to one `OrchestratorGuard` flake ticket and skip no test. The intentional-failure browser probes are never annotated.
- **Retries:** decisions come from the landing journal, so a GitHub error retries without new CI reads. Each step (quarantine PR, requeue, scan of a red base-branch commit) backs off from 1 to 32 minutes and stops after 7 failures in 24 hours with `system.pr.landing.quarantine_gave_up`. A retry reuses a quarantine branch that already holds the entry.
- **CI and expiry:** blocking CI skips listed tests. On main pushes the non-blocking `quarantined tests` job and a step of browser smoke shard 4 run them. Merging a fix PR or closing its owner ticket lifts the entry. Expiry decisions use per-test failure annotations from scheduled runs: three green runs lift an expired ExUnit row, while a failing run escalates only that test's owner ticket to `priority:1`. Unexpired rows are left alone. The hourly sweep reads up to 20 scheduled main CI runs and their job details. A local run of a quarantined test or spec skips it (browser runs print `Skipped by quarantine`) unless `AIUR_RUN_QUARANTINED=1` is set.

An approved PR that is not landing acts only when every failed required run has a non-PR cause. Infrastructure failures and known flakes are rerun.

A merge ref older than a base fix, a later merge that changed its workflow or a `.github/` or `scripts/` file its job uses, or a job the base workflow dropped is not rerun. Because a rerun reuses the old merge commit, the watcher updates the branch from the base instead.

On main CI recovery, the watcher checks approved auto-merge PRs for failures started after the first red workflow began and before recovery. It refreshes a branch when a failed run's merge ref predates the fix; otherwise it reruns that workflow. Each rerun uses one of three shared slots per 15 minutes; deferred run IDs stay scoped to recovery.

If the base changed the PR's own files, that refresh routes to rework instead. Other failures route to rework.

Agent pushes and `gh pr update-branch` check ticket labels via REST and refuse in `agent:ci-wait` or `agent:human-review`. Detached pushes use destination refs; `--repo` does not change the ticket. Rework is allowed. Current-branch pushes check queue status via GraphQL and refuse unless the PR conflicts or changes are requested. Failed lookups pass.

Draft PRs remain pending even with green checks. Mark completed work ready before CI wait; `ci gate` requires fast checks on PRs and full checks in the merge queue, or on policy-forced PRs. Main has no `ci` push run.

`ci-wait` and `human-review` hand-offs check drafts against a conditional repo-wide open-PR listing shared per poll cycle. Pull-request webhooks retire it. Pending drafts stay in human review. After `agent.ci_wait_rewake_minutes`, a CI-wait draft raises `ticket.<id>.pr.draft_ci_wait` until ready or outside CI wait. `aiur status` shows `draft_pr`.

Review polling keeps a per-ticket cursor seeded from its first cutoff; issue comments cannot advance it, and disabled or failed reads retain it. Polls in `agent:ci-wait` and `agent:human-review` route trusted `CHANGES_REQUESTED` and blocking `COMMENTED` reviews to `agent:rework`, including body-only reviews.

On `pull_request:synchronize`, Aiur compares an approved PR's old and new contributions. A changed or unreadable diff disarms auto-merge and raises `stale_approved_pr_head`; an identical diff leaves it armed.

Aiur retries a failed approval-state read twice, then raises `landing_withdrawal_failed` so an operator can inspect the PR and disable auto-merge if needed.

Trusted `CHANGES_REQUESTED` reviews also disarm auto-merge.

Body-only `COMMENTED` reviews need a line or heading starting with `Blocking:`, `Blockers:`, `Must fix:`, or `Changes required:`, or an update, rebase, merge, or fix requested “before merge”. Clean summaries such as “No blockers; waiting on CI” or “All blockers resolved” do not route to rework.

Failed CI in `agent:human-review` routes to rework when that head already passed CI or the head changed. An inherited failure on a dismissed head remains held; the existing test-only one-poll retry still applies.

This does not recover reviews that an older daemon already skipped before this cursor existed.

The repository events feed does not show a pull request going from draft to ready. Without a webhook, the polls infer it from each ticket PR's draft flag, which the comment poll and the CI poll already read.

A durable per-PR ledger records what they saw:

- `ticket.<id>.pr.ready_for_review` is published once per ready head, whether the poll or webhook sees the transition; a changed head can wake again.
- Webhook transitions seed the ledger; the shared dedup key prevents a later poll from replaying that same head as `initial_sync`.
- A ticket PR first seen already ready costs one issue-events read, once, to tell a former draft from a PR opened ready. A failed read is retried after a backoff, not on every poll.
- First-sight backfill wakes carry `observation: "initial_sync"`: review if not already reviewed. Observed draft-to-ready transitions carry no marker.
- Like the webhook, a PR opened ready gets no `ready_for_review`.
- The CI poll re-raises a ready PR in `human-review` after `agent.unreviewed_pr_age_limit_minutes` (default 120) when the current head is green and has no review on that head. Any review counts, whatever its state or author, so a bot comment on the head silences it; a `CHANGES_REQUESTED` decision from an older head does not. It repeats with the same interval until the head changes or receives a review; the attention names the PR, ticket, head SHA and age. Its ready timestamp and retry deadline survive daemon restarts.
- Wake records carry `head_sha` and, when cached review submissions provide it, `last_review_sha`; the Executor drops a ready wake when both match.

Where a webhook is proven, the comment sweep becomes a reconciliation pass rather than a second source. It still reads everything, but a comment a delivery already handled is not published twice, so an agent wakes once per comment rather than once per path. See [Comments arriving twice](/apis/github-webhooks#comments-arriving-twice).

The CI poll drops from its batch a target a `check_run` delivery already answered since the last read — the read is not bought again. Displacement is per target: a ticket with no delivery keeps its cadence, and only the read is skipped; no verdict is served from the held body. An unmatched check-run id keeps the target polled; polling stays the fallback.


## Build Order membership recovery

Build Order catalogs normally rebuild from stored issue and membership events. A daemon-owned membership reconciliation also reads GitHub in every webhook mode, including healthy and unproven delivery, because activity in other event families does not prove that sub-issue events arrived.

The safety check waits 15 minutes after a completed attempt, coalesces with in-flight reconciliation, and retains the held catalog on failure. Boot, explicit catalog refresh and delivery degradation can request earlier reconciliation.

Reconciliation replaces membership as one complete set. If GitHub returns only the first page of a root's sub-issues, Aiur reports incomplete membership and retains the held set instead of deleting unseen members.

If a membership edge changes while the GitHub read is in flight, the fetched set is discarded and a later scheduled attempt retries. This preserves newer webhook additions and removals without exposing an empty or partially rebuilt membership set.

If the membership store call times out or its owner exits, processing reports a membership-unavailable error instead of confirming the deposit. A timed-out call can still execute later; the error is not cancellation. HTTP admission remains separate and does not promise processing success.

These reads use the existing planning bounds and governed GitHub transport. This recovery adds bounded reads and claims no quota saving.

A stale single-root CLI read can separately refresh that root's graph. It respects provider retry delays and does not imply that catalog membership was refreshed at the same instant.


## Poll cadence

The cadence is per-state-class since #2309: each poll loop resolves its interval by naming the class it serves, and `polling.intervals` overrides `polling.interval_seconds` for one class while every unlisted class falls back to the scalar.

Poll spend still scales inversely with a class's interval, so `polling.interval_seconds` defaults to 120 — and the class that moves the most GraphQL spend is the one to widen, not the cheap tracker poll.

- **`dispatch`** — the tracker poll (open issues, `agent:*` labels). Cheap
  conditional REST (mostly free `304`s) and the dispatch trigger, so it stays at
  the base cadence and is the default for every unlisted class.
- **`ci`** — check state on a pull request with work in flight. Expensive
  GraphQL, but demand-scoped (only read while a PR is in flight) and deliberately
  left at the fallback: a wider `ci` would slow CI detection, which has
  agent-visible consequences.
- **`review`** — comments and review threads. Expensive GraphQL; webhooks cover
  comment *arrival*, so the poll is a safety net and minutes is defensible. The
  widening is enforced: a repo not proven webhook-backed keeps `review` at the
  dispatch rate (see below).
- **`planning`** — Build Order catalog and ticket history. The most expensive
  reads and the least urgent; recommended `0` (on-demand, no timer).
- **`firehose`** — repo events. Already self-regulating via GitHub's
  `X-Poll-Interval`; the class exists so `aiur status` can show its configured
  cadence, not to change its loop. Its loop is not gated on a class cadence — it
  rides the dispatch tick — so it stays at the fallback (`interval_seconds`).

The GitHub auth check runs once per credential, not once per sweep. It is re-run when the token or repository changes, and when a GitHub call answers `401` with the credential it proved — so a revoked token still produces the usual auth diagnostic rather than a raw failure downstream.

A CI poll failing with a GitHub broker timeout gets one immediate retry. If that also times out, it returns to the configured cadence. Shared-budget holds and other errors keep the normal cadence. Retries check all in-flight targets, adding at most 30 full-target polls per hour at a 120-second cadence.

Comments, reviews, watch-target discovery, strict commit CI reads, and merge-group run lists use conditional REST with `If-None-Match`. Unchanged answers return `304` and reuse only the matching held body; strict reads still contact GitHub on every poll. These requests do not count against the primary REST limit, and validators survive restarts.

When a worker starts or restarts, its bootstrap digest also re-reads the open PR's formal review submissions. This strict read revalidates the held review list with `If-None-Match`; a missing body or changed list is fetched from GitHub.

The digest includes body-only `CHANGES_REQUESTED` reviews and substantive `COMMENTED` reviews submitted after the latest Agent Workpad, subject to the same author trust filter as other GitHub feedback. A later approval or dismissal by that reviewer suppresses their earlier request.

### What a validator may answer

The savings above depend on the validator being the right one for the question asked. Two rules keep a `304` honest.

**A page-1 ETag cannot answer a multi-page question.**

GitHub orders issue timelines oldest-first and issue/PR listings by `created` desc. Changes can land beyond page 1, so a page-1 `304` means "page 1 is unchanged", never "the whole list is unchanged".

A page-1 `304` on a churned ticket cannot self-heal: the change that would refresh it lands on a later page.

Only trust a `304` for a paginated read when the read was single-page (then page 1 *is* the list), or when the validator kept is the last page's rather than the first's. If neither is practical, do not make the read conditional: an unconditional read that is correct beats a conditional one that is quietly wrong.

The open-PR branch lookup is a narrow exception: new PRs appear on page 1, so its validator changes. A later-page closure may remain visible until page 1 changes or a pull-request webhook arrives. This held listing serves only branch lookups, not general paginated-list queries.

Issue comments and PR changed files drain every page; single-list readers refuse a next page with `pagination_unexpected` rather than return a partial list.

**Incomplete label provenance is retried.** A new issue can carry `agent:todo`
before GitHub has indexed its `labeled` timeline event. Aiur does not cache a missing or malformed event as a final authorization decision. For a `todo`
ticket it defers dispatch and retries on the next candidate poll.

For active and rework tickets, Aiur still denies incomplete evidence. This preserves revocation after an unverified relabel.

Either incomplete result retires the daemon's cached reads for that issue number, including the timeline body. A webhook backed repository's hour-long
read TTL cannot replay the early snapshot.

The invalidation covers one issue number and may add a timeline request on each retry until the event appears, with further requests if the timeline spans
pages. No quota saving is claimed.

**A validator belongs to the thing it describes.**

A read of one resource earns a validator for that resource; a read of a query earns a validator for that query. Writing a query's validator into a resource's
key means any other writer of that key destroys or corrupts it.

A body change deletes the ETag, and a webhook deposit writes a body-derived validator that is then sent on a URL where it can never match — either way a
later conditional request is answered wrongly. Store a validator where the thing it describes lives, and only answer it against the read that earned it.

The ticket poll uses GraphQL to resolve which pull request belongs to a ticket and to read its inline review threads. Build history also uses bounded closed-issue catch-up, described below.

The batch previously fetched full comments and threads for every branch candidate. Before the sweep added cached approval, queue, and ready-time fields, a live ten-target measurement cost **11 points** versus **114** for that old shape. These historical figures do not measure the current expanded query.

Spend scales with target count, not with comment volume. The table below is for the **dispatch-class** cadence — the tick every poll loop rides.

A per-class entry in `polling.intervals` scales the same way for that class: halving a class's interval doubles its own spend, and the GraphQL pollers are
the classes worth widening (CI, comments/review threads, and previously the Build Order catalog, now event-sourced).

| `interval_seconds` | Approximate GraphQL spend | Worst-case wake latency |
| --- | --- | --- |
| 30 | ~1,300 points/hour | 30s |
| 60 | ~650 points/hour | 60s |
| 120 | ~330 points/hour | 2m |
| 300 | ~130 points/hour | 5m |

Figures are for a ten-target fleet. A busy repository raises REST request counts rather than GraphQL points, and most of those requests are `304`s.

GitHub also sends a 60-second `X-Poll-Interval` floor on the repo-events endpoint, and Aiur uses the wider of the two.

| Widening | Effect |
| --- | --- |
| Idle fleet (`polling.idle_widen_factor`, default 5.0) | Multiplies the effective interval while no agent is running and nothing dispatchable is waiting — turning the 120-second base into a 10-minute sweep. A live fleet with claimable tickets, or a freshly started daemon that has not yet observed a full idle cycle, keeps the base interval so work dispatches promptly (#2138). |
| Proven webhook repo (`webhooks.poll_widen_factor`, default 2.0) | Multiplies the interval for reconciliation polls. |
| Both active | Compose to `120s × 2 × 5 = 1,200s`; a wider GitHub rate-limit or connectivity floor still wins. |
| `aiur status` | Prints `POLL idle backoff active` with the base, effective interval, factor, and next sweep countdown. |

Dashboard state derives its staleness from the `dispatch` class (the cadence of the orchestrator snapshot it renders), and the Build Order catalog is event-sourced — its staleness and refresh bounds follow the `planning` class.

ExecutorList promotion candidates reuse the dispatch gate’s bounded `blocked_by` read (15-minute freshness, with early refresh on stale blocker evidence); unavailable or cross-repository edges hold promotion.

Dispatch declines a `todo` candidate with no validation read when fresh cached dependency evidence names an open blocker. Others validate in priority order; one whose evidence is past the 15-minute bound but last named an open blocker validates last. Neither step reads GitHub. Stale evidence only orders candidates: it never holds or releases a ticket.

`planning` is recommended as `0` (on-demand): its expensive query runs only when a page opens or a degradation needs a re-list.

<!--@include: ../.vitepress/includes/github-view-state.md-->

The ticket backlog, Ad Hoc overlay and Build Order catalog reach the page the moment a delivery deposits the changed issue; the sweep's only other steady-state cost is the single divergence-watermark head page on its own cadence, and pack status still reflects an outside change within one sweep.

| Immediate wake | Why idle backoff does not delay it |
| --- | --- |
| First startup sweep | Always immediate, and the first scheduling decision after a restart stays at the base interval (no idleness has been observed yet). |
| Verified label webhook, dashboard refresh | Wakes reconciliation at once. |
| `aiur --todo`, `aiur set max-agents`, global resume | Admission-changing actions request a fresh sweep, so a ticket is refreshed — and dispatched — before the backed-off timer can hold it up. `aiur --todo` also records the queued identifiers as known demand: the woken poll and one follow-up stay at the base interval even if GitHub has not yet indexed the label, and the command warns on stderr when the daemon did not accept the refresh. |

Aiur's poll is state-based, so a longer interval delays a wake without losing one; the exception is a comment posted and answered between two polls.
