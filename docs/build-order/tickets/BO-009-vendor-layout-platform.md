# BO: BO-009 — Vendor layout worker and static platform

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — Pinned third-party engine, worker protocol, and release packaging

**Risk:** high

**Phase hint:** 2

**Depends on:** BO-001, BO-008

**Serializes with:** none

**Requirements:** BOREQ-009

**Decisions:** DEC-007

**Design evidence:** DESIGN-001, DESIGN-002

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:4`, `model:codex-gpt-5.6-terra`, `phase:2`, `build-lane:platform`; never `agent:todo`

## Outcome

Aiur ships a pinned, locally served directed-graph layout engine behind a
versioned Web Worker protocol, with reproducible static-asset/release packaging,
license evidence, integrity checks, and no DOM or product-state ownership.

## Context and evidence

The prototype's fixed coordinates are a build-less reliability technique, not
a production layout for arbitrary 100-member graphs. A maintained layered
engine such as ELK.js fits directed lanes/layers and routed edges, but importing
it ad hoc from a CDN would violate offline, security, release, and repeatability
requirements. Layout must also leave the browser main thread at scale.

This ticket owns only the vendored engine/worker/static platform. BO-010 owns
measurement, DOM integration, SVG application, generation safety, and fallback.

## Scope

- Pin an exact maintained layout-only engine version after verifying its
  directed layered features, worker compatibility, supported browsers, license,
  package provenance, and representative fixture capability.
- Vendor/build the minimum required local asset through the repository's
  reproducible asset pipeline; include license/notices, version/checksum, size
  budget, source mapping policy, and release/npm inclusion.
- Define a versioned worker request/response/error protocol for bounded nodes,
  directed edges, lane/phase constraints, sizes, layout options, coordinates,
  routed points, and diagnostics. Payloads contain geometry identifiers only,
  never titles, bodies, credentials, or runtime actions.
- Add a dedicated Worker entry that validates/bounds messages, invokes the
  engine off the main thread, supports generation/request cancellation by
  obsolescence, and returns structured safe errors.
- Make local asset URLs compatible with the current Phoenix static path,
  content security policy, cache busting, packaged release, and offline use.
- Prove deterministic-enough geometry invariants on 20/50/100/cycle/external
  fixtures without making pixel coordinates a public contract.

## Non-goals

- Measure DOM cards, implement the LiveView hook, position cards, draw SVG,
  implement pan/zoom, define graph status, or render a fallback.
- Let the engine infer product phase/lane/readiness or consume issue bodies.
- Load a CDN, execute remote code, expose worker internals as public product
  state, or silently switch engine versions at runtime.

## Existing owner and reuse target

Extend the current static asset/release packaging and browser-hook asset
conventions. Keep the third-party adapter isolated behind a small worker
protocol so BO-010 and tests do not import engine-specific objects.

## Contract and invariants

- The exact engine build, license, checksum/version, and worker protocol are
  reproducible from committed sources and included in every supported release.
- The worker is geometry-only, bounded to the v1 maximum, and receives no
  sensitive/product-action content.
- Worker failure, timeout, unsupported browser, or malformed response is a
  structured result for BO-010; it never removes semantic DOM.
- Stale generations may finish but cannot claim currency; BO-010 decides
  whether a response still matches the active root/generation/measurement.
- Layout coordinates are implementation results, not readiness or dependency
  truth.

## Refreshable implementation notes

- Recheck the current ELK.js release, transitive package content, license, and
  browser-worker guidance at pickup; if it fails the bounded fixture/license
  gate, record evidence and select another maintained layout-only engine behind
  the same protocol.
- Avoid hand-editing generated bundles; document the exact reproducible command
  and keep generated/runtime files within repository size/module limits.
- Coordinate with any companion static-asset work through merge serialization,
  not hard dependencies.

## Acceptance and verification

### Agent gate

- Unit/worker tests cover valid 0/1/20/50/100 graphs, constraints, cycles,
  external stubs, malformed/oversized messages, engine errors, unsupported
  worker, and stale request IDs.
- Packaging tests verify local-only URLs, checksum/version, license files,
  production digest/release inclusion, cache busting, and no sensitive fields in
  worker payloads.
- BO-008's browser harness proves the worker executes off the main thread and
  returns bounded geometry for representative fixtures.

### At-merge gate

- Asset build/check, worker/static/release tests, compile/lint/spec checks, and
  full CI pass on the current configured integration branch.
- A packaged release smoke can load the worker offline without CSP or missing
  asset failures.

### Human/manual evidence

- Reviewer inspects the license/provenance/size record and loads the worker from
  a packaged local dashboard. BO-015 owns product visual acceptance.

## Failure, security, migration, and accessibility cases

- Pin and audit third-party code, serve locally under current CSP, and never
  send issue content or credentials into geometry payloads/errors.
- No persisted data migration; worker protocol and asset version are explicit
  upgrade boundaries.
- The worker cannot own accessibility. Semantic DOM/fallback remains available
  when JavaScript or layout fails.

## Surfaces

- Reads: BO-001 bounded graph vocabulary; current asset/release/CSP pipeline.
- Writes: pinned layout dependency/assets, license/provenance record, worker
  protocol/entry, packaging checks, and fixtures.
- Contracts: versioned geometry worker request/response/error protocol; local
  static asset identity.

## Sibling boundaries and open gates

BO-010 exclusively owns DOM measurement, hook state, SVG, and fallback. BO-008
supplies browser fixtures. Companion UI may reuse asset tooling but cannot make
the layout engine a companion prerequisite or product-state owner.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `BO-009`
- [Graph waves, critical path, and parallelism](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.
