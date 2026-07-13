# DASH-019 — Authenticate Claude telemetry transport

**Kind:** executable

**Provenance:** planned in plan v1 after companion-boundary review

**Complexity:** 4 — Cross-process local telemetry trust boundary, lifecycle correlation, and resource controls against a pinned protocol

**Risk:** high

**Depends on:** BO-004

**Serializes with:** BO-003, BO-005, BO-016, BO-019, DASH-002, DASH-009, DASH-012, DASH-018, DASH-024, DASH-025, DASH-026 — application supervision tree; DASH-018 also shares Claude process lifecycle adapters

**Predecessor baseline:** resolved — `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f`

**External gate:** `GATE-CLAUDE-OTEL-PROTOCOL-AUTHORITY`, owned by a human with `aiur-claude` write authority and resolved before dispatch

**Requirements:** DREQ-019

**Researched at:** `9849f32963c2a65367bce565b3f5ede3777c218f`

**Suggested labels:** `complexity:4`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Claude processes owned by Aiur can deliver allowlisted structured telemetry through a local-only, producer-authenticated, resource-bounded receiver whose session correlation proves the current run, ticket, attempt, and worker generation.

## Context and evidence

Claude Code exposes official OpenTelemetry monitoring events, but loopback binding or possession of a Claude session ID does not authenticate a producer. Remote Control bypasses the existing headless `MessageHandler`, and an exporter may retry or reconnect. Transport security, launch authority, and trusted correlation form one cross-process boundary; DASH-010 separately maps accepted events into usage envelopes.
BO-004 supplies the repository-qualified ticket identity carried by trusted
correlation; same-number tickets in different repositories must never collide.

## Scope

- Resolve `GATE-CLAUDE-OTEL-PROTOCOL-AUTHORITY` with a reviewed capability matrix selecting either a secure Aiur-only launch/receiver path or an already-landed pinned compatible `aiur-claude` revision. If sibling work is missing, a human must authorize and land it through a separate sibling issue/PR before this ticket becomes pickable.
- Configure or embed one local-only telemetry receiver for Claude processes Aiur owns. Prefer an owner-only Unix-domain socket.
- If loopback TCP is required, mint an unguessable per-process capability, inject it only at owned process launch, authenticate it before payload decoding/logging, bind it to process/session generation, and revoke it on teardown.
- Maintain a trusted correlation registry established at process/session
  creation: producer generation, Claude session identity, current `run_id`,
  BO-004 repository-qualified ticket identity, attempt, backend/transport, and
  worker generation.
- Define resume/reconnect/replacement semantics. Session ID alone never proves producer or ticket ownership; stale producer/session generations are rejected.
- Accept only the required structured event family/version and allowlisted bounded attributes. Enforce body, attribute count/length, concurrent connection, and per-capability event-rate limits before expensive allocation.
- Suppress authenticated replay floods with a bounded in-memory guard while preserving deterministic event/request identity for DASH-009's later durable deduplication.
- Drop content, prompts/outputs, account/email/org, headers, credentials, environment, endpoint/capability values, and unrelated attributes before any log, error, quarantine, publication, or subscriber delivery.
- Expose health, source-version coverage, bounded rejection classes, and an internal authenticated event/correlation subscription for DASH-010. Do not emit usage envelopes.

## Non-goals

- Normalize tokens/cost, persist usage, calculate prices, fetch provider meters, render UI, or scrape interactive output.
- Treat loopback, process PID, repository path, session ID, browser state, or account identity as producer authentication.
- Mutate or test unlanded changes in `aiur-claude`, infer sibling authority, or relay arbitrary raw telemetry payloads into Aiur.

## Existing owner and reuse target

Extend Claude REPL/Remote Control process/session lifecycle and trusted launch configuration in Aiur. Reuse existing supervised local-server, permissioned-socket, capability, lifecycle teardown, version negotiation, and redaction patterns against the gate-pinned installed protocol. Any sibling implementation is separate, already landed work.

