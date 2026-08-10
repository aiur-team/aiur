# GitHub webhook ingress

How GitHub reaches the daemon's webhook receiver from the public internet, what
that does and does not expose, and how to set it up on a new machine.

The receiver itself — the route, the HMAC verification, the secret name — is
documented by [#1676](https://github.com/aiur-team/aiur/issues/1676) in
[the configuration reference](../../website/docs-app/reference/configuration.md).
This document covers only the ingress in front of it.

> **Status.** The recommendation below is Cloudflare Tunnel with path-scoped
> ingress, recorded in
> [#1677](https://github.com/aiur-team/aiur/issues/1677). The security
> requirements and the verification step apply to any option; only the
> "Set up the tunnel" section is vendor-specific.

## Why this needs a decision at all

The daemon binds loopback. Making it reachable from the internet is a change in
deployment shape, not a config toggle, and the naive version of it is actively
dangerous. Two properties of the daemon drive everything here.

**One listener serves everything.** `AiurWeb.Router` mounts the LiveView
dashboard at `/`, `/decisions`, `/build-orders`, `/analytics` and `/streamdeck`,
the Supervisor Decision API under `/api/v1/decisions/*`, and the agent-control
routes under `/api/v1/*` — all on the same port the webhook receiver will use.
There is no second listener to expose in isolation.

**On loopback that listener is unauthenticated by design.**
`Aiur.HttpServer.start_link/1` computes
`dashboard_auth_required: dashboard_writable or not loopback?(ip)`, and
`AiurWeb.FinancialDataAccess.authenticate_request/2` passes the connection
through untouched when no credentials are configured. The boot guard only
refuses a *non-loopback* or *writable* bind without credentials — a read-only
loopback dashboard starts with no auth at all, deliberately.

Put those together: `cloudflared tunnel --url http://localhost:4099`, the
one-liner every tunnel tutorial opens with, publishes an unauthenticated Aiur
control plane. It does not trip the boot guard, because the process still bound
loopback. **Exposure must therefore be scoped at the tunnel, and the tunnel must
default-deny.**

## Options considered

| | Stable URL | Scoped to one route | Cost | Survives daemon downtime |
| --- | --- | --- | --- | --- |
| **A. Cloudflare Tunnel (named)** | yes, a DNS record you own | native ordered `ingress:` rules with a `http_status:404` catch-all | free; needs a domain with DNS on Cloudflare | no |
| A′. Tailscale Funnel | yes, `<node>.<tailnet>.ts.net` | `--set-path` mounts, but the mount prefix is stripped | free | no |
| A″. ngrok | free tier includes one static domain | path filtering needs Traffic Policy | free tier caps at 20K requests/month | no |
| B. Hosted relay | yes | yes, hand-written | an always-on host, a second deploy artifact, a second secret boundary | yes |
| C. Poll a relay's queue | n/a | n/a | same relay cost as B | yes |

**A was chosen.** B's only advantage over A is surviving daemon restarts, and
that is already covered: [#1675](https://github.com/aiur-team/aiur/issues/1675)
keeps polling as a reconciliation sweep precisely because webhooks are missed
while the daemon is down, and W-5 owns recovery. Buying a relay to solve it
again spends the currency the epic is short of — operational surface — on a
problem that already has an owner. A relay that is down also loses deliveries;
it moves the outage rather than removing it.

C is dominated. It needs all of B's infrastructure, and its distinguishing
benefit — never exposing the daemon — is one A already provides: with
path-scoped ingress the daemon keeps its loopback bind and `cloudflared` dials
*outward*, so no inbound port exists. C then pays that cost and reintroduces
polling, which is the thing the epic exists to stop.

Cloudflare over Funnel and ngrok because its ingress rules are a first-class,
ordered, default-deny router, and `cloudflared tunnel ingress rule <url>` proves
which rule a URL hits without sending a request. Funnel is the fallback if you
do not want to move a domain's DNS to Cloudflare; note that its `--set-path`
mount strips the prefix, which has to be accounted for against a fixed webhook
path.

**Known and accepted:** deliveries that arrive while the daemon is down are
lost. That is expected under A. Do not work around it here — the reconciliation
sweep recovers them.

## Prerequisites

### Pin the daemon's port

`Aiur.Config.Schema.Server` defaults `port` to `0`, which means "bind a free
OS-assigned loopback port". On the default config **the daemon binds a different
port on every restart**, and a stable public hostname in front of a moving
origin just starts returning 502.

Pin it in `.aiur/config` before configuring any tunnel:

```yaml
server:
  port: 4099
  host: 127.0.0.1
```

Leave `host` on loopback. The tunnel connects from the same machine; nothing
needs to bind a routable interface, and binding one would additionally require
dashboard Basic Auth credentials to satisfy the boot guard.

This is what makes "restarting the daemon does not change the webhook URL"
true. It is the prerequisite, not a detail.

### Generate the webhook secret

At least 32 bytes from a CSPRNG. Do not reuse `GITHUB_TOKEN`, the App private
key, or `AIUR_SUPERVISOR_TOKEN` — the webhook secret is verified by a different
party for a different purpose, and sharing it would let a webhook-secret leak
become a repository-write leak.

```sh
umask 077
printf 'AIUR_GITHUB_WEBHOOK_SECRET=%s\n' "$(openssl rand -hex 32)" >> ~/.aiur/.env
chmod 600 ~/.aiur/.env
```

Read the value back out of `~/.aiur/.env` when configuring the webhook in
GitHub. Never paste it into a commit, a ticket, a PR, or a log line.

## Set up the tunnel

Assumes a domain whose DNS is served by Cloudflare. `<domain>` is that domain
and `<tunnel>` is a name of your choosing.

```sh
cloudflared tunnel login
cloudflared tunnel create <tunnel>
cloudflared tunnel route dns <tunnel> hooks.<domain>
```

`create` writes a credentials file under `~/.cloudflared/` and prints the tunnel
UUID; `route dns` creates the CNAME. The hostname is stable from here on — it
does not change when the tunnel process or the daemon restarts.

Write `~/.cloudflared/config.yml`:

```yaml
tunnel: <tunnel-uuid>
credentials-file: /home/<user>/.cloudflared/<tunnel-uuid>.json

ingress:
  # The only published route. `path` is a Go regexp; anchor both ends so it
  # cannot match a longer path that merely contains this one.
  - hostname: hooks.<domain>
    path: ^/api/v1/github/webhook$
    service: http://127.0.0.1:4099

  # Default deny. Everything else -- the dashboard, the Decision API, every
  # other /api/v1/* route -- is answered at Cloudflare's edge and never reaches
  # the daemon. This also means a route added to the router later is not
  # silently published.
  - service: http_status:404
```

Check the rules before running anything. `cloudflared` evaluates them top to
bottom and reports the first match, without sending a request:

```sh
cloudflared tunnel ingress validate
cloudflared tunnel ingress rule https://hooks.<domain>/api/v1/github/webhook  # -> the service rule
cloudflared tunnel ingress rule https://hooks.<domain>/                       # -> http_status:404
cloudflared tunnel ingress rule https://hooks.<domain>/api/v1/state           # -> http_status:404
```

Then install it as a service so it comes back after a reboot:

```sh
sudo cloudflared service install
sudo systemctl enable --now cloudflared
```

## Configure the GitHub webhook

On the GitHub App (or the repository's webhook settings):

- **Payload URL:** `https://hooks.<domain>/api/v1/github/webhook`
- **Content type:** `application/json`
- **Secret:** the value of `AIUR_GITHUB_WEBHOOK_SECRET`
- **SSL verification:** enabled

Subscribe only to the events the fleet consumes. Every unused event costs no
quota but still costs parsing, log volume, and payload surface. The starting
set, which W-3 finalises:

| Event | Why |
| --- | --- |
| `issue_comment` | agent instructions and firehose comments |
| `issues` | `labeled`, `unlabeled`, `closed` drive the agent lifecycle |
| `pull_request_review` | wakes agents paused on review |
| `pull_request_review_comment` | review feedback threads |
| `check_suite` | CI completion |
| `check_run` | CI completion |

Do not select "Send me everything."

## Register the repo for webhook delivery

Ingress only carries deliveries to the daemon. Telling the fleet that a repo is
*expected* to be webhook-backed is a separate config key, added by #1734:

```yaml
webhooks:
  repos:
    - owner/name
```

Listing a repo is a hint, never a promise. It starts in `configured_unproven`
and keeps polling at full rate until a verified delivery actually arrives; if a
proven repo then goes silent past `silence_threshold_seconds` (default 900) it
degrades back to full polling and raises a needs-attention alert naming the
repo. `poll_widen_factor` defaults to `1.0`, so registering a repo here changes
no poll interval on its own — widening intervals is the cutover ticket's call.

It doubles as the end-to-end confirmation that ingress works: once a verified
delivery lands, the agent-control `usage` view (`Aiur.AgentControlCLI.usage/2`,
rows from `Aiur.Webhooks.ModePresenter`) prints an
`events <repo> <mode> last delivery <age>` line. A repo still reading
`configured_unproven` after a redelivery means the delivery is not reaching the
receiver — check the ingress rules before suspecting the verifier.

## Verify the scoping

Setting the ingress rules is not evidence that they hold. Run the guard against
the live public hostname:

```sh
scripts/verify-webhook-ingress https://hooks.<domain>
```

It asserts that `POST /api/v1/github/webhook` is reachable and answers `401` to
an unsigned body — the receiver is live *and* still fails closed — and that the
dashboard, the Decision API and the other `/api/v1/*` routes are not routable by
the same hostname. It exits non-zero if any of that is untrue.

Its own assertions are covered by `scripts/test-webhook-ingress.sh`, which runs
the guard against loopback fixtures modelling a correctly scoped edge, a
wide-open one, and a receiver that accepts unsigned deliveries. That runs in CI.

Finally, confirm a real delivery: redeliver from the App's **Advanced →  Recent
Deliveries** tab and check for a 2xx, then confirm the daemon logged the
delivery id and event type.

## What is exposed, stated plainly

- **Reachable from the internet:** exactly one route, `POST /api/v1/github/webhook`.
- **Not reachable:** the dashboard, the Supervisor Decision API, and every other
  `/api/v1/*` route. They are answered with 404 at Cloudflare's edge.
- **No inbound socket exists.** The daemon stays on `127.0.0.1`; `cloudflared`
  makes an outbound connection. There is no port forward and no firewall hole.
- **The secret** lives in `~/.aiur/.env` at mode 600 as
  `AIUR_GITHUB_WEBHOOK_SECRET`, distinct from `GITHUB_TOKEN`,
  `GITHUB_APP_PRIVATE_KEY` and `AIUR_SUPERVISOR_TOKEN`. It is never logged —
  #1676's route sets `log: false` to keep payloads out of the debug log.
- **An attacker who learns the hostname can do nothing.** They reach one route
  that answers 401 to anything lacking a valid `X-Hub-Signature-256` over the
  exact raw bytes. `scripts/verify-webhook-ingress` is the check for that claim
  rather than the assertion of it.

Optional defence in depth, free on Cloudflare's plan: a WAF rule limiting the
hostname to GitHub's published hook ranges (`GET /meta` → `.hooks`). Signature
verification remains the real boundary; this only narrows what can reach it.
