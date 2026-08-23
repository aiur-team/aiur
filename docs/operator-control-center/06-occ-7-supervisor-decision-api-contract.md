# OCC-7 supervisor Decision API contract

**Status:** Implemented by ticket #984

**Builds on:**
[`03-occ-1-decision-contract.md`](./03-occ-1-decision-contract.md),
[`04-occ-2-attention-adapter.md`](./04-occ-2-attention-adapter.md),
[`04-occ-3-answer-delivery-contract.md`](./04-occ-3-answer-delivery-contract.md),
and OCC-8's Decision revision contract.

This contract exposes the canonical Decision lifecycle to an authenticated
supervising agent. It adds an authorization and HTTP boundary, not a second
store, queue, dispatcher, event bus, or revision implementation.

## Authentication and transport

Every route requires:

```text
Authorization: Bearer <AIUR_SUPERVISOR_TOKEN>
```

`AIUR_SUPERVISOR_TOKEN` is independent of dashboard Basic Auth. It must be at
least 32 bearer-safe bytes, contain no surrounding whitespace, and is read on
each request so rotation is immediate. Generate one with
`openssl rand -base64 32`, then set `AIUR_SUPERVISOR_TOKEN=<generated-token>` in
`~/.aiur/.env` for all projects or the repository `.env` for one project. An
exported value wins, followed by the global file and then the repository file.
An absent or empty token disables the API, while a present non-empty unusable
value aborts startup. Requests without a usable instance credential, requests
with a missing or malformed Authorization header, and valid-shaped credential
mismatches return distinct redacted `401` responses. The token is never
accepted from JSON, persisted, published, or logged.

Bearer credentials do not encrypt traffic. Keep the dashboard on loopback or a
private tunnel, or put it behind an HTTPS reverse proxy before allowing remote
access. Do not send this API over an untrusted plaintext network.

Successful authentication injects exactly this trusted actor:

```json
{"kind":"supervisor","id":"supervising-agent"}
```

Payload `actor`, `authority`, and policy claims cannot replace it.

## Delegation policy

Supervisor autonomy is disabled by default:

```yaml
decisions:
  supervisor_allowed_kinds: []
  supervisor_allow_non_reversible: false
```

The mutation policy is narrowing and evaluated again against the current
Decision immediately before each answer or revision:

1. `human_required` is absolute and cannot be overridden by configuration.
2. `supervisor_allowed` and `supervisor_preferred` require an exact normalized
   `kind` in `supervisor_allowed_kinds`.
3. `irreversible` and `partially_reversible` additionally require
   `supervisor_allow_non_reversible: true`.
4. Missing/unknown kinds, authorities, reversibility values, or malformed
   policy fail closed.

Reads report the current evaluation under `supervisor_policy`. Enrichment may
add bounded context to any Decision but cannot alter the recorded policy
fields. Decide and revise are denied before append or dispatch unless every
gate passes.

## Routes

| Method | Route | Operation |
|---|---|---|
| `GET` | `/api/v1/decisions` | Deterministic bounded list |
| `GET` | `/api/v1/decisions/:decision_id` | One canonical current Decision |
| `POST` | `/api/v1/decisions/:decision_id/enrich` | Append constrained context |
| `POST` | `/api/v1/decisions/:decision_id/decide` | Delegate an answer to OCC-3 |
| `POST` | `/api/v1/decisions/:decision_id/revise` | Delegate a revision to OCC-8 |

Read routes require only the supervisor credential and stay available while
the dashboard is observe-only. Mutation routes also require all existing
dashboard write defenses:

```text
Origin: <exact dashboard/loopback origin>
X-Aiur-Request: 1
observability.dashboard_writable: true
```

Origin comparison parses and matches exact scheme, host, and effective port;
userinfo, lookalike hosts, malformed origins, and port mismatches are rejected.
The path Decision ID is authoritative over body/query content. Unsupported
methods return the Decision API's `405`, never the generic issue endpoint.

## List and get

List supports only these optional query fields:

- `ticket`, `authority`, `kind`, and `blocking` filters;
- `limit` from 1–200 (default 50);
- `offset` from 0–1,000,000.

Unknown or malformed filters fail instead of broadening the result. Records are
ordered by canonical `created_at` descending, then Decision ID, and include a
bounded pagination envelope with `limit`, `offset`, `next_offset`, and `total`.
The v1 offset contract remains supported over the retained store. For stable
pagination during insertion, clients may opt into `cursor` pagination instead;
cursor mode cannot be combined with `offset`, uses its own bounded retained-query
filters (`lifecycle` and `search` included), and returns `cursor` plus
`next_cursor` alongside retained health and partial-result metadata. A bounded
filtered scan may report a `nil` total and partial status rather than presenting
an incomplete page as a complete global result. Both reads reuse
`DecisionProjection`'s redacted request and lifecycle JSON; there is no
API-specific copy of canonical state.

Successful exact `GET /api/v1/decisions/:decision_id` responses also include
retained scope and health metadata. A Decision found in a validated corrupt
prefix is returned with partial health rather than being presented as complete.

## Enrich

An enrichment body contains `expected_version` plus one or more of:

- `context.short_summary` / `context.long_context_markdown`;
- `options`;
- `recommendation`;
- `consequence_of_delay`;
- `artifacts`.

