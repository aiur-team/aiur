# BO-008 — Build browser, accessibility, and performance harness

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — Cohesive but cross-cutting browser toolchain, deterministic fixtures, accessibility, artifact, and performance infrastructure

**Risk:** medium

**Phase hint:** 1

**Depends on:** none

**Serializes with:** none

**External gates:** GATE-001 (integration baseline), GATE-002 (Executor skill)

**Requirements:** BOREQ-008, BOREQ-014

**Decisions:** DEC-007, DEC-013

**Design evidence:** DESIGN-001, DESIGN-002

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:4`, `model:codex-gpt-5.6-terra`, `phase:1`, `build-lane:platform`; never `agent:todo`

## Outcome

The repository has CI-runnable, deterministic browser infrastructure for real
LiveView interaction, automated accessibility checks, responsive screenshots,
and performance measurements, plus reusable bounded graph-scenario generators
and neutral fixture primitives that later Build Order UI tickets can bind to the
accepted domain contract.

## Context and evidence

Current main now includes a Playwright documentation-capture runner that starts
a synthetic Phoenix/LiveView endpoint, allocates an isolated port, records
desktop/mobile screenshots, and rejects horizontal overflow. Its checked-in
fixture and assets are useful executable precedent, but the capture command is
not yet the shared CI acceptance harness: it does not prove authenticated
navigation, pointer/keyboard/focus behavior, workers, automated accessibility,
reconnect, trace-on-failure, or performance budgets. Deferring that reusable
layer to the capstone would make each UI ticket invent a different proxy and
leave interaction/performance/a11y failures unowned.

The harness and neutral fixtures do not require Build Order domain records, so
this ticket may proceed in parallel with BO-001 after GATE-001 and GATE-002 are
resolved. Downstream tickets own binding the harness to production Build Order
records and semantics.

## Scope

- Generalize the shipped Playwright/Phoenix capture precedent into a pinned
  maintained headless-browser runner compatible with the current Node/Elixir
  toolchain, add a pinned automated accessibility engine, and provide repository
  scripts/configuration that run locally and in CI without external services.
- Provide deterministic test-server startup/teardown, browser/port isolation,
  failure artifacts, timeouts, and environment detection with no fixed host,
  machine path, or shared global state.
- Add fixture builders for valid 0/1/20/50/100-member graphs, multi-root
  catalogs, DAGs, cycles/self-loops, external/missing endpoints, invalid and
  degraded payloads, and live updates through a neutral deterministic fixture
  schema. The harness must accept downstream domain adapters rather than
  defining Build Order edge, readiness, provider, or identity semantics.
- Provide reusable browser helpers for authenticated/read-only and writable
  modes, viewport/theme/reduced-motion, keyboard/touch/pointer input, focus,
  zoom/pan, LiveView reconnect, and worker readiness.
- Provide measurement primitives for layout latency, main-thread responsiveness,
  redraw/coalescing, long tasks, and stable budget assertions without choosing
  BO-014's final thresholds.
- Capture sanitized screenshots/traces only on configured runs or failure;
  document commands and artifact locations.

## Non-goals

- Implement graph production UI, choose layout geometry, declare final
  performance budgets, run Aiur agents, or replace the real CLI proof in
  BO-015.
- Define Build Order domain records, readiness policy, provider health, or the
  production mapping from neutral fixtures into BO-001 contracts.
- Test against the prototype's client-only sample code or depend on network
  CDNs/provider accounts.
- Make screenshots the only accessibility or behavior assertion.

## Existing owner and reuse target

Extend `website/scripts/capture-executor-control-center.mjs`, its synthetic
Phoenix fixture patterns, the root development/CI scripts, and existing
deterministic test conventions without turning documentation screenshots into
the acceptance API. Keep browser tooling isolated from production assets and
reuse existing Basic Auth/config injection.

## Contract and invariants

- Browser tests exercise rendered LiveView and real hooks/workers, not static
  HTML string assertions or direct HTTP API substitutes.
- Fixtures are deterministic, bounded, synthetic, and contain no real issue,
  account, repository, credential, or local-environment data.
- CI failures retain enough sanitized evidence to reproduce while successful
  runs do not grow unbounded artifacts.
- Performance clocks and thresholds use monotonic browser measurements with
  explicit warmup/repetition; test retries cannot hide a failed budget.
- The harness works without a globally installed browser or interactive TTY.

## Refreshable implementation notes

- Inspect the current package manager, CI caches, supported platforms, and
  contribution gate before pinning Playwright/Chromium and an accessibility
  engine such as axe-core; record the exact accepted choice and license.
- Keep scripts small and reusable for future dashboard companions without
  making those companions prerequisites.
- Prefer injected readiness markers and event-driven waits over arbitrary
  sleeps.

## Acceptance and verification

### Agent gate

- A sample fixture LiveView proves navigation, JS hook/worker execution,
  pointer/keyboard/touch, focus, theme, reduced motion, reconnect, screenshot,
  automated a11y, and performance measurement paths.
- Fixture tests assert exact node/edge/root counts and deterministic identities
  for every neutral size/scenario without claiming product semantics.
- Failure-injection tests prove teardown, timeout, trace/screenshot, port
  isolation, and sensitive-data scrubbing.

### At-merge gate

- The browser/a11y smoke runs in the repository CI matrix on the current
  configured integration branch alongside existing compile/lint/spec/test
  gates, with documented local invocation and cache behavior.
- Harness startup leaves no browser, server, port, or artifact process behind.

### Human/manual evidence

- Reviewer runs the documented browser smoke once locally and confirms a
  deliberately failing assertion yields useful sanitized evidence. BO-015 owns
  product acceptance.

## Failure, security, migration, and accessibility cases

- Never embed credentials in screenshots, traces, command lines, URLs, fixture
  bodies, or committed artifacts; use synthetic auth and redact failures.
- Production has no migration; development/CI dependencies are pinned and
  license/cache impacts documented.
- The harness itself must support keyboard/focus/reduced-motion/color-independent
  assertions and automated checks without claiming they replace human review.

## Surfaces

- Reads: current Node/Elixir toolchain, CI configuration, Phoenix test endpoint,
  and dashboard auth conventions.
- Writes: browser/a11y/performance configs and scripts, synthetic fixture
  builders, CI job/cache, helpers, and documentation.
- Contracts: deterministic browser environment; fixture vocabulary;
  measurement/artifact API.

## Sibling boundaries and open gates

BO-001 and downstream UI tickets own production domain adapters and product
semantics; BO-010, BO-013, BO-014, and BO-015 consume the harness. Production
layout and graph behavior remain owned by those tickets. Companion dashboard
tickets may reuse the infrastructure but must serialize only on shared test
configuration. GATE-001 and GATE-002 are direct pre-dispatch gates, not hidden
dependencies on BO-001.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `BO-008`
- [Graph waves, critical path, and parallelism](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.
