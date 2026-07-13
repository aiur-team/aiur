# Provider Usage, Quota, Token, and Cost Accounting

## Decision

The Codex/Claude usage cards are shared Operator Control Center work, not Build
Order behavior. Implement them as three companion tickets outside the Build
Order root:

1. durable attributed usage and cost ledger;
2. subscription/API provider account meters; and
3. shared dashboard summary UI.

A selected Build Order may supply a set of member ticket IDs to the accounting
query. The accounting store remains Aiur-owned and does not write totals to
GitHub.

## Current reusable capability

Aiur already has useful pieces:

- `Aiur.Orchestrator.TokenAccounting` folds cumulative token events into each
  running entry and one current-daemon total;
- Codex `thread/tokenUsage/updated` and completion events are normalized;
- Codex handshake already calls `account/rateLimits/read`;
- `Aiur.ModelAvailability` persists a small provider-availability snapshot;
- headless `aiur-claude` reports input/output/cache usage and provider-reported
  `cost_usd` on completion;
- the current dashboard forwards global tokens, active-ticket tokens, and one
  raw latest-rate-limit value.

The missing product boundary is durable, provider-neutral attribution:

- completed ticket totals disappear;
- current-daemon totals disappear on restart;
- provider, backend, exact model, run, attempt, and Build Order membership are
  not retained together;
- cost is ignored;
- direct `claude-repl`/Remote Control has no token/cost path;
- the last quota map can overwrite another provider;
- sparse/multi-limit account updates and all quota windows are not preserved.

## Provider protocol findings

### Codex

The locally installed Codex app-server schema exposes structured account,
rate-limit, and usage methods. It distinguishes API-key and ChatGPT accounts,
supports multiple rate-limit IDs, separates primary/secondary windows, and
emits sparse rolling updates. Token notifications include cached input and
reasoning output.

Current Aiur parsing expects some snake-case fields while the app-server schema
uses camelCase fields such as `limitId`. Aiur also drops multi-limit/reset-credit
data and cached/reasoning token components. Extend the existing integration
rather than building a new scraper.