Identity, ticket/source correlation, question, kind, authority, urgency,
blocking, reversibility, timestamps, hashes, and actor fields are rejected.
The merged object passes through the complete Decision validator and secret
redactor.

An accepted enrichment appends one typed `enriched` audit event containing the
next request snapshot, trusted supervisor actor, and expected prior version.
DecisionStore fsyncs that event and repairs its projection before publishing
`decision.enriched` or Decision PubSub. Existing answers, dispatch attempts,
acknowledgement, and resolution remain attached and no answer is redispatched.

Exact replay against the same historical base returns `duplicate` with no new
append/publication. Different normalized content reusing that base returns an
idempotency conflict. A stale base with no accepted matching enrichment appends
nothing.

## Decide

In addition to OCC-3's stable idempotency key, expected request version, and
exactly one option/custom answer, a supervisor answer requires:

```json
{
  "rationale": "Why this choice is appropriate",
  "confidence": 91,
  "alternatives_considered": ["Wait for another review"],
  "reversibility_belief": "reversible"
}
```

Confidence is an integer from 0–100. Rationale is bounded by OCC-3's answer
limit. Alternatives are an explicit list of at most 20 bounded strings.
Reversibility belief is one of the canonical Decision reversibility values; it
does not override the recorded value used by policy.

The accepted immutable `DecisionAnswer` stores these fields plus a
server-derived `policy_basis`: recorded authority/kind/reversibility, the three
authorization checks, and the non-reversible opt-in state. Supervisor basis
participates in answer content hashing. Legacy operator answer serialization
and hashes remain unchanged because their absent basis field is omitted.

DecisionApi calls only `DecisionStore.answer`. OCC-3 owns append, action
identity, one-winner/idempotency rules, scheduling, queue correlation,
reactivation, retry, delivery, acknowledgement, and resolution. The API never
calls `OperatorMessages` or publishes an answer itself.

## Revise

DecisionApi re-reads and authorizes the current Decision, rejects payload actor
or authority substitution, normalizes the same bounded supervisor reasoning
required by Decide, then injects the trusted actor and server-derived policy
basis into `DecisionStore.revise/5`. In addition to that reasoning, callers
provide OCC-8's current request/action correlation:

```json
{
  "expected_version": 2,
  "expected_action_id": "act_current",
  "expected_revision_sequence": 0,
  "idempotency_key": "stable-client-key",
  "custom_response": "Corrected direction",
  "rationale": "What changed and why",
  "confidence": 89,
  "alternatives_considered": ["Keep the current direction"],
  "reversibility_belief": "reversible"
}
```

Exactly one option or custom response remains required. OCC-8 exclusively owns:

- request/action/revision-sequence validation;
- idempotency and one-winner semantics;
- target revalidation and corrective dispatch;
- `recorded`, `dispatched`, and `no_longer_applicable` outcomes;
- the durable parent `follow_up_required` fact and stable reminder projection;
- durable handled/superseded facts before reminder resolution.

A successful response includes the canonical `accepted`/`duplicate` mutation
status, current Decision, immutable revision action, `revision_result`, and
dispatch status. A revision is corrective intent, not proof of rollback,
reversion, undo, or successful application. DecisionApi does not inspect
trackers, dispatch a message, open/resolve a reminder, or retry around OCC-8.

## HTTP result vocabulary

| Status | Code/result | Meaning |
|---:|---|---|
| `200` | read / `duplicate` / settled service result | Current or replayed canonical state |
| `202` | `accepted` / `recorded` | Intent is durable; downstream settlement may still be pending |
| `400/422` | `invalid_request` | Malformed, forbidden, or out-of-bounds input |
| `401` | `supervisor_auth_required` | Dedicated credential absent or invalid |
| `403` | `supervisor_forbidden` or write-gate error | Policy or mutation safety denied |
| `404` | `decision_not_found` | Canonical Decision missing |
| `405` | `method_not_allowed` | Known Decision route, unsupported method |
| `409` | `decision_conflict` | Stale or idempotency/action correlation conflict |
| `503` | `decision_service_unavailable` | Canonical DecisionStore unavailable |
| `503` | `decision_presence_indeterminate` | Retained data is partial, so a requested Decision cannot be proven absent |

Errors never include inspected exceptions, credentials, payloads, or raw
downstream terms. Clients should refresh after a conflict. They may retry an
unchanged logical action with the same idempotency/correlation values; they
must use a new key for changed content.

An indeterminate detail response includes retained scope and partial-health
metadata. It is distinct from a `decision_not_found` response and does not
claim that a partially replayed store is unavailable.

## Audit and recovery invariants

- DecisionStore remains the sole serialized writer.
- Every accepted mutation is durable before any live event, PubSub broadcast,
  queue insertion, agent wake, tracker read, or reminder projection it causes.
- Policy denial, invalid input, stale correlation, and idempotency conflict
  append and publish nothing.
- Restart rebuilds the same current Decision, supervisor answer basis, and
  action correlation from the canonical audit.
- A corrupt/read-only store continues serving its validated prefix to reads but
  rejects every mutation and causes no dispatch.

Downstream consumers should read DecisionStore/DecisionProjection and preserve
the actor, policy basis, action IDs, and sibling result vocabulary. They should
not reconstruct authorization from present-day configuration or infer that a
queued correction was applied.
