---
title: "feat: Normalize Codex account meters"
type: feat
status: completed
date: 2026-07-16
origin: docs/brainstorms/2026-07-12-build-order-requirements.md
---

# feat: Normalize Codex account meters

## Summary

Add a thin Codex protocol adapter that converts trusted camelCase account and
rate-limit observations into the shipped provider-meter projection. The adapter
will use the existing account-generation owner, retain scheduling-only
`ModelAvailability` as a one-way conservative feed, and construct all public
facts from an allowlist.

---

## Problem Frame

Codex has a structured `account/rateLimits/read` response and update
notifications, but the current code only redacts a small scheduling shape for
`ModelAvailability`. That loses arbitrary limit IDs and plan/credit controls,
does not classify meter update semantics, and leaves the canonical DASH-012
projection unpopulated (see origin:
`docs/brainstorms/2026-07-12-build-order-requirements.md`).

---

## Assumptions

*This plan was authored without synchronous user confirmation. The items below
are agent inferences that fill implementation details not fixed by DREQ-020
and should remain visible during review.*

- The installed Codex CLI (`codex-cli 0.144.4`) is the compatible protocol
  source. Its `account/rateLimits/read` response is a full observation; update
  notifications are patches unless the structured payload explicitly identifies
  a replacement or removal.
- Existing provider-meter input terms remain the source of truth. The adapter
  will report an unsupported or unknown structured fact rather than infer a
  financial value from scheduling status.

---

## Requirements

- R1. Normalize supported structured Codex subscription and API-key account,
  plan, limit, reset, credit, and spend facts into the DREQ-012 projection.
- R2. Resolve the current DASH-018 Codex account generation before every meter
  update; logout, account change, process loss, quota reset, and token refresh
  must not mint a meter-local generation.
- R3. Preserve a one-way, conservative `ModelAvailability` compatibility feed;
  it must not be a canonical provider-meter writer or query source.
- R4. Allowlist output and logs so account identity, credentials, raw responses,
  endpoint/capability data, and unknown fields never leave the adapter.

**Origin acceptance examples:** DREQ-020 and issue #1124's fixture, lifecycle,
compatibility, and redaction matrix.

---

## Scope Boundaries

- Do not define generic provider-meter reconciliation, generation ownership,
  usage/cost ingestion, or dashboard presentation.
- Do not scrape Codex output or call account/billing APIs outside the structured
  app-server protocol.
- Do not fabricate named hourly, weekly, or monthly windows from arbitrary
  source windows, or infer a plan, credits, or unlimited quota.
- Do not turn `ModelAvailability` into a second canonical meter writer.

---

## Context & Research

- `src/lib/aiur/provider_meters.ex` and its input/store/reconciler modules are
  the established DASH-012 ingestion boundary and resolve the account
  generation from `Aiur.ProviderAccountGeneration`.
- `src/lib/aiur/codex/account_generation.ex` owns Codex lifecycle transitions;
  its context already retains the binding/authority required by the meter
  projection.
- `src/lib/aiur/codex/handshake.ex` performs the structured read; startup must
  bind the account before attempting canonical meter ingestion.
- `src/lib/aiur/codex/event_normalizer.ex` is intentionally scheduling-shaped.
  The new adapter parses camelCase payloads before forwarding a sanitized
  compatibility subset to `ModelAvailability`.
- `src/lib/aiur/model_availability.ex` preserves existing fallback behavior
  using only a collapsed conservative window view.

---

## Key Technical Decisions

- Put camelCase/source-version and full/patch/tombstone classification in a
  dedicated Codex adapter; reuse `ProviderMeters` validation and reconciliation
  rather than duplicating its policy.
- Construct provider-meter updates from scalar allowlists and typed maps. Drop
  unrecognized protocol fields before any callback, projection, or log call.
- Treat an initial structured read as a full snapshot after the account binding
  is established. Treat malformed, timeout, and unavailable observations as
  projection-health failures that retain last-known-good facts.
- Feed compatibility only after adapter normalization, using a derived
  scheduling shape. Canonical projection writes remain exclusive to
  `ProviderMeters`.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for
> review, not implementation specification. The implementing agent should
> treat it as context, not code to reproduce.*

```text
Codex read / notification
           |
           v
  allowlisted Codex meter adapter
      |              |
      v              v
ProviderMeters   ModelAvailability
canonical facts  conservative scheduling-only view
      ^
      |
existing ProviderAccountGeneration binding
```

---

## Implementation Units

### U1. Normalize the structured Codex meter payload

**Goal:** Convert compatible `account/rateLimits/read` results and update
notifications into valid `ProviderMeters` snapshot, patch, tombstone, and
failure inputs without exposing untrusted source fields.

**Requirements:** R1, R4.

**Dependencies:** Existing DASH-012 input validation and the Codex account
generation context.

