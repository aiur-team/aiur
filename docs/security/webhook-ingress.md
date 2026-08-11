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

### What you need before starting

Two things are outside this repository, and both gate everything below — the
second one especially, because it decides whether you can use this approach at
all rather than merely how:

- **`cloudflared` installed** on the machine that runs the daemon. Cloudflare's
  package repositories and binaries are at
  <https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/>.
- **A domain whose DNS is served by Cloudflare.** The stable hostname is a CNAME
  this tool creates in that zone, so without one there is no `route dns` step and
  no stable URL — and a URL that changes means reconfiguring the GitHub webhook
  after every restart, which is the thing this whole setup exists to avoid. If
  you do not have one,
  re-read "Options considered" before going further; Tailscale Funnel is the
  fallback that does not need a domain.

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

**A `--host` or `--port` on the command line overrides this file, and some
launchers inject one.** `Aiur.HttpServer.start_link/1` resolves both as
`Keyword.get(opts, :host, Config.server_host())` — the flag wins, every time. So
`.aiur/config` saying `host: 127.0.0.1` is not evidence that the daemon is on
loopback: it can be bound to a single routable address with nothing listening on
`127.0.0.1` at all.

That is a problem for the tunnel rather than for the daemon. The `service:` line
in the next section has to name the address the daemon **actually** bound, and
pointing it at loopback while the daemon is elsewhere returns 502 on every
delivery — with the config file still reading `127.0.0.1`, the daemon healthy,
and nothing anywhere warning you. Read the bind instead of assuming it, once the
daemon is running and before you write the tunnel config:

```sh
ss -ltnp | grep beam.smp
```

That lists every address and port the daemon is listening on. If more than one
line comes back, or you want to be sure the listener is this daemon rather than
some other BEAM process, ask for the answer only this receiver gives:

```sh
curl -s -m 2 -X POST "http://<address>:<port>/api/v1/github/webhook" \
  -H 'X-GitHub-Event: ping' -d '{}' | grep -q invalid_signature && echo "daemon here"
```

Use the address that answers. If that is not `127.0.0.1`, the daemon was started
with an explicit host and the tunnel must follow it — or restart the daemon with
`--host 127.0.0.1` so the loopback posture this document describes is the one you
actually get.

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

That last sentence is an instruction, not a property — every way this secret
leaks is something a human does by hand, so none of it is prevented by the code.
Check it rather than trusting it. Everything below prints *file names and commit
subjects, never the value*:

Run these from your Aiur checkout:

```sh
env=~/.aiur/.env
secret=$(sed -n 's/^AIUR_GITHUB_WEBHOOK_SECRET=//p' "$env" | tr -d '"'"'"'')
: "${secret:?not set in $env}"

stat -c '%a %n' "$env"                        # expect: 600

# Files git tracks, or would track: a hit here is one commit from publication.
git grep -Il --untracked -e "$secret" -- .    # expect: no output

# Every blob in the reachable history. ~1.4s over 4,600 commits.
git log --all --oneline -S "$secret"          # expect: no output
```

Use `git grep --untracked` rather than `grep -r`. It is the difference between
scanning what git will publish and scanning 368 MB of `_build`, `deps` and
scratch directories — and because it honours `.gitignore` it will not trip over
temporary files, including the ones a check like this creates. A `grep -r`
version of this check reported a hit on its own pattern file.

Both commands take the secret as an argument, so it is briefly visible in `ps`
to other users on the machine. On a single-user host that is immaterial; on a
shared one, treat these as a setup-time check rather than a routine one.

A hit in either is not "tidy it up later": the secret is disclosed to everyone
who can read that repo or its history, and rewriting history does not recall it.
Generate a new one, put it in `~/.aiur/.env`, update the webhook in GitHub, and
restart — the rotation procedure below, run immediately.

To rotate it: change it on the GitHub side, change it in `~/.aiur/.env`, then
restart the daemon. `AiurWeb.GithubWebhook.Auth` reads the variable on every
request rather than caching it at boot, so the daemon does not need a code
change to pick up a new value — but the launcher sources `~/.aiur/.env` when it
starts the app, so a file edit alone does not reach the running process.
Deliveries signed with the old secret during the gap are rejected, which is why
rotation wants a quiet moment rather than a busy one.

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
    # The address the daemon actually bound, read with `ss -ltnp | grep beam.smp`
    # in "Pin the daemon's port" -- not assumed to be loopback. A `--host` flag
    # overrides `.aiur/config`, and naming the wrong address here is a 502 on
    # every delivery with nothing else looking wrong.
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

