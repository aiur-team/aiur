# DASH-010 — Account Claude Remote usage

**Kind:** executable

**Provenance:** planned in plan v1 after Claude transport and official telemetry review

**Complexity:** 4 — Local OTel ingestion and correlation for a transport bypassing current accounting

**Risk:** high

**Depends on:** DASH-008

**Serializes with:** Claude REPL/Remote Control lifecycle, local telemetry receiver, and aiur-claude adapter changes

**External gate:** sibling `aiur-claude` changes require explicit human repository/write authorization if the Aiur-side receiver cannot supply trusted correlation alone

**Requirements:** DREQ-010

**Researched at:** `b7c4e7c06b8c7011f306ce9efb0b9cd8fd8cbac5`

**Suggested labels:** `complexity:4`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Claude REPL/Remote Control requests produce required, locally ingested DASH-008 usage and provider-cost envelopes correlated to the correct run, ticket, attempt, and session, with no transcript, StatusLine, or `/usage` scraping.

## Context and evidence

Claude Code's official monitoring contract emits `claude_code.api_request` OpenTelemetry events containing structured session identity, event sequence or request identity, model, `cost_usd`, input/output/cache token fields, query source, and effort. Current Aiur HookTurn events carry no usage, and the Remote Control DisplayTailer bypasses the headless `MessageHandler` path. StatusLine is not a reliable cumulative token source and can conflict with user configuration. Explicit unsupported Remote Control coverage is not an accepted finished state.

## Scope

- Configure or embed a loopback/local-only OpenTelemetry ingestion path for the Claude processes Aiur owns. Prefer official `claude_code.api_request` events as the structured source; do not export operator telemetry to a third-party collector by default.
- Normalize each accepted event through DASH-008, mapping official session ID, event sequence/request ID, model, exact `cost_usd`, input/output/cache fields, query source, and effort into the versioned envelope with the correct delta/request scope.
- Correlate Claude session identity to trusted Aiur run, typed ticket, attempt, backend/transport, and worker generation at process/session creation. Reject or quarantine unattributable events; never guess from transcript text, display tail, account identity, or a reused session alone.
- Deduplicate OTel exporter retries/replay using the official event/request identity plus provider/session generation. Preserve exact decimal cost at decode and explicit coverage for unavailable optional fields.
- Cover Claude REPL and Remote Control lifecycle/resume/replacement. A resumed session retains the correct ticket only when the trusted correlation registry proves it; a replacement attempt or different run gets a new generation. Remote Control eligibility is subscription-only under the supported provider contract; API-key accounts must not be shown as Remote Control capable.
- Drop account, email, organization, raw content, prompt/output, environment, headers, credentials, endpoint secrets, and unrelated OTel attributes at the local receiver boundary. Store/publish only the normalized envelope.
- If trusted correlation or collector wiring requires `aiur-claude`, prepare the minimal sibling contract/change and stop at the external human authorization gate before mutating that repository.

## Non-goals

- Scrape `/usage`, terminal output, StatusLine, DisplayTailer prose, transcripts, browser storage, credentials, or Claude account pages.
- Fetch Claude subscription/API quota windows; DASH-013 owns account meters.
- Persist envelopes, calculate API-equivalent estimates, render UI, or make Remote Control accounting optional at final acceptance.

## Existing owner and reuse target

Extend Claude REPL/Remote Control process/session lifecycle and trusted session correlation in Aiur, use the official Claude Code OTel monitoring contract, and emit DASH-008 envelopes. Reuse a local telemetry receiver if one already exists; otherwise add the smallest supervised loopback receiver needed for this event family.

## Contract and invariants

- Official structured `claude_code.api_request` events are the preferred source. Transcript/TUI/StatusLine scraping is forbidden.
- Every emitted envelope has trusted run/ticket/attempt/session/generation correlation or an explicit rejected/unattributable coverage event; usage never crosses ticket boundaries.
- OTel exporter retry/replay is idempotent. Event receipt time cannot substitute for missing source identity.
- `cost_usd` is a provider-reported request estimate represented with exact decimal arithmetic; it is not billed spend or a subscription invoice allocation.
- The receiver is local-only by default and discards non-allowlisted attributes before persistence/publication.

## Refreshable implementation notes

- At pickup, refresh the official Claude Code monitoring-usage schema and installed Claude/aiur-claude versions. Keep fixtures by schema/source version because names may drift.
- Use `session.id` plus official event sequence/request ID where available. If source IDs are absent in an older version, mark that version unsupported until a reviewed deterministic dedup contract exists.
- Inject correlation through process/session ownership or opaque local resource attributes; do not encode repository paths, account identity, or secrets.

## Acceptance and verification

### Agent gate

- Synthetic OTel fixtures cover REPL and Remote Control requests, exporter retry/replay, session resume, new attempt/generation, model/effort changes, cache tokens, exact decimal cost, missing optional fields, and unattributable events.
- Integration tests prove HookTurn/DisplayTailer paths no longer create an accounting gap and that transcript/StatusLine output cannot affect totals.
- Security tests prove local bind/default no-egress behavior and allowlist removal of account/email/org/content/header/credential/path attributes.

### At-merge gate

- Rebase on DASH-008 and current Claude lifecycle code; pass Claude REPL/Remote Control, OTel receiver, correlation, normalizer, redaction, packaging, and full CI suites. If sibling work was authorized, pass both repositories' protocol compatibility gates.

### Human/manual evidence

- From the operator repository root, run one synthetic-safe Claude REPL and one Remote Control request through the real process path and show attributed token/cost envelopes and duplicate suppression after reconnect, without displaying real prompts or account identity.

## Failure, security, migration, and accessibility cases

- Receiver unavailable, malformed OTel, missing trusted correlation, or unsupported Claude version produces visible coverage failure and never zero/fabricated usage.
- Local ingestion is least-privilege and content-free; redact before logs, bug reports, ledger, PubSub, and UI.
- Version OTel source adapters and correlation state. Legacy runs remain explicitly uncovered rather than retroactively guessed.
- No direct UI; coverage failures use stable human-readable transport/source classes.

## Surfaces

- Reads: official Claude Code `claude_code.api_request` OTel events; trusted Claude session/run/ticket/attempt registry.
- Writes: local receiver/configuration, Claude OTel adapter, correlation/dedup state, DASH-008 envelopes, fixtures/tests.
- Contracts: required Claude REPL/Remote Control accounting coverage and external aiur-claude gate.

## Sibling boundaries and open gates

DASH-008 owns the envelope, DASH-009 owns persistence, DASH-011 owns cost estimates/grouping, and DASH-013 owns account meters. Lack of sibling-repository authority blocks only the required external change; it does not authorize an “unsupported is done” shortcut.
