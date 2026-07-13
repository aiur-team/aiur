# DASH-013 — Normalize Claude account meters

**Kind:** executable

**Provenance:** planned in plan v1 after provider-meter adversarial review

**Complexity:** 4 — Claude subscription/API integration with possible sibling protocol gate

**Risk:** high

**Depends on:** DASH-012

**Serializes with:** Claude account/auth protocol and aiur-claude adapter changes

**External gate:** sibling `aiur-claude` or upstream protocol changes require explicit human repository/write authorization when no existing structured Claude meter source is available

**Requirements:** DREQ-013

**Researched at:** `b7c4e7c06b8c7011f306ce9efb0b9cd8fd8cbac5`

**Suggested labels:** `complexity:4`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Aiur exposes Claude subscription and API-key account facts through DASH-012's provider-meter contract, including real supported session/weekly or API controls, plan tier, freshness, account generation, and honest partial/error states without scraping interactive output.

## Context and evidence

The refreshed prototype shows Claude session and weekly meters and the operator requires both subscription and API-token modes. Current headless/Remote Control paths expose request usage/cost but do not yet establish a complete structured account-quota projection. This ticket is a required adapter outcome: when the installed protocol lacks a needed structured source, the missing aiur-claude/upstream seam becomes an explicit human-authorized external gate rather than an “unsupported is finished” shortcut.

## Scope

- At pickup, characterize the installed Claude CLI, Claude Code OTel, and aiur-claude structured account/rate-limit capabilities using official schemas and sanitized fixtures. Select only a structured supported source; interactive `/usage`, TUI, transcript, StatusLine, browser, and credential scraping are forbidden.
- Implement Claude normalization into DASH-012 `ProviderMeterSnapshot`: provider/backend, opaque account generation, auth mode, actual plan/tier and source, snapshot/patch/tombstone semantics, named limit IDs/windows, used/remaining facts, duration/reset, API credit/rate/spend controls when reported, observed/ingested time, freshness/expiry, and health.
- Support subscription and API-key modes without assuming they expose the same facts. Renderable session/weekly windows require actual structured values; API mode reports only real rate/credit/spend controls.
- Preserve sparse updates, per-window last-known-good state, full-snapshot removals, and account-generation isolation exactly as DASH-012 defines. A Claude auth/session change starts a new opaque generation without persisting raw account identity.
- If the structured protocol cannot expose required meter facts from Aiur alone, define and implement the minimal typed aiur-claude adapter/protocol after explicit human authorization. Include version negotiation and synthetic fixtures in both repositories.
- Expose partial/temporarily unavailable/error coverage during protocol failure, but final ticket acceptance requires the supported Claude account modes available in the operator's configured integration; “all Claude meters unsupported” is not completion.
- Redact email, account/organization/workspace IDs, credentials, API/OAuth material, raw responses, headers, endpoint/capability URLs, and unrelated attributes at the adapter boundary.

## Non-goals

- Ingest request token/cost usage (DASH-010), calculate ticket/build spend, call browser/private endpoints, scrape interactive output, render UI, or redesign Claude authentication.
- Fabricate session/weekly bars or API controls from token totals, local timers, plan-name guesses, or scheduling availability.
- Mutate a sibling repository without the explicit external authority gate.

## Existing owner and reuse target

Implement against DASH-012's provider-meter contract and the current Claude/aiur-claude account/auth lifecycle. Reuse official structured monitoring/protocol sources, version negotiation, local-only transport, and trusted generation context.

## Contract and invariants

- Claude and Codex use the same snapshot/patch/tombstone/freshness contract but never share provider/account-generation keys.
- A displayed window/control has structured source evidence, source version, observation time, and coverage. Missing support is never zero usage or unlimited quota.
- Subscription and API-key presentations are capability-driven. Plan tier is actual structured/configured account fact with provenance, not inferred from usage price.
- Sparse updates cannot erase unrelated facts; full snapshots and explicit tombstones can. Authentication change cannot inherit prior account last-known-good state.
- External protocol work is a named gate with human owner; it cannot be silently dropped or converted into permanent unsupported acceptance.

## Refreshable implementation notes

- Refresh official Claude monitoring and installed aiur-claude schemas at pickup. Keep a source-capability matrix in the ticket workpad and fixtures, then implement the selected reviewed path.
- Prefer adding a narrow typed method/event to aiur-claude over relaying arbitrary raw account payloads.
- Keep provider polling/subscription daemon-owned and shared; no browser-specific fetch or credential access.

## Acceptance and verification

### Agent gate

- Fixtures cover Claude subscription and API-key modes, multiple windows/controls, full/patch/tombstone, sparse updates, account-generation changes, reset/freshness/expiry, partial/error/recovery, protocol-version drift, and provider isolation.
- Cross-adapter tests prove no Claude update overwrites Codex and no OTel request-usage event is mistaken for an account meter.
- Security tests prove interactive/raw/account/credential/capability data cannot enter normalized snapshots or logs.

### At-merge gate

- Rebase on DASH-012 and current Claude integration. Pass provider-meter, Claude lifecycle/protocol, version compatibility, redaction, packaging, and full CI suites; when sibling work is authorized, both repositories' contract tests must pass at pinned compatible revisions.

### Human/manual evidence

- With privacy-safe subscription and API-key accounts or sanctioned synthetic provider fixtures, verify each mode shows only real supported Claude facts, plan tier and resets are correct, account change does not merge data, and unsupported facts are not fabricated.

## Failure, security, migration, and accessibility cases

- Protocol/fetch/auth failure retains only generation-safe last-known-good facts with visible health/freshness; a new generation starts empty until real data arrives.
- Never persist/log account/email/org/workspace identity, credentials, raw responses, headers, environment values, endpoint/capability URLs, or interactive output.
- Version the adapter and any sibling method/event. Older protocols yield explicit version coverage rather than heuristic scraping.
- No direct UI; facts and failure reasons use the common human-readable DASH-012 vocabulary.

## Surfaces

- Reads: official structured Claude account/rate-limit sources; trusted Claude auth/process generation.
- Writes: Claude provider-meter adapter, optional authorized aiur-claude protocol, fixtures/compatibility/redaction tests.
- Contracts: Claude subscription/API parity on `ProviderMeterSnapshot`; external protocol gate.

## Sibling boundaries and open gates

DASH-010 owns Claude request token/cost accounting and does not satisfy quota meters. DASH-015 requires both tickets. If sibling authority is unavailable, this ticket is human-blocked rather than complete with universal unsupported coverage.
