---
title: "fix: Harden retained Decision query rework"
type: fix
status: completed
date: 2026-07-14
---

# fix: Harden retained Decision query rework

## Summary

Harden DASH-006's retained Decision reader without changing its public scopes: retain immutable audit order across updates and replay, keep candidate selection resource-bounded, and make validation and generated proof authoritative at the store boundary.

---

## Problem Frame

The initial retained-query implementation added direct lookup, cursor pages, and canonical counts, but its cursor key follows a mutable version timestamp and its prefix map grows with every character of every retained identifier and ticket. Direct store callers can also bypass the provider caps, while fixed-seed examples do not prove the requested page traversal invariants.

---

## Assumptions

*This plan was authored without synchronous user confirmation. The items below are agent inferences that fill gaps in the input — un-validated bets that should be reviewed before implementation proceeds.*

- Bounded search may report partial-result metadata when a fixed candidate-scan budget prevents it from truthfully claiming an exhaustive filtered total; canonical global open/blocking counts remain exact.
- A test-only property generator dependency is an acceptable way to meet the explicit generative acceptance gate without inventing a second in-house property framework.

---

## Requirements

- R1. Direct lookup, retained pages, filtered search, and canonical retained counts remain explicit, independently scoped contracts (DREQ-006).
- R2. Cursor traversal uses a stable first-accepted audit key, including after a version update, concurrent insertion, and replay.
- R3. Normal page reads seek and stop after the page window; search/filter candidate work and all request inputs have hard store-boundary limits.
- R4. Query health and total metadata never present an incomplete or corrupt retained set as complete truth.
- R5. Generated coverage proves invalid-input rejection, lifecycle ordering, duplicate-free traversal, cache-independent lookup, and secret-safe provider output.

---

## Scope Boundaries

- Do not change the Decision schema, provenance contract, supervisor-basis behavior, lifecycle/authority semantics, or retained audit format.
- Do not redesign Commands; retain the established provider and dashboard composition, adjusting only metadata needed to describe bounded query truthfully.
- Do not add free-form full-text indexing or export prompt, session, account, credential, or capability-URL fields.

### Deferred to Follow-Up Work

- DASH-007 owns Commands vocabulary, filters, cards, and actions that consume this read contract.
- DASH-017 owns durable provenance fields and migrations.

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/decision_store.ex` owns replay, serialized state mutation, and the atomic retained-query snapshot.
- `src/lib/aiur/decision_store/retained_snapshot.ex` owns retained indexes, cursor ordering, counts, and candidate selection.
- `src/lib/aiur/decision_query/params.ex` is the existing untrusted-input boundary; `src/lib/aiur/decision_query.ex` and `src/lib/aiur/decision_query/store_reader.ex` compose scope and health for consumers.
- `src/test/aiur/decision_query_test.exs` already exercises corrupt-prefix, restart-race, sanitization, and cursor behavior; extend it rather than introducing parallel fixtures.

### Institutional Learnings

- The approved DASH-006 contract requires partial/unavailable scopes to be explicit and forbids substituting the priority overview for retained data.
- `DecisionStore` rebuilds projections from the canonical audit stream, so a retained ordering key must be reconstructed from first accepted history rather than persisted as a new mutable Decision field.

### External References

- None; current repository patterns and the approved planning authority are sufficient.

---

## Key Technical Decisions

- Derive each retained entry's sort timestamp from its first accepted audit record and retain that key through later versions; replay rebuilds the same key from history.
- Replace all-prefix maps with a fixed-size candidate index, lifecycle-aware audit sets, and a declared candidate-work bound. Page selection remains audit ordered and response metadata distinguishes exact from bounded/partial filtered results.
- Normalize retained-query input inside `DecisionStore` as well as at the provider, so direct callers cannot bypass page, cursor, ticket, or search limits.
- Use real generated datasets rather than a finite seeded loop; retain focused examples for named regressions such as equal timestamps, corrupt prefixes, and restart behavior.

---

## Open Questions

### Resolved During Planning

- How can stable audit order survive a Decision version update without a schema migration? Rebuild first-accepted keys from the existing audit history and preserve them in the retained index during live mutations.
- How should bounded filtered work report totals? Return complete totals only when the indexed candidate evaluation completes within its declared bound; otherwise mark the page partial rather than inventing completeness.

### Deferred to Implementation

- The precise fixed candidate-key width and scan budget should be calibrated against the focused scan-bound regression while preserving the declared resource ceiling.

---

## Implementation Units

### U1. Stabilize and compact retained-store indexes

**Goal:** Keep retained audit order immutable across versions and replay while replacing character-prefix amplification with bounded, searchable candidate structures.

**Requirements:** R1, R2, R3, R4

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur/decision_store.ex`
- Modify: `src/lib/aiur/decision_store/retained_snapshot.ex`
- Test: `src/test/aiur/decision_store_test.exs`
- Test: `src/test/aiur/decision_query_test.exs`
- Test: `src/test/aiur/extensions_test.exs`

