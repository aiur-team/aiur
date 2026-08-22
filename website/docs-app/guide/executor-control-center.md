# Dashboard

The Dashboard is Aiur's browser interface for supervising a run. It combines the live fleet, durable decisions, recorded outcomes, provider meters, Build Orders, and analytics.

## Open the dashboard

| Launch condition | Dashboard result |
| --- | --- |
| Normal foreground or headless run | Listener requested. |
| `--no-dashboard` | Listener disabled. |
| Writable mode | Username and password required, including on loopback. |
| Read-only loopback | Requires credentials for access. Without them the listener may bind, but every request returns `503`. |
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
| **GitHub cache** | `/github-cache` is a read-only inspector for the shared GitHub state cache. | none |
| **Streamdeck+** | `/streamdeck` is the browser emulator for the physical Stream Deck + sidecar. | none |

| Route change | Behavior |
| --- | --- |
| `/commands` and `/commands/:decision_id` | Current Commands inbox and detail URLs. |
| `/decisions` and `/decisions/:decision_id` | Redirect permanently to the `/commands` equivalents. |
| `/api/v1/decisions`, `decision_id`, event topics | Keep the **decision** vocabulary for compatibility. |

The operator-facing UI and CLI call these records **Commands**.

Dashboard data tables sort by their meaningful column headings. The first click sorts descending, the second reverses the order, and the active heading shows its direction. Icon and action columns are not sortable.

The `sort` query parameter preserves the selected table, column, and direction in copied or refreshed URLs. Paginated and progressively revealed tables sort the displayed rows, then reapply that order when more rows appear.

## The pages

Each page renders a durable concept whose detail lives in Concepts.

| Page | Concept detail |
| --- | --- |
| Units | [Fleet, tickets, and meters](/concepts/units). |
| Commands | [Issues agents flag for the Executor](/concepts/commands). |
| Build Order | [Planning packs, phases, lanes, and dependencies](/concepts/build-orders). |
| Analytics | Lifecycle time, CPU, memory, concurrency, and cost; missing telemetry stays explicit. |
| GitHub cache | What the shared GitHub state cache holds right now, and which writer put it there. |

<img src="/images/dashboard/units-dark.png" alt="Desktop Units fleet table with synthetic active, blocked, retrying, and review tickets">

## GitHub cache

Aiur reads GitHub state through one shared store. Webhook deliveries, Aiur's own mutations, need-driven fetches, and the safety sweep all write to it, and every consumer reads it before spending a token. `/github-cache` shows what that store currently holds.

The page is strictly view-only. There is no refresh, no invalidate, no eviction and no fetch-now.

That is the store's own rule applied to its inspector: looking at cached state never costs a GitHub call, so a page that could trigger a fetch would break the property it exists to demonstrate.

Its headline tile, **Fetches caused by viewing**, counts GitHub requests whose request chain began in a LiveView process. Merely opening or navigating the cache inspector leaves it at `0`; operator actions on other pages that intentionally fetch fresh detail can raise it.

Caller names are shown separately and do not determine this count. Beside it the page prints how many calls the quota meter attributed in total, so a zero reads as a measurement rather than a reassurance.

The **What is spending the budget** table ranks each observed caller by the points that reached GitHub in the current rate-limit window. Its **ReadCache served free** column adds context from `ReadCache` only: caller-wide reads answered since this daemon boot.

Read the column as follows:

- A positive read count means low spend may be the cache doing its job.
- **none this boot** means `ReadCache` observed the caller but served no reads.
- A **policy refusal** means the caller reached `ReadCache` but was deliberately not cached.
- **not observed by ReadCache** means the caller did not reach that store.
- **cache unavailable** means there is no cache measurement.

None of the four non-count states is rendered as a bare zero.

Served-free reads cost no GitHub budget. They are shown alongside the ranking for diagnosis, but are excluded from points, calls, rates, shares, charts, attributed totals and outside-spend figures.

Cache counters do not identify a GitHub budget, so callers seen only by the cache are not assigned to the GraphQL or core table.

Reads served by `ResourceStore` are also outside this column. The header explicitly names `ReadCache`, so absence from one store is not presented as absence from every shared-state path.

It updates live. The page subscribes to the store's own change events, so a webhook delivery or an agent mutation landing is visible arriving — the row that changed flashes — without polling anything.

Three layers, each addressable and each reachable from the one above:

| Layer | Route | Shows |
| --- | --- | --- |
| Map | `/github-cache` | Every resource type as a tile, sized by how many entries it holds and tinted by how old its worst entry is. |
| Group | `/github-cache/:resource_type` | That type's entries, searchable by identity and filterable by freshness, writer and body state. |
| Entry | `/github-cache/:resource_type/:identity` | One record in full: key, `fetched_at`, processed version, body version, ETag, last writer, and the cached body. |

Above the map, two **history charts** show the same cache as a time-series rather than a snapshot:

| Chart | Shows |
| --- | --- |
| Entries over time | Total entries, how many hold a body, how many are validator-only — so a cache that grew and then dropped reads as a shape. |
| Freshness over time | The same totals stacked by freshness (fresh / older / expired / unknown) — so a cache quietly aging is a band that grows, not a number to compare. |

The charts are fed by a sampler that reads the same store the page reads — never GitHub — every 30 seconds and keeps a bounded, in-memory ring of the last hour.

The ring starts again at each daemon boot, and the page says so, because drawing a flat zero over a span the sampler never observed would be the same silent-subset lie the rest of the page refuses. When the ring is too new to draw, the page says it is collecting.

Filters are carried in the query string, so a filtered view such as `/github-cache/issue_comment?writer=webhook` can be pasted into a ticket as evidence. A deep link to an entry keeps meaning the same thing after a restart, because the identity is the resource's own `(type, owner, repo, id)` rather than a position in a list.

### Read "validator only, no body" carefully

An entry can hold an ETag and no cached body. That is a legitimate state: dropping a body deliberately keeps the validator, which still answers "has this changed?" cheaply.

It is **not** a cache hit. A consumer that sends that ETag is answered `304` with no data, so it spends a call and learns nothing. It has to re-read unconditionally instead.

The page shows those entries distinctly rather than as cached: their own count in the headline strip, their own filter, a marked row, and a `none — validator only` body cell. When a read you expected to be free still cost something, look here first.

Cached bodies are redacted on the way out and collapsed by default. A large store is truncated per resource type, with the number of undrawn entries stated rather than a subset shown as if it were everything.

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

Aiur refuses to start a writable dashboard, or a dashboard bound beyond loopback, without both credentials. A read-only loopback listener may bind without them, but its authentication plug fails closed and returns `503` for every dashboard request until both credentials are set.

Put remote access behind a private network or trusted reverse proxy and use TLS there; Basic Auth does not encrypt transport.

The supervisor Decision API has a separate bearer credential, `AIUR_SUPERVISOR_TOKEN`. Dashboard credentials never grant machine-API authority, and the bearer token never signs a human browser action.
