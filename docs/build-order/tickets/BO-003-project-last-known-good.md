# BO-003 — Project atomic last-known-good graphs

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — Supervised dual-cache lifecycle and GitHub budget integration

**Risk:** high

**Phase hint:** 3

**Depends on:** BO-002

**Serializes with:** BO-004

**Requirements:** BOREQ-001, BOREQ-004, BOREQ-007, BOREQ-012

**Decisions:** DEC-002, DEC-005

**Design evidence:** DESIGN-002

**Researched at:** 3d67b7be722eb649f28088fc8d609dd7b75254c7

**Suggested labels:** `complexity:4`, `model:codex`, `phase:3`, `build-lane:backend`; never `agent:todo`

## Outcome

The daemon exposes one independently healthy root catalog and demand-driven selected-order snapshot, replacing only complete validated generations and preserving explicit stale or unavailable state through provider failures.

## Context and evidence

`ControlCenterCache` coalesces reads but is not a validity or last-known-good boundary. Build Order needs catalog discovery and selected graph health to degrade independently, without multiplying GitHub work by LiveView/browser count or continuously polling every root.

This process shares supervision-tree and application-test surfaces with BO-004, so the two tickets serialize even though neither semantically depends on the other.

## Scope

- Add a supervised projection with separate root-catalog and per-selected-root generations, health, last success/attempt, failure class, freshness, next retry, and generation ID.
- Validate the complete adapter candidate before atomic replacement; retain the prior validated generation on every fetch/validation failure.
- Coalesce simultaneous browser demand, use bounded TTL/eviction for selected roots, and integrate with the repository's GitHub polling/rate-limit budget.
- Define initial unavailable, loading, fresh, stale, invalid, and retrying states and publish generation/health changes over PubSub.
- Decide and test lifecycle when the dashboard is disabled or no root is selected; avoid idle polling that has no consumer.
- Expose deterministic snapshot and refresh APIs suitable for Presenter/LiveView injection tests.

## Non-goals

- Parse GitHub responses, render the graph, join runtime activity, or mutate GitHub.
- Poll every known root, create one poller per browser, or clear a prior graph after failure.
- Implement webhook-only consistency; webhook invalidation may be a follow-up.

## Existing owner and reuse target

Follow the retain-on-failure discipline in `Aiur.WorkflowStore` and snapshot/health conventions in `Aiur.RecentMergeStore`; do not repurpose either store or the presentation-only `ControlCenterCache`.

## Contract and invariants

- Catalog health never silently substitutes for selected-graph health or vice versa.
- Only a fully validated candidate advances a generation. Stale snapshots retain their data plus failure/freshness metadata.
- Demand for the same canonical root coalesces; mutable issue-number lookup resolves to the canonical node-ID cache key.
- Cache/poll work is daemon-scoped and bounded independently of connected browsers.
- Eviction removes inactive cached generations, not durable GitHub truth, and a later selection refetches safely.

## Refreshable implementation notes

- Likely modules live under `Aiur.BuildOrder.Projection`; refresh application supervision seams at pickup.
- Refresh the current GitHub polling-budget implementation and PR #1009 lineage before coding.
- Prefer monotonic time for scheduling and wall-clock ISO timestamps for operator evidence.

## Acceptance and verification

### Agent gate

- Deterministic process tests cover first success, initial failure, stale LKG, recovery, catalog-only failure, selected-only failure, concurrent demand coalescing, TTL/eviction, refresh retry, and shutdown.
- Tests prove N connected LiveViews do not create N GitHub fetches and an incomplete candidate never replaces the prior generation.
- Supervision restart tests prove no crash loop and honest unavailable state after in-memory restart.

### At-merge gate

- Projection tests pass without sleeps, application supervision tests are green, and current-base full CI passes.
- Rate/call-budget assertions are documented and verified with the 100-member fixture.

### Human/manual evidence

- No separate human evidence; BO-011 owns end-to-end operator proof.

## Failure, security, migration, and accessibility cases

- Security: cache only normalized tracker facts and structured redacted errors.
- Migration: in-memory v1 means restart loses LKG; the post-restart state must say unavailable rather than infer an empty graph.
- Accessibility: provider health carries concise operator-facing reason and retry/freshness metadata.

## Surfaces

- Reads: complete GitHub adapter candidates; dashboard enablement/config; GitHub poll budget.
- Writes: supervised graph projection; catalog/order snapshots and PubSub.
- Contracts: catalog snapshot API; selected-order snapshot API; generation health/freshness.

## Sibling boundaries and open gates

BO-002 owns fetch completeness. BO-004 serializes on application supervision but owns runtime activity. BO-009 consumes snapshots and must not add polling.

