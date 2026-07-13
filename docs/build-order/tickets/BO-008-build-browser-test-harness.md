# BO-008 — Build browser, accessibility, and performance harness

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — Cohesive but cross-cutting browser toolchain, deterministic fixtures, accessibility, artifact, and performance infrastructure

**Risk:** medium

**Phase hint:** 1

**Depends on:** BO-001

**Serializes with:** none

**Requirements:** BOREQ-008, BOREQ-014

**Decisions:** DEC-007

**Design evidence:** DESIGN-001, DESIGN-002

**Researched at:** 16d6033d8824c8cb53ac09e2129f69af751be8c4

**Suggested labels:** `complexity:4`, `model:codex`, `phase:1`, `build-lane:infrastructure`; never `agent:todo`

## Outcome

The repository has CI-runnable, deterministic browser infrastructure for real
LiveView interaction, automated accessibility checks, responsive screenshots,
and performance measurements, plus reusable 20/50/100/cycle/invalid/degraded
Build Order fixtures built from BO-001's accepted domain contract that later UI
tickets must use.

## Context and evidence

The current suite has rich LiveView/component coverage but no committed
LiveView browser runner that can prove pointer, keyboard, focus, worker timing,
responsive redraw, reduced motion, or accessible dialogs. The static
`website/` now has a Vite/Playwright harness and path-scoped CI that can inform
toolchain and artifact conventions, but it does not exercise Phoenix,
LiveView, Basic Auth, or the real dashboard route. Deferring infrastructure to
the capstone would make each UI ticket invent a different proxy and leave
performance/a11y failures unowned.

## Scope

- Add a pinned maintained headless-browser runner compatible with the current
  Node/Elixir toolchain, a pinned automated accessibility engine, and repository
  scripts/configuration that run locally and in CI without external services.
- Provide deterministic test-server startup/teardown, browser/port isolation,
  failure artifacts, timeouts, and environment detection with no fixed host,
  machine path, or shared global state.
- Add fixture builders for valid 0/1/20/50/100-member graphs, multi-root
  catalogs, every edge/readiness state, cycles/self-loops, external/missing
  endpoints, malformed root among valid roots, selected structural-invalid,
  member metadata warnings, stale LKG, unavailable providers, and activity
  updates. Reuse BO-001's exact records, enums, identities, and bounded fixture
  vocabulary rather than defining a browser-only copy.
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
- Test against the prototype's client-only sample code or depend on network
  CDNs/provider accounts.
- Make screenshots the only accessibility or behavior assertion.

## Existing owner and reuse target

Extend the root development/CI scripts, Phoenix test endpoint/fixtures, and
existing deterministic test conventions. Keep browser tooling isolated from
production assets and reuse existing Basic Auth/config injection.

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
- Fixture tests assert exact node/edge/root/diagnostic counts and identities at
  every size/state, including one malformed root beside valid catalog entries.
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

BO-001 defines the domain fixtures this harness renders. BO-010, BO-013,
BO-014, and BO-015 consume the harness. Production layout and graph behavior
remain owned by those tickets. Companion dashboard tickets may reuse the
infrastructure but must serialize only on shared test configuration.