**Approach:**
- Feed replay history into retained-index construction, use each Decision's first accepted audit position as its stable sort key, and preserve that key through subsequent index updates.
- Replace variable-length, globally and lifecycle-scoped prefix maps with a fixed-size candidate index and exact lifecycle/count projections. Seek ordinary audit/lifecycle pages directly and stop after the page window; bound candidate work for search/filter combinations and expose whether results are complete.
- Keep lookup, page, and canonical-count snapshots atomic under the existing store call and preserve corrupt-prefix health.

**Patterns to follow:**
- `DecisionProjection.reduce_checked/1` history construction and `DecisionStore.replay_and_project/2` recovery boundary.
- Existing `:gb_sets` audit ordering and incremental `update_index/3` updates.

**Test scenarios:**
- Edge case: updating an older Decision after page one does not duplicate it, skip it, or change its place in a continued traversal; replay preserves the same order.
- Edge case: equal timestamps retain canonical ID order across every page boundary.
- Error path: a corrupt replay prefix leaves valid rows and counts partial and a missing ID indeterminate.
- Resource bound: a `limit: 1` ordinary page reads no more than its seek window; adversarial SHA-shaped Decision IDs do not create per-character index growth.
- Integration: direct store query, provider query, and canonical counts read one consistent retained snapshot.

**Verification:**
- Index size and query work are bounded by declared fixed structures and page/candidate limits, while retained cursor traversal remains stable through mutation and restart.

---

### U2. Enforce retained-query contracts at every boundary

**Goal:** Make provider and direct store calls share the same caps, filters, total/partial metadata, and accessible retained-data truthfulness.

**Requirements:** R1, R3, R4

**Dependencies:** U1

**Files:**
- Modify: `src/lib/aiur/decision_query.ex`
- Modify: `src/lib/aiur/decision_query/params.ex`
- Modify: `src/lib/aiur/decision_query/store_reader.ex`
- Modify: `src/lib/aiur_web/operator_control_center/decision_provider.ex`
- Modify: `src/lib/aiur_web/live/dashboard_live.ex`
- Test: `src/test/aiur/decision_query_test.exs`
- Test: `src/test/aiur_web/operator_control_center/decision_provider_test.exs`
- Test: `src/test/aiur_web/live/dashboard_live_test.exs`

**Approach:**
- Reuse one parser/normalizer from both the provider facade and `DecisionStore.retained_query/2`; reject unknown, oversized, malformed, or conflicting input before it can broaden work.
- Thread incomplete filtered-page state alongside existing partial/unavailable store health, so pagination labels, direct detail, and retained count displays do not claim complete global data when they cannot prove it.
- Keep allowed output construction and sanitization unchanged; exact detail still distinguishes invalid input, validated absence, indeterminate corrupt-prefix absence, and infrastructure unavailability.

**Patterns to follow:**
- `DecisionQuery.Params` bounded string/cursor checks.
- Existing `StoreReader` health vocabulary and Dashboard LiveView's accessible unavailable states.

**Test scenarios:**
- Error path: direct `DecisionStore.retained_query/2` rejects excessive limits, long ticket/search strings, invalid cursors, and conflicting search inputs.
- Happy path: well-formed direct-store and provider requests return equivalent page filters, scope, health, and canonical counts.
- Error path: partial candidate pages and corrupt-store pages preserve concise accessible warnings rather than a global-complete or definitive-not-found claim.
- Security: detail/list payloads omit prompt, raw session/account identity, credentials, and capability URLs across available, partial, and unavailable states.

**Verification:**
- No caller can opt out of query caps, and each rendered retained-data state identifies its scope and health accurately.

---

### U3. Replace example-only coverage with generated retained-query proofs

**Goal:** Establish non-flaky generative proof for retained-query ordering and boundary invariants, then repair the contained lint findings.

**Requirements:** R2, R3, R5

**Dependencies:** U1, U2

**Files:**
- Modify: `src/mix.exs`
- Modify: `src/mix.lock`
- Modify: `src/test/aiur/decision_query_test.exs`
- Modify: `src/test/aiur/decision_store_test.exs`
- Test: `src/test/aiur_web/operator_control_center/decision_provider_test.exs`
- Test: `src/test/aiur_web/live/dashboard_live_test.exs`

**Approach:**
- Use a property generator with varied equal-time groups, identifiers, lifecycle distributions, page sizes, and invalid inputs. Traverse the cursor contract and compare it against the stable audit-order model without fixed seeds.
- Keep focused regression cases for history-derived ordering, bounded candidate reads, provider sanitization, and UI health labels; format the four CI-owned line-length findings without suppressions.

