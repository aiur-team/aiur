---
ticket_id: MP-E3-C1-T01
feature_id: MP-E3
chunk_id: MP-E3-C1
bucket: 2-platform
title: "Executor session binding store: one opt-in attached session per instance, with generation and takeover"
status: blocked
blocked_by: [DESIGN-E3, MP-E4-C1-T02]
prior_units: [U3]
prior_boundaries: [EXE]
prior_features: [MP-E4 (journal), MP-R1 (instance_id)]
prior_findings: [MP-E3 plan §4.3; contract conversations-transcripts-anchors §3-§4]
size_owner: n/a (new module under src/lib/aiur/executor/)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E3-C1-T01 — Executor session binding store

## Identity and outcome

- Bucket 2 · MP-E3 · C1 · T01.
- **User value:** aiur knows which external Claude Code or Codex session is "the
  Executor" for this instance, only after the operator opts in, and never mixes
  two sessions into one conversation.
- **Deliverable:** `Aiur.Executor.Session` — a durable binding record with
  `attach/1`, `bind_provider_session/2`, `touch/2`, `detach/2`, `current/0`,
  a single-binding rule with explicit takeover, and a liveness TTL. MP-E7-C6-T01
  consumes `current/0`, `binding_id`, `generation`, `provider_session_id`.
- **Non-goals:** the hook endpoint (T02), the CLI (T03), reading transcripts (C2).

## Dependencies and blockers

- **DESIGN-E3** (opt-in story, terminology "attached/detached", takeover from
  CLI only or also dashboard — OQ-E3-5).
- MP-E4-C1-T02 (the binding opens and ends Executor journal sessions through
  `Aiur.Conversation.Ingest`).
- Concurrent with: MP-E3-C1-T02 (agree the record fields first).

## Verified starting point

- The Executor today is only a wake-stream consumer: `id`, `role`, `host`,
  OS `pid`, lease times, ack counts — no harness, session id or transcript path
  (`src/lib/aiur/executor/claims.ex:309-325`). Consumer id resolution:
  `--as`, then `AIUR_EXECUTOR_ID`, then `<hostname>-<instance>`
  (`claims.ex:180-193`).
- Claims rule this ticket mirrors: "taking the stream from a live, renewing owner
  is refused and names the current owner; revoking is explicit"
  (`claims.ex:18-20`); lease TTL 600,000 ms (`claims.ex:53`).
- Durable executor state dir: `Aiur.Executor.StatePaths.dir/0` — per
  **repository** (`~/.aiur/repo/<owner>/<repo>/executor`), override
  `:executor_state_dir` (`executor/state_paths.ex:33-45`). Two instances of the
  same repository share it, so the binding file name must include the instance
  key (`AIUR_INSTANCE_KEY`, as `claims.ex:477-481` reads it).
- Atomic JSON write: `Aiur.JsonStore.write!/2` (temp file, fsync, rename;
  `json_store.ex:25-37`).

## Chosen design

PROPOSED `src/lib/aiur/executor/session.ex` (GenServer, single owner of the file
inside one daemon) with record at
`StatePaths.dir() <> "/#{Paths.repo_name()}.#{instance_key}.executor.session.json"`
(mode 0600; directory created by `StatePaths.ensure/0`):

```json
{ "v": 1, "binding_id": "exb_<random 16 bytes base32>", "generation": 3,
  "harness": "claude | codex", "state": "awaiting_first_hook | attached | detached",
  "provider_session_id": "string or null", "transcript_path": "server-only or null",
  "locator_hash": "sha256 hex or null", "cwd": "string or null",
  "consumer_id": "string or null", "attached_at": "ISO8601", "last_hook_at": "ISO8601 or null",
  "takeover_armed": false, "detached_at": null, "end_reason": null,
  "transcript_offset": 0 }
```

