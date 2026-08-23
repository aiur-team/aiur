# Optional Optimizations

Most of Aiur's performance work was built against one operator's fleet: a Cloudflare tunnel, a GitHub App daemon identity, a tailnet, a physical Stream Deck, and a DeepSeek-first routing pin. None of it is required to run Aiur locally.

This page is the "do I need this, and how do I turn it on" layer. The mechanics (poll cadence, budgets, credential pooling, the read cache, webhook delivery states, the tunnel boundary) live in the [GitHub API reference](/apis/github).

## Baseline: what a local developer actually needs

Everything below this section is optional. A local run needs only:

| Requirement | How you satisfy it |
| --- | --- |
| A GitHub credential | `gh auth login` once. The boot gate falls back to the `gh` keyring, so no manual `GITHUB_TOKEN` export is required. |
| tmux | The launcher runs each daemon in its own detached tmux session. |
| A tracker repository | The repo you point `aiur init` at, with issues carrying `agent:todo`. |

Nothing else is load-bearing — webhooks, the tunnel, the GitHub App, Tailscale, dashboard credentials, Stream Deck hardware, a pinned model backend, and even `python3` all degrade to a supported "feature off" default. `python3` only powers the local budget broker, and without it the daemon runs GitHub requests unmetered.

## GitHub App identity

### Bottleneck it solves

A personal access token shares the operator account's rate-limit budget and makes the daemon authenticate as the operator, so it can react to its own comments. An App installation token (about one hour lifetime, five-minute refresh margin) gives the daemon its own budget and a bot identity it recognizes as its own.

### When you want it

You run a long-lived daemon, poll heavily enough to feel PAT rate limits, or want the daemon's API writes attributed to a bot (`<app-slug>[bot]`) instead of your personal account. Budget and credential-pooling details are in [API budgets](/apis/github#api-budgets).

### Configuration

