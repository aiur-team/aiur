---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
date: 2026-08-17
---

# One GitHub State Cache - Plan

## Goal Capsule

**Objective.** Every read of GitHub state in Aiur resolves against one shared, persistent cache. Fetching happens only because some consumer genuinely needs data it does not have. Viewing a page never causes a fetch.

**Product authority.** Operator (`its-everdred`), decided 2026-08-17.

**Open blockers.** None. #2079 (comment double-fetch) is in flight and introduces `Aiur.GitHub.ResourceStore`, which this plan generalises rather than replaces.

## Product Contract

### The problem, measured

With the daemon moved onto its own GitHub App installation token — separating its budget from the agent PAT for the first time — the split became measurable:

```
~20 minutes after a daemon restart
daemon (App token) : graphql    0/5000    core 4808/5000   (192 REST calls)
agents (PAT)       : graphql 4376/5000
```

The daemon exhausted a fresh 5,000-point budget in roughly 20 minutes — about **250 points/minute, ~15,000/hour of demand against a 5,000/hour ceiling** — while the whole agent fleet spent ~624 points in the same window.

This inverted the prior working assumption. Until the tokens were split, both consumers drew from one PAT and an agent caught mid-`gh pr view` made "agents are the burn" the obvious answer. It was wrong.

### Why it is structural, not a tuning problem

A systematic survey of the tree, rather than the reactive sampling that produced the earlier partial findings:

- **90 modules** touch a GitHub fetch path.
- **31 separate caches or stores** exist.
- **10 distinct refresh cadences** are configured, the tightest at 5 seconds.

Conditional-request support is the exception, not the rule:

| subsystem | conditional-capable | fetch-touching |
|---|---|---|
| `github` | 6 | 28 |
| **`build_order`** | **0** | **7** |
| `orchestrator` | 3 | 7 |
| `events` | 2 | 3 |

`build_order` is the worst case and the leading cost suspect: zero conditional support anywhere in the directory, its own four-module private cache (`ticket_detail_cache` and friends), and the tightest cadences in the system — `graph_demand_refresh_ms: 5_000`, `graph_selected_refresh_ms: 15_000` — against graphs with up to 54 members, on an API that bills by connection size. A 304 is impossible there because no validator is ever sent.

Poll-interval tuning cannot fix this. #2064 already moved the tracker poll from 5s to 120s, which should put the comment sweep near 200 points/hour; measured consumption is roughly 75x that.

### The decided design

**One store. Writers write. Readers never fetch.**

**Readers** — the dashboard, LiveView pages, agents, and the daemon's own decision paths — resolve against the store. A reader that misses may request a fetch only if it genuinely needs the data to proceed.

**Writers** are the only source of upstream traffic:

1. **Mutation write-through.** When Aiur itself changes GitHub state — an agent posting a comment, applying a label, editing a ticket body, opening a PR — the API response already contains the new state. Write it straight to the store. **This writer costs nothing and is the fastest path**: the change is in the cache before any webhook for it could arrive, and no read is needed to learn about a change we ourselves made.
2. **Webhook deliveries.** Free, already normalised to the poller's exact shape. Covers changes made by humans and by anything outside Aiur.
3. **Need-driven fetches.** A path that must have data it does not hold fetches it once and writes it to the store.
4. **A slow safety sweep.** The only timer that survives, existing solely to recover lost webhook deliveries.

The worked example that motivates writer 1: the Build Order page shows ticket descriptions and comments, and assumes they are unchanged. An agent then updates a ticket. Under the old design nothing knows until a timer re-reads it at full price. Under this design the agent's own write populates the cache, the store publishes a change event, and Build Order re-renders **for free** — the update costs zero additional API calls because the agent had already paid for the round trip it needed anyway.

**Viewing never fetches.** This is the operator's decision and the sharpest constraint in this plan. A dashboard page opening, focusing, or sitting open produces **zero** API calls. It renders from the store and subscribes to store-change events.

