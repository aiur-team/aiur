# DASH-010 — Account Claude Remote usage

**Kind:** executable

**Provenance:** planned in plan v1 after Claude transport and official telemetry review

**Complexity:** 4 — Local OTel ingestion and correlation for a transport bypassing current accounting

**Risk:** high

**Depends on:** DASH-008

**Serializes with:** Claude REPL/Remote Control lifecycle, local telemetry receiver, and aiur-claude adapter changes

**External gates:** `GATE-OCC-PREDECESSOR-BASELINE`; and
`GATE-CLAUDE-OTEL-PROTOCOL-AUTHORITY`, owned by a human with `aiur-claude`
write authority and resolved before implementation as either an evidenced
Aiur-only launch/receiver path or an explicitly authorized compatible sibling
protocol revision

**Requirements:** DREQ-010

**Researched at:** `1e0cfba31c0e6cc4fea14a25e8b4344ef1d6d67d`

**Suggested labels:** `complexity:4`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Claude REPL/Remote Control requests produce required, locally ingested DASH-008 usage and provider-cost envelopes correlated to the correct run, ticket, attempt, and session, with no transcript, StatusLine, or `/usage` scraping.

## Context and evidence

Claude Code's official monitoring contract emits `claude_code.api_request` OpenTelemetry events containing structured session identity, event sequence or request identity, model, `cost_usd`, input/output/cache token fields, query source, and effort. Current Aiur HookTurn events carry no usage, and the Remote Control DisplayTailer bypasses the headless `MessageHandler` path. StatusLine is not a reliable cumulative token source and can conflict with user configuration. Explicit unsupported Remote Control coverage is not an accepted finished state.

## Scope

- Configure or embed a local-only OpenTelemetry ingestion path for the Claude processes Aiur owns. Prefer an owner-only Unix-domain socket. If loopback TCP is required, mint an unguessable per-process capability, inject it only into the owned Claude launch, authenticate it before payload decoding/logging, bind it to worker/session generation, and revoke it on teardown. Prefer official `claude_code.api_request` events as the structured source; do not export Executor telemetry to a third-party collector by default.
- Normalize each accepted event through DASH-008, mapping official session ID, event sequence/request ID, model, exact `cost_usd`, input/output/cache fields, query source, and effort into the versioned envelope with the correct delta/request scope.
- Correlate the authenticated process capability/socket peer and Claude session identity to trusted Aiur run, typed ticket, attempt, backend/transport, and worker generation at process/session creation. Session ID alone is not producer authentication. Reject unattributable or stale-generation events without retaining their raw payload; never guess from transcript text, display tail, account identity, or a reused session alone.
- Derive a deterministic envelope idempotency identity from the official event/request identity plus provider/session generation. The receiver may use a bounded in-memory replay guard for abuse control, but DASH-009 remains the sole durable deduplication authority. Preserve exact decimal cost at decode and explicit coverage for unavailable optional fields.
- Cover Claude REPL and Remote Control lifecycle/resume/replacement. A resumed session retains the correct ticket only when the trusted correlation registry proves it; a replacement attempt or different run gets a new generation. Remote Control eligibility is subscription-only under the supported provider contract; API-key accounts must not be shown as Remote Control capable.
- Enforce bounded request/body size, attribute count/length, concurrent connections and per-capability event rate before expensive decode or allocation. Suppress duplicate/replay floods by authenticated source identity and never log rejected raw bodies or capabilities.
- Drop account, email, organization, raw content, prompt/output, environment, headers, credentials, endpoint secrets, and unrelated OTel attributes before any log, error, quarantine, persistence or publication. Store/publish only the normalized envelope and bounded rejection classes.
- Resolve `GATE-CLAUDE-OTEL-PROTOCOL-AUTHORITY` before implementation dispatch. If Aiur can securely configure the owned Claude process directly, record reviewed fixtures and mark the gate satisfied by the Aiur-only path. Otherwise a human must authorize the minimal versioned `aiur-claude` launch/configuration contract and compatible revision; this ticket never mutates the sibling implicitly.

## Non-goals

- Scrape `/usage`, terminal output, StatusLine, DisplayTailer prose, transcripts, browser storage, credentials, or Claude account pages.
- Fetch Claude subscription/API quota windows; DASH-013 owns account meters.
- Persist envelopes, calculate API-equivalent estimates, render UI, or make Remote Control accounting optional at final acceptance.
- Treat loopback binding or possession of a session ID as authentication, accept unbounded OTLP payloads/rates, or retain rejected raw telemetry for diagnosis.

