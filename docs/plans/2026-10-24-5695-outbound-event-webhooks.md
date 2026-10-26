---
title: Outbound Event Webhooks - Plan
type: feat
date: 2026-10-24
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Outbound Event Webhooks - Plan

## Goal Capsule

Ship a push-only, versioned outbound event surface for ticket lifecycle, progress, usage, spend-cap, and cancellation outcomes.
The implementation must give a TypeScript consumer independent schemas and a safe webhook receiver, preserve ticket/job correlation, and retry delivery without making the consumer poll Aiur.
The issue body and the CODEOWNER acceptance comment on issue #5695 are authoritative; the existing message-bus contract and Standard Webhooks specification constrain implementation details.
Work stops short of a ready PR until blocker tickets #5693 and #5696 have supplied their spend-cap and cancellation contracts and producer seams.

---

## Product Contract

### Summary

Aiur will deliver five event families to a configured HTTPS webhook endpoint.
Each request carries one versioned JSON event, Standard Webhooks HMAC headers, and a stable event identifier.
The consumer can subscribe globally or narrow the configured subscription to one ticket or job identifier.

### Actors and flows

- A1. The Aiur operator configures an outbound endpoint, a host-held signing secret, and an optional subject identifier.
- A2. The external TypeScript consumer installs the independently packed `@aiur/contracts` package plus the Standard Webhooks verifier, verifies the raw request body before parsing it, validates or types the event, and deduplicates by `(instance, id)` through `webhook-id`.
- F1. A lifecycle, progress, usage, spend-cap, or cancel-result producer commits its owning state and publishes a bounded internal event; the exporter normalizes and journals the external event before webhook delivery.
- F2. A transport failure, timeout, 408, 429, or 5xx response retains the delivery cursor and retries the same event with capped exponential backoff and jitter. A 2xx response advances the cursor; any other 4xx response raises an operator attention and advances past that permanent failure.
- F3. A configured subject filter advances past non-matching events without sending them and sends matching events whose ticket or job identifier equals the filter.

### Requirements

#### Push delivery and authentication

- R1. An enabled outbound subscription delivers events through HTTP POST without requiring the consumer to poll an Aiur endpoint.
- R2. Every delivery uses the Standard Webhooks symmetric signature shape: `webhook-id`, `webhook-timestamp`, and `webhook-signature`, with HMAC-SHA256 over the exact `id.timestamp.raw_body` bytes.
- R3. The TypeScript receiver rejects missing or malformed headers, a non-matching signature, timestamps outside a five-minute past-or-future tolerance, and a duplicate `webhook-id` before returning parsed data.
- R4. Delivery is at least once for retryable outcomes after journal admission: transport failures, timeouts, 408, 429, and 5xx responses retain the durable cursor and retry with capped exponential backoff and jitter. A 2xx response acknowledges the event; any other 4xx response raises an operator attention and advances past the permanent failure so one poison record cannot wedge the queue.

#### Event contracts and correlation

- R5. The independently installable `@aiur/contracts` package contains a draft-2020-12 schema, golden fixture, and generated TypeScript type for each v1 event family: ticket lifecycle, ticket progress, ticket usage, spend-cap reached, and cancel result.
- R6. Every event is produced through `Aiur.Events.Envelope.to_external/2` and includes the canonical `v`, `instance`, `seq`, `id`, `topic`, `class`, timestamps, `source`, typed `refs`, typed `attrs`, `payload_version`, and reserved `anchor`; event-family schemas constrain the shared envelope rather than defining a second one.
- R7. Actual Elixir-produced event maps validate against the same schemas shipped to TypeScript consumers.
- R8. Progress events carry the observed percentage and source facts from the trusted `TicketObservation`; usage events carry the durable ledger position, generation, and canonical delta rather than an asynchronously projected total.
- R9. Spend-cap delivery adopts the event contract owned by issue #5693, while cancel-result delivery wraps the response contract owned by issue #5696; this ticket never defines competing copies.

#### Configuration and operations