**Files:** `src/lib/aiur/codex/rate_limit_adapter.ex`,
`src/lib/aiur/codex/rate_limits.ex`, `src/test/aiur/codex/rate_limit_adapter_test.exs`.

**Approach:** Keep the raw camelCase boundary private to the adapter. Preserve
arbitrary valid limit IDs and source durations/resets, map only supported
structured plan/credit/spend controls, and distinguish a full read, sparse
update, explicit removal, protocol drift, and provider failure.

**Patterns to follow:** `Aiur.ProviderMeters.Input`,
`Aiur.ProviderMeters.Reconciler`, and the existing `Aiur.Codex.RateLimits`
privacy allowlist.

**Test scenarios:**

- Normalize multiple differently named limit IDs with independent duration,
  reset, used/remaining, and unknown-field stripping.
- Map subscription and API-key observations only to facts present in their
  structured payloads; do not infer absent plan, credit, or spend data.
- Classify full replacement, sparse patch, and explicit removal while malformed
  and timeout inputs become health failures rather than empty snapshots.
- Reject identity, credential, raw-response, capability, and unsupported
  fields from every adapter output.

**Verification:** Adapter outputs are accepted by the existing provider-meter
input validator and contain only allowlisted fields.

### U2. Connect lifecycle-aware reads and notifications

**Goal:** Send adapter results through the existing account-generation binding,
then derive the legacy scheduling feed without creating a second meter writer.

**Requirements:** R1, R2, R3, R4.

**Dependencies:** U1.

**Files:** `src/lib/aiur/codex/account_generation.ex`,
`src/lib/aiur/codex/session_lifecycle.ex`,
`src/lib/aiur/codex/coding_agent.ex`, `src/lib/aiur/agent_runner/message_handler.ex`,
`src/test/aiur/codex/account_generation_test.exs`,
`src/test/aiur/codex/coding_agent_test.exs`,
`src/test/aiur/codex/turn_loop_test.exs`.

**Approach:** Seed and confirm the trusted account binding before reading meters,
submit only generated typed updates through the projection facade, and record
errors through its failure API. Continue emitting the conservative scheduling
view from a derived sanitized payload; never consume `ModelAvailability` as
meter truth.

**Patterns to follow:** `Aiur.Codex.AccountGeneration.Context`,
`Aiur.ProviderAccountGeneration`, and the `MessageHandler` injected-observer
test seam.

**Test scenarios:**

- A bound subscription and API-key session produce snapshots that carry the
  same current generation held by usage/lifecycle consumers.
- Login/logout/account replacement changes the generation while token refresh,
  quota reset, and rate-limit patches do not.
- Failed and malformed reads retain same-generation last-known-good facts and
  report health; a valid later full snapshot recovers them.
- Notifications preserve current scheduling fallback behavior yet cannot write,
  replace, or query canonical meter facts through `ModelAvailability`.

**Verification:** Lifecycle integration tests show one generation source and
the canonical projection changes only through `ProviderMeters`.

### U3. Capture compatible protocol fixtures and regression coverage

**Goal:** Version sanitized fixtures and characterize the full operational
boundary, including compatibility and redaction regression cases.

**Requirements:** R1-R4.

**Dependencies:** U1, U2.

**Files:** `src/test/fixtures/codex/`,
`src/test/aiur/codex/rate_limit_adapter_test.exs`,
`src/test/aiur/model_availability_test.exs`,
`src/test/aiur/provider_meters_test.exs`.

**Approach:** Use only synthetic/redacted payload maps for the installed and
compatible protocol versions. Exercise arbitrary IDs, unknown fields, account
rotation, recovery, and the existing fallback characterization boundary.

**Patterns to follow:** the existing Codex fixture-style tests and
`ProviderMeters` store tests.

**Test scenarios:**

- Each fixture is safe to inspect and contains no account, organization,
  project, credential, OAuth, raw header, endpoint, or capability value.
- Property cases preserve arbitrary valid IDs and reject malformed identities,
  unsupported values, and unknown protocol drift.
- Compatibility tests retain the current `ModelAvailability.available?/2` and
  recovery behavior for an exhausted source window.

**Verification:** Focused adapter, lifecycle, provider-meter, and scheduling
tests pass without requiring a live account.

---

## Risks & Mitigations

- **Protocol drift:** retain unknown fields only as dropped diagnostics; valid
  protocol failures update health rather than deleting last-known-good facts.
- **Privacy leakage:** construct public values from an explicit allowlist and
  assert redaction at adapter and message boundaries.
- **Dual writers:** keep the compatibility conversion downstream of the adapter
  and test that it has no provider-meter write path.
- **Lifecycle ordering:** account binding precedes full-read ingestion; failed
  binding leaves meter generation unknown rather than inventing identity.

---

## Deferred to Implementation

- Exact synthetic fixture filenames and source-version constants will be chosen
  from the installed app-server schema while retaining the allowed input terms.
- A newly observed protocol update marker will be classified only after its
  documented semantics are confirmed; it will not be guessed from field names.