## Existing owner and reuse target

Extend Claude REPL/Remote Control process/session lifecycle and trusted session correlation in Aiur, use the official Claude Code OTel monitoring contract, and emit DASH-008 envelopes. Reuse a secure local telemetry receiver if one already exists; otherwise add the smallest supervised permissioned-socket or authenticated-loopback receiver needed for this event family.

## Contract and invariants

- Official structured `claude_code.api_request` events are the preferred source. Transcript/TUI/StatusLine scraping is forbidden.
- Every emitted envelope has an authenticated producer/process generation plus trusted run/ticket/attempt/session correlation or an explicit bounded rejected/unattributable coverage event; usage never crosses ticket boundaries.
- OTel exporter retry/replay carries deterministic idempotency identity; DASH-009 makes its durable accounting effect idempotent. Event receipt time cannot substitute for missing source identity.
- `cost_usd` is a provider-reported request estimate represented with exact decimal arithmetic; it is not billed spend or a subscription invoice allocation.
- The receiver is local-only, producer-authenticated, bounded and rate-limited by default. It discards non-allowlisted attributes before any diagnostic, persistence or publication.

## Refreshable implementation notes

- At pickup, refresh the official Claude Code monitoring-usage schema and installed Claude/aiur-claude versions. Keep fixtures by schema/source version because names may drift.
- Use `session.id` plus official event sequence/request ID where available. If source IDs are absent in an older version, mark that version unsupported until a reviewed deterministic dedup contract exists.
- Inject correlation through process/session ownership and an opaque authenticated local capability or permissioned socket; do not encode repository paths or account identity. Keep capabilities out of events, logs and persisted envelopes.

## Acceptance and verification

### Agent gate

- Synthetic OTel fixtures cover REPL and Remote Control requests, exporter retry/replay, session resume, new attempt/generation, model/effort changes, cache tokens, exact decimal cost, missing optional fields, and unattributable events.
- Integration tests prove HookTurn/DisplayTailer paths no longer create an accounting gap and that transcript/StatusLine output cannot affect totals.
- Security tests prove owner-only socket permissions or missing/wrong/stale capability rejection, session-ID spoof resistance, capability revocation on generation change, local bind/default no-egress behavior, bounded body/attribute/connection/rate handling, replay-flood suppression, and allowlist removal of account/email/org/content/header/credential/path attributes before logging.

### At-merge gate

- Rebase on DASH-008 and current Claude lifecycle code; pass Claude REPL/Remote Control, OTel receiver, correlation, normalizer, redaction, packaging, and full CI suites. If sibling work was authorized, pass both repositories' protocol compatibility gates.

### Human/manual evidence

- From the Executor repository root, run one synthetic-safe Claude REPL and one Remote Control request through the real process path and show attributed token/cost envelopes with stable idempotency identity after reconnect, without displaying real prompts or account identity. If DASH-009 is present, also show the replay adds no usage twice.

## Failure, security, migration, and accessibility cases

- Receiver unavailable, malformed/oversized/rate-limited OTel, failed producer authentication, missing trusted correlation, replay flood, or unsupported Claude version produces bounded visible coverage failure and never zero/fabricated usage.
- Local ingestion is least-privilege and content-free; redact before logs, bug reports, ledger, PubSub, and UI.
- Version OTel source adapters and correlation state. Legacy runs remain explicitly uncovered rather than retroactively guessed.
- No direct UI; coverage failures use stable human-readable transport/source classes.

## Surfaces

- Reads: official Claude Code `claude_code.api_request` OTel events; trusted Claude session/run/ticket/attempt registry.
- Writes: authenticated local receiver/configuration, capability/socket lifecycle, Claude OTel adapter, correlation/bounded replay-guard state, DASH-008 envelopes, fixtures/tests.
- Contracts: required Claude REPL/Remote Control accounting coverage and `GATE-CLAUDE-OTEL-PROTOCOL-AUTHORITY` receipt.

## Sibling boundaries and open gates

DASH-008 owns the envelope, DASH-009 owns persistence, DASH-011 owns cost
estimates/grouping, and DASH-013 owns account meters. This ticket is not
dispatchable until `GATE-CLAUDE-OTEL-PROTOCOL-AUTHORITY` has an Aiur-only or
authorized-sibling resolution receipt. Lack of sibling-repository authority
does not authorize an “unsupported is done” shortcut.