- R10. Outbound export is disabled by default and starts only when `events.export.enabled` is true, a valid HTTPS endpoint without userinfo or fragments is configured, and `AIUR_OUTBOUND_WEBHOOK_SECRET` is a valid `whsec_` secret of the required decoded length.
- R11. `events.export.subject_id` is optional; when present, only events whose `refs.ticket` or `refs.job_id` equals it are delivered.
- R12. Secret material is never written to config, event bodies, logs, alerts, or agent environments.
- R13. Operator documentation explains configuration, secret generation, signatures, retry/dedup behavior, event schemas, and the one-subject filter.

### Acceptance examples

- AE1. Given a lifecycle transition for ticket `5695`, when export is enabled without a subject filter, the receiver gets one schema-valid canonical event with topic `ticket.5695.lifecycle.changed`, `refs.ticket: "5695"`, and a valid signature.
- AE2. Given a subscription filtered to `5695`, when events for `5694` and `5695` are journaled, only `5695` is posted and both journal positions are acknowledged locally.
- AE3. Given the exact golden body but a changed byte, a missing signature header, a timestamp more than five minutes old, or a previously accepted `webhook-id`, the TypeScript receiver throws before returning parsed data.
- AE4. Given a 503 followed by a 204, the delivery handler posts the same event ID and body twice and advances its cursor only after the 204.
- AE5. Given a usage ledger append for a joinable ticket identity, the emitted usage event names that ticket and its payload validates against the usage-event schema.

### Scope boundaries

- v1 provides configured signed webhooks, which satisfies the ticket's “webhook or SSE” transport choice; SSE and a runtime subscription-management API are out of scope.
- v1 supports one configured endpoint and one optional subject filter. Multiple independently keyed endpoints require per-endpoint cursor and secret lifecycle work and are deferred.
- The exporter carries bounded structured facts, not issue bodies, comments, prompts, logs, or arbitrary event-bus payloads.
- Producer stores remain authoritative. The export journal is a delivery queue, not a replacement lifecycle or accounting database.

### Dependencies

- Issue #5693 owns the spend-cap read, cap-reached event contract, and distinct `budget_exhausted` outcome.
- Issue #5696 owns the bounded process-exit confirmation and cancel-result payload contract.
- `Aiur.Events.DurableConsumer`, `Aiur.Events.Journal`, `Aiur.CurrentRunMembership`, `Aiur.UsageLedger`, and `@aiur/contracts` already provide the required persistence, source, and packaging foundations.

### Sources

