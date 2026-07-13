# DASH-013 — Normalize Claude account meters

**Kind:** executable

**Provenance:** planned in plan v1 after provider-meter adversarial review

**Complexity:** 4 — Claude subscription/API integration with possible sibling protocol gate

**Risk:** high

**Depends on:** DASH-012

**Serializes with:** Claude account/auth protocol and aiur-claude adapter changes

**External gates:** `GATE-OCC-PREDECESSOR-BASELINE`; and
`GATE-CLAUDE-METER-PROTOCOL-AUTHORITY`, owned by a human with `aiur-claude`
write authority and resolved before implementation as either an evidenced
existing structured source or an explicitly authorized compatible sibling
protocol revision

**Requirements:** DREQ-013

**Researched at:** `9849f32963c2a65367bce565b3f5ede3777c218f`

**Suggested labels:** `complexity:4`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Aiur exposes Claude subscription and API-key account facts through DASH-012's provider-meter contract, including real supported session/weekly or API controls, plan tier, freshness, account generation, and honest partial/error states without scraping interactive output.

## Context and evidence

The refreshed prototype shows Claude session and weekly meters and the user requires both subscription and API-token modes. Current headless/Remote Control paths expose request usage/cost but do not yet establish a complete structured account-quota projection. This ticket is a required adapter outcome: when the installed protocol lacks a needed structured source, the missing aiur-claude/upstream seam becomes an explicit human-authorized external gate rather than an “unsupported is finished” shortcut.

## Scope

- Resolve `GATE-CLAUDE-METER-PROTOCOL-AUTHORITY` before implementation dispatch by characterizing the installed Claude CLI, Claude Code OTel, and aiur-claude structured account/rate-limit capabilities using official schemas and sanitized fixtures. The human-owned receipt must select an existing structured source or authorize the minimal sibling protocol/revision. Interactive `/usage`, TUI, transcript, StatusLine, browser, and credential scraping are forbidden.
- Implement Claude normalization into DASH-012 `ProviderMeterSnapshot`: provider/backend, opaque account generation, auth mode, actual plan/tier and source, snapshot/patch/tombstone semantics, named limit IDs/windows, used/remaining facts, duration/reset, API credit/rate/spend controls when reported, observed/ingested time, freshness/expiry, and health.
- Support subscription and API-key modes without assuming they expose the same facts. Renderable session/weekly windows require actual structured values; API mode reports only real rate/credit/spend controls.
- Preserve sparse updates, per-window last-known-good state, full-snapshot removals, and account-generation isolation exactly as DASH-012 defines. Report trusted Claude auth/session lifecycle changes through DASH-018 and use its returned generation without persisting raw account identity.
- If the gate determines that Aiur alone cannot expose required meter facts, implement only the minimal typed `aiur-claude` adapter/protocol authorized by its receipt. Include version negotiation and synthetic fixtures in both repositories; no worker infers sibling write authority from this ticket.
- Expose partial/temporarily unavailable/error coverage during protocol failure, but final ticket acceptance requires the supported Claude account modes available in the user's configured integration; “all Claude meters unsupported” is not completion.
- Redact email, account/organization/workspace IDs, credentials, API/OAuth material, raw responses, headers, endpoint/capability URLs, and unrelated attributes at the adapter boundary.

## Non-goals

- Ingest request token/cost usage (DASH-010), calculate ticket/build spend, call browser/private endpoints, scrape interactive output, render UI, or redesign Claude authentication.
- Fabricate session/weekly bars or API controls from token totals, local timers, plan-name guesses, or scheduling availability.
- Mutate a sibling repository without the explicit external authority gate.

## Existing owner and reuse target

Implement against DASH-012's provider-meter contract, DASH-018's generation owner, and the current Claude/aiur-claude account/auth lifecycle. Reuse official structured monitoring/protocol sources, version negotiation, local-only transport, and trusted generation context.

## Contract and invariants

- Claude and Codex use the same snapshot/patch/tombstone/freshness contract but never share provider/account-generation keys.
- A displayed window/control has structured source evidence, source version, observation time, and coverage. Missing support is never zero usage or unlimited quota.
- Subscription and API-key presentations are capability-driven. Plan tier is actual structured/configured account fact with provenance, not inferred from usage price.
- Sparse updates cannot erase unrelated facts; full snapshots and explicit tombstones can. Authentication change cannot inherit prior account last-known-good state.
- `GATE-CLAUDE-METER-PROTOCOL-AUTHORITY` has a human owner and durable resolution receipt; it cannot be silently dropped or converted into permanent unsupported acceptance.

## Refreshable implementation notes

- Refresh official Claude monitoring and the gate-approved aiur-claude schemas at pickup. Keep the approved source-capability matrix in the ticket workpad and fixtures, then implement only the selected reviewed path.
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

- Reads: official structured Claude account/rate-limit sources; trusted Claude auth/process lifecycle; DASH-018 account generation.
- Writes: Claude provider-meter adapter, DASH-018 lifecycle observations, optional authorized aiur-claude protocol, fixtures/compatibility/redaction tests.
- Contracts: Claude subscription/API parity on `ProviderMeterSnapshot`; `GATE-CLAUDE-METER-PROTOCOL-AUTHORITY` receipt.

## Sibling boundaries and open gates

DASH-012 owns the generic meter contract and DASH-018 owns account identity;
DASH-010 owns Claude request token/cost accounting and does not satisfy quota
meters. DASH-015 requires both adapters. This ticket is not dispatchable until
`GATE-CLAUDE-METER-PROTOCOL-AUTHORITY` is resolved; if sibling authority is
unavailable, it remains human-blocked rather than complete with universal
unsupported coverage.
