# Provider Usage, Quota, Token, and Cost Accounting

## Decision

Usage/accounting is a standalone Operator Control Center program, not Build
Order behavior. Eight companion tickets own it:

1. provider-neutral usage envelope and current transport normalization;
2. durable attributed usage ledger;
3. Claude REPL/Remote Control request accounting;
4. versioned cost and grouping projection;
5. provider-meter contract plus Codex adapter;
6. Claude subscription and API-key meter adapter;
7. canonical current-run summary projection; and
8. authenticated accessible summary UI.

GitHub supplies current Build Order membership and ticket metadata. Aiur owns
retained usage and current run facts. A selected order can pass its current
member identities to the accounting query, but no totals are written to GitHub
and no accounting ticket blocks the Build Order root.

## Current capability and gap

Aiur already folds Codex token notifications into current running entries,
normalizes headless Claude completion usage and cost, reads structured Codex
rate limits, and publishes dashboard changes through PubSub. It does not yet
retain complete ticket/model/backend attribution across daemon restart,
completed tickets, retry, fallback and Remote Control. The current latest rate
limit is not a provider/account-generation-aware meter store.

Existing work must be reconciled rather than duplicated:

- #132's durable per-ticket token/cost portion is superseded by DASH-009. Its
  proposed opencode side-panel surface stays outside this dashboard scope.
- #845 is a larger multi-controller/Postgres/BI program. This bounded local
  feature deliberately uses the repository's file-first durability pattern
  behind a behavior that can gain a future database adapter.
- #930 is debug-only telemetry. It may supply vocabulary or test evidence, but
  it is not a normal-run accounting authority.

## Measurement envelope

Normalize each provider message into a raw measurement before persistence.
DASH-008 owns this content-free protocol boundary; it does not derive or retain
cross-message deltas. The minimum versioned envelope is:

```text
schema_version, idempotency_key
occurred_at, ingested_at
measurement_kind: delta | absolute
counter_scope: request | turn | thread | session
provider_epoch, account_generation
source_event_id, source_sequence
run_id, tracker/repository/ticket identity, attempt_id
session_id, turn_id, request_id
agent_family, backend, requested_model, resolved_model, effort, auth_mode
raw_input, raw_cached_input, raw_cache_creation_input, raw_output
raw_reasoning_output, provider_reported_total
provider_cost_decimal, provider_cost_currency, completeness: full | partial
source, source_version
```

The DASH-009 single writer converts an absolute token or cost counter to a delta
only within the same provider, account generation, epoch, scope and counter key,
using its durable replayable checkpoint. Duplicate or out-of-order events add no
usage. A provider reset, new session/turn, retry attempt or model fallback cannot
inherit the prior checkpoint accidentally. DASH-008 classifies and preserves raw
source semantics; it never keeps a second ephemeral delta authority.

Token dimensions overlap. Cached input is normally a subset of input, and
reasoning output is normally a subset of output. Preserve each dimension for
pricing and display, but calculate total using the provider-reported total when
available; otherwise use non-overlapping input plus output. Never sum every
field. Preserve an exact decimal provider cost at the protocol boundary.

## Required Remote Control source

Current `claude-repl` turn/display events do not carry tokens or cost. Claude
Code's supported OpenTelemetry event stream now provides a structured
`claude_code.api_request` event with session ID, monotonic event sequence,
model, estimated USD cost, input/output/cache token fields, request ID,
query source and effort. DASH-010 must evaluate and implement a local-only OTLP
ingress path, correlate `session.id` to Aiur run/ticket/attempt identity, and
emit deterministic request/event idempotency identity for DASH-009's durable
deduplication.

This is preferable to scraping `/usage`, transcript output or the status line.
The status-line token totals describe the current context rather than
cumulative usage in current Claude Code versions, and taking over a user's
status-line configuration is not an acceptable accounting contract.

Raw prompts, tool details and API bodies remain disabled. Drop email, account,
organization, host paths and any other unnecessary identity at the ingress
boundary before persistence. If the local OTLP endpoint requires a sibling
`aiur-claude` launch-protocol change, that external change is an explicit gate;
the Aiur ticket cannot finish with Remote Control marked unsupported.

The local telemetry receiver is also a trust boundary, not merely a loopback
port. Prefer an owner-only Unix-domain socket. A loopback TCP receiver requires
an unguessable per-process capability minted by Aiur, authenticated before
payload decoding or logging, bound to the process/session generation, and
revoked at teardown. Both forms enforce bounded bodies, attributes,
connections and event rates; reject replay floods and redact before any error,
quarantine or diagnostic output.

Sources:

