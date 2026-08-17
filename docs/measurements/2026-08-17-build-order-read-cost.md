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
however it is written. For those queries cadence and connection size are the
entire cost story. That is why this change derives the cadences that survive and
deletes the two that existed only to serve viewers, rather than adding
conditional requests to them, and it is the honest answer to "add conditional
revalidation to graph reads": for the graph, it is not available.

## Hourly cost, one catalog and one selected root

| | Before | After |
| --- | --- | --- |
| catalog, cheap | 60/h × 1 = 60 | 30/h × 1 = 30 |
| catalog, labelled | 6/h × 26 = 156 | 6/h × 26 = 156 |
| selected root | 240/h × 3 = 720 | **no timer** — 3 points/page per writer or explicit refresh |
| **total on a timer** | **~936 points/hour** | **186 points/hour** |

Cadences before: catalog 60s, labels 600s, selected 15s. After: the two catalog
cadences derive from the 120s tracker poll interval — catalog 120s, labels 600s —
and the selected root has no cadence at all. `graph_selected_refresh_ms` and
`graph_demand_refresh_ms` were deleted rather than retuned.

A selected root's 3 points/page is now bought by exactly two things, and neither
depends on a viewer:

- **The catalog reconciliation says the root moved.** Each catalog read carries a
  per-root change marker — `{identity, member_count, updated_at}`, the same
  triple `Catalog.carry_forward_counts/2` matches on — and a watched root whose
  marker differs from the one recorded at its last successful read is re-read
  once. A root that sits still is not re-read, however long anyone watches it.
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

Build Order's timed GraphQL spend is now **186 points/hour**, about **3.1
points/minute**, all of it catalog reconciliation — 30 cheap catalog reads at 1
point and 6 labelled reads at 26. Everything else it spends is caused by a change
or an explicit request. No headline percentage is claimed for the improvement;
what remains unconditional is named below rather than averaged away.

## What this does not show

**Build Order was not the daemon's main GraphQL spender.** #2073 named it the
strongest candidate for the measured ~250 points/minute and asked for
confirmation rather than assumption; the measurement does not confirm it.

At the old cadences Build Order cost ~936 points/hour, which is **~15.6
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

- `AiurBuildOrderCatalog` — GraphQL, revalidation impossible. Controlled by
  cadence only: 30 cheap reads (1 point) and 6 labelled reads (26 points) per
  hour at a 120s poll interval, 186 points/hour together.
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
