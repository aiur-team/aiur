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

## Who Aiur trusts

| Source | Trust rule |
| --- | --- |
| Comment commands and review-driven rework | Accepted only from configured trusted accounts or the resolved CODEOWNERS set. |
| Unresolvable CODEOWNERS | Raises a degraded-trust alert instead of silently widening authority. |
| The bot identity | Cannot trigger its own work. |

## Poll cadence

Polling spends GraphQL points inversely to the interval, so `polling.interval_seconds` defaults to 120.

| `interval_seconds` | Approximate poll spend | Worst-case wake latency |
| --- | --- | --- |
| 30 | ~5,800 points/hour | 30s |
| 60 | ~2,900 points/hour | 60s |
| 120 | ~1,450 points/hour | 2m |
| 300 | ~580 points/hour | 5m |

At 30 seconds the poll loop alone can exhaust GitHub's 5,000 point/hour budget before an agent makes a request.

GitHub also sends a 60-second `X-Poll-Interval` floor on the repo-events endpoint, and Aiur uses the wider of the two.

| Widening | Effect |
| --- | --- |
| Idle fleet (`polling.idle_widen_factor`, default 5.0) | Multiplies the effective interval while no agent is actively running, turning the 120-second base into a 10-minute sweep. |
| Proven webhook repo (`webhooks.poll_widen_factor`, default 2.0) | Multiplies the interval for reconciliation polls. |
| Both active | Compose to `120s × 2 × 5 = 1,200s`; a wider GitHub rate-limit or connectivity floor still wins. |
| `aiur status` | Prints `POLL idle backoff active` with the base, effective interval, factor, and next sweep countdown. |

| Immediate wake | Why idle backoff does not delay it |
| --- | --- |
| First startup sweep | Always immediate. |
| Verified label webhook, dashboard refresh | Wakes reconciliation at once. |
| `aiur --todo`, `aiur set max-agents`, global resume | Admission-changing actions request a fresh sweep, so a ticket is refreshed before its first dispatch. |

Aiur's poll is state-based, so a longer interval delays a wake without losing one; the exception is a comment posted and answered between two polls.

## API budgets

| Budget | Unit | Where to read it |
| --- | --- | --- |
| Core | REST requests | The Units meter or `aiur units`. |
| GraphQL | Query points | The Units meter or `aiur units`. |
| Anonymous core | REST requests made without a token | A `core:anonymous` row, present only once an anonymous read has been observed. |
| Secondary limit | Temporary abuse-control backoff | A separate Units row while the backoff is active. |

Anonymous reads — a public `CODEOWNERS` fetch when no token is configured, for
instance — bill GitHub's 60/hour unauthenticated per-IP allowance rather than
the authenticated core budget, so they are metered in their own window. An
exhausted anonymous allowance holds further anonymous reads but never gates
agent dispatch.

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