For API accounts, OpenAI's organization Usage API can group completion usage by
model/project/user/API key, while the Costs endpoint reports invoice-aligned
spend by project and line item. Those organization endpoints require the
appropriate admin credential and do not provide Aiur ticket identity, so they
can reconcile aggregate billed spend but cannot replace Aiur's per-ticket
ledger. See [OpenAI Usage and Costs API](https://platform.openai.com/docs/api-reference/usage/audio_transcriptions_object).

### Claude

Headless `aiur-claude` already returns detailed token usage and a cost value
reported by the Claude CLI. Aiur currently copies that field into a normalized
event but does not store it.

The installed adapter exposes no structured account/quota method. If Claude
Session/Weekly values cannot be obtained through a supported structured
provider contract, render them as unsupported. Do not scrape interactive
status text, credential files, transcripts, or browser state. A required
`aiur-claude` protocol addition is a separate cross-repository prerequisite.

Direct `claude-repl` usage must either gain a supported observation path or be
shown as incomplete coverage; it must never count as zero.

## Account-meter contract

Use one normalized provider snapshot:

```text
agent_family
backend
auth_mode: subscription | api_key | other | unknown
plan_type
quota_status: available | partial | unsupported | stale | error
windows: [{bucket, limit_id, used_percent, duration_minutes, resets_at}]
credits_or_spend_control
observed_at
source
source_version
```

Subscription accounts show available session/weekly windows. API-key accounts
show applicable metered/rate/credit information without fabricated
subscription bars. Sparse updates merge into a provider-and-limit-ID
last-known-good snapshot. Failure retains stale data with health metadata;
failed fetch never means zero or fully available.

Normalize and discard email, account IDs, API-key material, OAuth tokens, and
raw credentials at the provider boundary.

## Durable usage record

Each accepted observation needs enough identity to aggregate without guessing:

```text
schema_version, idempotency_key, observed_at, run_id
tracker and repository/project identity, issue ID/display identifier
attempt_id, session_id, turn_id
agent_family, backend, model_requested, model_resolved, effort, auth_mode
input, cached-input, cache-creation-input, output, reasoning-output tokens
provider-reported total tokens
cost_micros_usd, cost_basis, pricing_revision
```

Keep `claude` and `claude-repl` distinct at storage time and group them into the
Claude card only at query time.

Cumulative counters are keyed by provider/session/thread/turn and counter kind,
not only by ticket. Duplicate or out-of-order observations add zero; new
sessions/turns start new counters; restart/resume reloads checkpoints; retries
receive distinct attempts; backend fallback retains the ticket while changing
backend/model attribution.

Use a daemon-owned durable store and stable projection. SQLite is available and
fits relational aggregation; a versioned append-only audit with rebuilt
projection can also fit existing patterns. The ticket must decide after
measuring write frequency. Either choice requires atomic/idempotent writes,
schema migration/replay, health separate from zero data, bounded compaction,
persist-before-broadcast, and no LiveView/log parsing.

## Cost semantics

Store currency in integer micros or exact decimal. Every value has a basis:

- `provider_reported`;
- `metered_actual`;
- `api_equivalent_estimate` from exact resolved model and versioned prices;
- `subscription_fixed` from explicit configuration;
- `allocated` under an explicit allocation policy; or
- `unknown`.

Never mix these into an unlabeled “spend” total. Preserve pricing revision and
effective date so history does not change when prices change. Unknown model or
auth semantics means unknown cost, not `$0.00`. Cached input/cache creation must
remain separate when prices differ.

The total card reports pricing coverage when any usage is unknown. For flat
subscriptions, the recommended default is to show provider-reported or
API-equivalent per-ticket usage cost and show the configured fixed fee once,
without allocating it across tickets. If allocation is desired, label it
allocated rather than actual.

## Aggregation API

Query exact groups over a caller-supplied ticket set:

```text
summary(ticket_ids, run_ids) ->
  totals, by_agent_family, by_backend, by_model, by_ticket,
  cost_basis_and_coverage, quota_snapshots, store_health
```

For a selected Build Order, GitHub membership supplies `ticket_ids`. For a plain
Units page, the caller may select the current Aiur run. UI copy must distinguish
“this build” from “this run.”

## Companion ticket boundaries

### DASH-USAGE-1 — Persist attributed usage and cost

**Complexity:** 5

Own the provider-neutral durable record, idempotency/checkpoints, exact cost
bases, attribution dimensions, aggregation query, retention/compaction, health,
and source redaction. Include Claude REPL coverage or an explicit incomplete
state. No provider quota fetching or dashboard cards.

Acceptance includes restart/resume, retries, fallback, duplicates/out-of-order
events, completed tickets, unrelated-ticket exclusion, exact micros/pricing
revision, unknown coverage, corruption, and credential redaction.

### DASH-USAGE-2 — Ingest provider account meters

**Complexity:** 4, or 5 with a cross-repository Claude adapter prerequisite.

Own Codex/Claude auth-mode and quota ingestion, sparse multi-limit merges,
session+weekly preservation, API-key meter behavior, last-known-good health,
and conservative fallback compatibility. No visual redesign.

Acceptance includes current Codex camelCase fixtures, multiple limit IDs,
300-minute plus 10,080-minute windows, API-key/ChatGPT modes, email stripping,
unsupported Claude state, stale/error behavior, and current availability-ledger
migration.

### DASH-USAGE-3 — Render shared OCC usage summary

**Complexity:** 3

Own the shared Codex/Claude/total cards, scope labels, supported quota windows,
cost basis/coverage, live updates, degraded states, responsive/accessibility
behavior, and drill-down/grouping presentation. Consume the first two tickets;
do not fetch providers per browser render.

## Security and privacy

- Never persist or log credentials, account emails, capability URLs, raw
  environment values, or raw provider responses.
- Token/cost history stays behind the authenticated operator dashboard/API.
- Store numeric/account-plan facts, not prompts, transcripts, or model output.
- Treat credit and spend controls as financial operator data, never agent prompt
  or public tracker content.
- Use synthetic values and account IDs in tests, recordings, and bug reports.

## Open product decisions

The durable questions are in `questions.md`: subscription cost basis, Build
Order membership-time semantics, and direct Claude REPL coverage.
