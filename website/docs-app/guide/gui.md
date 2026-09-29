# GUI

The GUI is Aiur's browser interface for supervising a run. It combines the live fleet, durable decisions, recorded outcomes, provider meters, Build Orders, and analytics.

## Open the GUI

| Launch condition | GUI result |
| --- | --- |
| Normal foreground or headless run | Listener requested. |
| `--no-dashboard` | Listener disabled. |
| Writable mode | On loopback it binds without credentials and fails closed; beyond loopback it refuses to start without both credentials. |
| Read-only loopback | Requires credentials for access. Without them the listener may bind, but every request is refused until both credentials are set. |
| Host selection | `server.host` wins over the `127.0.0.1` default. |

Startup prints the URL and effective bind only when the listener runs:

```text
Dashboard: http://127.0.0.1:4000 (bind host=0.0.0.0, port=4000)
```

## Find a surface

Use the browser when you need interactive detail; use the paired command when terminal output is more useful.

| GUI label | Route and purpose | CLI counterpart |
| --- | --- | --- |
| **Units** | `/` is the Units fleet table and its filters, plus the Tickets panel of every open ticket; [Units](/concepts/units) describes this surface. | `aiur units` |
| **Commands** | `/commands` is the durable decision inbox and each decision's detail. | `aiur commands` |
| **Build Order** | `/build-orders` is the Build Order catalog and one root's execution detail. | `aiur build-orders` |
| **Analytics** | `/analytics` is latest-run telemetry with durable restart fallback and an optional Build Order scope. A source line labels the data as the live boot or a retained prior run and shows how long ago it was observed. | `aiur analytics` |
| **Streamdeck+** | `/streamdeck` is the browser emulator for the physical Stream Deck + sidecar. | none |

| Route change | Behavior |
| --- | --- |
| `/commands` and `/commands/:decision_id` | Current Commands inbox and detail URLs. |
| `/decisions` and `/decisions/:decision_id` | Redirect permanently to the `/commands` equivalents. |
| `/api/v1/decisions`, `decision_id`, event topics | Keep the **decision** vocabulary for compatibility. |

The operator-facing UI and CLI call these records **Commands**.

Each current-run Units row shows Aiur orchestration turns for the current running attempt and the provider's current context occupancy. A turn counts a distinct `session_started` event, not a model request. An unknown count or context observation appears as `—`; context is separate from cumulative token usage.

GUI data tables sort by their meaningful column headings. The first click sorts descending, the second reverses the order, and the active heading shows its direction. Icon and action columns are not sortable.

The fleet table's **Context** column shows each agent's observed context occupancy when its provider reports it. If the provider reports used tokens without a window size, the table says **unknown capacity**; an absent observation shows **—**.

The `sort` query parameter preserves the selected table, column, and direction in copied or refreshed URLs. Paginated and progressively revealed tables sort the displayed rows, then reapply that order when more rows appear.

## The pages

Each page renders a durable concept whose detail lives in Concepts.

| Page | Concept detail |
| --- | --- |
| Units | [Fleet, tickets, and meters](/concepts/units). |
| Commands | [Issues agents flag for the Executor](/concepts/commands). |
| Build Order | [Planning packs, phases, lanes, and dependencies](/concepts/build-orders). |
| Analytics | Lifecycle time, CPU, memory, whole-host fleet/build pressure, concurrency, and cost; missing telemetry stays explicit. |

### Read fleet and build pressure

Analytics records fleet and build-gate whole-host sources alongside daemon process
telemetry. The pressure chart shows occupied agents, configured/max/effective
agent capacity, active and queued builds, and the oldest live build wait.

Its source state strip and timestamped data table distinguish current, stale,
degraded, partial, and empty observations. The table additionally reports the
binding admission signal and the measured load against its threshold, so a growing
build queue with load far below threshold reads as build-gate-saturated rather
than host-saturated.

A gap means the source was not current enough to support that value; it is never
silently plotted as zero. Build-queue wait is the oldest waiter still live at the
sample time, not a completed-build latency. These measurements expose when the
build gate is the fleet constraint; they do not automatically change the agent cap.

The build-gate scan runs on a reduced cadence and carries the last observation
forward, so measuring the gate never perturbs a real build acquisition.

<img src="/images/dashboard/units-dark.png" alt="Desktop Units fleet table with synthetic active, blocked, retrying, and review tickets">

## Writable controls

| Writable control | Action |
| --- | --- |
| Unit | Pause or resume. |
| Command | Answer or revise. |
| Fleet | Adjust capacity. |
| Ticket | Apply routing labels. |

The CLI covers Unit and Fleet controls plus initial Command answers. Command revision and ticket-routing preview remain GUI-only today.

Disable mutations for an observation-only surface:

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

Aiur refuses to start a dashboard bound beyond loopback without both credentials. A loopback listener — writable or read-only — may bind without them, but its authentication plug fails closed and refuses every dashboard request until both credentials are set.

Put remote access behind a private network or trusted reverse proxy and use TLS there; Basic Auth does not encrypt transport.

The supervisor Decision API has a separate bearer credential, `AIUR_SUPERVISOR_TOKEN`. Generate one with `openssl rand -base64 32`, then put `AIUR_SUPERVISOR_TOKEN=<generated-token>` in `~/.aiur/.env` for all projects or the repository `.env` for one project.

An exported value wins, then the global file, then the repository file. The token must be at least 32 bytes, bearer-safe, and free of surrounding whitespace. A present non-empty invalid value aborts startup, while an absent or empty value leaves the API disabled.

Dashboard credentials never grant machine-API authority, and the bearer token never signs a human browser action.
