---
title: Build Order package and published graph - Plan
type: feat
date: 2026-11-04
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

# Build Order package and published graph - Plan

## Goal Capsule

- **Objective:** publish one versioned graph contract for a Build Order, and render its review and
  graph from a standalone package so other tools stop needing a running aiur. The dashboard becomes
  a consumer of that package instead of a second renderer.
- **First deliverable:** the frozen `build-order.v1` contract in `@aiur/contracts` (this ticket, #7490).
  Every later unit reads it, so it ships before any code depends on it.
- **Product authority:** the operator's 2026-11-04 answers (a standalone package, a published
  contract, one copy in the dashboard) and the Epic/Feature/Lane vocabulary from
  [the hierarchy plan](2026-11-04-epic-feature-lane.md) are binding.
- **Stop conditions:** stop and report if a unit would need a breaking change to the dashboard's
  `/build` protocol without a version bump, a new credential in a browser-rendered page, or a public
  npm release the operator has not approved.
- **Tail ownership:** one GitHub ticket per unit, listed under Ticket Breakdown. Each worker owns
  its PR to merge; the Executor owns rebuild, restart and the live check after each merge.

---

## Product Contract

### Summary

A Build Order is now only readable inside aiur. Its planning pack, its graph, its review and its
GitHub publication are four daemon-side implementations of the same facts. This plan publishes those
facts once, as `build-order.v1`, and moves the review and graph rendering into a package that needs
nothing but that document.

### Problem Frame

- **Nothing published.** `@aiur/contracts` carries the CLI, status, ticket, usage, progress, Command
  and outbound-event contracts. It has no Build Order contract, so the graph exists only as the
  dashboard's private payload.
- **The payload is not a contract.** `AiurWeb.Build.Payload` pins a protocol version and uses
  compressed keys (`num`, `deps`, `children`, `sec`, `cx`, `qpos`). It is written for one reader and
  carries no marker, no version and no compatibility rule.
- **The review is daemon code.** The review and graph are drawn by about 4,500 lines of page-local
  modules in `src/priv/static/build-home/` plus 5,400 lines of page CSS. A second tool cannot render
  them without copying both.
- **Three copies of the graph arithmetic.** The daemon (`Aiur.BuildOrder.GraphAnalysis`,
  `Graph`, `DependencyChain`, `AiurWeb.Build.PlannedGraph`), the publication Python
  (`publication_live_graph.py`, `publication_live_expected.py`) and the dashboard each compute waves,
  dependency state and progress.
- **The general `build-order` skill and Game Maker are blocked.** Both need to show the same review
  and read the same graph without a daemon.

### Vocabulary (binding)

| Term | Meaning in the contract | Not |
| --- | --- | --- |
| Epic | The initiative a set of features belongs to. A Build Order root is one epic. | A lane column. |
| Feature | A ticket collection inside an epic. | A phase. |
| Lane | A technical column: backend, frontend, docs, art. | An epic. |
| Node | One ticket, addressed by its pack id (`BO-001`) and, once published, its tracker number. | A file. |
| Edge | A typed relation between two nodes or a node and a gate. | A derived level. |
| Gate | An external approval a node waits on. | A ticket state. |
| Source status | Whether the pack, tracker or progress reading is known, stale or unknown. | A count of zero. |

### Requirements

- **R1. One versioned contract.** `build-order.v1` in `@aiur/contracts` describes a published graph:
  metadata, sources, epics, features, lanes, tickets, typed edges, gates, waves, critical path and
  progress, with golden fixtures. A breaking change adds `build-order.v2` beside it.
- **R2. Epic, feature and lane are separate node fields.** A node's `epic`, `feature` and `lane` are
  three distinct values. A column is never published as an epic.
- **R3. Every typed edge is published.** `depends_on`, `serializes_with`, `suggested_after`,
  `contains` and `gates` are first class, each with its `source` (`pack` or `tracker`).
- **R4. Unknown is published, not implied.** An unavailable tracker or progress reading produces
  `status: "unknown"` with a reason on the affected object, never an empty graph or a 0% bar.
- **R5. A package renders it with no daemon.** `packages/aiur-build-order` renders the review and the
  graph from one document, framework-agnostically, using `@aiur/style` tokens.
- **R6. One copy in the dashboard.** Build home renders its review and graph through the package.
  The page-local renderers it replaces are removed rather than kept beside it.
- **R7. The pack stays authored; the document is derived.** The planning pack remains the artifact a
  planner writes. `build-order.v1` is what aiur publishes from it and from tracker truth.
- **R8. Publication reads the document.** The Build Order review aiur publishes to GitHub reads graph
  facts from `build-order.v1` instead of recomputing them.

### Acceptance Examples