Set three environment variables and one config key; the full setup (permissions, token lifecycle) is in [GitHub App authentication](/apis/github#github-app-authentication).

| Variable | Purpose |
| --- | --- |
| `GITHUB_APP_ID` | The App's numeric id. |
| `GITHUB_APP_INSTALLATION_ID` | The installation id from the installation URL. |
| `GITHUB_APP_PRIVATE_KEY_PATH` | Path to the App private-key PEM. Inline `GITHUB_APP_PRIVATE_KEY` is the alternative; set one, not both. |

```yaml
tracker:
  github:
    github_app:
      account: <app-slug>[bot]
```

`tracker.github.github_app.account` must end in `[bot]` — the login an installation token actually writes as. With App credentials configured, the daemon authenticates with an installation token and `GITHUB_TOKEN` is ignored; the token remains the fallback when no App credentials are present.

## Webhook ingress and the Cloudflare tunnel

### Bottleneck it solves

Poll latency. By default the daemon reconciles GitHub state on a poll cadence, so a comment, review, or merged PR can take up to the poll interval to surface. A proven webhook cuts that to near-instant delivery.

### When you want it

You want events to arrive immediately and to save the poll spend that would buy them. Base `polling.interval_seconds` is 120s; `webhooks.poll_widen_factor` 2.0 puts a proven repo on a 240s sweep, composing with the idle widen (5.0) to 1,200s.

The daemon read-cache TTL rises from 30s to one hour on a proven repo for comment and issue reads; repository-configuration reads (`:repo_config`) rise from five minutes to one hour — see [Optional webhook](/apis/github#optional-webhook).

### Configuration

1. Generate a secret and export it:

   ```bash
   openssl rand -hex 32
   export AIUR_GITHUB_WEBHOOK_SECRET=<generated>
   ```

2. List the repos expected to deliver in `.aiur/config`:

   ```yaml
   webhooks:
     repos:
       - owner/repo
   ```

3. Pin `server.port` to a fixed value, then point the tunnel at whatever address the daemon actually bound — `127.0.0.1` on that port by default, or the `server.host` address if you pinned one. The default `server.port: 0` binds a fresh OS port every boot, so a tunnel aimed at a guessed port finds nothing; and an origin the daemon is not listening on (loopback or otherwise) returns `502`. Serve only `/api/v1/github/webhook` and finish the ingress list with a catch-all `404`; the same origin serves the operator dashboard, and a host-wide tunnel would expose it. See [Cloudflare tunnel boundary](/apis/github#cloudflare-tunnel-boundary).

4. Give the tunnel a public hostname you control and set GitHub's webhook payload URL to `https://<your-host>/api/v1/github/webhook` (`hooks.aiur.dev` is one operator's choice, not a requirement). Without a domain, `cloudflared tunnel --url` (quick tunnels) exposes the daemon on a temporary public URL — fine for a single session, gone when the process exits.

Without public ingress, polling is the default mode and degrades cleanly: a repo that is configured but never delivers keeps polling at the full interval, and a repo that goes silent returns to full polling and raises an attention. Delivery states are in [Optional webhook](/apis/github#optional-webhook).

## Tailscale

### Bottleneck it solves

Reaching the dashboard from another device — a phone or a second laptop — without exposing it to the public internet.

### When you want it

You want the dashboard on your tailnet. There is no automatic Tailscale detection in code: the dashboard binds `127.0.0.1` by default, so serving it off-box is always an explicit choice.

### Configuration

Set `server.host` to the machine's tailnet IPv4:

```yaml
server:
  host: 100.x.y.z
```

The dashboard must also have credentials before it is usable — see the next section. See [server](/reference/configuration#server) for the full key.

## Dashboard authentication

### Bottleneck it solves

Not an optimization but a gate, and it belongs here because omitting it silently costs you the dashboard.

### The symptom

With no `AIUR_DASHBOARD_USERNAME` or `AIUR_DASHBOARD_PASSWORD`, the loopback listener binds but no dashboard page is usable — a writable dashboard (the default) challenges every request with basic auth, a read-only one refuses with `503` naming both variables. Beyond loopback the listener refuses to start at all.

### The `observability.dashboard_writable` interaction

`dashboard_writable` (default `true`) authorizes the dashboard's write controls; it is not authentication. Either way, the two credentials are required to view the dashboard: a loopback listener binds without them but fails closed; beyond loopback it refuses to start. See [observability](/reference/configuration#observability).

### Configuration

```bash
export AIUR_DASHBOARD_USERNAME=<you>
export AIUR_DASHBOARD_PASSWORD=<secret>
```

With both set, the dashboard requires Basic Auth on every request, writable or not.

## Stream Deck

### Bottleneck it solves

Fleet-control latency for a human operator: physical keys for pause, logs, and dictation instead of reaching for a terminal.

### When you want it

You operate a fleet from a desk and want a dedicated surface. It is a separate sidecar package, Linux x64, experimental, and a clean no-op when absent — no supervised child, no retry loop, no error log. The browser emulator at `/streamdeck` in the dashboard shows the same surface without hardware.

### Configuration

Follow the [Stream Deck](/guide/stream-deck) guide to install the sidecar and udev rule.

## Model routing and provider keys

### Bottleneck it solves

Cost and concurrency: which model backend handles a ticket, and which provider API keys the daemon can use.

### When you want it

You want to pin the default backend or route by complexity. The shipped default is an empty `agent.priority`, so the effective backend is `agent.kind`, else the registry default (codex).

`priority` is live: the first priority route becomes the effective backend with no enablement filter, so `priority: [deepseek]` (this repo's own `.aiur/config`) selects DeepSeek even though it is not dispatch-enabled by default. The flag gates `agent.kind`, `rate_limit_primary`, `switch_model_on_ratelimit`, and fleet gating, not `priority` entries.

The "codex → claude" pairing is the automatic rate-limit reroute, not the default backend.

### Configuration

Set `agent.priority` in `.aiur/config` and provide the matching provider keys via `agent.backend_configs.<backend>.api_key_env`. See [agent](/reference/configuration#agent) for the full key.

## What you lose by skipping everything

| Optimization | Without it | Still works |
| --- | --- | --- |
| GitHub App identity | PAT rate limits; daemon writes attributed to your account | Dispatch, control, all polling |
| Webhook ingress and tunnel | Up to 120s event latency | Polling is the default fallback |
| Custom webhook hostname / domain | A quick tunnel, or polling at the full interval | Webhooks with any hostname you control; polling fallback |
| Budget broker (`python3`) | GitHub requests run unmetered, with no shared admission budget | All dispatch, GitHub requests, polling |
| Tailscale | Dashboard reachable only on the machine | Local dashboard, CLI, TUI |
| Dashboard credentials | No usable dashboard (every request refused) | CLI and TUI |
| Stream Deck | Browser emulator instead of physical keys | Dashboard controls |
| Model routing and provider keys | codex default (codex → claude rate-limit reroute) | Agent dispatch |

## A warning about this repo's `.aiur/config`

This repository's own `.aiur/config` is an operator file, not a starting template. Copying it into a fresh checkout yields a DeepSeek-first fleet, a foreign repo (`aiur-team/aiur`) and bot account, and codex `writableRoots` pinned to operator-machine paths. Run `aiur init` to scaffold a config for your own repository instead.
