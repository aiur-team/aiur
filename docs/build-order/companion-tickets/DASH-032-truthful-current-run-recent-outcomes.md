# DASH-032 — Project truthful current-run outcomes

**Kind:** executable

**Provenance:** planned in plan v1 after shipped-dashboard recent-outcome causality audit

**Complexity:** 3 — Source-aware temporal join between current-run membership and canonical repository merge facts

**Risk:** high

**Phase hint:** 6

**Depends on:** DASH-002, DASH-014

**Serializes with:** none

**Resolved predecessor baseline:** `origin/main@9849f32963c2a65367bce565b3f5ede3777c218f` — the shipped OCC predecessor is present; no external gate remains

**Requirements:** DREQ-032

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:3`, `model:codex-gpt-5.6-sol`, `phase:6`, `build-lane:runtime`; never `agent:todo`

**Build Order membership:** member of the consolidated Build Order (operator decision 2026-07-13)

## Outcome

Aiur exposes a bounded current-run outcome projection containing only repository merges that can be associated with an exact current-run member through canonical branch/ticket facts and the run window, while stating association evidence without claiming that Aiur caused the merge.

## Context and evidence

Current main durably records bounded `RecentMerge` facts and already documents that `observed_run_id` means only that a BEAM run saw a live GitHub event. It does not prove that the run, an Aiur agent, or a ticket caused the merge. `RecentMerge.ticket_id` is derived only from a canonical `aiur/<number>[-slug]` head branch, while DASH-002 supplies exact current-run membership and DASH-014 owns canonical run identity/start time. The prototype's `Finished this run` language therefore requires a server-side evidence join, not a filter on `observed_run_id`.

## Scope

- Define a pure, versioned `CurrentRunOutcomeSnapshot` over DASH-002 membership, DASH-014 run identity/window metadata, and the configured repository's `RecentMergeStore` snapshot/reconciliation state.
- Qualify a merge only when all evidence is present: exact configured repository match; canonical `TicketBranch.ticket_id/1` result; unique resolution of that repository/number locator to one DASH-002 member's canonical BO-004 identity; and `merged_at` within the active run window.
- Treat the repository/number from the canonical branch only as a locator into authoritative membership. Missing, ambiguous, legacy-unjoinable, or repository-mismatched membership never becomes an outcome.
- Include bounded safe PR identity/title/summary/URL, merge commit/time, canonical member identity and display number, run generation/window, association basis, merge observation provenance, source health/freshness, and truncation/reconciliation metadata.
- Keep observation and association separate. A backfilled merge may qualify when its canonical facts, member, and merge time match; a live-observed merge does not qualify merely because `observed_run_id` equals the current run.
- Classify excluded candidates by bounded reason counts such as `noncanonical_branch`, `not_current_member`, `outside_run_window`, `repository_mismatch`, `ambiguous_identity`, or `source_unavailable`. Do not expose rejected raw content.
- Sort qualified outcomes deterministically by merge time and canonical PR identity, deduplicate enriched snapshots by merge identity, and cap the current-run list explicitly. Recompute from immutable source snapshots on membership, run, or recent-merge updates; do not create a second merge ledger.
- Distinguish healthy empty, partial reconciliation, stale membership/run facts, source unavailable, and restart/new-run generation. Preserve a same-generation last-known-good result only with visible stale provenance.

## Non-goals

- Claim that Aiur, an agent, or the current run authored, completed, or caused a PR merge; use `observed_run_id` as causality or membership; or infer linkage from title/body/prose.
- Fetch GitHub, mutate issues/PRs, change `RecentMerge` persistence, redefine DASH-002 membership, redefine DASH-014 run start, or render outcome cards.
- Include Decision history, non-merge events, arbitrary branches, other repositories, cross-run analytics, or usage/spend accounting.

## Existing owner and reuse target

Compose the shipped `Aiur.RecentMerge`/`RecentMergeStore`, `Aiur.TicketBranch`, DASH-002 current-run membership, DASH-014 canonical run identity/window, and BO-004 identity lookup rules. Keep the projection pure/stateless so `RecentMergeStore` remains the sole durable merge fact owner.

## Contract and invariants

- `observed_run_id` is observation provenance only. It is neither a join key nor evidence of work, authorship, ticket completion, or causality.
- Qualification requires the conjunction of canonical branch-derived ticket locator, unique exact configured-repository member resolution, and merge time inside the canonical current-run window.
- Display number is never canonical identity. It may locate a member only within the exact configured repository, and the output carries the resolved BO-004 identity.
- Backfilled and live-observed facts use identical qualification rules. Observation timing cannot promote or demote an otherwise identical merge.
- Partial/unavailable sources never produce a confidently complete empty list. A new run generation cannot inherit prior outcomes.
- Presentation wording must describe a merge associated with a current-run ticket; downstream consumers may not relabel it `merged by Aiur` or equivalent.

## Refreshable implementation notes

- Reinspect `RecentMerge`, `RecentMergeStore`, `TicketBranch`, reconciliation health, DASH-002 member lookup, and DASH-014 run-window fields at pickup. Consume public snapshots; do not read the merge audit file directly.
- Define the active window as canonical `started_at <= merged_at <= observed_at` while the run is active. If a future ended-run query is added, require its canonical end time in a separately versioned contract.
- Keep qualification and exclusion-reason functions pure with injected/current snapshot times. Reuse the configured repository normalizer and trusted GitHub URL already enforced by `RecentMerge`.

## Acceptance and verification

### Agent gate

- Join tests cover canonical/noncanonical branches, exact/mismatched repository, same number in two repositories, unique/ambiguous/missing/legacy membership, before/at/after run start, future merge time, and new-run isolation.
- Provenance tests prove matching and nonmatching `observed_run_id` never changes qualification; live and backfilled versions of the same canonical fact yield the same association result.
- Health tests cover healthy empty, partial GitHub reconciliation, stale/unavailable membership, missing run start, merge-store corruption/unavailability, same-generation recovery, truncation, enrichment/deduplication, and deterministic ordering.
- Negative tests prove PR title/body, merge observer, current directory, workspace path, active row, and bare number alone cannot qualify an outcome or leak into exclusion diagnostics.

### At-merge gate

- Rebase on DASH-002/014 and current main; pass membership/run-window, TicketBranch, RecentMerge/RecentMergeStore replay/reconciliation, identity collision, projection, security, compile/lint/spec, and full CI suites.

### Human/manual evidence

- None separately; the owning recent-outcomes presentation ticket must show a canonical current-run association, an unrelated live-observed merge excluded, a qualifying backfilled merge, and partial/unavailable source wording without claiming causality.

## Failure, security, migration, and accessibility cases

- Missing/ambiguous identity, run time, or source health makes a candidate excluded or the projection partial/unavailable; it never weakens qualification to preserve a card.
- Consume only `RecentMerge`'s bounded/redacted fields. Do not expose PR bodies beyond the existing safe summary, raw GitHub events, credentials, account identity, workspace paths, or local audit paths.
- No durable migration or second ledger. Version only the pure output/association basis so later wording or ended-run support cannot rewrite current semantics.
- No direct UI. Association basis, health, freshness, partiality, and exclusion states have concise human-readable labels for downstream accessible presentation.

## Surfaces

- Reads: DASH-002 membership snapshots/lookups; DASH-014 run identity/window; `RecentMergeStore` snapshot/reconciliation; configured repository and `TicketBranch` facts.
- Writes: pure current-run outcome projection, association/exclusion policy, snapshot schema, tests.
- Contracts: `CurrentRunOutcomeSnapshot`; current-run merge qualification; observation-versus-association semantics; health/truncation provenance.

## Sibling boundaries and open gates

DASH-002 owns membership, DASH-014 owns the run window, and `RecentMergeStore` owns durable merge facts. BO-018/019 ticket context/history and DASH-026/027 conversation are unrelated. A separate presentation ticket owns cards and wording but must consume this contract without promoting association to causality.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `DASH-032`
- [Graph waves, critical path, and parallelism](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.