## Contract and invariants

- Every delivered event is tied to an authenticated current producer generation and trusted current run/ticket/attempt/session correlation.
- Local-only binding is necessary but not sufficient. Authentication happens before payload decode or logging.
- Capabilities are unguessable, per-process, short-lived, never logged/persisted into usage, and revoked on teardown/replacement.
- Resource limits apply before expensive decode. Reject/replay paths retain only bounded reason classes, never raw bodies.
- No third-party telemetry export is enabled by default; Aiur's receiver is content-free and least privilege.

## Refreshable implementation notes

- Refresh official Claude monitoring transport/version behavior and installed aiur-claude launch capabilities at pickup; pin sanitized fixtures in the gate receipt.
- Prefer a small generic receiver boundary plus Claude lifecycle adapter, without creating a general-purpose unauthenticated OTLP collector.
- Use injected clocks/capability minting and deterministic connection fixtures; never `Process.sleep` in lifecycle/rate tests.
- Reconcile the central application supervision tree with every declared
  serialization peer before either overlapping branch executes or merges.

## Acceptance and verification

### Agent gate

- Transport tests cover owner-only socket or authenticated loopback, correct/wrong/missing/stale capability, reconnect, resume, replacement generation, teardown revocation, session-ID spoof, and current ticket correlation.
- Resource tests cover oversize body/attributes, connection/rate exhaustion, malformed encoding, replay flood, slow/partial clients, and recovery without crashing owned Claude workers.
- Redaction/no-egress tests prove forbidden content/account/header/credential/path/capability attributes are removed before diagnostic or subscriber delivery.
- Compatibility fixtures prove Aiur works against the exact already-landed sibling revision named by the gate receipt; this worker changes only Aiur.

### At-merge gate

- Rebase on current Claude lifecycle and the gate-pinned installed protocol; pass Claude REPL/Remote Control, launch/teardown, local receiver, correlation, capability, redaction, packaging, compatibility, and full Aiur CI suites.

### Human/manual evidence

- From the Executor repository root, launch synthetic-safe Claude REPL and Remote Control processes through the real path, reconnect one session, replace another, and show accepted current correlation plus rejected stale/spoofed producer without exposing capability or content.

## Failure, security, migration, and accessibility cases

- Receiver unavailable, auth failure, malformed/oversized/rate-limited input, unsupported version, or stale correlation produces bounded health/rejection evidence and never forwards a raw event as trusted.
- Secrets and content are removed before logs, bug reports, quarantine, PubSub, or adapter delivery. Use synthetic values in all committed evidence.
- Version transport/configuration/correlation contracts. Older unsupported launch paths remain visibly uncovered, not heuristically accepted.
- No direct UI. Health and rejection classes are concise and suitable for downstream accessible diagnostics.

## Surfaces

- Reads: BO-004 repository-qualified tracker identity, owned Claude
  launch/session lifecycle, and official local telemetry transport.
- Writes: Aiur permissioned receiver or authenticated-loopback capability
  lifecycle, Claude process lifecycle adapters, trusted correlation registry,
  allowlisted event stream, health/rejections, fixtures/tests.
- Contracts: producer-authenticated bounded local telemetry and `GATE-CLAUDE-OTEL-PROTOCOL-AUTHORITY` receipt.
- Safety: authenticated bounded content-free transport and the application
  supervision tree.

## Sibling boundaries and open gates

DASH-010 alone converts delivered events into DASH-008 envelopes. BO-004 owns
repository-qualified identity. DASH-019 serializes with DASH-018 because both
write Claude process lifecycle adapters; this ticket owns telemetry transport,
not account-generation identity. Other declared peers share only the central
application supervision tree. This ticket is not dispatchable until its human
gate names an Aiur-only path or already-landed pinned compatible sibling
revision. Missing sibling capability requires a separate human-authorized
sibling issue/PR and cannot be implemented here or reclassified as unsupported
completion.