- `src/lib/aiur/events/durable_consumer.ex` and `src/lib/aiur/events/journal.ex` define the existing at-least-once consumer and append/replay primitives.
- `src/lib/aiur/current_run_membership/event.ex` and `src/lib/aiur/usage_ledger/store.ex` are the persist-before-notify lifecycle and usage seams.
- `src/lib/aiur/ticket_observation.ex` is the safe progress attribute boundary.
- `docs/research/aiur-mobile-and-platform/contracts/events-and-replay.md` at historical commit `b43dab779` records the single-writer export sequence and allowlisted external-envelope rationale.
- [Standard Webhooks specification](https://github.com/standard-webhooks/standard-webhooks/blob/main/spec/standard-webhooks.md) defines the signed `id.timestamp.raw_body` input, headers, replay tolerance, and constant-time comparison requirement.

---

## Planning Contract

### Key technical decisions

- KTD1. Implement webhook push only for v1. The issue explicitly permits webhook or SSE, and webhook delivery is the transport required by the signature acceptance criteria.
- KTD2. Follow Standard Webhooks rather than inventing Aiur headers. Use a base64 `whsec_` host secret, standard header names, a `v1,<base64-hmac>` signature, exact raw bytes, and a five-minute replay window.
- KTD3. Publish lifecycle and usage changes into `Aiur.Events.Exchange` only after their owning stores commit. Progress already crosses that boundary; spend-cap and cancel-result producers will adopt the same persist-then-publish rule.
- KTD4. A single export-journal writer assigns a dense delivery sequence in observed order. `Aiur.Events.IdGenerator` IDs remain unique identifiers, not ordering cursors.
- KTD5. Use `Aiur.Events.DurableConsumer` for webhook delivery. Retry transport failures, timeouts, 408, 429, and 5xx responses with capped exponential backoff and jitter. Treat other 4xx responses as permanent: raise an operator attention and advance the cursor so a poison event cannot block later delivery.
- KTD6. Keep `@aiur/contracts` free of custom cryptography. Ship an executable TypeScript receiver example and tests using the official `standardwebhooks` package, including an ID-deduplication seam the application must back with storage in production.
- KTD7. Event schemas constrain the one external envelope owned by `Aiur.Events.Envelope.to_external/2` and remain five separately addressable schema files and fixtures. Progress and usage expose bounded refresh attributes; spend-cap and cancel-result validation adopts the producer contracts without copying their full payloads into the signal.
- KTD8. The optional `subject_id` filter matches either `refs.ticket` or `refs.job_id` exactly. Filtering occurs in the delivery handler so the journal remains a complete ordered record and changing the filter never changes producer behavior.

### High-level technical design

```text
membership store ─┐
progress bus ─────┼─> Exchange allowlisted topics ─> ExportJournal ─> DurableConsumer ─> signed HTTP POST
usage ledger ─────┤                                  seq + raw body       cursor            2xx advances
cap/cancel stores ┘

@aiur/contracts: five event schemas + fixtures + generated types + tested Standard Webhooks receiver example
```

`ExportJournal` subscribes before replay, normalizes only the five registered topic families, assigns `seq`, persists the JSON-safe event, and notifies live consumers.
Its source adapter supports replay after a cursor and reset when bounded retention has removed the requested successor.
The webhook handler applies the subject filter, JSON-encodes once, signs those exact bytes for each attempt, and sends with retries disabled at the HTTP library layer so cursor semantics remain explicit.

### Implementation constraints

- Add new event-export code in small modules under `src/lib/aiur/events/outbound/`; do not grow an oversized file.
- Do not expose arbitrary Exchange payload keys. Each normalizer constructs its event from an explicit allowlist.
- A malformed or unattributed producer event is dropped with bounded diagnostics; it never becomes a schema-invalid webhook.
- The signing secret is read by daemon code only and must be scrubbed from agent children through the existing secret-name machinery.
- The package's generated source and fixture type probe must include all five event types.
- Every new behavior test must fail when its production hunk is reverted in a clean isolated worktree.

### System-wide impact

- Configuration gains an embedded `events.export` block and one operator secret environment variable; templates, generated `.env.example`, startup checks, config docs, and the operator guide must move together.
- Application supervision gains the export journal and durable delivery consumer after the Exchange and producer stores they consume.
- Lifecycle and usage stores gain best-effort Exchange publication after persistence; publication failure must never roll back or crash the authoritative write.
- `@aiur/contracts` becomes packable as an independent dependency and retains type/schema-only runtime exports; its executable receiver example uses the official Standard Webhooks dependency instead of maintaining custom cryptography.
- The webhook client disables redirects so a configured endpoint cannot redirect the signed body and secret-derived proof to another origin.
- Webhook delivery carries spend-cap state but no cost amounts. HTTPS remains mandatory, and logs contain only event IDs, status classes, and endpoint origin-safe metadata.

### Risks and mitigations

- A slow or unavailable endpoint could grow the local queue. Never evict pending records: compact only the delivered tail, enforce a configured storage ceiling at admission, raise a needs-attention alert when admission stops, and keep HTTP work out of the exporter process.
- Producer-to-exporter delivery is live after the producer commit. On exporter restart, reconcile durable lifecycle and usage heads or record a visible source gap rather than claiming complete history.
- Cross-ticket work can create schema and generated-file conflicts. Keep wrapper files additive, integrate blocker refs only after explicit `unblocked`, and regenerate once against the combined schema set.
- Signing parsed and reserialized JSON would break verification. Encode once to a binary and pass that same binary to both signer and `Req` body.
- A subscription filter can silently exclude expected events if misconfigured. Validate it as a non-empty identifier and document exact matching.

---

## Implementation Units

### U1. Define consumer event and signature contracts

- **Requirements:** R2, R3, R5-R9
- **Files:** `packages/aiur-contracts/package.json`, `packages/aiur-contracts/schemas/*.json`, `packages/aiur-contracts/fixtures/*.json`, `packages/aiur-contracts/src/`, `packages/aiur-contracts/examples/`, `packages/aiur-contracts/scripts/`, `packages/aiur-contracts/test/`, `packages/aiur-contracts/README.md`
- **Approach:** Add or adopt five v1 event schemas and fixtures, export a generated event union, make the package independently packable, and add a Standard Webhooks receiver example backed by the official library. Add a fixed cross-language signature vector and negative tests for missing, wrong, stale, future, duplicate-ID, and body-mismatched deliveries.
- **Test scenarios:** Every fixture validates only against its intended schema; catalog-declared references and attributes cannot be omitted; unallowlisted envelope fields are rejected; the receiver accepts the fixed valid vector once and rejects every tampered or replayed variant; an isolated consumer installs the packed tarball and imports its types and schemas.
- **Verification:** `npm --prefix packages/aiur-contracts run generate`, `npm --prefix packages/aiur-contracts run check`, `npm --prefix packages/aiur-contracts test`, and the package's pack/install smoke test all pass.

### U2. Add configuration, secret validation, and supervision

- **Requirements:** R10-R12
- **Files:** `src/lib/aiur/config/schema/events.ex`, `src/lib/aiur/config/`, `src/lib/aiur/env/schema.ex`, `src/lib/aiur/application/startup_checks.ex`, `src/lib/aiur/application/children.ex`, `.aiur/examples/config.example`, `.env.example`, and focused config/startup/children tests
- **Approach:** Add the disabled-by-default export block, require HTTPS and a valid endpoint/subject shape at config parse time, require a valid `AIUR_OUTBOUND_WEBHOOK_SECRET` only when enabled, and supervise export children only for a valid enabled configuration.
- **Test scenarios:** Defaults start no children; enabled export without URL or secret fails startup without exposing values; HTTP URLs, userinfo, fragments, and malformed `whsec_` values fail; an optional valid subject starts both children with deterministic paths.
- **Verification:** Focused config, env, startup-check, and child-list tests pass and `.env.example` regeneration is clean.

### U3. Publish and normalize the three available event families

- **Requirements:** R6-R8
- **Files:** `src/lib/aiur/current_run_membership/`, `src/lib/aiur/usage_ledger/store.ex`, `src/lib/aiur/events/envelope.ex`, `src/lib/aiur/events/outbound/event.ex`, and mirror tests
- **Approach:** Emit lifecycle and usage topics only after durable acceptance; map progress from the trusted observation attached by `Publisher`; pass validated producer facts through `Aiur.Events.Envelope.to_external/2` with catalog-owned reference and attribute allowlists.
- **Test scenarios:** Persist failure publishes nothing; accepted lifecycle and usage writes publish once; duplicate usage writes do not publish again; unattributed progress is dropped; all constructed events validate against package schemas.
- **Verification:** Changed-source mirrors and direct publisher/ledger/membership callers pass with `--max-cases 4`.

### U4. Persist and deliver the outbound stream

- **Requirements:** R1-R4, R11
- **Files:** `src/lib/aiur/events/outbound/export_journal.ex`, `src/lib/aiur/events/outbound/source.ex`, `src/lib/aiur/events/outbound/webhook.ex`, `src/lib/aiur/config/paths.ex`, and focused tests
- **Approach:** Subscribe to allowlisted topics, append normalized records with dense sequence numbers, expose replay/live source callbacks, and deliver through `DurableConsumer`. Sign the exact encoded body for every attempt, retry transport failures, timeouts, 408, 429, and 5xx responses with capped exponential backoff and jitter, and skip other 4xx responses only after raising an operator attention.
- **Test scenarios:** Replay precedes live delivery without loss; concurrent internal IDs cannot reorder the dense sequence; 503/timeout retry the same record with capped backoff and jitter; 204 advances; a permanent 4xx alerts, advances, and permits the next record; redirects are rejected; filtering sends only one ID; compaction removes only acknowledged or explicitly discarded records; a full queue refuses admission and alerts without claiming delivery.
- **Verification:** Export-journal, source, and webhook handler tests pass, including a local test HTTP adapter that validates headers against the fixed TypeScript-compatible vector.

### U5. Integrate spend-cap and cancel-result producers

- **Requirements:** R5, R7, R9
- **Dependencies:** issues #5693 and #5696 must explicitly emit `unblocked` with validated refs.
- **Files:** blocker-provided producer and schema paths plus additive event-wrapper schema, fixture, normalizer, and integration tests
- **Approach:** Fetch and inspect each validated blocker ref, adopt #5693's exact event contract and #5696's response contract, publish after each durable state transition, remove any provisional integration points, and regenerate the combined TypeScript union.
- **Test scenarios:** `budget_exhausted` emits one schema-valid spend-cap event; confirmed and timed-out cancel outcomes emit truthfully distinct schema-valid results; neither producer emits before its owning result is committed.
- **Verification:** Blocker-owned focused tests and this ticket's cross-contract emission tests pass together.

### U6. Document and hand off the feature

- **Requirements:** R13
- **Files:** `website/docs-app/reference/configuration.md`, a relevant page under `website/docs-app/guide/`, `website/docs-app/.vitepress/config.ts` if a new page is needed, `AGENTS.md`, and PR evidence
- **Approach:** Document enablement, secret generation, subject filtering, schema imports, raw-body verification, retries/deduplication, and the five event types. Record any real endpoint smoke test as a post-deploy check rather than claiming it ran in the issue workspace.
- **Test scenarios:** Config and env documentation generators/checkers pass; schema and header examples match fixtures and code.
- **Verification:** Docs guards, lint, structural checks, PR-body checks, and pre-handoff guards pass.

---

## Verification Contract

- Compile and format from `src/`: `mise exec -- mix compile --warnings-as-errors` and `mise exec -- mix format --check-formatted` after formatting changed files.
- Compute and run the scoped Elixir set with `mise exec -- mix aiur.affected_tests`; execute each selected test command with `mix test --max-cases 4`.
- Run the package gates: `npm --prefix packages/aiur-contracts ci`, `npm --prefix packages/aiur-contracts run generate`, `npm --prefix packages/aiur-contracts run check`, and `npm --prefix packages/aiur-contracts test`.
- For each added test, revert only its guarded production hunk in an isolated worktree, confirm the test fails, restore it, and confirm it passes; record exact commands and outcomes in the PR body.
- Before push, run `mise exec -- mix lint`, `python3 scripts/check-bare-assert-receive.py`, and `mise exec -- python3 scripts/check-pr-structure.py --base "$(git -C "$AIUR_AGENT_WORKSPACE" rev-parse "origin/$AIUR_BASE_BRANCH")"`.
- Run `aiur pre-pr` before and after PR creation, refresh the tested head/base evidence, and run `scripts/pre-handoff-guards` with fresh PR metadata.
- CI remains authoritative for the full required-check set. A real external receiver smoke test is manual-only and must be recorded as `Post-deploy check:` in the PR body.

---

## Definition of Done

- All thirteen requirements and five acceptance examples are implemented without a stub.
- Five event schemas, fixtures, generated TypeScript types, and an executable receiver example ship through the independently packable `@aiur/contracts` package.
- Actual lifecycle, progress, usage, spend-cap, and cancel-result emissions validate against their shipped schemas.
- Signed delivery rejects replayed and tampered requests, retries retryable failures with capped exponential backoff and jitter, skips permanent 4xx poison records with an operator attention, and supports one exact ticket/job filter.
- Configuration, environment declarations, templates, operator docs, and supervision agree on disabled and enabled behavior.
- Blocker-owned APIs are consumed from their validated refs without duplicating their contracts.
- New tests demonstrate fail-without-production-change behavior in an isolated worktree.
- No abandoned experiments, temporary compatibility stubs, secrets, or unrelated changes remain in the diff.
- The draft PR is self-reviewed, ready for review, and handed to CI with current test evidence.