- [Claude Code OpenTelemetry monitoring](https://code.claude.com/docs/en/monitoring-usage)
- [Claude Code status-line field semantics](https://code.claude.com/docs/en/statusline)
- [Claude Code cost semantics](https://code.claude.com/docs/en/costs)

## Durable storage decision

V1 uses a daemon-owned, single-writer file store:

- a canonical append-only, versioned NDJSON observation stream;
- crash-safe atomic JSON checkpoints for absolute-counter deduplication;
- crash-safe atomic aggregate projections for bounded reads;
- persist-before-publish acknowledgement and explicit store health;
- deterministic replay/migration, corruption quarantine and rollback tests;
- configurable retention/compaction that preserves run/ticket/agent/backend/
  model aggregates plus the earliest retained coverage timestamp.

Aiur has no application Ecto repository, migration/backup lifecycle or shared
relational store to extend. The opencode SQLite database is viewer-owned and
cannot become accounting truth. Adding Postgres for this local-first feature
would make a deployment program a hidden dashboard prerequisite. The storage
behavior and envelope remain backend-neutral so a separately authorized
multi-controller/BI run can add an adapter later.

## Cost policy

V1 produces only bases supported by actual inputs:

- `provider_reported_estimate`, when a provider reports a request/session
  estimate;
- `api_equivalent_estimate`, derived from resolved model, token dimensions and
  an immutable versioned price table; and
- `unknown`.

Do not invent metered actual, subscription allocation or fixed-fee attribution.
Do not add different bases into one dollar total. Group and display each basis
separately with coverage and pricing revision/effective date. Unknown model,
auth mode or token coverage produces unknown/partial cost, never `$0.00`.

For flat subscriptions, per-ticket/build dollars are API-equivalent estimates,
marked with an asterisk. An information popover explains that the value is not
billed spend and identifies the actual subscription tier separately. Provider
reported estimates are also labelled as estimates; authoritative API billing
may reconcile an account total but cannot infer Aiur ticket identity.

For a Build Order, totals include all retained Aiur usage attributable to each
current member ticket, including observations recorded before that ticket was
added to the order. The view reports the earliest retained coverage time and
excludes nonmembers. For Units, the default scope is the current Aiur run.

## Account-meter contract

Meters are separate from request accounting:

```text
provider, backend, auth_mode, plan_tier, account_generation
snapshot_kind: full | patch
windows: [{stable_key, kind, used_percent, resets_at, observed_at}]
credits_or_spend_control
health: available | partial | stale | error | unsupported
observed_at, source, source_version
```

A full snapshot tombstones absent prior windows; a sparse patch changes only
named windows. Each window has independent freshness/expiry. Authentication
changes start a new account generation so stale data from a prior login cannot
merge into the new account, while raw account identity is discarded.

Subscription accounts show supported session/weekly windows and plan tier.
API-key accounts show supported metered/rate/credit information without fake
subscription bars. Codex extends the existing structured account/rate-limit
path. Claude parity gets its own ticket because subscription quotas and API
organization usage are different protocols; interactive-output or credential
scraping is prohibited.

## Query and summary contracts

The accounting projection supports exact caller-supplied scope:

```text
usage_summary(ticket_ids, run_ids) ->
  totals_by_basis,
  by_ticket,
  by_agent_family,
  by_backend,
  by_model,
  token_and_cost_coverage,
  earliest_retained_at,
  store_health
```

The current-run summary is a separate projection. It defines:

- live unit count from the canonical current-run catalog;
- remaining tickets and the included lifecycle states;
- weighted progress denominator (complexity when present, otherwise one point)
  without treating missing progress as zero;
- wall-clock elapsed from the run start, not summed agent runtimes; and
- ETA from observed completed work and remaining weight, with sample window,
  confidence/freshness and unknown/insufficient-evidence states.

LiveView reads bounded cached snapshots and subscribes to PubSub. It does not
poll providers or scan the ledger per browser. Reconnect/render immediately
reads current GitHub/Aiur snapshots, then continues with pushed updates.

## Ticket boundaries

| Ticket | Owns | Does not own |
|---|---|---|
| DASH-008 | Raw envelope, transport classification and exact attribution inputs | cross-message delta derivation, durability, pricing, UI |
| DASH-009 | File-first durable ledger, absolute-counter checkpoints/delta derivation and projections | provider adapters, pricing, UI |
| DASH-010 | Claude REPL/Remote Control OTel usage and cost adapter | Claude account quotas, summary UI |
| DASH-011 | Versioned API-equivalent pricing and grouped usage query | provider account meters, ingestion, UI |
| DASH-012 | Meter snapshot/patch contract and Codex adapter | Claude adapter, ticket usage ledger |
| DASH-013 | Claude subscription and API-key meter parity | Remote Control request accounting |
| DASH-014 | Canonical current-run count/progress/elapsed/ETA | usage pricing or provider quotas |
| DASH-015 | Authenticated responsive cards, meters and drill-down | provider I/O or ledger scanning |

## Security and accessibility

- Token/cost history and all account-meter facts and APIs require authenticated
  Executor mode. This includes plan/tier, auth mode, quota/rate/credit windows,
  percentages, limits and reset times. Optional unauthenticated local dashboard
  mode renders a locked state with none of those values in HTML, assigns,
  client events or generic APIs.
- Never persist prompts, transcripts, output, credentials, email/account/org
  identity, capability URLs, raw environment values or provider bodies.
- Keep the ledger outside agent workspaces with restrictive permissions. Do not
  inject values into agent prompts or public bug reports.
- Meters expose accessible names, values, reset timestamps and unknown states;
  color or progress width is never the only meaning.
- At 320px and 200% text zoom, summary facts reflow, bottom navigation does not
  obscure content, and every action target is at least 44px.

## Resolved product decisions

There are no remaining product-choice gates for this track: subscription
estimates, current-member/all-retained scope, read-only GitHub planning, and
required Remote Control accounting are accepted in `questions.md`. Two named
human-owned protocol gates remain: `GATE-CLAUDE-OTEL-PROTOCOL-AUTHORITY` for
DASH-010 and `GATE-CLAUDE-METER-PROTOCOL-AUTHORITY` for DASH-013. Each must be
resolved either with evidence that the Aiur-only path satisfies the contract or
with explicit authority and a compatible sibling revision. Provider protocol
availability can block an adapter ticket, but cannot silently weaken its
acceptance criteria or be treated as an executable worker's implicit authority.