- **AE1.** A document with one epic, two features, three lanes and four tickets renders a review with
  an epic row, its features indented under it, a lane legend and a wave-ordered graph. The page makes
  no network call other than to its build-order URL.
- **AE2.** The same document with `sources.tracker.status: "unknown"` renders a visible unknown banner
  and still lists the pack's tickets. No row shows `0%` or "done".
- **AE3.** A ticket whose `depends_on` edge is `terminal_unsatisfied` renders as failed-blocked and
  names the gate. A `serializes_with` edge renders as an order hint, not a blocker.
- **AE4.** `GET /api/v1/build-order` returns a document that the `build-order` skill writes to disk
  and renders with `renderReview` and `renderGraph`, with no aiur running.
- **AE5.** Build home's review shows the package's markup: a browser assertion finds the package's
  class names, and the page-local renderer modules are gone from the tree.

### Scope Boundaries

- **No tracker credentials in the browser.** The document is produced by the daemon; the package
  never calls GitHub.
- **No pack format change.** `build-order.json` v1 and its validation stay as they are; the document
  is a derived publication, not a new authored format.
- **No public npm release in this unit.** The package is built and packed in CI. Publishing it to a
  registry is a separate operator decision.
- **No Stream Deck or mobile work.** Both read the daemon payload today and keep doing so until a
  later unit moves them onto the document.

#### Deferred to Follow-Up Work

