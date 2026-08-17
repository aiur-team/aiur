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

## Who Aiur trusts

| Source | Trust rule |
| --- | --- |
| Comment commands and review-driven rework | Accepted only from configured trusted accounts or the resolved CODEOWNERS set. |
| Unresolvable CODEOWNERS | Raises a degraded-trust alert instead of silently widening authority. |
| The bot identity | Cannot trigger its own work. |

## Poll cadence

Poll spend still scales inversely with the interval, so `polling.interval_seconds` defaults to 120.

Comments are read over conditional REST with `If-None-Match`. An unchanged comment list answers `304`, which does not count against GitHub's primary REST limit, so repeatedly sweeping quiet tickets is free rather than merely cheap. The validators are kept on disk, so a daemon restart does not force a full-price re-read.

GraphQL is now used only to resolve which pull request belongs to a ticket, and to read inline review threads for the pull request that resolved.

The old query attached full comment and review-thread selections to every speculative branch candidate, so identifying one pull request paid for the contents of up to ten. Measured against the live API with `rateLimit { cost }`, ten targets now cost **11 points** where that shape cost **114**.

Spend scales with target count, not with comment volume.

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
| Idle fleet (`polling.idle_widen_factor`, default 5.0) | Multiplies the effective interval while no agent is actively running, turning the 120-second base into a 10-minute sweep. |
| Proven webhook repo (`webhooks.poll_widen_factor`, default 2.0) | Multiplies the interval for reconciliation polls. |
| Both active | Compose to `120s × 2 × 5 = 1,200s`; a wider GitHub rate-limit or connectivity floor still wins. |
| `aiur status` | Prints `POLL idle backoff active` with the base, effective interval, factor, and next sweep countdown. |

Dashboard and Build Order state is not on this cadence.

| View state | Behaviour |
| --- | --- |
| Opening, focusing, or holding a page open | Zero API calls. |
| Ticket backlog, Ad Hoc overlay, pack status | Reconciled by one slow sweep, `polling.view_state_sweep_seconds` (default 900). |
| Comments, reviews and CI | Delivered free by webhook; the tracker poll recovers what a delivery loses. |

A change made outside Aiur reaches those three panels within one sweep rather
than at once, which is the trade for them costing nothing while nobody is
looking.

| Immediate wake | Why idle backoff does not delay it |
| --- | --- |
| First startup sweep | Always immediate. |
| Verified label webhook, dashboard refresh | Wakes reconciliation at once. |
| `aiur --todo`, `aiur set max-agents`, global resume | Admission-changing actions request a fresh sweep, so a ticket is refreshed before its first dispatch. |

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

If the record is unavailable or unreadable, Aiur behaves as though it were absent: it publishes, and the existing one-hour replay window catches short-range duplicates. A duplicate wake is recoverable; a dropped comment is not.

## One record for one resource

The record is not only a set of marks. Aiur keeps the resource GitHub returned — the comment, the issue, the pull request — addressed by what it is: type, owner, repository, id.

It is not addressed by which code path asked for it. So a resource read down one path answers every other path.

Each entry carries when it was recorded, which path recorded it, the resource's own `updated_at`, and an `ETag` where GitHub provides one.

When a path deposits the resource itself, that is written to disk alongside the marks, so a restart does not re-buy state the daemon already had. Keeping only the `ETag` would not achieve that: a validator sent for a resource Aiur no longer holds earns a `304 Not Modified` with no body — a spent request that returns nothing usable.

Every write that changes what a reader could see is announced, so anything watching that resource learns about it without asking GitHub. A change costs one API call at most, no matter how many things were watching.

The record is a cache, never the system of record. If it is cold, corrupt, or not running, every read behaves exactly as it did before it existed: Aiur fetches. A cache that cannot answer costs throughput, never correctness.

## Optional webhook

The webhook shortens reaction time for repository events while polling continues as a reconciliation path.

| Setting | Value |
| --- | --- |
| Payload URL | `https://hooks.aiur.dev/api/v1/github/webhook` |
| Content type | `application/json` |
| Secret | The same strong value exported as `AIUR_GITHUB_WEBHOOK_SECRET` to Aiur. |
| Signature | GitHub `X-Hub-Signature-256`, HMAC-SHA256 over the raw request body. |

`POST /api/v1/github/webhook` has no configuration keys and no bearer credential, authenticates every delivery by its `X-Hub-Signature-256` digest, and fails closed.

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

See [Configuration](/reference/configuration#webhooks) for the repository list, silence threshold, sweep interval, and widen factor.

## Cloudflare tunnel boundary

Cloudflare is transport for the GitHub webhook, not an API Aiur calls.

| Boundary | Operator requirement |
| --- | --- |
| Origin | Route the tunnel to the Aiur daemon at `127.0.0.1:4000`. |
| Public host | Serve the webhook at `hooks.aiur.dev`. |
| Reachable path | Route only `/api/v1/github/webhook`; finish the ingress list with a catch-all `404`. |
| Network | No inbound firewall rule is needed or wanted because `cloudflared` dials out. |

The path scope and webhook signature are independent locks:

| Lock | Protects against |
| --- | --- |
| Path-only tunnel routing | Public access to the dashboard and every other route on `127.0.0.1:4000`. |
| HMAC-SHA256 signature | Requests from anyone who does not know the shared webhook secret. |

Do not remove the catch-all `404`: the same origin serves the operator dashboard, and a host-wide tunnel would expose it to anyone who learned the hostname.