Where this is registered depends on how the daemon authenticates, and the two
are not equivalent. `Aiur.GitHub.Config.token/0` prefers a GitHub App
installation token when `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID` and the
App private key are set, and otherwise falls back to `GITHUB_TOKEN` or the `gh`
CLI's credential.

- **App deployment:** register once on the App. Every repo the installation
  covers delivers to it, and a repo added later needs no webhook step.
- **PAT / `gh` deployment (the common case):** there is no App to register on,
  so add the webhook under **each repository's** Settings → Webhooks, using the
  same payload URL and the same secret every time. This is per-repo work that
  scales with the fleet — and it is the step most likely to be forgotten when a
  repo is added to `webhooks.repos` later, which shows up as a repo stuck in
  `configured_unproven`.

Either way, the settings are:

- **Payload URL:** `https://hooks.<domain>/api/v1/github/webhook`
- **Content type:** `application/json`
- **Secret:** the value of `AIUR_GITHUB_WEBHOOK_SECRET`
- **SSL verification:** enabled

`application/json` is the recommendation, not a correctness requirement: the
receiver also accepts `application/x-www-form-urlencoded`, where GitHub sends the
JSON inside a single `payload` field, and both resolve to the same payload. That
is covered by tests, so an existing registration already using the form encoding
does not need to be changed. It matters that this is verified rather than
assumed — every outcome on this endpoint answers `202`, so if the form path ever
broke, a repo configured that way would show green ticks in GitHub's delivery UI
while nothing was ever processed.

One secret is shared across every registration. The receiver verifies against
the single configured value, so a per-repo secret would not be checked against
the right key.