- The daemon encoder and read surface (#7507).
- The package and its CI workflow (#7508).
- Dashboard adoption (#7509).
- The GitHub publication review moving onto the document (#7510).
- Epic records above features (#7496) are a hard prerequisite for published epic grouping, so
  `build-order.v1` publishes an epic per imported root until that lands.

---

## Planning Contract

### Key Technical Decisions

- **KTD1. The contract is a snapshot document, not a stream.** It uses the same top-level markers as
  the other snapshot contracts (`contract`, `contract_version`), so a consumer can pin a version and
  reject a document it does not understand. Chosen over a new envelope: every other consumer contract
  in the package already reads that way.
- **KTD2. Ids stay the pack id, numbers are additive.** A node's `id` is the pack id (`BO-001`) and
  `number` is the tracker number or `null`. Chosen over keying on the tracker number: an unpublished
  ticket has none, and the pack is what a reviewer diffs.
- **KTD3. Edges are one flat array.** Typed relations live in `edges` with `kind`, `source` and, for
  dependency edges, `state`. Chosen over per-relation arrays on each ticket: the graph renderer needs
  one list, and `contains` and `gates` do not fit a ticket field.
- **KTD4. Source status is per source, and progress repeats it.** `sources` names the pack, tracker
  and progress readings; epics, features, lanes and `progress` carry their own `status`. Chosen over
  one global flag: one unavailable provider must not blank a page that has good pack data.
- **KTD5. The daemon stays the graph authority.** Waves, dependency state, progress and the critical
  path are computed where tracker truth already lives and then published. The package lays out and
  draws; it does not decide what blocks what.
- **KTD6. The package is rendering only.** It holds no queue, no dispatch and no tracker client. The
  acceptance test for the boundary is that it renders a checked-in fixture in a browser with no
  daemon running.
- **KTD7. Adoption happens in one copy.** The package and the dashboard adoption ship in separate PRs
  but adoption removes the old renderers in the same PR that switches the page, so no release carries
  two review implementations.
- **KTD8. Nothing in `build-order.v1` may be dashboard-shaped.** Compressed keys, protocol versions
  and page state stay in `AiurWeb.Build.Payload`. If a field only makes sense to one page, it is not
  in the contract.

### High-Level Technical Design

The document is produced by the daemon, published by one HTTP and one CLI surface, and rendered by
the package. Nothing else touches the graph facts.

```text
planning pack (build-order.json, authored)
        │  pack walk + tracker reads
        ▼
daemon projection ─────────────► build-order.v1 document ─────► GET /api/v1/build-order
(Aiur.BuildOrder.*)               (@aiur/contracts)             aiur build-orders --json --contract
        │                                                              │
        │ dispatch, queue, progress                                    ▼
        ▼                                              packages/aiur-build-order
continuous build (BuildOrder.Cadence)                  renderReview / renderGraph
                                                              │
                                            ┌─────────────────┴─────────────────┐
                                            ▼                                   ▼
                                  dashboard Build home              GitHub review body / any tool
```

Document shape at the top level, in the order a reader needs it:

```text
contract, contract_version, build_order_id, title, repository, root,
generated_at, sources{pack,tracker,progress}, epics[], features[], lanes[],
tickets[], edges[], gates[], waves[], critical_path, progress
```

### Inventory

Measured on `main` at `c16c731ad`, the base of this ticket.

| Surface | Code today | Lines | Boundary |
| --- | --- | --- | --- |
| Planning pack | `.claude/skills/aiur-build/references/build-order.example.json`; `scripts/validation_*.py` | 4,324 Python | Stays authored; the daemon reads it |
| Graph and leveling | `Aiur.BuildOrder.{GraphAnalysis,Graph,Dependency,DependencyChain}`, `AiurWeb.Build.PlannedGraph`, `BuildQueue.SetSummary` | ~600 | Stays in the daemon; published as `edges`, `waves`, `critical_path` |
| Review and graph view | `src/priv/static/build-home/*` plus `home/*.css`; SVG layout hook in `src/browser/layout/worker/` and `src/priv/static/aiur-dom-svg-layout/` | 4,513 JS + 5,413 CSS + 1,810 | Moves to `packages/aiur-build-order` |
| Dashboard projection | `AiurWeb.Build.{Payload,PayloadSchema,PlannedGraph}`, `AiurWeb.BuildOrderViewModel`, `build_order_presenter/*` | ~4,150 | Stays; gains the `build-order.v1` encoder |
| Daemon Build Order core | `src/lib/aiur/build_order/**` | 19,654 across 138 modules | Stays |
| GitHub publication | `.claude/skills/aiur-build/scripts/publication/*` | 6,569 Python | Stays in the skill; reads the document (#7510) |
| Continuous build | `Aiur.BuildOrder.Cadence`, `BuildQueue.Sources.BuildOrder`, `Orchestrator.StatusReport` | ~900 | Stays; needs tracker truth and dispatch |

What moves to `packages/aiur-build-order`: the review markup, the graph drawing, its CSS, and the
page-state-free formatting helpers those need. What stays in the daemon: every tracker read, every
graph decision, the queue, dispatch, progress and the publication write. What stays in the pack: the
authored plan.

### How the dashboard consumes the package

Build home already fetches a payload from the daemon per view. Adoption keeps that one call and
changes only what it returns and who draws it:

- The daemon serves the document at `GET /api/v1/build-order` (#7507).
- Build home fetches that document for the review and graph regions, and keeps
  `AiurWeb.Build.Payload` for the queue, usage and conversation regions that the package does not
  model.
- The page imports `renderReview` and `renderGraph` from the package through the existing static
  asset route, so no bundler enters the dashboard build.
- URL state (focused feature, filters, section) stays in the page; the package takes state as an
  option and never reads `location`.

### Contract field map

The daemon projection already holds each of these facts; the encoder names them once.

| Document field | Source of truth today | Used by |
| --- | --- | --- |
| `root`, `build_order_id`, `title` | Pack identity and the `build-order` root | Header, links |
| `sources.*` | Provider health from the projection | Stale and unknown banners |
| `epics`, `features`, `lanes` | Feature registry, root import, lane labels | Grouping rows, legend, columns |
| `tickets` | Pack members joined to tracker issues | Cards, rows, Gantt bars |
| `edges` | Pack edges plus `blocked_by` reads | Graph, blocking badges |
| `gates` | Pack `external_gates` | Gate rows, blocked reasons |
| `waves`, `critical_path` | Graph leveling and queue summaries | Wave columns, path highlight |
| `progress` | Progress generation and closure counts | Bars, totals, percents |

---

## Unit Breakdown

### U1. The contract (this ticket)

**Goal:** freeze `build-order.v1` with fixtures and generated types.

**Requirements:** R1-R4. **Status:** delivered with this plan.

**Files:** `packages/aiur-contracts/schemas/build-order.v1.schema.json`,
`fixtures/build-order.v1.json`, `fixtures/build-order-unavailable.v1.json`,
`src/build-order.generated.ts`, `test/build-order.test.mjs`, `scripts/{generate,validate}.mjs`,
`scripts/check-fixture-types.mjs`, `README.md`.

**Approach:** a snapshot contract with the shared markers, one full fixture and one unavailable-source
fixture, and tests that pin the marker, the edge kinds, the nullable-count rule and the additive-field
rule.

**Verification:** `npm run check` and `npm test` in `packages/aiur-contracts`.

### U2. Publish it from the daemon (#7507)

**Goal:** one encoder and two read surfaces produce the document from existing projections.

**Requirements:** R1-R4, R7. **Dependencies:** U1.

**Approach:** `Aiur.BuildOrder.Published.encode/1` maps catalog and selected-root projections plus the
feature, lane and progress records onto the document, reusing the graph, wave, critical-path and
progress code that already exists. `GET /api/v1/build-order` and
`aiur build-orders --json --contract build-order.v1` expose it. A golden document is validated by
`packages/aiur-contracts` in CI.

**Test scenarios:** the encoder output validates against the schema; a projection with an unavailable
tracker publishes `status: "unknown"` with tickets intact; every edge kind appears with its source; a
selected root publishes only its members; mutation check: drop the unknown-status branch and AE2's
test fails.

### U3. The package (#7508)

**Goal:** render the review and graph from the document alone.

**Requirements:** R5. **Dependencies:** U1, U2 for the fixtures.

**Approach:** ESM + TypeScript, no framework and no network client. `parseBuildOrder`,
`renderReview`, `renderGraph` and an `<aiur-build-order>` element. Layout is deterministic: waves are
columns, node order inside a column comes from the document, and edge kinds get their own stroke and
legend entry. Tokens come from `@aiur/style`.

**Test scenarios:** the full fixture renders every ticket, epic, feature and lane and one edge of each
kind; the unavailable fixture renders an unknown banner and no `0%`; an invalid document returns a
structured error and renders nothing; a fixture page renders in Chromium; mutation check: dropping the
`terminal_unsatisfied` branch makes AE3 fail.

### U4. Dashboard adoption (#7509)

**Goal:** one renderer in the product.

**Requirements:** R6. **Dependencies:** U2, U3.

**Approach:** Build home fetches the document for its review and graph regions and renders through the
package, keeping the payload for queue, usage and conversation. The replaced page-local modules are
deleted in the same PR, and the PR names every retired module and every retained protocol key.

**Test scenarios:** each `src/browser/tests/build-home-*.browser.spec.mjs` passes; a browser assertion
finds the package's markup in the review and graph; the unknown-source banner shows when the document
says so; mutation check: reverting the page to the local renderer fails the package-markup assertion.

### U5. Publication on the document (#7510)

**Goal:** the GitHub review and the dashboard review cannot disagree.

**Requirements:** R8. **Dependencies:** U2.

**Approach:** the publication rendering reads graph facts from the document; where the skill must run
without a daemon, it publishes a document from the pack walk and reads that. The PR carries a diff of
the body before and after.

**Test scenarios:** the example pack publishes the same review sections with a listed diff; an unknown
source publishes an explicit notice; mutation check: reverting the document read restores the
recomputation and fails the consistency test.

---

## Ticket Breakdown

| Order | Unit | Ticket | Priority | Complexity | Blocked by |
| --- | --- | --- | --- | --- | --- |
| 1 | U1 | #7490 (this ticket: plan, contract, follow-ups) | 1 | 3 | — |
| 2 | U2 | #7507 Publish build-order.v1 from the daemon projection | 2 | 3 | #7490 |
| 3 | U3 | #7508 Ship packages/aiur-build-order | 1 | 4 | #7507 |
| 4 | U4 | #7509 Adopt the package in the dashboard | 2 | 4 | #7508 |
| 5 | U5 | #7510 Render the GitHub review from build-order.v1 | 3 | 3 | #7507 |

Every filed ticket carries `agent:todo`, `enhancement`, a `complexity:N` and a `priority:N` label, and
its `blocked_by` edge is set on GitHub before this plan merges.

---

## Verification Contract

- **Contracts:** from `packages/aiur-contracts`, `npm ci`, `npm run check` (generation drift, fixture
  schema and type checks, build) and `npm test`.
- **Package:** from `packages/aiur-build-order`, `npm run build`, `npm run lint`, `npm test` (node
  --test), the Playwright spec for the fixture page, and `npm run pack:check`.
- **Elixir:** the touched test files with `mise exec -- mix test <files>`, then `mise exec -- mix lint`
  from `src/`. CI runs the full partitions.
- **Browser:** `src/browser` spec runs for the touched `build-home-*` specs; CI runs the harness.
- **Docs:** `scripts/check-config-docs.py` and `website/docs-app/scripts/check-cli-reference.sh` for
  the CLI flag and page changes.
- **Mutation discipline:** each new test fails with its production hunk reverted; each PR names the
  result per test.
- **Live:** after each merge the Executor rebuilds, restarts and checks the surface the unit changes
  (the endpoint, the package demo page, the Build home review and graph).

## Definition of Done

- `build-order.v1` is in `@aiur/contracts` with fixtures, generated types and tests, and the daemon
  publishes it from one encoder.
- `packages/aiur-build-order` renders the review and graph from a document in a browser with no
  daemon, and Build home draws through it with the duplicate renderer removed.
- The GitHub publication review and the dashboard review read the same graph facts.
- Every unit's docs page is updated in the same PR that changes it.
- Every acceptance example has a test that fails with its production hunk reverted.

## Open Questions

- **Q1. Should the contract carry per-ticket acceptance text?** Default: no. The review links to the
  ticket document instead of embedding it, so the document stays small enough to cache per view.
- **Q2. Should `progress` publish a forecast?** Default: not in v1. Forecasts are an estimate surface
  with their own freshness rules; a wrong forecast in a published contract is worse than none.
- **Q3. Does the package own the Stream Deck graph?** Default: no. Stream Deck renders its own compact
  frames and stays on the daemon payload until a later unit.