**Cache writes propagate to viewers.** When any writer updates the store — a webhook delivery, or an agent fetching something because it needed it — subscribed views update automatically. The dashboard rides on other consumers' writes rather than generating its own reads.

The consequence worth stating plainly: **API cost becomes proportional to real change and real agent need, and completely independent of how many people are looking at how many pages.**

### Requirements

- **R1.** One store, keyed by **resource identity** — `(resource_type, owner, repo, id)` — never by call site. A resource fetched by any path satisfies every other path.
- **R2.** All four writers write to it. Webhook deliveries populate the store, not merely fire an event.
- **R2a.** **Mutations write through.** Every Aiur-originated change to GitHub state writes its response into the store: comments posted, labels applied, ticket bodies edited, PRs opened, reviews submitted. A change Aiur made must never require a read to discover.
- **R3.** Every reader resolves against the store before any upstream call.
- **R4.** No view-state read path may initiate a fetch. Opening, focusing, or holding a page open costs zero API calls.
- **R5.** Store changes publish events; subscribed views re-render without polling.
- **R6.** Need-driven fetches revalidate with `If-None-Match` where the API supports it. A 304 does not count against the primary rate limit.
- **R7.** Freshness is explicit per entry — `fetched_at`, `source`, `version` (the resource's `updated_at`), and an ETag where one exists. A consumer states the staleness it tolerates; the store answers or declines.
- **R8.** Entries and validators survive restart. Restarts are frequent; an in-memory cache re-pays full cost every time.
- **R9.** The safety sweep is the only timer touching GitHub for view state, and it exists solely for lost-delivery recovery. All other refresh cadences are removed or justified individually.
- **R10.** A consumer needing strictly-fresh data can demand it and bypass the cache. Merge decisions, CI verdicts and dispatch gating must never be silently served stale.
- **R11.** Degrade safely: a cold, corrupt or unavailable store behaves exactly as today — direct fetch. Never fail a read because the cache failed.
- **R12.** `ticket_detail_cache*` and other per-subsystem GitHub caches are **removed**, not bypassed.

### Acceptance criteria

- **A1.** Opening any dashboard page consumes **zero** primary rate limit, cold cache included — a cold read waits for a writer or the sweep rather than fetching.
- **A2.** Two consumers requesting the same resource inside the freshness window produce **one** upstream call. Assert call counts, not latency.
- **A3.** A resource whose webhook delivery already arrived is served with **zero** upstream calls.
- **A4.** An agent fetching a resource because it needed it causes any subscribed view of that resource to update, with no additional fetch.
- **A4a.** An agent **mutating** a resource — posting a comment, editing a body, applying a label — updates every subscribed view with **zero** additional API calls. Assert the call count is unchanged by the view update, and assert the view reflects the new state without waiting for a webhook.
- **A4b.** A mutation's write-through beats its own webhook: when the delivery for a change Aiur made arrives, it must be recognised as already-processed and cause no duplicate wake. (Uses the identity plus `version` suppression from KTD5.)
- **A5.** A steady-state period with no upstream change and no agent need consumes **zero** primary rate limit.
- **A6.** A resource whose webhook delivery was lost is still recovered by the sweep. Simulate a dropped delivery and assert recovery.
- **A7.** Restarting the daemon does not cause a full-cost repopulation.
- **A8.** An edited resource is not suppressed: a changed `updated_at` invalidates the entry.
- **A9.** With the store disabled, every existing behaviour and test passes unchanged.
- **A10.** `ticket_detail_cache*` is absent from the tree.
- **A11.** GraphQL consumption per hour drops by at least an order of magnitude at the same fleet size and viewer count.

### Key decisions

- **KTD1.** Keyed by resource identity, not call site. (`session-settled`: the operator's framing — three pipes, one store, read before spend.)
- **KTD2.** Viewing never fetches; the dashboard is a pure reader. (`session-settled`: operator, 2026-08-17.)
- **KTD3.** Cache writes propagate to viewers, so views ride on webhook and agent-need writes. (`session-settled`: operator, 2026-08-17.)
- **KTD4.** The store is a cache with reconciliation, never the system of record. Webhook loss is measured and real: 9 of 100 deliveries returned 502 during a restart, GitHub retried none, none arrived later.
- **KTD5.** Suppression keyed on identity plus `version`, never a timestamp watermark. A delivered resource must not advance a mark past an older sibling whose delivery was lost.
- **KTD6.** Cost is attributed before cadences are tuned (#2084). One confident wrong diagnosis has already been made here; the next change is evidence-led.

### Assumptions

- **AE1.** Build Order is the dominant consumer. This fits the numbers and the module survey but is **not proven**; #2084 confirms it. The plan does not depend on it being true — every path benefits regardless.
- **AE2.** GraphQL has no conditional-request mechanism, so graph reads cannot be made free by revalidation. They must instead become need-driven and rare.

## Implementation Units

### U1. Store foundation (cites R1, R7, R8, R11, KTD1, KTD5)

Generalise `Aiur.GitHub.ResourceStore` (from #2079) into the single store: resource-identity keys, per-entry `fetched_at`/`source`/`version`/`etag`, disk persistence with restart survival, and a safe-degrade path when unavailable. Cache response **bodies**, not just validators — an ETag shared between two consumers without the body gives the second a 304 and no data, converting a duplicate fetch into a dropped event.

### U2. Change events and view subscription (cites R5, A4, KTD3)

Publish a store-change event per resource write. Give LiveView pages a subscription so a write from any writer re-renders subscribed views.

### U3. Dashboard becomes a pure reader (cites R3, R4, A1)

Remove every fetch from view-state paths. Pages read the store and subscribe. A cold miss renders an explicit "not yet loaded" state rather than fetching.

### U4. Build Order onto the store (cites R6, R12, A2, A10)

Route graph and ticket-detail reads through the store. Retire all four `ticket_detail_cache*` modules. Make remaining reads need-driven; delete `graph_demand_refresh_ms` and `graph_selected_refresh_ms` or justify each individually.

### U4a. Mutation write-through (cites R2a, A4a, A4b)

Wrap every Aiur-originated GitHub mutation so its response populates the store and publishes a change event. Covers comment creation, label changes, body edits, PR creation and review submission — the paths in `Aiur.GitHub.Comments.create_comment/3`, the label writers behind `Tracker.update_issue_state/2`, and the PR/review mutations.

Cheapest unit in the plan and possibly the highest leverage: it removes an entire class of read (learning about our own changes) at zero cost, because the round trip was already paid. Sequence it early — it is independent of U3 and U4, and it makes their zero-fetch claims easier to hold.

The trap: the webhook for a self-made change arrives moments later. Without `version`-aware suppression it re-wakes agents for a change they made themselves, which is the `bot_account` self-loop problem in a new place.

### U5. Need-driven fetch path with revalidation (cites R6, R10)

One entry point for "I need this and do not have it": check store, revalidate with `If-None-Match` when a validator exists, fetch otherwise, write back, publish. Includes the explicit strict-freshness bypass.

### U6. Agent reads through the store (cites R1, R2, A2)

Route the agent `gh` wrapper's reads through the store so 16 agents asking for one PR produce one call. `command_scan.ex:40-41`'s call-site-keyed ETags fold in here.

### U7. Safety sweep only (cites R9, A6)

Reduce all view-state timers to one slow reconciliation sweep for lost deliveries. Bound suppression so a mapping mistake cannot hide a resource indefinitely.

### U8. Cost attribution (cites KTD6, A11)

`rateLimit { cost }` on GraphQL queries, per-call-site accounting, and a CLI view ranking consumers. Free on existing queries. This is #2084 and should land early enough to validate the rest.

## Validation

Every acceptance criterion is asserted by call count or measured rate limit, never by latency or inference. Cost measured with `rateLimit { cost }` rather than observed consumption, since fleet activity makes observed numbers noisy. No criterion is reported as a percentage: A1 and A5 are zero or they are unmet, and a path that is still unconditional is named rather than averaged away.
