# DASH-026 — Project bounded live conversations

**Kind:** executable

**Provenance:** planned in plan v1 after shipped-dashboard conversation audit

**Complexity:** 3 — New source-aware, bounded, sanitized live conversation contract over runtime event streams

**Risk:** high

**Depends on:** BO-017

**Serializes with:** BO-003, BO-005, BO-016, BO-019, DASH-002, DASH-009, DASH-012, DASH-018, DASH-019, DASH-024, DASH-025 — central supervision-tree and structured-event seams, not shared semantics

**Resolved predecessor baseline:** `origin/main@9849f32963c2a65367bce565b3f5ede3777c218f` — the shipped OCC predecessor is present; no external gate remains

**Requirements:** DREQ-026

**Researched at:** `9849f32963c2a65367bce565b3f5ede3777c218f`

**Suggested labels:** `complexity:3`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Aiur exposes a bounded, sanitized, source-aware live conversation snapshot for an exact running unit generation, without exposing local workspace paths, raw event JSON, or filesystem reads as a web contract.

## Context and evidence

Current main's `Aiur.AgentLog` and `AgentLogModal` read `logs/agent.ndjson` or `logs/agent.md` from a running workspace, return the chosen local path, and may summarize an unrecognized structured record as raw JSON. That compatibility reader is useful internally, but it is not a safe public web projection. The prototype instead shows a bounded read-only conversation mirror. BO-019 owns recent ticket activity/history, and BO-018 renders ticket description, progress, latest evidence, and a Logs timeline; neither owns an agent/operator conversation transcript.

## Scope

- Define a versioned `LiveConversationSnapshot` keyed by BO-017's propagated
  BO-004 configured-repository identity plus current run, attempt/session, and
  worker/backend generation. A replacement generation never inherits or
  appends to the prior conversation.
- Normalize only allowlisted structured runtime conversation events at a trusted ingestion boundary: agent messages, Executor/operator messages, concise system transitions, and explicitly safe tool-result summaries. Preserve stable message/event identity, role, safe title, occurred/observed time, and source generation.
- Compact streaming deltas deterministically, deduplicate retries/replays, and replace a partial message only with its matching completed message. Out-of-order or late events from an older generation cannot mutate the current snapshot.
- Sanitize and bound content before retention: at most 80 display messages, at most 1,600 Unicode characters per body, bounded titles, and a total snapshot byte ceiling. Expose truncation/count metadata rather than silently dropping evidence.
- Drop unknown event kinds and unsafe/unstructured payloads with bounded diagnostic counters. Never render, retain, or return a raw record as a fallback body.
- Distinguish `live`, `ended`, `known_empty`, `stale`, `unavailable`, and `restart_unknown` source states with generation, health, freshness, and observation metadata. A healthy empty conversation requires a healthy authoritative source.
- Publish immutable snapshots and coalesced change notifications for dashboard consumers. Queries are bounded in-memory reads and perform no workspace, log-file, process, or provider I/O.
- Define explicit retention for an ended generation within the active run and bounded eviction thereafter. A daemon restart does not reconstruct a conversation by parsing workspace logs; it reports the truthful restart state.

## Non-goals

- Render a drawer, send operator messages, pause/resume a unit, discover Remote Control URLs, or expose raw logs/downloads.
- Replace BO-019 ticket activity/history or BO-018 ticket context/Logs with conversation messages, or add conversation content to either contract.
- Make `Aiur.AgentLog` paths, markdown/NDJSON parsing, arbitrary model output, reasoning, command transcripts, or successful command output part of a browser-facing API.
- Persist a cross-run transcript archive or build log search, pagination, export, or analytics.

## Existing owner and reuse target

Reuse the supported app-server/runtime event ingress, current session/
generation ownership, BO-017 propagated identity, `Aiur.AgentPubSub`/
observability notifications, and existing redaction vocabulary. Reuse only the
allowlisted normalization knowledge in `Aiur.AgentLog`; its path-bearing
`read_workspace/1` result and permissive raw fallback remain internal
compatibility behavior, not this contract.

