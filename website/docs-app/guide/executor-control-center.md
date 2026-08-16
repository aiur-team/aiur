# Dashboard

The Dashboard is Aiur's browser surface for supervising a run. It renders the live fleet, the durable decision inbox, Build Orders, and run analytics without becoming a second source of truth: every page reads the same projection its paired CLI command reads.

This page covers how to run it. The [Concepts](/concepts/executor) section covers what each page means.

## The pages

| Page | Route | What it is | CLI counterpart |
| --- | --- | --- | --- |
| **Units** | `/` | The fleet table and the open-ticket backlog. See [Units](/concepts/units). | `aiur units` |
| **Commands** | `/decisions` | The durable decision inbox and each decision's detail. See [Commands](/concepts/commands). | `aiur commands` |
| **Build Order** | `/build-orders` | The planning-pack catalog and one root's execution detail. See [Build Orders](/concepts/build-orders). | `aiur build-orders` |
| **Analytics** | `/analytics` | Live-run telemetry, optionally scoped to one Build Order. | `aiur analytics` |
| **Streamdeck+** | `/streamdeck` | Browser emulator for the same live projection used by the authenticated physical Stream Deck + sidecar. See [Stream Deck](/guide/stream-deck). | Not applicable |

<img src="/images/dashboard/units-dark.png" alt="Desktop Units page with a synthetic fleet table and ticket backlog">

::: info Example data
Every screenshot on this page was captured from the shipped dashboard against an isolated fixture. Tickets (`EX-142` and similar), agents, decisions, repositories, and links are synthetic.
:::

## Open it

Foreground and headless runs request the dashboard unless `--no-dashboard` is present. The launcher binds to loopback by default, unless it can safely use authenticated Tailscale exposure. A configured `server.host` wins over that default, and `--host` wins over both.

Launch output prints the URL and effective bind address only when the listener is actually running:

```text
Dashboard: http://127.0.0.1:4000 (bind host=0.0.0.0, port=4000)
```

Set a stable bind explicitly when local ingress, probes, or tunnels depend on it:

```yaml
server:
  host: 127.0.0.1
  port: 4000
```

## Analytics

`/analytics` renders the durable telemetry stream for the current live session: ticket lifecycle timing, per-unit CPU and memory, concurrency against the cap, CPU-second cost per ticket, dispatch-time complexity breakdown, and completed-ticket counts. The writer records `pr_opened` and `pr_merged` anchors from the GitHub firehose, so completion KPIs and burn-up render for the current run.

A selected Build Order narrows the view to its typed members in this session. A missing telemetry stream renders an explicit empty state rather than zeros. The Provider spend KPI appears only to an authorized browser and only when a scoped provider estimate exists; otherwise it is locked or unavailable, never reported as zero. [#1458](https://github.com/aiur-team/aiur/issues/1458) and [#1459](https://github.com/aiur-team/aiur/issues/1459) track remaining analytics gaps.

## Writable controls

Dashboard mutations are enabled by default. They cover pausing and resuming a unit, answering and revising decisions, adjusting capacity, and applying routing labels from the Tickets panel. Disable them when the dashboard is an observation-only surface:

```yaml
observability:
  dashboard_writable: false
```

Writable requests must also carry the expected same-origin `Origin` or `Referer` and `X-Aiur-Request: 1`. These checks supplement authentication; they are not a reason to expose the dashboard publicly.

## Authentication and network exposure

Browser access uses HTTP Basic Authentication configured through environment variables:

```bash
export AIUR_DASHBOARD_USERNAME=example-executor
export AIUR_DASHBOARD_PASSWORD='replace-with-a-strong-secret'
aiur
```

Aiur refuses to start a writable dashboard, or one bound beyond loopback, without both credentials. A loopback dashboard may run without them only when it is not writable. Put remote access behind a private network or a trusted reverse proxy and use TLS there; Basic Auth does not encrypt transport.

The supervisor Decision API has a separate bearer credential, `AIUR_SUPERVISOR_TOKEN`. Dashboard credentials never grant machine-API authority, and the bearer token never signs a human browser action.

## Reproduce the screenshots

The checked-in capture command starts the real endpoint with isolated in-memory providers and captures one desktop image per documented surface. Keeping one image per surface prevents a screen change from creating a stale light, dark, and mobile set:

```bash
cd website
npm ci
npm run shot:dashboard
```

The fixture never reads a live repository, customer record, issue, agent transcript, or secret. Do not replace its `example.test` data with production data when updating these assets.
