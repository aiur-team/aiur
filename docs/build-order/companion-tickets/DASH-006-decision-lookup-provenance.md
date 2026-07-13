# DASH-006 — Add Decision lookup and provenance

**Kind:** executable

**Provenance:** planned in plan v1 after Commands/current-main adversarial review

**Complexity:** 4 — Durable provenance schema plus bounded-list, direct-lookup, and paginated-query contracts

**Risk:** high

**Depends on:** none

**Serializes with:** Decision schema/store/API/presenter and active Decision lifecycle changes

**External gate:** `GATE-OCC-PREDECESSOR-BASELINE` — resolve before dispatch

**Requirements:** DREQ-006

**Researched at:** `1e0cfba31c0e6cc4fea14a25e8b4344ef1d6d67d`

**Suggested labels:** `complexity:4`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Commands consumers can resolve any retained Decision by stable ID, page/search the complete retained set without unbounded payloads, and render exact backend/model plus supervising-confidence facts only from trusted durable provenance.

## Context and evidence

Current `ControlCenterPresenter` loads a priority-bounded 50-Decision overview and `DashboardLive` searches that payload for direct detail, even though `DecisionStore.get/2` exists. Old deep links can therefore report missing despite durable data. The prototype also derives provider/model by parsing prose and shows confidence fields absent from the canonical Decision schema; production needs trusted persisted fields rather than presentation inference.

## Scope

- Add an on-demand Decision detail provider that calls `DecisionStore.get/2`, applies the same presenter/sanitization/latency composition as overview rows, and preserves provider health. A direct retained ID resolves independently of the overview window.
- Define a bounded cursor-based retained-Decision query for Commands `All`, with stable audit ordering, validated page size, lifecycle filters, optional ticket/Decision-ID search, total/partial-result metadata, and provider failure semantics. Keep the priority-bounded overview as a distinct query.
- Version trusted Decision provenance to optionally persist agent family, backend, requested model, resolved model, session/attempt identity, source, and captured time. Populate it from authoritative runtime/session context at acceptance; never trust agent payload fields or parse `originName`, question, rationale, or other prose.
- Add optional supervising recommendation/decision confidence as a validated exact decimal in `[0, 1]`, with actor, source, and captured time. Only the authenticated supervising decision path may author supervisor confidence. Preserve it append-only across answer/revision/history records; human and legacy records may be unknown.
- Migrate/replay legacy Decision records with provenance/confidence absent, not guessed. Expose canonical summary counts for open and blocking retained Decisions separately from bounded overview counts.

## Non-goals

- Rename the Decision domain/store, redesign Commands UI, infer historical models/confidence, change authority policy, or add prototype Defer/Acknowledge actions.
- Load every Decision into one LiveView payload, perform free-form full-text indexing, or expose raw prompts/session/account data.
- Treat recommendation prose, agent-provided model names, or display strings as trusted provenance.

## Existing owner and reuse target

Extend `Aiur.Decision`, `DecisionValidation`, `DecisionStore`, `DecisionApi`, `DecisionHistory`, `DecisionPresenter`, `ControlCenterPresenter`, and `PayloadLoader`. Reuse current schema-version, append-only audit, sanitization, supervisor authentication, and bounded-query patterns.

## Contract and invariants

- Overview, page/search, and direct lookup are separate contracts: overview is bounded and prioritized; page/search is bounded and cursor-stable; direct lookup is exact by canonical ID.
- Direct detail applies the same sanitization, lifecycle, latency, and provider-health presentation as list rows.
- Provenance is accepted only from trusted runtime context and remains immutable for a Decision version. Unknown legacy provenance/confidence stays unknown.
- Confidence is exact, finite, within `[0, 1]`, actor-scoped, and append-only with the action/revision it describes. It never grants authority or changes lifecycle by itself.
- Search input, cursors, and page sizes are bounded and validated; partial/unavailable counts are explicit.

## Refreshable implementation notes

- Refresh current Decision schema version and OCC contract docs at pickup. Prefer one versioned additive migration/replay path over view-only shadow fields.
- Thread selected Decision ID into `PayloadLoader` or a dedicated detail loader so it can fetch outside the cached overview without making every browser load unbounded.
- Use store/audit ordering keys for cursors, not list offsets that drift under concurrent insertions.

## Acceptance and verification

### Agent gate

- Store/provider tests cover old direct IDs outside the newest 50, missing IDs, cursor stability under insertions, lifecycle/search filters, page bounds, canonical counts, provider failure, and sanitization parity.
- Schema/replay tests cover trusted runtime provenance, backend fallback/resolved model, legacy unknowns, forged agent fields, valid/invalid confidence, revisions, and full history round trips.
- Security tests cover bounded search inputs and prove no prompt, raw session, account identity, credential, or untrusted model string crosses the provider boundary.

### At-merge gate

- Rebase on the resolved configured integration target and active Decision work; run Decision schema/store/API/history/metrics, presenter/cache/LiveView compatibility, migration/replay, security, and full CI suites.

### Human/manual evidence

- From the Executor repository root, open a retained Decision older than the overview window by direct URL, navigate at least two `All` pages, and verify trusted and legacy-unknown provenance/confidence render distinctly once DASH-007 consumes the contract.

## Failure, security, migration, and accessibility cases

- Detail failure degrades only detail and names whether the ID is absent or the provider unavailable; it does not erase the overview.
- Provenance excludes account/email/org, raw environment, credentials, prompts, transcripts, and capability URLs. Existing Decision text sanitization remains mandatory.
- Version and replay the additive schema; rollback must continue reading legacy records without manufacturing new fields.
- No direct visual UI, but provider output includes concise accessible labels and partial-result metadata.

## Surfaces

- Reads: Decision store/audit, authoritative runtime/session context, DecisionMetrics.
- Writes: Decision schema/provenance/confidence, paginated/direct providers, counts, migrations and tests.
- Contracts: exact detail lookup, retained cursor query/search, trusted Decision provenance/confidence.

## Sibling boundaries and open gates

DASH-007 owns Commands vocabulary, filters, cards, and banner. It may omit unknown fields but may not invent them. Existing supervisor authority, delivery, revision, acknowledgement, and resolution owners remain unchanged.
