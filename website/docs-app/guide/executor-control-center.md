# Dashboard

The Dashboard is Aiur's browser surface for supervising a run. It combines the live fleet, durable decisions, recorded outcomes, provider meters, Build Orders, and analytics without turning the browser into a second source of truth.

::: info Example data
Every screenshot on this page was captured from the shipped LiveView dashboard against an isolated fixture. Tickets (`EX-142` and similar), agents, decisions, repositories, and links are synthetic.
:::

## Open the dashboard

Foreground and headless runs request the dashboard unless `--no-dashboard` is present. Its default writable mode requires both `AIUR_DASHBOARD_USERNAME` and `AIUR_DASHBOARD_PASSWORD`, including on loopback. Without credentials, set `observability.dashboard_writable: false` for a read-only loopback dashboard, or the listener refuses to start. The launcher binds to loopback by default unless it can safely use authenticated Tailscale exposure. A configured `server.host` wins over that default. The launch output prints its URL and effective bind address only when the listener is running:

```text
Dashboard: http://127.0.0.1:4000 (bind host=0.0.0.0, port=4000)
```

## Find a surface

The navigation labels and routes are the same projections the page-parity CLI reads. Use the browser when you need interactive detail; use the paired command when terminal output is more useful.

| Dashboard label | Route and purpose | CLI counterpart |
| --- | --- | --- |
| **Units** | `/` is the Agents fleet table and its filters, plus the Tickets panel of every open ticket; [Units](/concepts/units) describes this surface. | `aiur units` |
| **Commands** | `/decisions` is the durable decision inbox and each decision's detail. | `aiur commands` |
| **Build Order** | `/build-orders` is the Build Order catalog and one root's execution detail. | `aiur build-orders` |
| **Analytics** | `/analytics` is live-run telemetry and an optional Build Order scope. | `aiur analytics` |
| **Streamdeck+** | `/streamdeck` is the browser emulator for the same live projection used by the authenticated physical Stream Deck + sidecar; [#1358](https://github.com/aiur-team/aiur/issues/1358) defines the remaining terminal hardware proof. | none |

## The pages

Each page is a projection of a durable concept. The Concepts pages carry the detail; the Dashboard just renders it.

- **Units** is the live fleet table of agent runs. Read how to filter and read the rows in [Units](/concepts/units).
- **Commands** is the Executor's decision inbox, where issues agents flag are answered or deferred. See [Commands](/concepts/commands).
- **Build Order** renders planning packs as a catalog, phases, and lanes. See [Build Orders](/concepts/build-orders).
- **Analytics** renders the durable telemetry stream for the current live session: lifecycle timing, per-unit CPU and memory, concurrency against the cap, and cost per ticket. A missing telemetry stream renders an explicit empty state.

<img src="/images/dashboard/units-dark.png" alt="Desktop Units fleet table with synthetic active, blocked, retrying, and review tickets">

## Writable controls

Dashboard mutations are enabled by default. They cover pausing and resuming a unit, answering and revising decisions, adjusting capacity, and applying routing labels from the Tickets panel. Disable them when the dashboard is an observation-only surface:

```yaml
observability:
  dashboard_writable: false
```

Writable requests must also have the expected same-origin `Origin` or `Referer` and `X-Aiur-Request: 1`. These checks supplement authentication; they are not a reason to expose the dashboard publicly.

## Authentication and network exposure

Browser access uses HTTP Basic Authentication configured through environment variables:

```bash
export AIUR_DASHBOARD_USERNAME=example-executor
export AIUR_DASHBOARD_PASSWORD='replace-with-a-strong-secret'
aiur
```

Aiur refuses to start a writable dashboard, or a dashboard bound beyond loopback, without both credentials. A loopback dashboard may run without them only when it is not writable. Put remote access behind a private network or trusted reverse proxy and use TLS there; Basic Auth does not encrypt transport.

The supervisor Decision API has a separate bearer credential, `AIUR_SUPERVISOR_TOKEN`. Dashboard credentials never grant machine-API authority, and the bearer token never signs a human browser action.

## Reproduce the screenshots

The checked-in capture command starts the real endpoint with isolated in-memory providers and captures one desktop image for each documented surface. Keeping a single image prevents a screen change from creating a stale light, dark, and mobile set:

```bash
cd website
npm ci
npm run shot:dashboard
```

The fixture never reads a live repository, customer record, issue, agent transcript, or secret. Do not replace its `example.test` data with production data when updating these assets.
