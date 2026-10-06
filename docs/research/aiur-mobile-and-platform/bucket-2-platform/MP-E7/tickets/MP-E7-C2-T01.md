---
ticket_id: MP-E7-C2-T01
feature_id: MP-E7
chunk_id: MP-E7-C2
bucket: 2-platform
title: "Aiur.Listener.ModeStore: durable per-ticket-run listener mode record with compare-and-set"
status: blocked
repo: aiur-team/aiur
wave: 3
blocked_by: [DESIGN-E7, E7-D5]
prior_units: [U4, U6]
prior_boundaries: [MSG (16), RUN (18)]
prior_features: [integrations-43]
prior_findings: []
size_owner: n/a for new files; LIFECYCLE_DISPATCH for the 2-line hook in orchestrator/workspace_cleanup.ex (165 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C2-T01 — Durable listener mode store

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E7 / C2 (mode store and control API).
- **User value:** a mode chosen for an agent survives agent respawn and
  daemon restart, and two writers cannot silently overwrite each other.
- **Deliverable:** `Aiur.Listener.ModeStore` (PROPOSED
  `src/lib/aiur/listener/mode_store.ex`), a pure file-backed store:
  `get/2`, `put/5` (compare-and-set), `clear/2`; cleared when a ticket's
  terminal artifacts are cleaned.
- **Non-goals:** no effective-mode logic (C2-T02), no Orchestrator call or API
  (C2-T03), no event (C2-T04), no delivery change (C3). Nothing reads the store
  on the send path until MP-E7-C3 with routing `:listener`.

## Dependencies and blockers

- **DESIGN-E7**, and owner decision **E7-D5** (mode lifetime: per ticket run,
  proposed, or per agent session). This ticket implements the per-ticket-run
  lifetime; if E7-D5 chooses per session, the only change is an extra
  `clear/2` call on session start (named below), so the ticket stays blocked
  until the answer is recorded rather than letting the implementer pick.
- No code predecessor. Successors: MP-E7-C2-T03, MP-E7-C2-T04.
- May run concurrently with MP-E7-C2-T02, MP-E7-C3-T01, MP-E7-C1-*.

## Verified starting point (aiur `45a290e3`)

- **The agent queue is not durable across a daemon restart.**
  `Aiur.AgentQueueStore` is "In-memory queue state" (`src/lib/aiur/agent_queue_store.ex:2-3`)
  and the Orchestrator starts with `queue_store: AgentQueueStore.new()`
  (`src/lib/aiur/orchestrator/state.ex:234`). The `durability: :durable` field
  on items (`src/lib/aiur/agent_queue.ex:21`) does not persist anything. The
  mode store therefore cannot live in the queue; it needs its own file. (This
  corrects MP-E7 plan "Restart" non-happy path and contract §3/§5 wording that
  pending items survive a restart.)
- Closest durable per-issue precedent: `Aiur.SessionHandle`
  (`src/lib/aiur/session_handle.ex:1-30`): JSON sidecar via crash-safe
  `Aiur.JsonStore` (`json_store.ex:33,45` `write!/2`, `read/2`) under
  `Aiur.Config.Paths.runtime_state_dir/0` (`config/paths.ex:243-248`), keyed
  `<repo>.<id>.session.json` (`session_handle.ex:110-115`), `schema_version`
  field, never raises on a bad file (`:20-28`).
- Terminal cleanup hook: `WorkspaceCleanup.cleanup_terminal_issue_artifacts/2`
  calls `clear_session_handle/1` (`orchestrator/workspace_cleanup.ex:21-27`),
  guarded by `TestTicketScope.allowed_identifier?/1` (:29-35); called from
  `orchestrator.ex:391` and `orchestrator/agent_teardown.ex:57`.
- Relevant tests to mirror: `src/test/aiur/session_handle_test.exs`,
  `src/test/aiur/json_store_test.exs`.

## Chosen design

- **Record (JSON, schema_version 1):**

```json
{ "schema_version": 1, "requested": "sync", "version": 3,
  "actor": "human", "idempotency_key": "dash-9f…", "updated_at": "2026-10-06T12:00:00Z" }
```

- **Default:** a missing file is `%{requested: :sync, version: 0, actor: :default, updated_at: nil}`
  (D13). `actor: :default` distinguishes "never changed" from "chosen sync"
  (DESIGN-E7 §3 "Default" state).
- **Decoding:** an unknown mode string decodes to `:sync` (contract §1, Khala
  `m1/listening-mode.ts:18-22`) and is logged once at warning level with the
  identifier; a corrupt or forward-versioned file is treated as the default
  and is **not** deleted (evidence stays for diagnosis), matching
  `SessionHandle.load/3`'s "never raises" rule.
- **CAS:** `put(identifier, mode, expected_version, meta, opts)` returns
  `{:ok, record}` when `expected_version == current.version` (version + 1),
  `{:ok, current}` when `meta.idempotency_key == current.idempotency_key` and
  `mode == current.requested` (idempotent retry), else
  `{:error, {:mode_conflict, current}}`. Invalid mode → `{:error, :invalid_mode}`.
- **Single writer:** the store is a plain module; every write is issued from
  the Orchestrator GenServer (C2-T03), so CAS needs no file lock.
- **Path:** `<runtime_state_dir>/listen-modes/<repo>.<sanitized id>.listen-mode.json`
  via `Paths.repo_name/0` and `Paths.sanitize/1` exactly as
  `session_handle.ex:110-115`. `opts[:dir]` and `opts[:repo_name]` injectable.
- **Lifetime (E7-D5 = per ticket run):** cleared in
  `cleanup_terminal_issue_artifacts/2` beside `clear_session_handle/1`, with the
  same `TestTicketScope` guard. If E7-D5 = per session: also call `clear/2`
  from the session-start path (`State.handle_session_execution_info/3`,
  `orchestrator/state.ex:441-461`).

## Implementation steps

1. Add `src/lib/aiur/listener/mode_store.ex` (~120 lines) with `@spec`s.
2. Add `clear_listen_mode/1` to `orchestrator/workspace_cleanup.ex` and call it from `cleanup_terminal_issue_artifacts/2` (+6 lines).
3. Add `src/test/aiur/listener/mode_store_test.exs` using `tmp_dir`.

## Non-happy paths

- Disk full / write error: `JsonStore.write!/2` raises; `put/5` rescues and
  returns `{:error, {:write_failed, reason}}`; the in-memory caller keeps the
  old record (no partial state).
- Two daemons for one repo: out of scope (instance identity is one instance
  per repository and Executor, brief §3).
- Restart: the file is read lazily on first `get/2`; no boot-time scan.

## Compatibility and rollout

- New file under the runtime state dir; no config key. Rollback: delete the
  module; stale files are harmless and are removed by the next terminal
  cleanup only if the code exists — document `rm <state>/listen-modes/*` in
  the PR body as the manual rollback.

## Verification

```sh
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/listener/mode_store_test.exs test/aiur/orchestrator/workspace_cleanup_test.exs
env -C src mise exec -- make lint
```

Tests (`Aiur.Listener.ModeStoreTest`):

- "missing record reads as default sync with version 0 and actor default".
- "put with matching expected_version stores and increments version".
- "put with stale expected_version returns mode_conflict with the current record" (two sequential writers, one wins).
- "retry with the same idempotency_key and mode returns the stored record without a version bump".
- "unknown stored mode decodes to sync and keeps the file".
- "record survives a fresh read (restart simulation: new process, same dir)".
- `WorkspaceCleanup` test: "terminal cleanup removes the listen-mode file for an allowed identifier".

Mutation checks: drop the version comparison → the conflict test fails;
remove the `clear_listen_mode/1` call → the cleanup test fails; replace the
unknown-mode decode with `:steer` → the decode test fails.

## Completion and handoff

- [ ] Store, tests, cleanup hook merged; `make lint` green.
- [ ] PR body records each mutation result and the exact command.
- Dependents: MP-E7-C2-T03, MP-E7-C2-T04, MP-E7-C3-T02.
- Docs: none (no user-facing surface; `website/docs-app` unchanged).
