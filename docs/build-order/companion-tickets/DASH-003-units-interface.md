# DASH-003 — Render responsive Units interface

**Kind:** executable

**Provenance:** planned in plan v1 after refreshed-prototype and current-main review

**Complexity:** 3 — URL-backed filter interaction and accessible responsive rendering over a fixed catalog

**Risk:** medium

**Depends on:** DASH-001, DASH-002, BO-011

**Serializes with:** DASH-005 and other Units/DashboardLive/shared CSS branches

**Requirements:** DREQ-003

**Researched at:** `b7c4e7c06b8c7011f306ce9efb0b9cd8fd8cbac5`

**Suggested labels:** `complexity:3`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Executors can share, refresh, filter, inspect, and navigate one responsive Units page whose rows and counts exactly implement DASH-002 and whose rich ticket context reuses the accepted Build Order integration rather than a dashboard-only copy.

## Context and evidence

Current main already renders one Fleet table with waiting reasons, Decisions, safe tracker links, and running-agent log access. The refreshed prototype simplifies the columns and adds scope presets, condition chips, progress, model/complexity/lane facts, and rich ticket context, but its clickable table rows, client-mutated objects, exclusive buckets, and narrow typography are not production contracts. BO-011 defines the shared all-state ticket-context path used here; BO-015, not this companion, owns the later Build Order capstone.

## Scope

- Render DASH-002's single-select Live/Unfinished/All/None scope and independent Active/Alert/Paused/Stuck/Queued/Finished condition chips. Display predicate counts from the catalog without implying overlapping counts are additive.
- Persist validated scope and conditions in URL parameters. Refresh, copied URLs, and browser back/forward restore the same view. Provide a named reset when a valid selection yields no rows.
- Render one desktop table and narrow card/reflow presentation with typed identity, agent/backend/model/effort/complexity, title and optional lane, latest evidence, progress source/freshness, runtime, waiting/blocking context, open Commands, and safe available actions. Unknown/stale values use explicit text, never fake percentages or placeholder models.
- Consume the accepted BO-011 ticket-context integration for row inspection, dependency navigation, GitHub navigation, and optional chat/log/Command actions. Preserve the existing running-agent log behavior until the shared context is available; do not fetch tracker data during render.
- Preserve focus and selection across live row updates when the same identity remains visible. Coalesce screen-reader count/status announcements and avoid reorder animation when reduced motion is enabled or focus would move.
- Use explicit named buttons/links for row inspection and actions. A visual row may be hover-highlighted, but a non-focusable clickable `<tr>` is not the interaction contract.

## Non-goals

- Define catalog membership/predicates, implement pause/resume or capacity writes, ingest usage, redesign Commands, or build the Build Order graph.
- Reimplement BO-011 ticket context, parse workspace logs during render, or invent completed/progress/model data.
- Copy the prototype's client-side cap behavior, fake remote-control links, 9–12px essential text, or visual-only status encoding.

## Existing owner and reuse target

Extend the current Fleet table/filter/presenter components under `AiurWeb.OperatorControlCenter`, consume DASH-001 shell metadata and DASH-002 APIs, and reuse the BO-011-accepted ticket-context components and trusted-link policy.

## Contract and invariants

- UI rows, counts, scopes, and chips are projections of DASH-002 only; the LiveView does not rederive lifecycle policy.
- URL state is canonical and validated. A live update may change results but never silently rewrite the user's selected scope or conditions.
- DOM and visual order match. Every fact and action remains available at 320, 390, 768, and 960 CSS pixels and 200% zoom without page-level horizontal scrolling.
- Unknown progress uses an indeterminate or labelled unavailable state and omits `aria-valuenow`; it is never shown as `0%`.
- Live updates are keyed by typed identity, preserve focused controls when possible, and produce bounded/coalesced announcements.

## Refreshable implementation notes

- Refresh BO-011's final context component names and current Fleet behavior at pickup. Keep a thin adapter if the Build Order view model is richer than a plain Units row.
- Prefer Phoenix streams or keyed components for row updates, but verify focus behavior rather than assuming DOM patch stability.
- Keep filter controls as real buttons/links with server-backed URL patches. Do not duplicate the prototype JavaScript state machine.

## Acceptance and verification

### Agent gate

- LiveView/component tests cover every scope/chip combination, overlapping counts, URL round trip/back/reset, live insert/update/terminal retention, unknown/stale facts, and provider degradation.
- Browser/a11y tests cover keyboard and touch inspection, named row actions, focus persistence/restoration, coalesced announcements, reduced-motion changes, 44px touch targets, 200% zoom, and 320/390/768/960/desktop reflow.
- Tests prove row/context render performs no GitHub or workspace-log read and does not weaken trusted URL handling.

### At-merge gate

- Merge current main plus DASH-001/002 and the BO-011 acceptance result, sequence shared `DashboardLive`/CSS ownership, and pass Fleet, ticket-context, Decision-link, accessibility, asset, and full CI gates.

### Human/manual evidence

- From the operator repository root, run the real `scripts/aiurdev --test` UI and verify multi-signal, queued, paused, unknown, and terminal rows at desktop and 390px; copy a filtered URL, navigate ticket context with keyboard only, and confirm focus returns to the originating control.

## Failure, security, migration, and accessibility cases

- Catalog degradation keeps the last-known-good rows visibly stale or shows a named unavailable state; it never presents an empty healthy fleet.
- Render only normalized facts and trusted URLs. Do not expose raw logs, paths, provider payloads, credentials, or account data.
- Preserve existing Fleet URLs or redirect them explicitly; there is no stored-data migration.
- Use semantic table/card markup, explicit labels, non-color status text, meter semantics, visible focus, and announcement throttling.

## Surfaces

- Reads: DASH-002 Units catalog/policy, DASH-001 route shell, BO-011 ticket context, URL params.
- Writes: Units LiveView composition, filter/table/card components, CSS, browser and component tests.
- Contracts: Units URL presentation, row action model, focus/live-update behavior.

## Sibling boundaries and open gates

DASH-005 owns all writes and may add controls only through this row/action seam. DASH-015 owns summary cards. This ticket does not start until BO-011 has proven the reusable ticket-context integration, preventing a second incompatible modal contract.