Subscribe only to the events the fleet consumes. Every unused event costs no
quota but still costs parsing, log volume, and payload surface. W-3 (#1732) has
landed, so this list is final rather than provisional: it is exactly the set
`Aiur.Events.GithubWebhook.Normalizer` has a clause for. Every other type is
dropped as `unsupported_event`.

| Event | Why |
| --- | --- |
| `issue_comment` | agent instructions and firehose comments |
| `issues` | `labeled`, `unlabeled`, `closed` drive the agent lifecycle |
| `pull_request` | publishes `pr.opened` / `pr.merged`; `synchronize` drives CI reconcile |
| `pull_request_review` | wakes agents paused on review |
| `pull_request_review_comment` | review feedback threads |
| `check_suite` | CI completion |
| `check_run` | CI completion |

Do not select "Send me everything."

Omitting `pull_request` is the easiest mistake to make here and the hardest to
notice: deliveries still arrive and are still accepted, so the ingress guard and
the delivery-mode diagnostic both stay green, while agents silently never wake on
a PR opening or merging. If the normalizer gains or loses a clause, this table is
what has to change with it.

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
repo. Since [#1772](https://github.com/aiur-team/aiur/issues/1772),
`poll_widen_factor` defaults to `2.0`, so listing a repo does eventually change
its poll interval: once a delivery proves the repo webhook-backed, its polls
widen by that factor. Nothing has to remember to restore the tighter interval —
the widened value is recomputed per tick from the repo's current transport, so a
silence degradation back to `:polling` narrows the very next tick on its own.
Set `poll_widen_factor: 1.0` to register repos without changing any interval.

It doubles as the end-to-end confirmation that ingress works: once a verified
delivery lands, the agent-control `usage` view (`Aiur.AgentControlCLI.usage/2`,
rows from `Aiur.Webhooks.ModePresenter`) prints one line per known repo:

```text
events  owner/name  webhook  last delivery 2026-07-27T12:00:00Z
events  owner/other  polling  last delivery never  (webhook configured but never delivered)
```

The mode word is `webhook` or `polling`, and the last-delivery field is an
ISO-8601 timestamp or `never` — not an age, so do not expect a `5m ago`. A repo
still printing `(webhook configured but never delivered)` after a redelivery
means the delivery is not reaching the receiver — check the ingress rules before
suspecting the verifier. That parenthetical is the operator-visible form of the
`configured_unproven` state; the atom itself is never printed, so grepping the
output for it finds nothing whether ingress works or not.

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
wide-open one, a receiver that accepts unsigned deliveries, and an ingress rule
that never matches the webhook path. That last case is the one worth knowing
about when you are reading the guard's output: a tunnel scoped so tightly that
it delivers nothing passes *every* "not publicly routable" assertion, so the
reachability line at the top is the only thing that catches it. A run whose
denied-path list is all `ok` is not a pass on its own. That harness runs in CI.

Those four fixtures collapse the edge and the daemon into a single process, so
none of them can say anything about a restart — killing that process takes the
public URL down with it. The harness therefore also runs a two-tier case, an
`origin` (the daemon) behind a long-lived `edge` (the tunnel), and restarts the
origin underneath an edge whose port never moves: pinned, and the same URL still
passes; unpinned, and the same URL must fail. That pair is the restart invariant
below, checked on every CI run rather than only when someone remembers to redo
the manual procedure.

Finally, confirm a real delivery: redeliver from the App's **Advanced →  Recent
Deliveries** tab and check for a 2xx, then confirm the daemon logged the
delivery id and event type.

### Verify the URL survives a restart

Do this once, during setup, before signing the ingress off. Everything above
passes on a daemon that was never restarted, so a missing port pin does not show
up here — it shows up days later, when something restarts the daemon and a
hostname that is still perfectly stable starts answering 502.

```sh
# The port this runbook pins. Everything below compares against it rather than
# assuming it, because a daemon bound somewhere else is the case this check
# exists to catch — and the case a bare `grep 4099` cannot see.
pinned=4099

# Find the port serving the receiver by the error body only it produces.
#
# Two weaker versions of this check do not work, and both look right:
#   - Matching a process name. A BEAM node also listens on distribution ports,
#     so `grep beam.smp` returns several ports with nothing to say which one is
#     the endpoint.
#   - Matching the 401 status alone. `401` is not distinctive: on the host this
#     runbook was written against, two ports belonging to an unrelated desktop
#     application answered a bare `HTTP/1.1 401` to this exact probe. The first
#     such port to sort ahead of the daemon's silently becomes "the port the
#     daemon is bound to", and step 2 then confirms a stranger came back.
#
# The receiver's `invalid_signature` body is emitted by nothing else, so match
# on that. It is pinned to AiurWeb.GithubWebhook.Auth by a test.
bound() {
  for p in $(ss -ltn 2>/dev/null | awk 'NR>1 {n=split($4,a,":"); print a[n]}' | sort -un); do
    if curl -s -m 2 -X POST "http://127.0.0.1:$p/api/v1/github/webhook" \
         | grep -q '"code":"invalid_signature"'; then
      echo "$p"
      return 0
    fi
  done
}

# 1. Note the port the daemon is ACTUALLY bound to. Do not skip the two checks
#    below: if the daemon is bound elsewhere, a `grep $pinned` prints nothing
#    here *and* nothing after the restart, and two empty results compare equal.
before=$(bound)
: "${before:?no aiur daemon is listening — start it before running this check}"
echo "daemon is bound to $before"
[ "$before" = "$pinned" ] || echo "MISMATCH: bound to $before, but this runbook and the tunnel origin pin $pinned — reconcile before continuing"

# 2. Restart the daemon, then confirm it came back on the same port.
after=$(bound)
: "${after:?daemon did not come back up}"
[ "$after" = "$before" ] || echo "PORT MOVED: $before -> $after; server.port is not pinned"

# 3. Re-run the guard against the unchanged public hostname.
scripts/verify-webhook-ingress https://hooks.<domain>
```

The guard passing *after* a restart, against the same hostname, with nothing
reconfigured on the GitHub side, is the evidence for "restarting the daemon does
not change the webhook URL". If step 2 reports `PORT MOVED`, `server.port` is
not pinned — re-read the prerequisite above; the tunnel is fine and the config
is not.

The same fault reaches you through the guard in step 3 as a **502**, because
`cloudflared` is up and its ingress rule still matches — it dialled the origin
address and got nothing back. The guard calls that out and points at
`server.port` rather than at the ingress rule, which is worth knowing because
every instinct on seeing a routing-shaped failure is to go and edit the one file
that is correct.

If step 1 reports `MISMATCH`, stop and reconcile before going further. The
daemon is up and deliveries may well be arriving, so nothing looks wrong — but
the tunnel origin and this document are describing a port the daemon is not on,
and the next person to follow this runbook on a fresh machine will pin the
documented port and get a 502 on every delivery.

Nothing about the App or the per-repo webhook registration should need touching
at any point in this check. If it does, the URL was not stable.

## What is exposed, stated plainly

- **Reachable from the internet:** exactly one route, `POST /api/v1/github/webhook`.
- **Not reachable:** the dashboard, the Supervisor Decision API, and every other
  `/api/v1/*` route. They are answered with 404 at Cloudflare's edge.

  It is worth being concrete about what that sentence is protecting, because
  "every other `/api/v1/*` route" reads like a list of read-only endpoints and is
  not. The same listener serves `POST /api/v1/<issue>/pause` and `/resume`,
  `/messages` (inject a message into a running agent's session),
  `/claude-hook`, `POST /api/v1/decisions/<id>/decide` (answer an operator
  decision), and `GET /api/v1/<issue>/events` and `/api/v1/<issue>`, which
  return agent data to an unauthenticated caller on a loopback bind. An
  over-broad ingress rule does not leak a status page; it hands over the fleet's
  control plane. `scripts/verify-webhook-ingress` probes each of those paths by
  name — with `GET`, so the check itself cannot pause an agent or decide a
  decision as a side effect.
- **No inbound socket exists — *if* you followed the loopback prerequisite.**
  With `server.host: 127.0.0.1`, `cloudflared` makes an outbound connection and
  there is no port forward and no firewall hole.

  This bullet is a consequence of your config, not a property of the design, and
  it is the one claim on this page that a deployment can quietly falsify. A
  daemon bound to `0.0.0.0` is reachable directly on the LAN, on every route —
  the tunnel's `404` catch-all scopes *the tunnel*, and says nothing about the
  local network. Check rather than assume:

  ```sh
  pinned=4099

  # Every global-scope address the daemon is answering on. Loopback-only is the
  # documented posture, so anything listed here is a second way in.
  for ip in $(ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1); do
    printf '%s/ -> %s\n' "$ip" \
      "$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://$ip:$pinned/")"
  done
  ```

  A blank or refused response is the documented posture. A `401` means the bind
  is not loopback but `Aiur.HttpServer.start_link/1`'s guard is doing its job —
  the boot guard requires dashboard credentials for any non-loopback or writable
  bind, so the dashboard is reachable but not usable. **A `200` is an
  unauthenticated control plane on your LAN**, and the tunnel being perfectly
  scoped will not have warned you: every check on this page still passes.
- **The secret** lives in `~/.aiur/.env` at mode 600 as
  `AIUR_GITHUB_WEBHOOK_SECRET`, distinct from `GITHUB_TOKEN`,
  `GITHUB_APP_PRIVATE_KEY` and `AIUR_SUPERVISOR_TOKEN`. It is never logged —
  #1676's route sets `log: false` to keep payloads out of the debug log.
- **An attacker who learns the hostname can do nothing.** They reach one route
  that answers 401 to anything lacking a valid `X-Hub-Signature-256` over the
  exact raw bytes. Both halves of that claim are checked rather than asserted:
  `scripts/verify-webhook-ingress` proves the *edge* publishes only this route,
  and `src/test/aiur_web/github_webhook_test.exs` (#1676) proves the *receiver*
  fails closed — no signature, mismatched digest, malformed or duplicated
  header, legacy SHA-1 header, a body altered after signing, a blank secret and
  a truncated read of an oversized body are each rejected, and the digests are
  compared in constant time.
- **The ingress rule selects on path, not on method**, so publishing the
  receiver publishes *every* verb on that path — an attacker will try `GET`
  before anything else. Only `POST` is routed; `GET`, `PUT`, `PATCH`, `DELETE`
  and `OPTIONS` fall through to the router's catch-all and answer a bare
  `404 {"error":{"code":"not_found"}}`, reaching no handler. This is pinned by
  *only POST reaches a handler on the published path* in
  `src/test/aiur_web/github_webhook_test.exs`, because it is the one property
  here that a future routing change can break silently: every other test on
  this path drives `POST`, so a route added later that also matches it under
  another verb would become publicly reachable with the suite still green. The
  pin asserts `POST` still reaches the signature check first, so it cannot
  itself pass vacuously by the path having moved.

Optional defence in depth, free on Cloudflare's plan: a WAF rule limiting the
hostname to GitHub's published hook ranges (`GET /meta` → `.hooks`). Signature
verification remains the real boundary; this only narrows what can reach it.
