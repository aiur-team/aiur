# Configuration reference: build_order

Sections of the [configuration reference](/reference/configuration) covering `build_order` and the resolution and validation notes.

## build_order

| Key | Type | Default | Controls |
| --- | --- | --- | --- |
| `build_order.ticket_detail_freshness_ms` | integer | derived (¼ poll interval, min 5000) | Freshness window for ticket detail. |
| `build_order.ticket_detail_max_entries` | integer | 32 | Maximum cached ticket-detail entries. |
| `build_order.ticket_detail_max_description_bytes` | integer | 16384 | Maximum cached ticket-description size. |
| `build_order.ticket_history_limit` | integer | 50 | Maximum ticket history records per view. |
| `build_order.ticket_history_max_identities` | integer | 100 | Maximum distinct ticket identities retained in history. |
| `build_order.ticket_history_stale_after_ms` | integer | 60000 | Minimum age after which ticket history is stale. It is a floor, not the final window: the effective window is always at least two poll intervals wide, so a value below the poll cadence does not mark correct data stale. |
| `build_order.graph_catalog_refresh_ms` | integer | derived (1× effective poll interval) | Base cadence for the Build Order catalog's reads (boot, a viewer's mount, a degraded re-list) and the window after which a selected root is displayed as ageing. The catalog is event-sourced (#2325) and demand-gated (#2312): it is maintained from the resource store's change stream, so this is not a recurring poll, and no page open means no read. |
| `build_order.graph_catalog_labels_refresh_ms` | integer | derived (5× effective poll interval, min 600000) | Cadence for the labelled catalog read that resolves epic and wave counts on a boot/mount/degraded read; the event-sourced catalog resolves those counts from the store instead. |
| `build_order.graph_refresh_timeout_ms` | integer | 30000 | Maximum graph-refresh request duration. |
| `build_order.graph_max_selected_roots` | integer | 32 | Maximum selected Build Order roots. |
| `build_order.graph_max_inflight` | integer | 4 | Maximum concurrent graph refreshes. |
| `build_order.general_epics` | array | Bugs, Design, Infra, Docs (below) | General epic definitions in column order. A list replaces the defaults; `[]` disables general epics. |
| `build_order.general_epics.key` | string | required | Lowercase identifier (letters, digits, dash, underscore); starts with a letter or digit. Must be unique; `unsorted` is reserved. |
| `build_order.general_epics.label` | string | required | Column header text, without control characters. |
| `build_order.general_epics.labels` | array | `[]` | GitHub label matchers, trimmed, downcased and deduplicated. A label may belong to one epic only. `epic:` matchers are refused because they mark parked tickets. |
| `build_order.general_epics.hue` | integer | required | Colour hue, 0–359. |
| `build_order.general_epics.icon` | string | required | One of `bug`, `pen`, `server`, `docs`. |

### General epics

Omitting `build_order`, omitting `general_epics`, or setting `general_epics: null` uses these defaults:

```yaml
build_order:
  general_epics:
    - { key: bugs, label: Bugs, labels: [bug], hue: 38, icon: bug }
    - { key: design, label: Design, labels: [design], hue: 312, icon: pen }
    - { key: infra, label: Infra, labels: [refactor, chore], hue: 200, icon: server }
    - { key: docs, label: Docs, labels: [documentation], hue: 100, icon: docs }
```

A configured list replaces all four defaults and keeps its order. Matchers within an entry are normalized; sharing a matcher across entries is a config error. For a ticket carrying different matched labels, config order defines which general epic wins. `enhancement` has no default matcher; add it to an epic if your repository uses it for that work.

These settings define the epic catalogue for the build history home page; its resolver and rendering are delivered separately.

### Two removed keys

`build_order.graph_selected_refresh_ms` and `build_order.graph_demand_refresh_ms`
no longer exist. They were the two settings by which *viewing* bought GitHub
reads: the demand cadence fired when an operator selected a root, and the
selected cadence repeated for as long as the page stayed open.

No value makes that correct, because it makes API cost track how many people are
looking rather than what has changed. They were removed rather than retuned.

A selected root is now read by the daemon's own catalog reconciliation, and by
nothing else. Each catalog update carries a per-root change marker — the root's
identity, member count and update time, plus a digest of its members' states — and
a watched root whose marker moved is re-read once, as is a watched root that has
never been read.

Selecting a root and holding it open consume zero GitHub reads.

The **catalog** itself is different: it is the most expensive single query in the
system, and since #2312 it is demand-gated on an open Build Order page. Opening
`/build-orders` renders the stored snapshot immediately (with its age), then buys
one refresh on mount.

While any Build Order page stays open the catalog reconciles on the cadence
below; closing the last page stops it entirely, so a headless run — the normal
case — buys none of it.

`Aiur.BuildOrder.GraphProjection.refresh/2` is the explicit "read this now" path.
It exists so that removing the viewer cadence does not also remove an operator's
ability to demand a read, but **nothing calls it yet** — an operator-facing
refresh control is its intended consumer.

A configuration that still sets either key keeps loading unchanged: unknown keys
are ignored rather than rejected, so an upgrade gets the new behaviour instead of
a boot failure.

### Derived Build Order cadences

Three of these keys have no fixed default. They are derived from the poll
interval, and setting any of them explicitly overrides the derivation.

Build Order displays state that the tracker produces, so it cannot be fresher
than the tracker's own cycle. Refreshing faster only re-reads a graph that cannot
have moved.

The previous fixed defaults were chosen when the tracker polled every 5 seconds,
and did not move when the tracker changed to 120 seconds. Deriving them is what
stops that recurring.

Since #2325 the Build Order **catalog is event-sourced**: it is maintained from
`Aiur.GitHub.ResourceStore` change events, so there is no recurring catalog poll
at all — a root's membership and a blocked-by edge reach the page the moment the
delivery deposits them.

What remains on a cadence is the boot fill (one GraphQL read per daemon start),
the degraded re-read, and the selected-root reads those changes trigger; the two
graph keys below size those and the staleness window that follows, and they
follow the *effective* interval: the one the daemon actually scheduled.

- It is not `polling.interval_seconds` alone. It includes
  `polling.idle_widen_factor` and `webhooks.poll_widen_factor`.
- It is the value `aiur status` reports as `interval=`.
- So an idle fleet widens the catalog's reads and the staleness window exactly
  as it widens the tracker, and a fleet that picks up work narrows both back
  together.
- The widening matters only while a page is open: the catalog is event-sourced
  (#2325) and demand-gated (#2312), so with no Build Order page open it neither
  polls nor reads — it costs nothing rather than merely running slowly.

`ticket_detail_freshness_ms` follows the **base** interval instead. It is a
staleness window for the ticket-detail drawer, read once when the daemon starts
and never re-derived, so tying it to a cadence that moves would freeze it at
whatever the cadence was at boot.

Each derivation, and the values it produces at a 120s base interval:

| Key | Derivation | Busy fleet | Idle, polling repo | Idle, webhook-backed |
| --- | --- | --- | --- | --- |
| `graph_catalog_refresh_ms` | 1× effective interval, ceiling 3600000 | 120000 | 600000 | 1200000 |
| `graph_catalog_labels_refresh_ms` | 5× effective interval, floor 600000, ceiling 3600000, never below `graph_catalog_refresh_ms` | 600000 | 3000000 | 3600000 |
| `ticket_detail_freshness_ms` | ¼ base interval, floor 5000, ceiling 300000 | 30000 | 30000 | 30000 |

The effective interval at idle is 600s for a repository Aiur polls, and 1200s
once that repository is a proven webhook source (`webhooks.poll_widen_factor`
multiplies again). The labelled catalog read reaches its 3600000 ceiling in that
last column.

`graph_catalog_labels_refresh_ms` covers the 26-point labelled variant used by
the boot fill and a degraded re-read, so it is the slowest of the three, and it
can never fall below the catalog cadence it rides on — a labels read that
outran the catalog read would make every boot or degraded re-read buy the
expensive query.

`ticket_detail_freshness_ms` is not a cadence: nothing fires on it. It is the
staleness a ticket-detail reader accepts from the shared store before
revalidating, and it is allowed to be tighter than the graph cadences because it
is the only one of the three backed by a REST read — so the only one whose
refresh can be a free `304` rather than a paid query.

### What these cadences cost

GitHub's GraphQL API sends no `ETag`, no `Last-Modified` and no `Cache-Control`,
and every query is a `POST`. There is no conditional request to make, so no
GraphQL read below can ever return `304`, however it is written.

What that leaves is **how often a query runs**, which is where almost all of the
cost is.

GitHub's point cost is `round(connection_requests / 100)`, with a minimum of one
point. Anything below roughly 150 connection requests therefore costs exactly one
point, however much it asks for.

Size is not free above that threshold, but the lever is small: measured, a
54-member Build Order root costs 3 points at the shipped 100-per-page and 2 at
54-per-page. Running a query less often is worth far more than making it leaner.

Measured against `aiur-team/aiur` with GitHub's own `rateLimit { cost }`:

| Read | Protocol | Cost | Revalidation |
| --- | --- | --- | --- |
| `AiurBuildOrderCatalog` (cheap) | GraphQL | 1 point/page | Not possible |
| `AiurBuildOrderCatalog` (labelled) | GraphQL | 26 points/page | Not possible |
| `AiurBuildOrderSelectedRoot` (54 members) | GraphQL | 3 points/page, per selected root | Not possible |
| `AiurLinkedPullRequests` | GraphQL | 1 point | Not possible |
| `GET /repos/{owner}/{repo}/issues/{number}` | REST | 1 REST request | **`304`, which costs no primary rate limit** |

## Resolution & validation notes

- An unset or blank `prompt_file` falls back to the built-in default prompt; a configured unreadable path fails startup.
- A legacy top-level `linear:` section is merged into `tracker.linear`.
- Only `$VAR` environment references resolve; legacy `env:NAME` values remain literal.
- `polling.interval_ms` is rejected by the loader; use `interval_seconds`.
