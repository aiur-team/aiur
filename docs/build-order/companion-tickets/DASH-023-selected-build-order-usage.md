# DASH-023 — Integrate selected Build Order usage

**Kind:** executable

**Provenance:** planned in plan v1 after selected-scope integration review

**Complexity:** 4 — URL-backed cross-source membership/accounting join with generation-safe live updates

**Risk:** high

**Phase hint:** 8

**Depends on:** BO-003, BO-012, DASH-030, DASH-031, DASH-021

**Serializes with:** DASH-022, BO-013, BO-014 — summary and Build Order route CSS

**Predecessor baseline:** resolved — `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f`

**Requirements:** DREQ-023

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:4`, `model:codex`, `phase:8`, `build-lane:accounting`; never `agent:todo`

**Build Order membership:** member of the consolidated Build Order (operator decision 2026-07-13)

## Outcome

An authenticated selected Build Order route can show DASH-031 usage/cost
summaries scoped to the exact current GitHub member set, updating safely when
root selection, membership generation, retained usage, or meter facts change.

## Context and evidence

Units correctly defaults accounting to `this run`, while the user also requires
tokens and estimates for a total build and its tickets/models/agents. BO-003
owns current GitHub root/member truth, BO-012 owns URL-backed selected-root
presentation, and DASH-030 accepts an explicit repository-qualified ticket set.
This ticket owns only the live selected-scope integration and never writes
membership or changes Build Order completion.

## Scope

- Derive the selected root solely from BO-012's canonical `/build-orders/:root_number` URL and validated repository context; browser-local selection is not authority.
- Consume BO-003's complete current selected graph generation and exact repository-qualified member identities. Never infer membership from labels, prose, phase/lane, visible nodes, or issue-number adjacency.
- Call DASH-030 with that explicit current member set and label the result `this
  build`, retaining basis/currency/account-generation/coverage semantics and
  the compatible-currency API-equivalent roll-up.
- Include every retained usage observation attributable to a current member, including observations recorded before it joined the Build Order. Exclude a removed/nonmember ticket immediately on the next complete membership generation; there is no joined-at cutoff.
- Treat catalog generation, selected-root generation, complete membership generation, accounting generation, and provider-meter generation independently. Discard stale async/query results after any relevant generation changes.
- Subscribe to BO-003 selected-graph updates and protected DASH-021 accounting/meter changes. Requery bounded snapshots on mount/reconnect, root switch, or complete membership change; coalesce updates without per-browser GitHub polling.
- Render through DASH-031's protected usage/cost component contract on the
  Build Order route, preserving exact-generation tier annotations, the
  asterisked compatible-currency API-equivalent total and contributor
  reconciliation, bounded drill-down, health/freshness, and locked state.
- Define loading, empty-build, no-retained-usage, partial-retention, selected-invalid, stale graph, graph unavailable, accounting unavailable, and membership-changed states without confusing them with zero.
- Preserve URL/share/back/refresh behavior and focus when switching roots or live membership changes.

## Non-goals

- Add/remove members, edit dependencies/labels/phases/lanes, write totals to GitHub, allocate subscription fees, or define Build Order progress/ETA/readiness.
- Make this companion a member or acceptance dependency of the Build Order root, alter BO-003/012 source truth, or count accounting work in Build Order completion.
- Infer historical membership intervals, include removed tickets, poll GitHub per browser, or bypass DASH-021.

## Existing owner and reuse target

Extend BO-012's selected-route composition with a thin generation-safe scope
adapter. Consume BO-003 selected graph/member identities, DASH-030 explicit-
ticket-set query, DASH-031 components, and DASH-021 protected query/
subscription boundary.

## Contract and invariants

- Current complete GitHub membership from BO-003 is the only build-scope authority; accounting remains Aiur truth.
- Scope identity is repository plus GitHub node identity, never bare number.
- Current members include all retained pre-membership usage; removed/nonmembers are excluded. Missing retained coverage remains explicit.
- A result is renderable only when selected root/member and accounting generations match the request; stale responses cannot cross root or membership changes.
- `this run` and `this build` remain distinct labelled scopes and never share a cache key accidentally.
- A selected-build API-equivalent total is emitted only per compatible currency
  and reconciles exactly to preserved provider/account-generation, ticket,
  agent-family, backend and model contributors. Provider-reported estimates
  and exact-generation tier facts never enter that arithmetic.
- Read-only integration cannot mutate GitHub or Aiur runtime and cannot affect Build Order membership, progress, readiness, critical path, ETA, or acceptance.

## Refreshable implementation notes

- Refresh BO-003/012 generation and route contracts plus DASH-030/031/021 APIs
  at pickup; adapt through public seams.
- Keep the scope adapter and generation key pure; LiveView handlers should validate URL/generation, request bounded cached data, and render normalized state.
- Coordinate the shared summary container/CSS with DASH-022 and Build Order route work; serialize rather than duplicate components.

## Acceptance and verification

### Agent gate

- Scope tests prove exact current members, repository/number collision safety, pre-membership inclusion, removed/nonmember exclusion, empty build, no retained usage, partial retention, and run/build cache separation.
- Generation tests cover root switch, membership add/remove, stale graph/query replies, accounting/meter updates, reconnect, provider degradation, and coalesced subscriptions without per-browser GitHub calls.
- LiveView/browser tests cover URL/share/back/refresh, locked/authenticated modes, focus preservation, bounded drill-down, mixed Codex/Claude compatible-currency total and constituent reconciliation, disclosure/tier joins, and explicit non-zero/empty/error states.
- Mutation-negative tests prove no GitHub planning or Aiur runtime action handler is introduced and Build Order acceptance/progress remains unchanged.

### At-merge gate

- Rebase all five prerequisites and the resolved configured integration target; sequence with DASH-022/Build Order shared UI surfaces and pass root/provider, accounting, auth/security, LiveView/browser/accessibility, performance, and full CI suites.

### Human/manual evidence

- From the Executor repository root, select two roots by URL, add/remove a synthetic member in a mixed Codex/Claude fixture, and show the asterisked compatible-currency build total and every provider/ticket/model/agent constituent updating with pre-membership inclusion/removal exclusion while Units remains `this run` and no planning mutation appears.

## Failure, security, migration, and accessibility cases

- Partial/stale/unavailable membership or accounting never becomes a healthy zero or guessed scope. Preserve safe LKG only with explicit generation/freshness.
- Protected values remain behind DASH-021 and contain no raw account identity, credentials, prompts, logs, workspace paths, or provider payloads.
- No stored-data migration; scope/query cache versions include root/member/accounting generations.
- Scope, coverage, health, disclosures, selection changes, and drill-down are keyboard/touch reachable, non-color-dependent, and screen-reader bounded.

## Surfaces

- Reads: BO-003 current selected graph/members, BO-012 URL route state,
  DASH-030 explicit-ticket query, DASH-031 component contract, and DASH-021
  protected delivery.
- Writes: selected-build scope adapter, generation-keyed
  query/cache/subscriptions, Build Order usage composition, Build Order route
  component CSS, and tests.
- Contracts: exact current-member `this build` accounting scope, compatible-
  currency API-equivalent total/constituent reconciliation, and live generation
  reconciliation.
- Safety: GitHub/Aiur read-only boundary, protected financial delivery, cross-root stale-result isolation.

## Sibling boundaries and open gates

DASH-030 owns grouped scope and DASH-031 owns usage/cost presentation; both are
hard predecessors. DASH-015 provider meters are independent. DASH-022 owns
nonfinancial run summary and serializes on shared layout only. This
companion declares the cross-pack serialization edges with BO-013 and BO-014
because all three write Build Order route component CSS. BO-003/012 retain Build
Order truth; this standalone companion never enters root membership or
completion.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `DASH-023`
- [Graph waves, critical path, and parallelism](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.
