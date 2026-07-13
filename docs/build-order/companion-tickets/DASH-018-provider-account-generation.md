# DASH-018 — Own provider-account generation identity

**Kind:** executable

**Provenance:** planned in plan v1 after accounting-boundary review

**Complexity:** 3 — One privacy-safe lifecycle identity shared across provider usage and meter adapters

**Risk:** high

**Phase hint:** 1

**Depends on:** none

**Serializes with:** BO-003, BO-005, BO-016, BO-019, DASH-002, DASH-019, DASH-026 — application supervision tree; DASH-019 also shares Claude process lifecycle adapters

**Predecessor baseline:** resolved — `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f`

**Requirements:** DREQ-018

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:3`, `model:codex`, `phase:1`, `build-lane:accounting`; never `agent:todo`

**Build Order membership:** member of the consolidated Build Order (operator decision 2026-07-13)

## Outcome

Every trusted provider/auth lifecycle exposes one opaque local account generation that usage and meter adapters share, rotate together, and can correlate without retaining or deriving account identity.

## Context and evidence

Usage estimates may show an actual plan tier only when the usage and meter facts belong to the same authenticated account binding. Independent usage-only and meter-only counters cannot prove that join, while raw email/account/org identifiers violate the privacy boundary. This ticket owns the shared identity lifecycle independently of usage-envelope and provider-meter implementations.

## Scope

- Define a versioned `ProviderAccountGeneration` service keyed by provider/backend/auth-process binding rather than ticket or browser.
- Mint an opaque random/non-derivable local generation when a trusted provider-account binding becomes known. Keep it stable only while continuity of that exact binding is known.
- Rotate on login, logout, credential/account replacement, backend binding replacement, or loss of continuity. A quota reset, request retry, process restart with proven binding continuity, or counter reset does not itself assert account change.
- Accept lifecycle observations only from trusted Codex/Claude auth/process owners. Never accept browser, agent payload, display prose, account page, or meter/usage value as identity evidence.
- Expose current lookup, generation-change subscription, source/freshness/health, and test-only injected mint/clock hooks. Usage and meter adapters consume the same returned value.
- Make unknown/unavailable binding explicit. Unknown generation may group tokens but cannot join a meter snapshot or another known generation.
- Persist only the minimum continuity state needed across supported process restarts, if continuity can be proven safely. Loss of proof rotates or becomes unknown rather than reusing a guess.

## Non-goals

- Normalize usage, fetch account meters, retain tokens/cost, expose raw account IDs, allocate subscription fees, or render UI.
- Reuse `counter_epoch`, quota reset, ledger generation, run ID, session ID, credential hash, email, account, organization, project, or workspace as the account generation.
- Guarantee continuity when a provider protocol supplies no trustworthy lifecycle evidence.

## Existing owner and reuse target

Extend trusted Codex app-server and Claude/aiur-claude authentication/process lifecycle boundaries. Add one shared daemon owner and typed interface rather than parallel counters inside DASH-008, DASH-012, DASH-013, or DASH-020.

## Contract and invariants

- The generation is opaque, random/non-derivable, content-free, provider/backend scoped, and stable only for proven binding continuity.
- All adapters for the same binding receive the same generation. No consumer may mint or increment a local substitute.
- Account generation, usage `counter_epoch`, quota-window reset, run ID, session ID, and storage generation are distinct namespaces.
- An unknown generation never joins known usage and meter facts by provider/backend alone.
- Rotation is monotonic as an identity change event, but the opaque value exposes no ordinal, account fingerprint, or cross-install correlation.

## Refreshable implementation notes

- Characterize installed Codex and Claude auth/process lifecycle events at pickup and record which transitions prove continuity versus force rotation/unknown.
- Keep lifecycle adapters thin; centralize generation minting, validation, storage, and change publication in one module family under repository size limits.
- Prefer in-memory state when daemon lifetime already breaks continuity; persist only when an existing trusted binding token can prove safe restoration without retaining PII or credentials.
- Reconcile the central application supervision tree with every declared
  serialization peer before either overlapping branch executes or merges.

## Acceptance and verification

### Agent gate

- State-machine/property tests cover initial unknown, trusted bind, stable repeated observation, login/logout/account replacement, credential replacement, process replacement with and without continuity, provider/backend isolation, and duplicate/out-of-order lifecycle events.
- Cross-consumer tests prove DASH-008 and DASH-012 fixtures receive one shared value, quota/counter reset does not rotate it, and account rotation invalidates both consumers together.
- Security tests prove values are non-derivable and no email/account/org/project/credential/hash/raw response/capability data is persisted, logged, published, or exposed.

### At-merge gate

- Rebase on the resolved configured integration target and current Codex/Claude auth lifecycle; run app-server/process lifecycle, credential replacement/logout, state recovery, PubSub, redaction, packaging, and full CI suites.

### Human/manual evidence

- With synthetic bindings, show usage and meter fixtures sharing a generation, then rotate the binding and prove old usage cannot join the new meter without exposing any account identifier.

## Failure, security, migration, and accessibility cases

- Missing, ambiguous, stale, or failed lifecycle evidence yields unknown or rotates safely; it never reuses a guessed account generation.
- Never retain credentials, hashes usable as fingerprints, raw provider responses, email/account/org/project identity, environment values, or capability URLs.
- Version the service state and events. Existing consumers begin with unknown until a trusted binding is observed; no historical account generation is fabricated.
- No direct UI. Health, continuity, and unknown reasons are stable human-readable classes.

## Surfaces

- Reads: trusted Codex/Claude auth and process-binding lifecycle observations.
- Writes: opaque generation owner/state, Claude process lifecycle adapters,
  change events, tests.
- Contracts: shared provider-account-generation lookup, rotation, health, and privacy semantics.
- Safety: non-derivable provider/account isolation and the application
  supervision tree.

## Sibling boundaries and open gates

DASH-008 consumes this identity for usage envelopes. DASH-012 consumes it for
generic meter snapshots, while DASH-020 and DASH-013 report provider lifecycle
changes through the trusted owner. DASH-018 serializes with DASH-019 because
both write Claude process lifecycle adapters; this ticket owns account
generation while DASH-019 owns authenticated telemetry transport. Other
declared peers share only the central application supervision tree. DASH-011
groups but never joins meters; DASH-015 performs the only exact-generation
usage/tier composition.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `DASH-018`
- [Graph waves, critical path, and parallelism](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.