**Patterns to follow:**
- Existing temporary DecisionStore fixture and explicit corrupt-prefix replay coverage.
- Repository test isolation conventions: no timing sleeps, unique state directories, and bounded `mix test --max-cases 4` execution.

**Test scenarios:**
- Property: generated retained datasets with equal timestamps, lifecycle filters, and varying limits have stable order, no duplicate IDs, and no gaps across continuation pages.
- Property: generated malformed page, cursor, ticket, search, and decision-ID inputs fail validation without widening the query.
- Property: lookup returns the same retained Decision regardless of its priority-overview position.
- Regression: a version update and a replay preserve the original page key; a direct oversized store query cannot exceed the same caps as provider input.

**Verification:**
- Generated properties and focused store/provider/LiveView suites pass without line-length or formatting violations.

---

### U4. Continue capped filtered retained pages

**Goal:** Ensure a bounded filtered or search scan can always advance past its
candidate cap without claiming an incomplete page is final.

**Requirements:** R1, R3, R4

**Dependencies:** U1

**Files:**
- Modify: `src/lib/aiur/decision_store/retained_snapshot.ex`
- Test: `src/test/aiur/decision_query_test.exs`

**Approach:**
- Preserve the final audit key inspected by a capped candidate scan separately
  from the final returned match. When the cap leaves candidates uninspected,
  return that inspected key as the continuation and mark the page partial.
- Retain the existing returned-row continuation when the page reaches its
  `limit + 1` lookahead before the scan cap.

**Patterns to follow:**
- The existing `:gb_sets` audit iterator, `partial?` metadata, and encoded
  retained cursor contract.

**Test scenarios:**
- Regression: more than 1,000 same-bucket candidates with a matching retained
  Decision just beyond the cap produce an empty partial first page with a
  continuation, then return the match on the following page.
- Edge case: a capped scan with no later candidate remains final rather than
  creating a spurious continuation.

**Verification:**
- A bounded filtered traversal cannot strand a valid retained Decision beyond
  its first candidate window.

### U5. Bound latency enrichment failure

**Goal:** Keep a failed or suspended metrics provider from multiplying the
retained-page response timeout by its row count.

**Requirements:** R1, R3, R4

**Dependencies:** U2

**Files:**
- Modify: `src/lib/aiur_web/operator_control_center/decision_provider.ex`
- Test: `src/test/aiur_web/operator_control_center/decision_provider_test.exs`

**Approach:**
- Keep per-row latency data when the provider is healthy, but stop further
  synchronous metric reads after the first unavailable outcome and label the
  page latency unavailable once.

**Patterns to follow:**
- Existing `safe_metrics_call/1` fault handling and presenter latency-health
  composition.

**Test scenarios:**
- Failure path: an unavailable metrics snapshot receives no calls for subsequent
  retained rows and returns an unavailable latency state.
- Happy path: a healthy metrics provider is still called only for the bounded
  response page and attaches each available snapshot.

**Verification:**
- A provider failure incurs at most one bounded metrics call per retained page.

---

## System-Wide Impact

- **Interaction graph:** `DecisionStore` supplies one atomic snapshot to `DecisionQuery`, which remains the sanitizing boundary used by the provider and Dashboard LiveView.
- **Error propagation:** malformed input becomes a matchable invalid-query result; unavailable, corrupt-prefix, and bounded-partial data retain their distinct health states.
- **State lifecycle risks:** first-accepted order must be reproducible from replay, while lifecycle changes update only membership/count projections and never move a cursor key.
- **API surface parity:** direct store callers and provider callers use identical caps and result truthfulness.
- **Unchanged invariants:** Decision persistence, schema, provenance, authority, and overview priority remain unchanged.

---

## Risks & Dependencies

| Risk | Mitigation |
| --- | --- |
| A compact search index omits matches or reorders pages | Model the audit-order result in generated tests and keep explicit equal-time/update/replay regressions. |
| Candidate bounding is mistaken for a complete total | Carry explicit partial metadata and accessible labels through the provider/UI boundary. |
| New property dependency destabilizes the test toolchain | Keep it test-only and scope generated cases to the retained-query module. |
| Shared DecisionStore files overlap DASH-017 | Keep the diff query/index-only; do not introduce schema/provenance changes. |

---

## Sources & References

- Approved planning authority: [DASH-006 companion ticket](https://github.com/aiur-team/aiur/blob/4d8de9508206e08e314f2730cd916501a3b4cafd/docs/build-order/companion-tickets/DASH-006-decision-lookup.md)
- Requirements: [DREQ-006](https://github.com/aiur-team/aiur/blob/4d8de9508206e08e314f2730cd916501a3b4cafd/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Related PR and authoritative rework: #1144, [review comment](https://github.com/aiur-team/aiur/pull/1144#issuecomment-4966514666)