| Call | Effect |
| --- | --- |
| `attach(%{harness, consumer_id, takeover?})` | No live binding → new `binding_id`, `generation + 1`, `awaiting_first_hook`. Live binding (state `attached` and `last_hook_at` within TTL) → `{:error, {:already_attached, summary}}` unless `takeover?` → `takeover_armed: true` on the new record and old session ended `superseded`. |
| `bind_provider_session(binding_id, hook)` | First hook in `awaiting_first_hook`, or a hook whose `session_id` equals the bound one, or any session while `takeover_armed` → record `provider_session_id`, `transcript_path`, `locator_hash = sha256(path)`, `cwd`, state `attached`. A different session while live and not armed → `{:error, :foreign_session}` (counted; T03 shows it). |
| `touch(binding_id, at)` | `last_hook_at`; never more often than once per second to the file. |
| `rebind_on_session_start(binding_id, hook)` | `SessionStart` with `source` `clear | compact | resume | fork` from the same Claude process → new provider session id accepted; journal session ends, a new one opens with that `start_reason` (contract §4). |
| `detach(binding_id, reason)` | state `detached`, `end_reason`, `Ingest.end_session(Ref.executor(), sid, reason)`. |
| `current()` | `{:ok, binding} \| :none`; `binding.live?` computed from TTL. |
| `record_offset(binding_id, offset)` | used by C2 to resume the transcript tail. |

- **TTL:** 600,000 ms, the claims lease (`claims.ex:53`), via
  `Application.get_env(:aiur, :executor_session_ttl_ms, 600_000)`.
- **Inferred end:** a binding with no hook for > TTL is reported
  `live?: false`; it is ended `detached` with `end_reason: "detached"`
  (labelled inferred) only when a new attach or session arrives.
- `transcript_path` never leaves the daemon (contract §12): `current/0`'s public
  projection (`Session.public/1`) drops it and keeps `locator_hash`.

## Implementation steps

1. Module + record codec + `public/1`.
2. Child under the existing Executor recording children (next to
   `Aiur.Executor.Claims` in `src/lib/aiur.ex`, after the Exchange; find it by
   `git grep -n "Executor.Claims" -- src/lib/aiur.ex` at pickup).
3. Journal integration: on `bind_provider_session` and `rebind…`, nothing is
   appended yet (C2 appends entries; the writer opens sessions from the source
   key). On `detach`/takeover, `Ingest.end_session/3`.

## Non-happy paths

- **Two daemons, same repository, different checkouts:** different
  `AIUR_INSTANCE_KEY` → different files; no cross-talk.
- **Empty `AIUR_INSTANCE_KEY`** (allowed shared-identity override): `attach`
  refuses with `:missing_instance_key` (the decision-state rule,
  `config/paths.ex:330-335`), because a shared binding would merge two
  Executors.
- **Corrupt file:** `JsonStore.read/2` error → treated as no binding, file
  renamed `.corrupt-<ts>` (kept, never deleted), one warning log.
- **Hook arriving after detach:** `:not_attached`, counted.
- **Clock jumps:** TTL is wall-clock like claims; worst case a live session reads
  stale until the next hook.

## Compatibility and rollout

- Inert until `aiur executor-attach` (T03). No config key (TTL override is an
  `Application` env for tests only). Rollback: revert; delete the file by hand.

## Verification

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/executor/session_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "second attach while live is refused and names the live binding" | `{:error, {:already_attached, %{binding_id: _, harness: _, last_hook_at: _}}}` | live check |
| "takeover ends the old session superseded" | journal end line `superseded`; new generation | takeover branch |
| "foreign session hook while live is refused" | `{:error, :foreign_session}` | session-id comparison |
| "SessionStart clear from the same binding opens a new journal session" | new session `start_reason: clear` | rebind clause |
| "restart reloads the binding" (stop/start the GenServer) | same `binding_id`, `generation` | file persistence |
| "public projection has no transcript_path" | key absent, `locator_hash` present | `public/1` |
| "binding older than TTL is not live" (TTL 10 ms) | `live?: false` | TTL rule (mutation: always live fails) |
| "empty instance key refuses attach" | `{:error, :missing_instance_key}` | guard |

Tests set `:executor_state_dir` and `:conversation_state_dir` to temp dirs.

## Completion and handoff

- [ ] Module and tests merged; record fields match what MP-E7-C6-T01 expects.
- Dependents: MP-E3-C1-T02, MP-E3-C1-T03, MP-E3-C2-T01, MP-E3-C4-T01, MP-E7-C6-T01.
- Docs: in MP-E3-C1-T03 (CLI) and MP-E3-C7-T02 (concepts).
