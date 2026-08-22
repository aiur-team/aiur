---
title: "fix: Diagnose invalid supervisor tokens"
date: 2026-08-21
type: fix
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Diagnose Invalid Supervisor Tokens

## Goal Capsule

- **Objective:** Make an unusable `AIUR_SUPERVISOR_TOKEN` visible at startup and distinguish instance configuration failures from caller authentication failures at the Decision API.
- **Authority:** GitHub issue #2262 and the existing Supervisor Decision API contract.
- **Stop conditions:** Present empty, short, or malformed tokens fail startup without leaking values; HTTP responses distinguish unavailable configuration, missing credentials, and mismatches; operator docs include a valid generation and placement recipe.
- **Tail ownership:** Complete the scoped local gate, draft PR self-review, and CI handoff against `main`.

---

## Product Contract

### Summary

The Supervisor Decision API must fail closed without misdirecting operators: an intentionally absent token disables the optional API, an invalid configured token is a startup configuration error, and a request-time mismatch is identified as a caller credential error.

### Requirements

- R1. An absent `AIUR_SUPERVISOR_TOKEN` remains a supported optional-integration state and is reported by the existing disabled-integration startup notice.
- R2. A present empty, whitespace-only, shorter-than-32-byte, padded, or non-bearer-safe token aborts startup with a secret-safe error naming `AIUR_SUPERVISOR_TOKEN` and its requirements.
- R3. Supervisor-authenticated routes return a configuration-specific 401 when the instance has no usable configured token.
- R4. A missing or malformed Authorization header remains distinct from a valid-shaped bearer token that does not match the configured credential.
- R5. Authentication failures never echo either configured or presented secret material.
- R6. Documentation states how to generate a bearer-safe token of at least 32 bytes and place it in `~/.aiur/.env` or the repository `.env` according to documented precedence.

### Scope Boundaries

- Preserve the existing route set, fixed supervisor actor, constant-time token comparison, and per-request token rotation behavior.
- Do not make the optional Supervisor Decision API mandatory for daemon startup.
- Do not change decision delegation, writable-origin, or authority policy.

---

## Planning Contract

### Key Technical Decisions

- KTD1. Centralize token classification in a core module shared by startup validation and the Plug so minimum length and bearer-safe syntax cannot drift between the two enforcement points.
- KTD2. Treat a present invalid value as fatal startup configuration, while preserving a genuinely absent value as the supported disabled state.
- KTD3. Use three secret-safe 401 payloads: instance credential unavailable, authentication required for missing/malformed input, and credential mismatch for valid-shaped nonmatching input.

### Sequencing

Introduce shared classification first, wire startup and request behavior to it with mutation-resistant tests, then update the existing operator documentation.

---

## Implementation Units

### U1. Share and enforce supervisor-token classification

- **Goal:** Give startup validation and request authentication one definition of a usable credential.
- **Requirements:** R1, R2, R5.
- **Dependencies:** None.
- **Files:** `src/lib/aiur/supervisor_token.ex`, `src/lib/aiur/env.ex`, `src/test/aiur/supervisor_token_test.exs`, `src/test/aiur/env_test.exs`.
- **Approach:** Classify missing, invalid, and usable values without exposing their contents; add invalid-present errors to the existing boot gate while leaving missing optional tokens to the disabled-integration notice.
- **Test scenarios:** Missing passes optional startup validation; empty, whitespace, 31-byte, padded, and illegal-character values each abort and name requirements without secret contents; 32-byte bearer-safe values pass.
- **Verification:** Tests call the real startup validator so deleting the invalid-token check or accepting empty values fails them.

### U2. Differentiate Supervisor Decision API failures

- **Goal:** Make request failures tell operators whether to repair the instance or the caller.
- **Requirements:** R3, R4, R5.
- **Dependencies:** U1.
- **Files:** `src/lib/aiur_web/supervisor_auth.ex`, `src/test/aiur_web/supervisor_auth_test.exs`.
- **Approach:** Branch first on shared configured-token status, then on presented-header parsing, then on constant-time comparison; render stable JSON bodies per cause.
- **Test scenarios:** Missing and invalid instance values use the unavailable payload; missing/malformed headers use the required payload; valid-shaped mismatches use the mismatch payload; the unavailable and mismatch bodies are explicitly unequal; valid authentication and rotation still work.
- **Verification:** Separate exact-body assertions ensure collapsing the 401 branches fails the suite.

### U3. Document credential generation and placement

- **Goal:** Give operators a copyable, correct recovery path.
- **Requirements:** R6.
- **Dependencies:** U1.
- **Files:** `src/README.md`, `website/docs-app/guide/executor-control-center.md`, `website/docs-app/reference/configuration.md`.
- **Approach:** Amend the existing Supervisor Decision API and environment-variable guidance with `openssl rand -base64 32`, the 32-byte minimum, supported bearer syntax, dotenv placement, precedence, and startup-failure behavior.
- **Test expectation:** None -- documentation mirrors behavior proven by U1 and U2.
- **Verification:** Each existing operator-facing mention remains correct and points to an actionable generation/placement recipe.

---

## Verification Contract

- Compile Elixir with warnings treated as errors.
- Format all touched Elixir files and confirm formatting is clean.
- Compute and run the deterministic affected-test set with `--max-cases 4`.
- Confirm focused test output names both startup-validation and SupervisorAuth test files.
- Do not substitute an agent-workspace `--test` launch for the scoped gate; this bug is fully exercised before the HTTP server starts and in direct Plug tests.

---

## Definition of Done

- R1-R6 are implemented with one shared token classifier and no secret leakage.
- Mutation-resistant tests prove empty values remain rejected and unavailable-vs-mismatch 401s cannot collapse.
- All existing operator docs that describe the credential are accurate.
- A draft PR against `main` matches the pushed diff and is self-reviewed before CI handoff.
