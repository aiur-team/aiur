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

## API budgets

| Budget | Unit | Where to read it |
| --- | --- | --- |
| Core | REST requests | The Units meter or `aiur units`. |
| GraphQL | Query points | The Units meter or `aiur units`. |
| Secondary limit | Temporary abuse-control backoff | A separate Units row while the backoff is active. |

## Optional webhook

The webhook shortens reaction time for repository events while polling continues as a reconciliation path.

| Setting | Value |
| --- | --- |
| Payload URL | `https://hooks.aiur.dev/api/v1/github/webhook` |
| Content type | `application/json` |
| Secret | The same strong value exported as `AIUR_GITHUB_WEBHOOK_SECRET` to Aiur. |
| Signature | GitHub `X-Hub-Signature-256`, HMAC-SHA256 over the raw request body. |

`POST /api/v1/github/webhook` rejects a missing, blank, malformed, or mismatched secret with `401`; an unset `AIUR_GITHUB_WEBHOOK_SECRET` never enables unsigned access.

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