## Contract and invariants

- The key is exact configured-repository identity plus runtime generation. Bare issue number, workspace basename/path, current directory, and currently selected row are never identity.
- Only allowlisted normalized fields enter a snapshot. Raw JSON, raw NDJSON/markdown, prompts, reasoning, full tool output, credentials, environment values, account data, capability URLs, and local paths are forbidden.
- Bounds and sanitization apply before retention/publication. A consumer cannot request an unbounded or less-redacted form.
- Missing, stale, unavailable, restart-unknown, known-empty, and ended are distinct. None is converted to a healthy empty transcript.
- Message order is deterministic by trusted source ordering plus stable identity; delta compaction, duplicate delivery, and late-generation rejection are idempotent.
- This projection conveys conversation evidence only. It cannot change lifecycle, progress, ticket history, readiness, Commands, or control state.

## Refreshable implementation notes

- Reinspect active Codex, Claude, and Remote Control event shapes and the session/generation owner at pickup. Add small producer adapters to one normalizer; do not create backend-specific public snapshot variants.
- Characterize `Aiur.AgentLog`'s existing allowlist and compaction regressions, then extract shared pure normalization only at the second real use. Keep path reading and compatibility fallback out of the new module.
- Prefer one supervised projection with pure normalizer/retention modules and injected clocks. Coordinate supervision and shared redaction edits with BO-019 before parallel branches merge.

## Acceptance and verification

### Agent gate

- Normalizer tests cover every accepted role/kind, streaming delta completion, duplicate/replayed/out-of-order events, two repositories sharing a number, attempt/session replacement, and malformed timestamps/Unicode.
- Boundary tests prove 0/1/80/81 messages, body/title/total-byte limits, deterministic eviction, explicit truncation, subscriber churn, source degradation/recovery, ended generation, projection-only restart, and daemon restart.
- Negative security tests prove unknown records, raw JSON, paths, prompts, reasoning, full command output, credentials, account data, capability URLs, and prior-generation messages cannot enter snapshots or diagnostics.
- Query tests prove snapshot reads perform no filesystem, workspace-log, process, GitHub, or provider I/O.

### At-merge gate

- Rebase on BO-017 and current main, sequence central supervision and shared
  event/redaction edits with the declared peers, and pass app-server adapter,
  AgentLog compatibility, PubSub, restart, security, compile/lint/spec, and full
  CI suites.

### Human/manual evidence

- None separately; DASH-027 owns real-dashboard evidence for live, empty, ended, stale, and unavailable conversation snapshots.

## Failure, security, migration, and accessibility cases

- Source loss preserves a bounded last-known-good snapshot only with visible stale health for the same generation; it never reads a local file as recovery or reports healthy empty.
- Redact and bound before storage/publication. Diagnostics contain event kind, reason class, and counts only, never rejected content.
- Version the snapshot and event adapters; the current AgentLog modal may remain as a compatibility surface until DASH-027 lands, without becoming a migration source.
- No direct UI. Roles, state, source, truncation, and unavailable reasons use stable human-readable labels for accessible consumers.

## Surfaces

- Reads: BO-017 propagated BO-004 identity; trusted run/attempt/session/worker
  generation; allowlisted structured runtime conversation events; injected
  clock/configuration.
- Writes: live conversation normalizer/projection, bounded snapshots, health/freshness/change notifications, tests.
- Contracts: `LiveConversationSnapshot`; role/event allowlist; generation isolation; bounds/redaction and source-state semantics.
- Safety: structured-event redaction and application supervision tree.

## Sibling boundaries and open gates

DASH-027 alone renders this snapshot as a read-only conversation drawer. BO-019 remains the bounded ticket activity/history owner, and BO-018 remains the ticket-context/Logs presenter; neither may consume this transcript as its history source. Messaging, pause/resume, Remote Control navigation, and usage accounting remain with their explicit owners.
