# Build Order read cost

Date: 2026-08-17
Repository measured: `aiur-team/aiur` (5 `build-order` roots; root #1084 has 54 members)
Method: each query was issued with GitHub's own `rateLimit { cost }` selection and
the reported `cost` recorded. Observed consumption was **not** used to infer
per-query price — the daemon fleet shares the token, so observed numbers are
noisy and cannot be attributed to one caller.

## Reproduction

Re-measured independently on 2026-08-17 against the same repository, by issuing
`Aiur.BuildOrder.GitHubGraph.Queries.catalog/1` and `.selected/0` verbatim — the
shipped query text, which already selects `rateLimit { cost }` — and reading the
cost GitHub reported:

```
catalog cheap 25/page:        cost=1
catalog labelled 25/page:     cost=26
selected root #1084 100/page: cost=3
```

Every figure below reproduces. The "no validator" claim reproduces too: a
`POST https://api.github.com/graphql` returned `HTTP/2 200` with
`x-ratelimit-resource: graphql` and **no** `ETag`, `Last-Modified` or
`Cache-Control` header.

## Per-query price

| Read | Protocol | Measured cost | Revalidation |
| --- | --- | --- | --- |
| `AiurBuildOrderCatalog` (cheap variant, 25/page) | GraphQL | **1 point/page** | Not possible |
| `AiurBuildOrderCatalog` (labelled variant, 25/page) | GraphQL | **26 points/page** | Not possible |
| `AiurBuildOrderSelectedRoot` (54 members, 100/page) | GraphQL | **3 points/page, per selected root** | Not possible |
| `AiurLinkedPullRequests` (limit 20) | GraphQL | **1 point** | Not possible |
| `GET /repos/{owner}/{repo}/issues/{number}` | REST | 1 REST request | **`304` → no primary rate limit** |

### Why four of the five cannot be revalidated

Directly observed, not assumed. A `POST https://api.github.com/graphql` response
carries no `ETag`, no `Last-Modified`, and no `Cache-Control`:

```
HTTP/2 200
x-ratelimit-limit: 5000
x-ratelimit-remaining: 4968
x-ratelimit-reset: …
x-ratelimit-resource: graphql
```

There is no validator to send, so no GraphQL read in Aiur can ever answer `304`,
however it is written. That is the honest answer to "add conditional revalidation
to graph reads": for the graph, it is not available.

### What actually drives the cost: requests, not bytes

Corrected against measurement, because the opposite was assumed. GitHub's GraphQL
point cost is close to flat per request: #2084's instrumentation priced four live
call sites at **1 point each**, and a `build_order_catalog` read of 50 issues with
nested label connections cost the same single point as a one-field identity
lookup. So the daemon's observed ~250 points/minute is ~250 *requests* per minute,
about four per second.

That is not the same as "size is free", and the published algorithm says so:
`cost = round(connection_requests / 100)`, minimum 1. Anything under roughly 150
connection requests costs exactly one point, however much it asks for, and
`build_order_catalog` is ~51 connection requests. It is a steep discount below a
threshold, not indifference.

### Is the graph query over that threshold? Measured, at a real member count

Worth checking rather than assuming, because a Build Order root carries up to 54
members and a 5-member fixture would have read 1 point and proved nothing. Root
#1084 has 54 members (confirmed by `subIssues { totalCount }`), and the shipped
query was priced at four page sizes against it:

| `pageSize` | Requests for a full read | Measured cost | Total |
| --- | --- | --- | --- |
| 10 | 6 | 1 point | 6 points |
| 25 | 3 | 1 point | 3 points |
| 54 | 1 | **2 points** | **2 points** |
| 100 (shipped) | 1 | **3 points** | 3 points |

So the graph query **is** above the one-point floor, and page size does move it.
The available saving is exactly **1 point per full graph read** — 3 down to 2, by
asking for 54 per page instead of 100 — and it only holds at this member count:
the tuning is a function of the largest root, so it would be wrong again the next
time a root grows. Paginating smaller is worse, not better, because each page
costs its own minimum point.

That is the whole size lever, and it is one point. The cadence lever, by contrast,
was 240 requests/hour for a single selected root and 720 requests/hour for one
viewed graph at the 5-second demand floor, each costing at least one point.

The consequence for this change, stated plainly: **no field was removed and no page
size was changed.** Trimming was measured and found to be worth 1 point per read;
the cadences were worth two orders of magnitude more requests, so that is where the
work went. The numbers below are request counts priced at their measured point
cost, not payload sizes.

## Hourly cost, one catalog and one selected root

Derived from the code rather than from the query list, because an earlier version
of this table was not and got it wrong. The labelled catalog read is **not a
separate request**: `catalog_labels_due?/2` sets `member_labels?` on the one
scheduled catalog poll (`graph_projection.ex`), so a labelled read *replaces* that
cycle's cheap read rather than adding to it. Counting it as its own row
double-counted six requests an hour in both columns.

So one catalog poll per `catalog_refresh_ms`, of which one per
`catalog_labels_refresh_ms` is the expensive variant:

| | Before (catalog 60s, labels 600s, selected 15s) | After (catalog 120s, labels 600s, no selected cadence) |
| --- | --- | --- |
| catalog polls | 60/h | 30/h |
| — of which labelled | 6 | 6 |
| — of which cheap | 54 | 24 |
| selected root | 240/h | **no timer** |
| **scheduled requests/hour** | **300** | **30** |

| | Before | After |
| --- | --- | --- |
| catalog, cheap | 54 × 1 = 54 | 24 × 1 = 24 |
| catalog, labelled | 6 × 26 = 156 | 6 × 26 = 156 |
| selected root | 240 × 3 = 720 | **no timer** — 3 points/page per writer or explicit refresh |
| **total on a timer** | **930 points/hour** | **180 points/hour** |

The request row is the one to read. Per *viewed* graph the demand cadence alone
was 12 requests/minute at its 5s floor — 720/hour at 3 points, ~2,160 points/hour
— and the selected cadence another 4/minute at 15s. Both are now zero.

Cadences before: catalog 60s, labels 600s, selected 15s. After: the two catalog
cadences derive from the 120s tracker poll interval — catalog 120s, labels 600s —
and the selected root has no cadence at all. `graph_selected_refresh_ms` and
`graph_demand_refresh_ms` were deleted rather than retuned.

A selected root's 3 points/page is now bought by exactly two things, and neither
depends on a viewer:

- **The catalog reconciliation says the root moved.** Each catalog read carries a
  per-root change marker: `{identity, member_count, updated_at}` **plus a digest
  of the members' lifecycle states**. A watched root whose marker differs from the
  one recorded when its last read was *dispatched* is re-read once. A root that
  sits still is not re-read, however long anyone watches it.

  The member digest is the load-bearing part and it is free — the catalog query
  already asks every member for `state`/`stateReason`. Without it the marker is
  built only from the root issue, and **GitHub does not bump a parent issue's
  `updatedAt` when a sub-issue closes**, nor does closing change `member_count`.
  A member finishing — the change the page most exists to show — would leave the
  marker byte-identical and the graph would never be re-read at all. That is a
  worse regression than the cadence this replaces, and it is pinned by a test
  that fails against the root-only marker.
- **A watched root has never been read.** Bought once, on the catalog's cycle
  rather than on the viewer's, subject to the same failure backoff, and never
  again once it succeeds.

`Aiur.BuildOrder.GraphProjection.refresh/2` is the third, explicit path: a caller
saying "read this now". It has no production caller yet — it exists so that
removing the viewer cadence does not also remove an operator's ability to demand
a read, and an operator-facing refresh control is the obvious consumer.

The selected root's "after" figure is therefore not a per-hour number: it tracks
how often the repository changes, not how many people have the page open or for
how long. Opening the Build Order page, selecting a root, and holding it open buys
nothing.

### What the change marker does not catch

Named rather than left for someone to discover. GitHub does not bump a parent
issue's `updatedAt` when a sub-issue is relabelled, so a member moving from
`phase:1` to `phase:2` — or between build lanes — leaves the marker identical and
does not trigger a re-read. Under the deleted 15-second cadence that change
reached the page within one cadence; under this one it does not reach the page at
all until something else moves the root.

That is not a reason to keep a 15-second cadence, and it is not fixed by a tighter
marker either: the catalog read that produces the marker deliberately does not
resolve member labels on most polls, because that variant costs 26 points against
1 (#1766). The correct owner is the plan's slow safety sweep (U7, R9) — the one
timer that survives, existing to recover exactly this class of missed change.
Until that lands, an operator sees a relabelled member after the next change to
the root itself.

Build Order's timed GraphQL spend is now **180 points/hour**, about **3
points/minute**, across **30 requests/hour** — all of it catalog reconciliation:
24 cheap polls at 1 point and 6 labelled polls at 26. Everything else it spends is
caused by a change or an explicit request. No headline percentage is claimed for the improvement;
what remains unconditional is named below rather than averaged away.

## What this does not show

**Build Order was not the daemon's main GraphQL spender.** #2073 named it the
strongest candidate for the measured ~250 points/minute and asked for
confirmation rather than assumption; the measurement does not confirm it.

At the old cadences Build Order cost 930 points/hour, which is **~15.5
points/minute** — roughly **6%** of the observed ~250/minute. The remaining ~94%
is elsewhere and is still unattributed. #2084 is the ticket that attributes it.

Two caveats in Build Order's favour, both worth keeping in view:

- **The selected-root cost is per selected root.** With the maximum 32 roots
  selected, one refresh round is 32 × 3 = 96 points, and at the old 15s cadence
  that would have been ~23,000 points/hour — far past the budget. The typical
  single-root case was small; the worst case was not.
- **An open page used the demand cadence, not the selected one.** At the old 5s
  demand floor a root under active view refreshed ~720 times/hour at 3 points =
  ~2,160 points/hour, about 36 points/minute. Still under 15% of observed.

## What is still unconditional after this change

Named rather than folded into a percentage:

- A member being **relabelled** still does not move the change marker: the catalog
  read that produces it deliberately omits the per-member `labels` connection
  because that variant costs 26 points against 1 (#1766). A close is caught; a
  lane or phase change is not, until something else moves the root. That gap
  belongs to the plan's slow safety sweep (U7, R9).

- `AiurBuildOrderCatalog` — GraphQL, revalidation impossible. Controlled by
  cadence only: 30 polls/hour at a 120s poll interval, of which 6 buy the
  labelled variant — 24 × 1 + 6 × 26 = 180 points/hour.
- `AiurBuildOrderSelectedRoot`, `AiurLinkedPullRequests` — GraphQL, revalidation
  equally impossible, and now on no cadence at all. Their cost is 3 points/page
  and 1 point respectively, paid per writer or explicit refresh, so it is bounded
  by the repository's change rate rather than by viewing.
- `GET /repos/{owner}/{repo}/issues/{number}/timeline` — REST, issued per issue by
  `Aiur.GitHub.DispatchAuthorization` on the tracker poll path. Conditional
  support is possible and not done here.
- `GET /repos/{owner}/{repo}/issues/{number}` reached through
  `Aiur.GitHub.IssueDependencies` → `Aiur.GitHub.Client.fetch_issue_raw/2`. The
  same URL as the read that did become free, but a third caller that still goes
  through the unconditional `fetch_issue_raw/2` and neither reads nor populates
  the store. It is an orchestrator path rather than a Build Order one, so it is
  named here and left to the unit that owns that path.
- `GET /repos/{owner}/{repo}/issues?labels=build-lane:adhoc&state=all&per_page=100`
  — the Build Order ad-hoc epic poll, REST, every 60s. Conditional support is
  possible and not done here.

## Why graph bodies are not deposited in the shared store

The ticket-detail read is, because it is REST and the store's whole value there
is a validator plus a body two readers can share. A graph snapshot is not, and
the reasons are worth writing down rather than leaving as an omission:

1. **There is nothing to revalidate.** No GraphQL response carries a validator
   (verified above), so a stored graph entry could never turn a read into a
   `304`. The store cannot make a graph read cheaper; only cadence can, which is
   what this change does.
2. **`GraphProjection` is already the single owner.** It is one supervised
   process holding one entry per scope, and `request_scope/2` declines while a
   read is inflight — so two consumers demanding the same root already produce
   one upstream read within a boot. Depositing the same snapshot in a second
   place would add a second copy, not remove a fetch.
3. **A graph snapshot cannot survive the store's checkpoint.** The store persists
   as JSON and hands back whatever it decoded. A `SelectedRoot` is a nest of
   structs, so it would either be dropped on the way in or come back as
   string-keyed maps that no reader can use — and a body that cannot be encoded
   risks the checkpoint that every *other* resource type depends on.

So the graph's answer to "viewing never fetches" is cadence removal, not caching.

## What did become free

`GET /repos/{owner}/{repo}/issues/{number}` — the ticket-detail read — now goes
through `Aiur.GitHub.ResourceStore`, keyed by the issue rather than by the caller.
Proven by request count in
`src/test/aiur/build_order/shared_resource_store_test.exs`:

- a second read inside the freshness window issues **no request**;
- a refresh of an unchanged ticket is a `304`, which GitHub does not count
  against the primary rate limit;
- a ticket the daemon's per-issue reconciliation poll already fetched
  (`Issues.fetch_issue_states_by_ids_conditional/3`, reached from
  `Aiur.Orchestrator.Reconciler`) is served to Build Order with **no upstream
  call**, and the reverse direction costs a `304` rather than a second full read.
