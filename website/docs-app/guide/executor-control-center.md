# Dashboard

The Dashboard is Aiur's browser interface for supervising a run. It combines the live fleet, durable decisions, recorded outcomes, provider meters, Build Orders, and analytics.

## Open the dashboard

| Launch condition | Dashboard result |
| --- | --- |
| Normal foreground or headless run | Listener requested. |
| `--no-dashboard` | Listener disabled. |
| Writable mode | Username and password required, including on loopback. |
| Read-only loopback | May run without credentials. |
| Host selection | `server.host` wins over authenticated Tailscale or loopback default. |

Startup prints the URL and effective bind only when the listener runs:

```text
Dashboard: http://127.0.0.1:4000 (bind host=0.0.0.0, port=4000)
```

## Find a surface

Use the browser when you need interactive detail; use the paired command when terminal output is more useful.

| Dashboard label | Route and purpose | CLI counterpart |
| --- | --- | --- |
| **Units** | `/` is the Units fleet table and its filters, plus the Tickets panel of every open ticket; [Units](/concepts/units) describes this surface. | `aiur units` |
| **Commands** | `/commands` is the durable decision inbox and each decision's detail. | `aiur commands` |
| **Build Order** | `/build-orders` is the Build Order catalog and one root's execution detail. | `aiur build-orders` |
| **Analytics** | `/analytics` is live-run telemetry and an optional Build Order scope. | `aiur analytics` |
| **Streamdeck+** | `/streamdeck` is the browser emulator for the physical Stream Deck + sidecar. | none |

| Route change | Behavior |
| --- | --- |
| `/commands` and `/commands/:decision_id` | Current Commands inbox and detail URLs. |
| `/decisions` and `/decisions/:decision_id` | Redirect permanently to the `/commands` equivalents. |
| `/api/v1/decisions`, `decision_id`, event topics | Keep the **decision** vocabulary for compatibility. |

The operator-facing UI and CLI call these records **Commands**.

Dashboard data tables sort by their meaningful column headings. The first click sorts descending, the second reverses the order, and the active heading shows its direction. The `sort` query parameter preserves the selected table, column, and direction in copied or refreshed URLs; icon and action columns are not sortable. Paginated and progressively revealed tables sort the displayed rows, then reapply that order when more rows appear.

## The pages

Each page renders a durable concept whose detail lives in Concepts.

| Page | Concept detail |
| --- | --- |
| Units | [Fleet, tickets, and meters](/concepts/units). |
| Commands | [Issues agents flag for the Executor](/concepts/commands). |
| Build Order | [Planning packs, phases, lanes, and dependencies](/concepts/build-orders). |
| Analytics | Lifecycle time, CPU, memory, concurrency, and cost; missing telemetry stays explicit. |

<img src="/images/dashboard/units-dark.png" alt="Desktop Units fleet table with synthetic active, blocked, retrying, and review tickets">

## Writable controls

| Writable control | Action |
| --- | --- |
| Unit | Pause or resume. |
| Command | Answer or revise. |
| Fleet | Adjust capacity. |
| Ticket | Apply routing labels. |

The CLI covers Unit and Fleet controls plus initial Command answers. Command revision and ticket-routing preview remain Dashboard-only today.

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

Aiur refuses to start a writable dashboard, or a dashboard bound beyond loopback, without both credentials. A loopback dashboard may run without them only when it is not writable. Put remote access behind a private network or trusted reverse proxy and use TLS there; Basic Auth does not encrypt transport.

The supervisor Decision API has a separate bearer credential, `AIUR_SUPERVISOR_TOKEN`. Dashboard credentials never grant machine-API authority, and the bearer token never signs a human browser action.
