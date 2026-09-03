# GitHub

Aiur reads GitHub to find work, follow each ticket, and return completed changes for review.

## What Aiur polls

| Poll | What it tracks | Why it exists |
| --- | --- | --- |
| Tracker state | Issue labels, active tickets, blockers, and pull requests | Keeps dispatch and the Units page aligned with GitHub. |
| Ticket branches | The validated ref and commit for each active ticket | Lets dependent agents inspect the exact code another ticket pushed. |
| Comments and reviews | Trusted issue comments, PR comments, reviews, and unresolved threads | Wakes the correct agent for operator direction or rework. |
| CI | Terminal checks while a ticket is in `agent:ci-wait` | Returns passed work for human review and failed work for repair. |
| Repository events | Default-branch pushes and opened or merged pull requests | Refreshes work whose base or review state changed. |

Polling remains the complete fallback because it reads current GitHub state even when no webhook is installed or a delivery is missed.

Where a webhook is proven, the comment sweep becomes a reconciliation pass rather than a second source. It still reads everything, but a comment a delivery already handled is not published twice, so an agent wakes once per comment rather than once per path. See [Comments arriving twice](#comments-arriving-twice).

The CI poll drops from its batch a target a `check_run` delivery already answered since the last read — the read is not bought again. Displacement is per target: a ticket with no delivery keeps its cadence, and only the read is skipped; no verdict is served from the held body. An unmatched check-run id keeps the target polled; polling stays the fallback.

## Who Aiur trusts

| Source | Trust rule |
| --- | --- |
| Comment commands and review-driven rework | Accepted only from configured trusted accounts or the resolved CODEOWNERS set. |
| Unresolvable CODEOWNERS | Raises a degraded-trust alert instead of silently widening authority. |
| The bot identity | Cannot trigger its own work. |

## GitHub App authentication

The daemon authenticates with a short-lived GitHub App installation token when App credentials are configured, and falls back to the `GITHUB_TOKEN` personal access token otherwise.

When no App credentials are set, a `GITHUB_TOKEN` env var is preferred, then the `gh` keyring (`gh auth login`). Installation tokens identify the machine integration, are scoped to one installation's repositories, and expire after about an hour.

### Set up the App

Create a GitHub App under **Settings → Developer settings → GitHub Apps** and install it on the target repository with only these repository permissions.

| Permission | Grant |
| --- | --- |
| Contents | Read and write |
| Issues | Read and write |
| Pull requests | Read and write |
| Administration, Actions, Secrets, Workflows | Never |

GitHub always adds `Metadata: Read-only` implicitly. Generate and download a private key (`.pem`); it can mint installation tokens for every repository the App is installed on, so keep it in a secure store.

### Configure the daemon

The daemon reads App credentials from the same `.env` the launcher sources; they are never written to `.aiur/config`.

| Variable | Purpose |
| --- | --- |
| `GITHUB_APP_ID` | The App's numeric id. |
| `GITHUB_APP_INSTALLATION_ID` | The installation id from the installation URL. |
| `GITHUB_APP_PRIVATE_KEY_PATH` | Path to the private-key PEM file; preferred. |
| `GITHUB_APP_PRIVATE_KEY` | Inline PEM alternative; use one or the other. |

`GITHUB_APP_PRIVATE_KEY_PATH` wins over the inline value so the key never appears in the process environment or shell history. When App credentials are configured, the daemon authenticates with a fresh installation token and ignores `GITHUB_TOKEN`.

The env token remains the fallback when no App credentials are present, followed by the `gh` keyring (`gh auth login`).

The keyring lookup (`gh auth token`) is bounded at boot, so a `gh` that stalls — a locked keyring prompting for a passphrase, a slow host, or a missing GUI credential agent — cannot hang the daemon with no log line.

The lookup logs before the shell-out and treats an unanswered lookup as "no keyring credential" (never a fatal error), naming `gh auth login` on timeout. The default bound is 5 seconds; set `AIUR_GH_KEYRING_TIMEOUT_MS` to a larger positive integer when a slow-but-succeeding unlock legitimately needs more time, or a smaller one to fail faster.

### Organization repository access during init

`aiur init` verifies that it can read the configured repository before it offers CI or label setup. GitHub deliberately returns `404 Not Found`, rather than `403 Forbidden`, for an inaccessible private repository, so a repository 404 is not proof that the repository or its base branch is missing.

Aiur checks the owner namespace and, when it can confirm an organization, reports an authorization diagnostic for the exact credential used by the probe.

The recovery depends on that credential:

- A classic PAT (`ghp_…`) needs the `repo` scope and SAML SSO authorization for the organization under **Settings → Developer settings → Personal access tokens → Tokens (classic) → Configure SSO**.
- A fine-grained PAT (`github_pat_…`) must use the organization as its resource owner, include the repository, and may need organization approval. A personal-owner token cannot be expanded to cover the organization's repositories.
- An OAuth token (`gho_…`) must belong to an OAuth app authorized for the organization. The `gh` CLI commonly uses a separate OAuth token from its keyring, so a successful `gh api` request does not prove that Aiur's configured token has the same access.
- A GitHub App installation token (`ghs_…`) requires the App to be installed on the repository with Contents read access.

If Aiur cannot confirm that the owner is an organization, it keeps the 404 ambiguous and asks you to verify both the repository name and token access.

### Token lifecycle

At boot the daemon signs an `RS256` JWT with the App private key and exchanges it at `POST /app/installations/{installation_id}/access_tokens`.

| Condition | Result |
| --- | --- |
| Refresh failure | Needs-attention `system.github_app_token.refresh_failed` alert with capped backoff retries. |
| Recovery | `system.github_app_token.refresh_recovered` clears the attention. |
| Grant beyond least-privilege | Needs-attention `system.github_app_token.permission_violation` alert. |

A supervised refresher re-acquires a fresh token before the hour-long expiry (5-minute safety margin) for the life of the daemon. The last known-good token keeps being used until it expires.

### Identity under App auth

An installation token authenticates as the App's bot user, `<app-slug>[bot]`, so every API-created comment, label, review, and pull request is attributed to that login.

| Setup | Requirement |
| --- | --- |
| `tracker.github.bot_account` | Set to the App's bot login, `<app-slug>[bot]`. |
| Unset or non-bot login | Needs-attention `system.github_app_token.identity_mismatch` alert at boot. |

Self-loop suppression, PR command handling, and the CODEOWNERS self-include all key off `bot_account`, so a wrong login means the daemon does not recognize its own writes.

Git commits keep their configured author; only GitHub API objects are authored by the App bot. Add the App bot login to `trusted_accounts` if any gate needs to trust it beyond the `bot_account` self-include.

See `docs/security/daemon-token-posture.md` in this repository for the full setup narrative.

## Poll cadence

The cadence is per-state-class since #2309: each poll loop resolves its interval
by naming the class it serves, and `polling.intervals` overrides
`polling.interval_seconds` for one class while every unlisted class falls back
to the scalar.

Poll spend still scales inversely with a class's interval, so
`polling.interval_seconds` defaults to 120 — and the class that moves the most
GraphQL spend is the one to widen, not the cheap tracker poll.

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

Comments, review submissions, and watch-target discovery are read over
conditional REST with `If-None-Match`. An unchanged answer returns `304`, which
does not count against GitHub's primary REST limit, so repeatedly sweeping quiet
tickets is free rather than merely cheap. Validators are kept on disk, so a
restart does not force a full-price re-read.

### What a validator may answer

The savings above depend on the validator being the right one for the question
asked. Two rules keep a `304` honest.

**A page-1 ETag cannot answer a multi-page question.**

GitHub orders most collections so page 1 becomes effectively immutable while
the interesting changes land elsewhere: issue timelines are oldest-first, and
issue and pull request listings are `created` desc. A `304` against a page-1
ETag therefore means "page 1 is unchanged" — never "the whole list is
unchanged".

A page-1 `304` on a churned ticket is permanently stale, with no self-healing,
because the change that would refresh it is exactly the change that lands on a
later page.

Only trust a `304` for a paginated read when the read was single-page (then
page 1 *is* the list), or when the validator kept is the last page's rather
than the first's. If neither is practical, do not make the read conditional:
an unconditional read that is correct beats a conditional one that is quietly
wrong.

**A validator belongs to the thing it describes.**

A read of one resource earns a validator for that resource; a read of a query
earns a validator for that query. Writing a query's validator into a resource's
key means any other writer of that key destroys or corrupts it.

A body change deletes the ETag, and a webhook deposit writes a body-derived
validator that is then sent on a URL where it can never match — either way a
later conditional request is answered wrongly. Store a validator where the
thing it describes lives, and only answer it against the read that earned it.

GraphQL is now used only to resolve which pull request belongs to a ticket, and to read inline review threads for the pull request that resolved.

The old query attached full comment and review-thread selections to every speculative branch candidate, so identifying one pull request paid for the contents of up to ten. Measured against the live API with `rateLimit { cost }`, ten targets now cost **11 points** where that shape cost **114**.

Spend scales with target count, not with comment volume. The table below is for
the **dispatch-class** cadence — the tick every poll loop rides.

A per-class entry in `polling.intervals` scales the same way for that class:
halving a class's interval doubles its own spend, and the GraphQL pollers are
the classes worth widening (CI, comments/review threads, and previously the
Build Order catalog, now event-sourced).

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

Dashboard state derives its staleness from the `dispatch` class (the cadence of
the orchestrator snapshot it renders), and the Build Order catalog is
event-sourced — its staleness and refresh bounds follow the `planning` class.

`planning` is recommended as `0` (on-demand), so the most expensive query in the
system runs only when a page opens or a degradation needs a re-list.

| View state | Behaviour |
| --- | --- |
| Opening, focusing, or holding a page open | Zero API calls. |
| Ticket backlog, Ad Hoc overlay, Build Order catalog | Event-sourced: every input is already deposited in the resource store by the webhook delivery before it is published, so a change made outside Aiur is reflected immediately, with no fetch. One listing per daemon boot establishes the baseline; a `webhooks` degradation re-lists while deliveries are known to be dropped, and recovery re-lists once more on the gap's trailing edge. A Build Order root's membership moves on the `sub_issues` delivery and a blocked-by edge re-reads the selected root on the `issue_dependencies` delivery. |
| Divergence watermark | On the same sweep cadence, one bounded `updated_at`-ordered head page of the open-issue listing. It does two jobs the deleted polls used to do: it records poller corroboration for the silence sweep (so an `issues` delivery loss can degrade the repo instead of looking like an idle one), and it re-lists the event-sourced sources when GitHub's newest open issue is newer than the store's — the proof that a delivery was dropped. One page, never a paged listing. |
| Pack status | Reconciled by one slow sweep, `polling.view_state_sweep_seconds` (default 900). The pack-status writer puts `status.json` on disk, so moving it to the event stream is a separate change. |
| Comments, reviews and CI | Delivered free by webhook; the tracker poll recovers what a delivery loses. |

The ticket backlog, Ad Hoc overlay and Build Order catalog reach the page the
moment a delivery deposits the changed issue; the sweep's only other
steady-state cost is the single divergence-watermark head page on its own
cadence, and pack status still reflects an outside change within one sweep.

| Immediate wake | Why idle backoff does not delay it |
| --- | --- |
| First startup sweep | Always immediate, and the first scheduling decision after a restart stays at the base interval (no idleness has been observed yet). |
| Verified label webhook, dashboard refresh | Wakes reconciliation at once. |
| `aiur --todo`, `aiur set max-agents`, global resume | Admission-changing actions request a fresh sweep, so a ticket is refreshed — and dispatched — before the backed-off timer can hold it up. |

Aiur's poll is state-based, so a longer interval delays a wake without losing one; the exception is a comment posted and answered between two polls.

## API budgets

| Budget | Unit | Where to read it |
| --- | --- | --- |
| Core | REST requests | The Units meter, `aiur units`, or `aiur github-cost --budget core`. |
| GraphQL | Query points | The Units meter, `aiur units`, or `aiur github-cost`. |
| Anonymous core | REST requests made without a token | A `core:anonymous` row, present only once an anonymous read has been observed. |
| Secondary limit | Temporary abuse-control backoff | A separate Units row while the backoff is active. |

Anonymous reads — a public `CODEOWNERS` fetch when no token is configured, for
instance — bill GitHub's 60/hour unauthenticated per-IP allowance rather than
the authenticated core budget, so they are metered in their own window. An
exhausted anonymous allowance holds further anonymous reads but never gates
agent dispatch.

### Where the budget went

The meters above say how much is left.

`aiur github-cost` says which code path spent it, ranked by points and by points
per hour, for one budget at a time.

| Column | What it means |
| --- | --- |
| `CALLER` | The code path that issued the call, not the ticket it was issued for. A batch query naming 33 tickets is one poller, so it is one row. |
| `POINTS` | What the calls cost the budget in the current window. |
| `POINTS/HR` | The rate the caller is running at, extrapolated from the elapsed part of the window rather than a whole hour. `unknown` when too little of the window has elapsed to extrapolate from. |
| `SOURCE` | `reported` when GitHub priced the call itself through a `rateLimit { cost }` selection in the query, `estimated` when it did not and the call is counted at one point. GraphQL queries are instrumented automatically; mutations and REST calls are counted per request. |

Below the ranking, one reconciliation line per budget compares the sum of the
rows against `limit - remaining` on the credential's own window:

| Line | What to do |
| --- | --- |
| `reconciles` | The ranking accounts for the window's spend. |
| `N points unattributed (spend outside this process)` | Expected. Anything else using the same credential — a shell `gh` call, another Aiur instance — is spend this process never saw. It bounds how much of the window the ranking explains. |
| `DOES NOT reconcile — attributed more than was spent` | A double count in the accounting. Points cannot be spent twice, so this is a defect worth reporting. |
| `not measurable` | No window has been observed yet. Not the same as zero spend. |

The command reads the meter the daemon already keeps and issues no GitHub
request of its own, so checking it is free.

### Reading these numbers without fooling yourself

Three traps have each cost a run more than an hour. All three produce a figure
that looks like a leak and is not.

**A daemon restart invalidates reconciliation for the rest of the window.**

The daemon's attribution window restarts with the process; GitHub's does not.
Points spent before the restart stay in `limit - remaining` and appear in no row
of the ranking.

So the unattributed figure is inflated by exactly that much until the GitHub
window rolls. Wait for the reset before comparing attribution against the
credential's window.

**The unattributed figure is not a leak.**

As the table above says, it is expected. It counts anything sharing the
credential that this process did not issue: a shell `gh` call, a script minting
its own installation token, another Aiur instance.

A monitoring loop sampling the API on the same credential *is itself*
unattributed spend, so an investigation can widen the gap it is measuring.
Baseline with the fleet quiet and your own tooling stopped.

**Agent `gh` calls do not bill the daemon's credential.**

Agents hold the bot PAT; the daemon under App auth holds an installation token.
Separate budgets, separate windows.

An agent-driven `gh pr view` never appears in the daemon's GraphQL ranking and
never spends the App pool. Agent activity correlating with App-pool spend means
something else scales with the fleet.

Related: a low read-cache hit rate is not automatically a defect. See
[Shared agent reads](#shared-agent-reads) for what the cache refuses on purpose
and why refusing is correct.

### Credential pooling

GitHub's budgets are per credential. An operator who holds more than one
credential can let the daemon spread read traffic across them instead of
exhausting one, by listing them under `tracker.github.credentials`:

```yaml
tracker:
  github:
    credentials:
      - id: app
        kind: app_installation
        identity: my-aiur[bot]
        writes: true
      - id: machine
        kind: machine_user
        identity: my-bot-account
        token_env: MACHINE_USER_TOKEN
        writes: true
      - id: operator
        kind: human
        identity: my-login
        token_env: OPERATOR_TOKEN
```

An empty list — the default — is the single-credential setup and is unchanged
by any of this.

For each request the daemon picks the eligible credential with the most
remaining budget for that request's resource.

Core and GraphQL are chosen separately. They are separate budgets on separate
windows, so REST core sitting near-idle is not headroom a GraphQL query can
spend.

Headroom comes from the `x-ratelimit-*` headers of calls the daemon was already
making, so selection costs no budget of its own.

A credential with no observation this window is treated as probably full rather
than as empty, and ties resolve to the primary credential.

`aiur github-usage` grows a per-credential section and a pool total. Both
commands show them only when more than one credential is configured.

#### Writes stay on their own identity

A `human` credential is read-only and cannot be configured otherwise.

Every write GitHub records against a person's token is attributed to that
person: their name on the comment, their account in the audit trail.

Aiur's merge policy also depends on agent pull requests and the reviewing human
being different identities. Pooling writes would break that at random.

Pool the reads, which is where the budget actually goes. Leave comments, labels,
merges and pull request creation where they belong.

#### What pooling is worth

Each credential carries its own hourly budget, so three credentials raise the
ceiling roughly threefold.

That is headroom, not a fix. A fleet burning more than its combined ceiling
still exhausts it, just later.

The pool total is also a ceiling rather than a balance, because the credentials'
windows reset at different moments. Pooling buys margin while the burn itself is
reduced.

## Comments arriving twice

A comment can reach Aiur down two paths: a webhook delivery, which is free and arrives first, and the comment sweep, which reads it back from the API.

Both must exist. Deliveries are genuinely lost — measured here, 9 of 100 returned `502` during a daemon restart, GitHub retried none, and none arrived later. A sweep that skipped webhook-backed repositories would drop those comments silently.

Aiur therefore records each comment it has processed by its identity, and both paths write to the same record.

| Situation | What happens |
| --- | --- |
| Delivery arrives | The comment is published once. The next sweep reads it, recognises it, and does not publish it again. |
| Delivery is lost | Nothing recorded it, so the next sweep publishes it. No delay beyond one poll interval. |
| Older comment lost, newer one delivered | The older one is still recovered. Suppression is per comment, not "everything before the newest thing I saw". |
| Daemon restarts | The record is on disk, so a comment handled before the restart is not re-published after it. |
| A comment is edited | The agent wakes again. The record stores the comment's `updated_at`, so an edit is a new state of that comment rather than a repeat of it. |
| No webhook installed | Nothing is ever recorded by a delivery, so nothing is ever suppressed. Polling behaves exactly as it did before. |

Inline review comments on a pull request coalesce per **review thread**, not per comment. A review thread is one finding plus its replies, so a reviewer adding several comments to one thread wakes the agent once.

The webhook resolves a delivered comment's thread from the comment's own node id, so both pipes key inline feedback the same way. A follow-up comment on an already-woken thread within the one-hour replay window does not wake a second time; it wakes once the thread is re-read after the window passes.

If the delivery cannot be resolved to a thread, it is keyed on its own comment id as before — a duplicate wake is recoverable, a dropped delivery is not.

If the record is unavailable or unreadable, Aiur behaves as though it were absent: it publishes, and the existing one-hour replay window catches short-range duplicates. A duplicate wake is recoverable; a dropped comment is not.

## One record for one resource

The record is not only a set of marks. Aiur keeps the resource GitHub returned — the comment, the issue, the pull request — addressed by what it is: type, owner, repository, id.

It is not addressed by which code path asked for it. So a resource read down one path answers every other path.

Each entry carries when it was recorded, which path recorded it, the resource's own `updated_at`, and an `ETag` where GitHub provides one.

When a path deposits the resource itself, that is written to disk alongside the marks, so a restart does not re-buy state the daemon already had. Keeping only the `ETag` would not achieve that: a validator sent for a resource Aiur no longer holds earns a `304 Not Modified` with no body — a spent request that returns nothing usable.

Every write that changes what a reader could see is announced, so anything watching that resource learns about it without asking GitHub. A change costs one API call at most, no matter how many things were watching.

A webhook delivery is the cheapest writer of all — GitHub has already paid for the round trip, and the delivery arrives before any sweep would have read the same object — so every delivery for a tracked repository deposits the state it carries, whether or not it also wakes an agent.

| Delivery | What it deposits |
| --- | --- |
| Any comment activity | The issue or pull request the comment hangs off, with its label set. |
| Comment created or edited | That comment as well. |
| Review submitted, edited or dismissed | The review, and the pull request. |
| Pull request, any action | The pull request — including a `synchronize` push, which wakes CI reconciliation rather than publishing. |
| Issue, any action | The issue and its label set, whether or not the action is one Aiur reacts to. |
| Check run | The matching run inside a complete CI-context snapshot already established for the same head. A lone delivery never invents the rest of the collection. |
| Review thread resolved | The matching thread inside a complete review-thread snapshot already established for the pull request. |
| A comment or issue is deleted | Nothing is deposited and the held body is discarded, because serving an object that no longer exists is worse than not holding one. |
| A delayed delivery carrying older state | Refused. A body cannot walk a resource backwards and then be reported as freshly fetched. |

A deposit records what Aiur is *holding*, never what it has *handled*. The two are separate facts: only a successful publish marks a comment processed, so caching a body can never suppress the event for it — including for a change Aiur made itself, where the body is cached and the self-loop stays filtered.

The record is a cache, never the system of record. If it is cold, corrupt, or not running, every read behaves exactly as it did before it existed: Aiur fetches. A cache that cannot answer costs throughput, never correctness.

Comment, CI, and review-thread pollers consult these complete snapshots before
building their GraphQL documents. A poll-written snapshot is only a baseline;
it does not suppress the next poll. When a verified delivery advances that
baseline, the matching collection is eligible for 30 seconds.

During that window Aiur omits `reviewThreads` or the delivered `CheckRun`
fields. Legacy commit statuses, `reviewDecision`, `mergeable`, and other strict
verdict state remain live reads.

Successful polls write complete selections back so the next delivery and poll
converge on the same state. Partial, stale, poll-only, head-mismatched, or
unavailable entries fall back to GitHub. A review-comment delivery invalidates
the complete thread snapshot because one comment cannot prove the collection.

## Shared agent reads

Agents run `gh` through a wrapper that keeps the answers, so the next agent
asking the same question is served the first agent's answer — the exact output
the first call produced, replayed byte for byte.

These reads are shared:

| Read | Shared |
| --- | --- |
| `gh pr view`, `gh issue view` with `--json` and a number | Yes |
| `gh pr list`, `gh issue list` with `--json` | Yes |
| `gh api` GET of a repository endpoint | Yes |
| A CI or merge verdict — `gh pr checks`, or `--json` asking for `statusCheckRollup`, `mergeable`, `mergeStateStatus`, `state`, `reviewDecision` and their like | No; never shared, at any age |
| Anything else — no `--json`, `gh pr diff`, `gh api graphql`, every write | No; the call goes to GitHub as before |

A verdict is refused rather than kept briefly because a push and a completing
check run do not pass through the wrapper, so nothing could retire the answer
before an agent acted on it.

The same refusal applies to direct REST paths for check runs, check suites,
commit statuses, reviews, requested reviewers, the pull-request resource
itself, merge state, and Actions run or job state. Spelling a verdict read as
`gh api` does not make it safe to cache.

Stable Actions workflow *definitions* (`actions/workflows`) are still shared.

A workflow definition changes when its YAML is edited, which is a
wrapper-passing write that retires it, while a run's status is a verdict that
nothing retires. This is a deliberate divergence from the daemon's `ReadCache`
policy, which refuses every `/actions` path wholesale — the two stores serve
different callers with different invalidation reach.

An answer is kept for 60 seconds.

**Conditional requests and 304s.** `gh api` reads carry a validator where the
store holds one: a re-read sends `If-None-Match` with the entry's stored `ETag`,
and an unchanged answer returns `304`, is served from the cache, and is
reconciled free — the same contract as the daemon's REST reads.

The high-level subcommand reads — `gh pr view`, `gh pr list`, `gh issue view`,
`gh issue list` — hit GitHub's GraphQL endpoint, which returns no `ETag` and no
`Last-Modified`, so there is no validator for the store to send. Those entries
stay TTL-cached with invalidation markers.

When a high-level read does return a `304` (an underlying REST read), the
wrapper reconciles the lease as free rather than billing it full-price.

The free share a TTL body cache cannot recover is GraphQL's — which no cache on
either side can recover.

The GitHub cache page reports whether this sharing is effective. Its **Agent gh
exact-shape hit rate** is `hits / (hits + misses)` over the previous 24 hours,
alongside the raw hit and miss counts.

It reads the durable `agent-cache.tsv` counters from agent workspaces on the
daemon host; workspaces on remote SSH workers are not included.

If no readable counter exists, or the readable files contain no hit or miss in
that window, the page says **Not measured** instead of presenting zero as a
measurement. Malformed or unreadable sources are retained as partial coverage
rather than hiding the valid samples.

The cache key intentionally includes the exact requested output shape. Two
reads of one pull request that request different JSON fields, templates, or
queries cannot share an answer without changing `gh`'s output, so each shape
misses independently.

Likewise, a write or daemon delivery retires every shape of the changed
resource to protect correctness.

Different output requests cannot share bytes, and a changed resource cannot
safely reuse an older answer. The cache therefore keeps its byte-exact key,
correctness invalidation, and 60-second lifetime.

The wrapper now records a reason with every miss (`absent`, `expired`,
`invalidated`, `bypassed`, `clock-skewed`, `corrupt`, or `torn`).

That lets a later regression distinguish expected correctness misses from
entries expiring before reuse, and can tell a cold cache from a
store-integrity failure — a present stamp whose body has vanished is `torn`,
never `absent`.

Editing a ticket or a pull request discards the kept answers for it at once, so
an agent never reads back what it just replaced.

So does anything the daemon learns about that resource — a webhook delivery, a
comment Aiur posted itself. That is what lets a free delivery stop sixteen agents
paying to discover the same change.

Agents that ask **at the same moment** are also one call, not many.

Thirteen agents opening the same pull request in the same second cannot be helped
by a kept answer, because none exists yet when they all look. One is admitted to
fetch and the rest wait behind it, then read what it wrote.

If the admitted one never answers, the others stop waiting and fetch. The cost is
the single call the waiting was meant to save, never a stall.

Sharing is controlled by these settings:

| Setting | Effect |
| --- | --- |
| `AIUR_GITHUB_STATE_CACHE_ENABLED=0` | Turns sharing off; every call goes to GitHub. |
| `AIUR_GITHUB_STATE_CACHE_BYPASS=1` | Makes one call ignore kept answers, for a decision that must not be stale. |
| `AIUR_GITHUB_STATE_CACHE_TTL_MS` | How long an answer is kept, in milliseconds, rounded down to whole seconds. Below 1000 keeps nothing. |
| `AIUR_GITHUB_STATE_CACHE_WAIT_MS` | How long an agent waits for another agent's identical call before making its own. |

If the store is missing or unwritable, every call behaves as it did before.

Sharing is between the agents on one host that use the same GitHub credential —
the same boundary the shared request budget draws. A second credential keeps its
own answers, because a response can depend on who asked.

A change made outside those agents — a merge from the web UI, a label set by
somebody else — is not seen by the wrapper. Aiur learns of it through the webhook
or the next poll and retires the affected answers then.

That gap is the exposure, and it is why a verdict is never kept at all.

## What the agent guard governs

Agent processes do **not** inherit `GITHUB_TOKEN` or `GH_TOKEN`. The daemon
scrubs them from every agent environment and instead writes the bot PAT to a
credential file (`~/.aiur/github-budget/agent-token`) that the `gh` guard
reads.

The wrapper injects the credential only into the real `gh` process it spawns
for a governed call, for the duration of that call — never into the agent's
environment and never into the sibling processes the wrapper launches.

So `env | grep -i -E 'GITHUB_TOKEN|GH_TOKEN'` in an agent shell returns
nothing, and a bare `curl` to `api.github.com` from an agent workspace is
unauthenticated.

This is a **policy boundary, not a capability boundary.** Agents run as the
same OS user as the daemon, so an agent that deliberately goes looking can read
the credential file, the shared budget database, or the operator keyring.

What the file removes is the raw token from the *environment* of every agent
process — where a dependency's build script, a `curl` one-liner, or a Node
fetch would inherit it — and the broker ledger counts the governed calls, not
every request a determined agent could make.

| Path | Governed by the guard |
| --- | --- |
| `gh` on the agent's PATH (the wrapper in the workspace `.aiur-runtime/bin`) | Yes — rate-limited, metered, and recorded in the broker ledger. |
| `git` on the agent's PATH (the wrapper in the workspace `.aiur-runtime/bin`) | Yes — destructive-command protection, not quota. |
| `gh`/`git` invoked by absolute path (`/usr/bin/gh`), or after a `PATH` reset | No — but unauthenticated, because the environment carries no token and the agent's `GH_CONFIG_DIR` is empty. |
| Any direct-HTTP client — `curl`, `Req`, a Python script, a Node fetch | No — unauthenticated from an agent workspace. |
| The daemon's own GitHub traffic | No — it runs as the daemon's own credential (the App installation token under App auth), a separate budget pool. |

## Changes Aiur makes itself

There is a third path, and it is the cheapest one: a change Aiur makes.

Aiur posts comments, applies and removes labels, closes tickets, repairs pull request bases, declares dependencies, and replies to and resolves review threads. GitHub's answer to each of those requests already contains the new state, and Aiur keeps it.

The round trip was required by the write, so learning its result costs nothing extra. No later read is spent discovering a change Aiur made.

Two consequences:

| Situation | What happens |
| --- | --- |
| A view is showing the resource | It updates from the write, with no API call of its own, and before any webhook for that change could arrive. |
| The webhook for that change arrives | It is recognised as already handled and wakes nobody. An agent is never re-woken by its own comment or its own review reply. |
| A label or a close is delivered | It reconciles state rather than waking anybody, so an orchestrator label write cannot wake the agent that state belongs to. |

Suppression here is per resource **and per version**, as above. A later edit of that same comment moves its `updated_at`, so it wakes the agent normally.

Where GitHub's answer cannot name a version — the label endpoints return the label array and nothing else — Aiur keeps the state but suppresses nothing. The resource's next genuine change is never swallowed.

Such a write still records the marker of the snapshot it was applied to, rather than recording nothing. That is what keeps "a delayed delivery carrying older state is refused" true afterwards: staleness is judged against the marker on the record, so a record left unmarked would accept every late delivery instead of refusing the old ones.

A label write also corrects the labels on the issue Aiur already holds, and does so as one indivisible step. Reading the issue, changing it, and writing it back as separate steps would let a delivery that landed in between be overwritten by the older copy — including its `open` or `closed` state.

A write that fails records nothing.

## Optional webhook

The webhook shortens reaction time for repository events while polling continues as a reconciliation path.

| Setting | Value |
| --- | --- |
| Payload URL | `https://<your-host>/api/v1/github/webhook` |
| Content type | `application/json` |
| Secret | The same strong value exported as `AIUR_GITHUB_WEBHOOK_SECRET` to Aiur. |
| Signature | GitHub `X-Hub-Signature-256`, HMAC-SHA256 over the raw request body. |
| Events | `issues`, `issue_comment`, `pull_request`, `pull_request_review`, `pull_request_review_comment`, `pull_request_review_thread`, `check_run`, and `check_suite`. |

The hostname is yours to choose — `hooks.aiur.dev` is this operator's setup, not a requirement. Without a domain, a quick tunnel (`cloudflared tunnel --url`) exposes the daemon on a temporary public URL, fine for a single session.

`POST /api/v1/github/webhook` has no configuration keys and no bearer credential, authenticates every delivery by its `X-Hub-Signature-256` digest, and fails closed.

Select every event listed above so a `pull_request_review_thread` delivery reconciles resolved or reopened threads immediately while the scheduled comment sweep remains the loss-recovery path.

| Delivery | Result |
| --- | --- |
| Signature header absent, malformed, or mismatched | Rejected with `401`. |
| `AIUR_GITHUB_WEBHOOK_SECRET` unset or blank | Rejected with `401` and a needs-attention `system.github_webhook.secret_missing` alert; an unset secret never enables unsigned access. |
| Legacy SHA-1 `X-Hub-Signature` header | Ignored; never accepted as a fallback. |
| Body larger than 25 MB | Refused, matching GitHub's own delivery ceiling. |

| Webhook state | Polling behavior |
| --- | --- |
| Not configured | Polls at `polling.interval_seconds`. |
| Configured but never delivered | Polls at the full interval until a verified delivery proves the path works. |
| Delivering | Uses the configured `webhooks.poll_widen_factor` for slower reconciliation polls. |
| Silent past the threshold | Returns to full polling and raises an attention; a later delivery restores webhook mode. |

A proven webhook also lengthens the daemon's read-cache TTL: a delivering repo gets hour-long `ReadCache` TTLs, because a delivery retires the reads it makes stale — the TTL is only a backstop.

A repo that is not proven (or degraded back to full polling) keeps 30-second TTLs, and degradation collapses the TTL immediately.

Repository-configuration reads are the one exception: branch protection, rulesets and workflow-file reads (`:repo_config`) ride a five-minute TTL in polling mode and still rise to an hour under a proven webhook, because every delivery also retires a repository's config reads.

See [Configuration](/reference/configuration#webhooks) for the repository list, silence threshold, sweep interval, and widen factor.

## Cloudflare tunnel boundary

Cloudflare is transport for the GitHub webhook, not an API Aiur calls.

| Boundary | Operator requirement |
| --- | --- |
| Origin | Point the tunnel at whatever address the daemon actually bound: `127.0.0.1` on the pinned `server.port` by default, or the `server.host` address if you pinned one. Pin `server.port` to a fixed value first — the default `0` binds a fresh OS port each boot. A `502` means the tunnel aims somewhere the daemon is not listening. |
| Public host | Serve the webhook at a hostname you control (`hooks.aiur.dev` here); without one, a quick tunnel (`cloudflared tunnel --url`) works for a single session. |
| Reachable path | Route only `/api/v1/github/webhook`; finish the ingress list with a catch-all `404`. |
| Network | No inbound firewall rule is needed or wanted because `cloudflared` dials out. |

The path scope and webhook signature are independent locks:

| Lock | Protects against |
| --- | --- |
| Path-only tunnel routing | Public access to the dashboard and every other route served on the daemon's bound address. |
| HMAC-SHA256 signature | Requests from anyone who does not know the shared webhook secret. |

Do not remove the catch-all `404`: the same origin serves the operator dashboard, and a host-wide tunnel would expose it to anyone who learned the hostname.
