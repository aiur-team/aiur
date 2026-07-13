# DASH-015 — Render accessible usage and run summary

**Kind:** executable

**Provenance:** planned in plan v1 after refreshed-prototype and backend-capability review

**Complexity:** 4 — Authenticated responsive composition across seven independently degrading contracts

**Risk:** high

**Depends on:** DASH-001, DASH-003, DASH-010, DASH-011, DASH-012, DASH-013, DASH-014

**Serializes with:** Units summary, DashboardLive, shell/shared CSS, and dashboard authentication changes

**External gate:** `GATE-OCC-PREDECESSOR-BASELINE` — resolve before dispatch

**Requirements:** DREQ-015

**Researched at:** `1e0cfba31c0e6cc4fea14a25e8b4344ef1d6d67d`

**Suggested labels:** `complexity:4`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

The Units page renders authenticated, responsive Aiur, Codex, and Claude summary cards with truthful current-run status, tokens, comparable cost bases, plan/quota facts, retained coverage, freshness, and accessible drill-down—without exposing usage or account/meter values on an unauthenticated dashboard.

## Context and evidence

The refreshed prototype adds Units-only Codex/Claude usage cards and an Aiur summary, but all values are static, its `$50.47` total combines unexplained costs, and its responsive order/clipping are not acceptable. Current loopback read-only dashboards may run without Basic Auth, so merely placing financial data on an existing route does not keep it authenticated. The prerequisite tickets supply normalized data; this ticket owns composition and disclosure only.

## Scope

- Render the Aiur current-run summary first in both DOM and visual order using DASH-014: live/remaining/terminal counts, weighted progress denominator/coverage, wall elapsed, and ETA formula/provenance or explicit unavailable reason.
- Render Codex and Claude provider cards from DASH-012/013: generation-scoped plan/tier with source/freshness, auth mode, supported subscription windows or API-key controls, reset timestamps, per-window health, stale last-known-good, partial, unsupported field, loading, empty-supported, and hard-error states. Do not fetch providers from LiveView/browser render.
- Render DASH-011 current-run token and cost groups, including totals and accessible drill-down by ticket, agent family, backend, exact model, currency, and opaque provider-account generation. Preserve total tokens alongside provider split. A reusable query/component input may accept an explicit typed Build Order member set, but Units defaults to and labels `this run`; it never infers `this build`.
- Join a usage group to DASH-012/013 plan/tier facts only when provider,
  backend, and the exact known opaque `provider_account_generation` all match.
  A generation-unknown group shows tier `unknown`; a group spanning multiple
  generations shows tier `mixed`; a known mismatch remains visibly unjoined.
  Never fall back to provider/backend, current login, render order, or the only
  meter card on screen. A meter may describe its own current tier, but that tier
  cannot be presented as the usage estimate's plan without the exact join.
- Display `provider_reported_estimate` and `api_equivalent_estimate` in separate labelled buckets and never sum them across basis, currency, or account generation. For subscription usage, show the API-equivalent dollar value with `*` and an information popover explaining that it is an estimate rather than billed spend. Show the actual plan tier beside that estimate only after the exact-generation join; otherwise show the explicit `unknown`, `mixed`, or generation-mismatch state rather than a guessed tier. Unknown cost is not `$0.00`.
- Enforce the account-data boundary server-side: usage tokens/cost/groups and every provider-meter/account fact are queried and rendered only when dashboard authentication is configured and enforced for the connection. Protected meter facts include provider/backend, auth mode, plan/tier, quota/rate/credit/spend-control windows, percentages/limits, reset times, freshness and retained last-known-good values. Otherwise render a locked “authentication required” state with none of those facts in HTML, assigns, client events, caches keyed for an unauthenticated connection, or generic state APIs. Existing nonfinancial local read-only run facts may remain available.
- Authenticated connections subscribe to daemon-owned meter/ledger and run-summary updates; locked connections subscribe only to the nonfinancial run summary and never receive protected payloads. Coalesce render/screen-reader announcements. Keep independent provider failures isolated; one unavailable card does not erase healthy run or other-provider facts.
- Reflow every fact, control, reset, disclosure, and drill-down at 320/390/768/960/desktop and 200% text zoom, accounting for DASH-001 safe-area/navigation offsets. Use native/ARIA meter/progress semantics and at least 44px interactive targets.

## Non-goals

- Ingest usage/meters, persist ledger data, apply prices, compute run progress/ETA, allocate subscription fees, call provider billing APIs, redesign Analytics, or make this companion work part of Build Order completion.
- Fetch providers per browser, combine unlike cost bases/currencies/account
  generations, correlate tier by provider/backend alone, show fake
  session/weekly bars for API accounts, or leak usage/account/meter values
  before authentication.
- Copy prototype static values, CSS-only visual reordering, inaccessible meter divs, or an unbounded table into the summary.

## Existing owner and reuse target

