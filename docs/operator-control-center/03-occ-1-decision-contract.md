# OCC-1 Decision contract and storage

**Status:** Implemented in this ticket (#979)

**Source:** [`docs/operator-control-center/02-occ-0-audit-and-design-decisions.md`](./02-occ-0-audit-and-design-decisions.md) (accepted foundation), amended per a foundation-review comment on #979 (owner, 2026-07-12).

This is the schema/storage handoff for OCC-2 through OCC-9. It documents what OCC-1 delivers; it does not claim answer dispatch, delivery correlation, acknowledgement, or resolution exist yet — those are OCC-2/3.

## Delivered capabilities

- A versioned `Aiur.Decision` struct and a validating `Aiur.DecisionValidation.normalize/2` pipeline.
- `Aiur.DecisionStore`, the single public application service and serialized writer: persist-before-notify, deduplication, version progression/conflict detection, replay-and-repair on restart, read-only corruption mode.
- A neutral, BEAM-lifetime `run_id` on `Aiur.Boot`, shared by audit records and debug telemetry.
- A project/instance-isolated, owner-only on-disk state directory.

## Not yet delivered (owned by later tickets)

- Operator answers, revisions, acknowledgement/resolution lifecycle (OCC-3, OCC-8).
- Durable dispatch/outbox correlation with `Aiur.Orchestrator.OperatorMessages` (OCC-3).
- LiveView, REST, and dashboard surfaces (OCC-4, OCC-7).
- Legacy `attention.*`/`blocked`/`pause.request` adapter into this schema (OCC-2); `Aiur.DecisionAttention` is unchanged.
- Fleet/outcomes and latency metrics (OCC-5, OCC-6, OCC-9).

## Schema (version 1)

`Aiur.Decision` fields:

| Field | Type | Notes |
|---|---|---|
| `schema_version` | integer | Currently `1`. |
| `decision_id` | string | Canonical identity, deterministic from trusted ticket scope + an agent-supplied `source_id` (sha256-truncated); random (non-replayable) when `source_id` is absent. |
| `source_id` | string \| nil | Agent-proposed identity, preserved for correlation only — never the canonical identity. |
| `version` | positive integer | Starts at 1; an accepted enrichment is exactly `current + 1`. |
| `ticket` | `%{identifier, title, url}` | Injected from trusted runtime context; never read from the raw payload. |
| `source` | `%{agent_id, session_id, event_id}` | Injected from trusted runtime context; never read from the raw payload. |
| `kind` | string \| nil | Free-form bounded category (e.g. `"architecture"`, `"destructive_op"`, `"credential"`, `"product"`). Not a closed enum in this ticket. |
| `authority` | `:human_required \| :supervisor_allowed \| :supervisor_preferred` | Defaults to `:human_required` (the safe default per the PRD) when omitted. |
| `urgency` | `:low \| :normal \| :high \| :critical` | Defaults to `:normal`. |
| `blocking` | boolean | Required — part of the PRD's "required minimum." |
| `reversibility` | `:reversible \| :irreversible \| :partially_reversible` | Defaults to `:irreversible` (the cautious assumption) when omitted. |
| `question` | string, 1–2000 chars | Required. |
| `context` | `%{short_summary, long_context_markdown}` | Both optional; bounded at 500 / 20,000 chars. Treated as data — never rendered as trusted HTML. |
| `options` | list of `%{id, label, description, benefits, drawbacks, risk}` | Optional, up to 20; ids must be unique. A custom-response-only request needs no invented options. |
| `recommendation` | `%{option_id, reason}` \| nil | `option_id` must match an existing option — a dangling reference is rejected. |
| `consequence_of_delay` | string \| nil | Bounded at 2000 chars. |
| `artifacts` | list of `%{kind: :path \| :url, value}` | Up to 20. See Artifact safety below. |
| `created_at` | `DateTime.t()` | Canonical acceptance time, stamped by the store's clock. |
| `source_created_at` | `DateTime.t()` \| nil | Optional agent-reported time, provenance only — never controls audit order, version order, or notification age. |
| `content_hash` | string | sha256 over only the meaningful content fields (question, options, context, artifacts, authority, urgency, blocking, reversibility, kind, recommendation, consequence_of_delay) — excludes identity/timestamps. Used for dedup and (on replay) tamper detection. |

### Validation

`Aiur.DecisionValidation.normalize/2` bounds every field, rejects unsafe control bytes, redacts known credential patterns (`Aiur.SecretRedactor`, extracted from `Aiur.Events.Sanitizer` so both share one pattern list) before hashing, and never accepts `ticket`/`source` from the untrusted payload — those are always injected via trusted `opts`.

### Artifact safety

`Aiur.DecisionArtifact.validate/2`: a local path must be absolute and canonicalize (symlink-resolved) beneath a configured safe root (workspace root or log root); a remote reference must be an HTTPS URL with no embedded credentials and a host that exactly matches, or is a dot-delimited subdomain of, an approved allowlist (`Application.get_env(:aiur, :decision_artifact_allowed_hosts)`, default `github.com`/`api.github.com`/`raw.githubusercontent.com`). File-serving consumers must re-canonicalize and re-check containment at access time — this only proves containment at ingestion.

## Storage

Both files live beneath `Aiur.Config.Paths.decision_state_dir/0`: an owner-only (`0700`) directory rooted at `AIUR_BG_STATE_DIR`, keyed by the sanitized `AIUR_INSTANCE_KEY` (already a truncated sha256 of the launcher-resolved project root) and the sanitized tracker project identity. Resolution fails closed — refusing to start rather than silently sharing state — when `AIUR_INSTANCE_KEY` is explicitly empty or the project identity is unavailable; the resolved path is also canonicalized and asserted to stay under the configured root, rejecting a `.`/`..` escape without touching the shared, byte-pinned `Aiur.Config.Paths.sanitize/1` used by four other subsystems.

- `decisions.ndjson` — canonical, append-only, newline-terminated JSON records (owner-only `0600`). Each accepted mutation appends the full Decision snapshot at its version plus its reserved `event_id`.
- `decisions.json` — atomically-replaced current-state projection (via `Aiur.JsonStore`), rebuildable from the audit stream at any time.

On first-ever creation of the directory or the audit file, `Aiur.Fs.sync_filesystem/0` is also called once so the new directory entry itself is durable — a file's own fsync never syncs its parent directory, and the BEAM has no way to open a directory as a file descriptor to fsync one directly (`:file.open/2` returns `:eisdir` for every mode), so this shells out to POSIX `sync(1)` as a one-time, global barrier rather than a per-append cost.

## Corruption / threat model

The append+fsync-before-ack barrier means a **crash** can only tear the tail of `decisions.ndjson` — never corrupt an interior record. On replay, an incomplete (non-newline-terminated) trailing fragment is therefore truncated in place (`ftruncate`, not a full rewrite) and treated as unacknowledged.

An **interior** record that fails to decode, or that decodes as valid JSON but fails full schema/invariant re-validation, is corruption — bit-rot or a violation of the single-writer trust boundary, not a crash artifact — and is never silently skipped. Replay reuses `Aiur.DecisionValidation.normalize/2` itself (the same ingress pipeline, not a second parallel implementation) and recomputes `content_hash` for comparison against the persisted value, so a record that merely decodes as JSON but whose content changed since it was written (e.g. a flipped byte in a still-valid-JSON string field) is caught. This explicitly does **not** defend against an adversarial rewriter with full access to overwrite the file with internally-consistent fabricated records — that is outside the local single-writer trust boundary this ticket protects.

On interior corruption, the store enters read-only mode: reads keep serving the validated prefix, every mutation is rejected (`{:error, {:store_unavailable, {:corrupt, line, reason}}}`), and one operator alert (`decision_store.corrupted`) is emitted — never retried silently.

## Versioning and deduplication

A request targets `decision_id` at an explicit or implied `version` (defaults to `1`):

- No current record for `decision_id`: accepted only at version `1`.
- Current record exists, requested version equals it, and `content_hash` matches: **duplicate** — returns the existing record; no append, no new notification.
- Current record exists, requested version equals it, `content_hash` differs: **idempotency conflict**.
- Requested version is exactly `current + 1`: accepted as the next version (append-only enrichment).
- Requested version is lower than current: **stale**.
- Anything else higher: **version gap**.

## Run identity

`Aiur.Boot` mints one opaque `run_id` per BEAM-lifetime run (`mark/0`, idempotent) and every accepted audit record carries it. `Aiur.RunTelemetry.boot_id/0` delegates to `Aiur.Boot.run_id/0` directly (rather than caching its own copy), and `Aiur.Boot.remark/0` (test-only) mints a fresh `run_id` together with the clock reset, so a test simulating a reboot within one VM never observes a stale id from either reader.

## Notification (scope note)

After successful audit append and projection replacement, the store publishes the persisted event through `Aiur.Events.Publisher.publish_persisted/4` (under the durably-reserved `event_id` from `Aiur.Events.IdGenerator.reserve_durable_id/1`, skipping the contamination/dedup filters meant for best-effort external sources) and broadcasts on `Aiur.DecisionPubSub`. `Aiur.Events.Publisher.publish/3` rejects direct publication of any `decision.requested`-family topic outright, so no other call site can bypass durability.

This ticket implements notification as **best-effort, attempted once synchronously** right after persistence succeeds — not a fully persisted pending-notification index with bounded-backoff retry across restarts. The durable audit record and projection are unaffected either way; a missed live notification is recoverable because every consumer is expected to re-read `Aiur.DecisionStore` on mount/reconnect rather than trust the broadcast alone. A full settlement-record mechanic (recording notification completion as its own audit event, so a restart can resume an *specific* unsettled notification with its original `event_id`) is deferred — the schema has room to add it without a breaking change.

## Agent ingress

Only the structured `decision.requested` name from the agent tool boundary routes through `Aiur.DecisionStore`; every other event name (`progress`, `attention.*`, `blocked`, `pause.request`, arbitrary `decision.<slug>` coordination events) keeps its existing behavior through the generic `Aiur.Events.Publisher` path and `Aiur.DecisionAttention` unchanged.
