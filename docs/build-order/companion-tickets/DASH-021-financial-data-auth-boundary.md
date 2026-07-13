# DASH-021 — Enforce financial-data authentication

**Kind:** executable

**Provenance:** planned in plan v1 after security-boundary review

**Complexity:** 3 — Server-side query, subscription, assign, event, and cache boundary for protected accounting facts

**Risk:** high

**Depends on:** DASH-001

**Serializes with:** DASH-003, DASH-005, DASH-007, DASH-022 — shared `DashboardLive`/auth composition

**External gate:** `GATE-OCC-PREDECESSOR-BASELINE` — resolve before dispatch

**Requirements:** DREQ-021

**Researched at:** `9849f32963c2a65367bce565b3f5ede3777c218f`

**Suggested labels:** `complexity:3`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Usage, token, cost, provider account, plan, quota, rate, credit, and reset facts can cross the web boundary only for a connection under configured and enforced dashboard authentication; every other connection receives a content-free locked contract.

## Context and evidence

Current loopback read-only dashboards may run without Basic Auth. Merely hiding financial cards in HEEx would still permit protected facts to enter LiveView assigns, PubSub messages, caches, events, or generic APIs. This ticket establishes the server-side access boundary independently of DASH-015 presentation. Nonfinancial run status remains available through DASH-022.

## Scope

- Define one server-side `financial_data_access` decision derived from endpoint authentication configuration and the authenticated connection/session established by trusted plugs/hooks. Browser flags and mount parameters are never authority.
- Classify records by source/context, not field name. Usage/cost/group and provider-meter/account records are protected, including their provider/backend/model dimensions, auth mode, plan/tier, quota/rate/credit/spend controls, percentages/limits, reset times, freshness, health, and retained LKG values.
- Keep nonfinancial runtime execution facts public under existing read-only policy: StatusReport/Units backend, agent family, requested/resolved model, lifecycle, waiting reason, and progress do not become financial merely because protected accounting records use similarly named fields.
- Add protected query facades for usage/grouping and provider-meter snapshots. Denied callers receive a stable content-free `authentication_required` result without invoking the underlying provider.
- Separate protected update delivery from generic dashboard PubSub. Authenticate before subscribing and before delivering/reloading; an unauthorized connection never receives a protected payload.
- Ensure protected financial records never enter denied LiveView assigns, rendered HTML, client events, serialized diffs, connection-scoped caches, logs, telemetry metadata, or generic observability/state APIs, while preserving authorized nonfinancial StatusReport/Units facts.
- Define a content-free locked descriptor and capability state for DASH-015. It may identify that authentication is required but contains no provider, account, usage, plan, quota, reset, freshness, or monetary facts.
- Preserve existing supervisor authentication, CSRF, same-origin, writable/read-only, secure-document, and nonfinancial dashboard behavior. Financial read authorization does not grant mutation authority.
- Define cache keys/eviction so authenticated payloads cannot be reused by an unauthenticated connection or after authentication configuration/generation changes.

## Non-goals

- Render provider cards, ingest/query provider data directly, change usage/meter semantics, require auth for existing allowed nonfinancial loopback status, or redesign all dashboard authentication.
- Put protected values in a hidden DOM node, redact them only after provider query/subscription, or block nonfinancial Units backend/model by matching field names globally.
- Treat loopback, writable mode, supervisor capability, browser local state, or possession of a route as authenticated financial access.

## Existing owner and reuse target

Extend `AiurWeb.Router`, current Basic/Supervisor authentication plugs/hooks, dashboard provider loaders, LiveView mount/connect lifecycle, PubSub subscription boundaries, and cache helpers. Reuse DASH-001 route metadata while keeping policy in a shared server-side authorization module.

## Contract and invariants

- Authentication is enforced before protected query, subscription, assignment, event serialization, caching, or render.
- Denied mode is content-free and does not call the underlying protected provider. Hiding after fetch is a failure.
- Financial read access, supervisor authority, writable mode, CSRF, and runtime control capability are separate decisions.
- Protected cache/subscription identity includes authenticated connection/config generation and cannot cross to a denied connection.
- Nonfinancial DASH-014 and DASH-016 StatusReport/Units facts remain available according to existing dashboard policy. Provider/backend/model is protected only inside a financial record, never by name alone.

## Refreshable implementation notes

- Refresh current auth plug/session/LiveView topology at pickup. If enforced-auth state is not exposed safely to LiveView, add the smallest server-side contract rather than trusting request params.
- Inventory every generic dashboard/observability endpoint, assign, cache, and PubSub topic that could expose protected record classes before writing the policy; preserve explicit StatusReport/Units allowlist coverage.
- Test with synthetic sentinel values that are easy to search across HTML, serialized events, process state, logs, and cache output.

## Acceptance and verification

### Agent gate

- Authorization tests cover auth configured/enforced, absent, invalid, connection/config generation change, read-only/writable combinations, supervisor capability, and direct protected-facade calls.
- Nonleakage tests prove denied mode never invokes financial providers and contains none of the sentinel token, cost, group, account, auth-mode, plan/tier, quota/rate/credit, percentage/limit/reset, freshness, or LKG records in HTML, assigns, LiveView diffs/events, subscriptions, caches, logs, telemetry, or generic APIs.
- Units regressions render unauthenticated read-only StatusReport backend, agent family, requested/resolved model, lifecycle, waiting, and progress values, proving they remain visible while identically named dimensions inside financial fixtures remain absent.
- PubSub/cache race tests cover authentication loss/config change, reconnect, stale queued message, cache reuse, and provider update concurrent with disconnect without sleeps.
- Regression tests prove allowed nonfinancial status, Analytics security, CSRF, supervisor auth, and runtime write gates retain their prior behavior.

### At-merge gate

- Rebase on DASH-001 and the resolved configured integration target; run router/auth, LiveView connect, provider loader, PubSub/cache, observability API, Analytics, CSRF/write-gate, security, and full CI suites.

### Human/manual evidence

- From the Executor repository root, compare authenticated and optional unauthenticated dashboard connections using synthetic protected values. Confirm authenticated queries/subscriptions work and denied rendered source/network events contain only the content-free locked contract.

## Failure, security, migration, and accessibility cases

- Ambiguous/missing auth evidence fails closed for protected facts while preserving permitted nonfinancial dashboard health.
- No protected financial record enters logs, prompts, bug reports, telemetry labels, unauthenticated caches, or generic APIs. Nonfinancial runtime backend/model remains available. Use synthetic fixtures in evidence.
- No stored-data migration. Version the access/locked contract so future consumers cannot bypass it accidentally.
- The locked state exposes a concise accessible name/reason and authentication path without revealing protected facts.

## Surfaces

- Reads: trusted dashboard auth/session/config state and provider capability metadata without provider facts.
- Writes: financial authorization policy, protected query/subscription facades, content-free locked contract, cache/loader integration, security tests.
- Contracts: record-context-aware financial-data access and protected-delivery boundary; nonfinancial runtime-fact preservation.

## Sibling boundaries and open gates

DASH-015 is the only companion UI allowed to consume protected provider/usage facades. DASH-022 consumes nonfinancial DASH-014 directly and remains functional in optional unauthenticated read-only mode. This ticket owns authorization, not visual composition.