Add shared OCC summary presenters/components to DASH-003's Units page and DASH-001 shell. Consume DASH-010/011/012/013/014 APIs through daemon providers, reuse current provider-health/LiveView PubSub and authentication patterns, and keep provider/accounting policy outside `AiurWeb`.

## Contract and invariants

- Every number names scope, source/basis, coverage, and freshness where relevant. `this run` and explicit `this build` are never interchangeable.
- Unlike cost bases, currencies, and account generations are separate.
  Subscription estimates always carry `*` and explanatory popover; actual tier
  appears with an estimate only for an exact known provider/backend/generation
  match. Unknown, mixed, and mismatch tier states are explicit, and no UI copy
  calls estimates billed/actual spend.
- Usage and all account/meter values cross the web boundary only for an authenticated connection under enforced dashboard auth. Locked mode contains no hidden plan, auth-mode, quota, rate, credit, reset, token, group or monetary values.
- Unknown, mixed, generation mismatch, unsupported field, partial, stale
  last-known-good, error, empty, and zero are distinct states.
- DOM and visual order match. Meter/progress names, values, bounds, resets, coverage, and unavailable reasons are programmatically exposed; live announcements are coalesced.

## Refreshable implementation notes

- Refresh the final auth enforcement helper at pickup. If current plugs do not expose enforced-auth state to LiveView, add a small server-side contract rather than trusting browser flags.
- Build presenters over synthetic contract fixtures before wiring PubSub. Keep grouping/detail pagination bounded and keyed so large runs do not render unbounded DOM.
- Format reset timestamps with absolute local time plus relative time where useful; retain machine-readable `<time datetime>` values.

## Acceptance and verification

### Agent gate

- Presenter/component tests cover current-run and explicit-build input, every cost basis/currency/coverage, subscription `*`/tier/popover, exact known generation match, unknown generation, mixed generations, known mismatch, API-key versus subscription cards, all meter health states, RC inclusion, run progress/ETA unavailable states, grouping reconciliation, and live updates.
- Join tests prove a current tier cannot attach to historical usage from another
  generation/account, provider/backend-only matches fail closed, and mixed or
  unknown groups never expose one constituent's tier.
- Auth tests prove unauthenticated/unenforced mode never queries or contains token, dollar, group, provider account/auth-mode, plan/tier, quota/rate/credit/spend-control, percentage/limit/reset, freshness, last-known-good, or hidden serialized values in HTML, assigns, events, cache entries or generic APIs; authenticated mode preserves existing CSRF/write behavior.
- Browser/a11y tests cover DOM order, native/ARIA meter semantics, reset times, keyboard/touch drill-down/popover, focus restore, announcement coalescing, light/dark/reduced motion, 44px targets, 200% zoom, 320/390/768/960/desktop, safe-area offsets, and no clipping.

### At-merge gate

- Rebase all seven prerequisites and the resolved configured integration target, sequence shared Units/shell/CSS/auth ownership, and pass accounting/meter/run-summary, provider isolation, dashboard auth/security, accessibility, performance, and full CI suites.

### Human/manual evidence

- From the Executor repository root, run the real dashboard and compare subscription, API-key, partial/stale, Remote Control-inclusive, exact-generation, account-switched, and mixed-generation variants. Verify grouped totals, estimate disclosure/tier or explicit unknown/mixed state, run progress/elapsed/ETA provenance, 390px/200% layout, and that disabling enforced auth produces a locked card with no values in rendered source.

## Failure, security, migration, and accessibility cases

- Each provider/query failure degrades only its region and preserves safe last-known-good facts with timestamps. No failure resets usage/quota/progress to zero or unlimited.
- Usage and all account/meter data require enforced dashboard authentication and never enter generic unauthenticated APIs, connection assigns/events/caches, logs, prompts, bug reports, or agent-visible state. This includes plan/auth mode, quota/rate/credit windows, percentages/limits and reset times as well as token/group/cost data. Use only synthetic values in tests/evidence.
- No stored-data migration; prerequisite schema migrations own compatibility.
- All metrics, statuses, scopes, bases, coverage, errors, disclosures, and drill-downs are named, non-color-dependent, keyboard/touch reachable, and screen-reader bounded.

## Surfaces

- Reads: DASH-010 Remote usage coverage, DASH-011 generation/currency-qualified
  grouped summaries, DASH-012/013 generation-scoped provider meters, DASH-014
  run summary, DASH-003 Units/scope, enforced auth state.
- Writes: summary presenters/components, bounded drill-down/popover, LiveView subscriptions, CSS, auth integration and tests.
- Contracts: exact-generation tier composition, authenticated summary UI
  states, scope/basis/currency disclosure,
  responsive/accessibility/live-update behavior.

## Sibling boundaries and open gates

Prerequisites own every number and policy; this ticket is the sole composition
owner for joining DASH-011 usage to DASH-012/013 tier facts, and it does so only
by provider, backend, and exact known opaque generation. A future Build Order
view may pass explicit current member identities to the reusable summary
query/component, but neither that use nor this companion UI changes Build Order
membership, critical path, remaining count, ETA, or acceptance.
