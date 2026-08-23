# Optional Optimizations

Most of Aiur's performance work was built against one operator's fleet: a Cloudflare tunnel for webhook ingress, a GitHub App daemon identity, a tailnet, a physical Stream Deck, and a DeepSeek-first routing pin. None of it is required to run Aiur locally. This page is the "do I need this, and how do I turn it on" layer — what each optimization buys you, when you want it, and the exact steps to configure it. The mechanics (poll cadence, budgets, credential pooling, the read cache, webhook delivery states, the tunnel boundary) live in the [GitHub API reference](/apis/github).

## Baseline: what a local developer actually needs

Everything below this section is optional. A local run needs only:

| Requirement | How you satisfy it |
| --- | --- |
| A GitHub credential | `gh auth login` once. The boot gate falls back to the `gh` keyring, so no manual `GITHUB_TOKEN` export is required. |
| tmux | The launcher runs each daemon in its own detached tmux session. |
| `python3` | The local budget broker that coordinates GitHub request admission. |
| A tracker repository | The repo you point `aiur init` at, with issues carrying `agent:todo`. |

Nothing else is load-bearing. Webhooks, the tunnel, the GitHub App, Tailscale, dashboard credentials, Stream Deck hardware, and a pinned model backend can all be omitted; absent, each degrades to a supported "feature off" default rather than a failed boot.

## GitHub App identity

### Bottleneck it solves

A personal access token shares the operator account's rate-limit budget and, worse, makes the daemon authenticate as the operator — so the daemon's own comments look like the operator's and it can react to itself. A GitHub App installation token (about one hour lifetime, refreshed with a five-minute safety margin) gives the daemon its own budget and a bot identity it recognizes as its own.

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

You want events to arrive immediately and to save the poll spend that would otherwise buy them. The numbers this repo owns: the base `polling.interval_seconds` is 120s; `webhooks.poll_widen_factor` 2.0 puts a proven repo on a 240s reconciliation sweep, composing with the idle widen (5.0) to 1,200s when idle; and the daemon read-cache TTL rises from 30s to one hour on a repo a webhook has actually proven.

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

3. Point the tunnel at the daemon's Tailscale IPv4 (a `100.x.y.z` address) on port 4000 — not `127.0.0.1`, which returns `502` because the tunnel origin must reach the daemon over the tailnet. Serve only `/api/v1/github/webhook` and finish the ingress list with a catch-all `404`; the same origin serves the operator dashboard, and a host-wide tunnel would expose it. See [Cloudflare tunnel boundary](/apis/github#cloudflare-tunnel-boundary).

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

With no `AIUR_DASHBOARD_USERNAME` or `AIUR_DASHBOARD_PASSWORD`, the loopback listener binds but every dashboard request returns `503` naming both variables, and no dashboard page is usable. Beyond loopback the listener refuses to start at all.

### The `observability.dashboard_writable` interaction

`dashboard_writable` (default `true`) is an authorization gate for the dashboard's write controls, not an authentication mechanism. The two credentials are required to view the dashboard at all; writable mode additionally requires them even on loopback, and read-only mode still needs them to log in. See [observability](/reference/configuration#observability).

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

You want to pin the default backend or route by complexity. The shipped default is an empty `agent.priority` with codex/claude as the code default. Note that `priority: [deepseek]` in this repo's own `.aiur/config` is one operator's choice — and DeepSeek is dispatch-disabled by default, so a bare `priority: [deepseek]` is ignored without a `deepseek.enabled` block.

### Configuration

Set `agent.priority` in `.aiur/config` and provide the matching provider keys via `agent.backend_configs.<backend>.api_key_env`. See [agent](/reference/configuration#agent) for the full key.

## What you lose by skipping everything

| Optimization | Without it | Still works |
| --- | --- | --- |
| GitHub App identity | PAT rate limits; daemon writes attributed to your account | Dispatch, control, all polling |
| Webhook ingress and tunnel | Up to 120s event latency | Polling is the default fallback |
| Tailscale | Dashboard reachable only on the machine | Local dashboard, CLI, TUI |
| Dashboard credentials | No usable dashboard (every request `503`) | CLI and TUI |
| Stream Deck | Browser emulator instead of physical keys | Dashboard controls |
| Model routing and provider keys | codex/claude default backend | Agent dispatch |

## A warning about this repo's `.aiur/config`

This repository's own `.aiur/config` is an operator file, not a starting template. Copying it into a fresh checkout yields a DeepSeek-first fleet, a foreign repo (`aiur-team/aiur`) and bot account, and codex `writableRoots` pinned to operator-machine paths. Run `aiur init` to scaffold a config for your own repository instead.
