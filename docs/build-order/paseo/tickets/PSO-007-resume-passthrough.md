# PSO-007 — Resume passthrough in GenericBackend

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 2 — One handshake branch in the generic adapter, mirroring the codex resume ladder, plus its tests.

**Risk:** low

**Phase hint:** 2

**Depends on:** PSO-001

**Serializes with:** PSO-001 — same file

**External gates:** none

**Requirements:** R10

**Decisions:** DEC-004, DEC-005

**Design evidence:** 00-design.md sections 5, 6, 8; 01-spike-report.md sections 4, 11

**Researched at:** 8199f5373

**Suggested labels:** `complexity:2`, `model:claude`, `phase:2`, `build-lane:paseo-core`; never `agent:todo`

## Outcome

After an aiur restart, an issue on a `paseo-*` backend re-attaches to the same Paseo agent. `Aiur.AppServer.GenericBackend.start_session/2` sends `thread/resume {threadId}` when the runner supplies `resume_thread_id`, marks the session `resumed: true` on success, and degrades to `thread/start` on any miss. The `claude` wrapper never sends `thread/resume` because its registry entry stays `resumable: false`.

## Context and evidence

The behaviour contract for resume lives in `src/lib/aiur/coding_agent/backend.ex` ("Resume contract"): a `resumable: true` backend receives `opts[:resume_thread_id]` and must attempt to rejoin, set `resumed: true` on success, and degrade silently on failure.

The runner side is already generic:

- `Aiur.AgentRunner.SessionResume.load_resume_thread_id/3` (`src/lib/aiur/agent_runner/session_resume.ex:19`) loads the handle only for a resumable backend on the local worker (line 20).
- `maybe_put_resume_thread_id/2` (line 42-44) injects the option; `resolve_session_options/3` (`session_lifecycle.ex:620-657`) calls both.
- `maybe_persist_turn_handle/4` (line 82) and `persist_session_handle/3` (line 115) write `Aiur.SessionHandle` with `backend` and `thread_id` after each turn; `SessionHandle.load/3` (`src/lib/aiur/session_handle.ex`) gates on the same backend and host.

The codex adapter is the template: `Aiur.Codex.Handshake.start_or_resume_thread/5` (`src/lib/aiur/codex/handshake.ex:44-78`) sends `thread/resume`, classifies the outcome with `resume_outcome/2` (lines 82-85) into `:resumed`, `:fresh` (different id returned, treated as clean start with a warning), and `:fallback` (error, then `thread/start`).

`aiur-claude` documents `thread/resume {threadId}` returning `{thread: {id, turns[], cwd, ...}}` (README "Thread management"). The sidecar (PSO-011) answers it by re-attaching to the Paseo agent whose id equals `threadId`, so the returned id equals the requested one on success.

## Scope

- In `src/lib/aiur/app_server/generic_backend.ex`, replace `do_start_session/2` with `do_start_session(port, workspace, launch, opts)`: after `send_initialize/1`, if `opts[:resume_thread_id]` is a binary, send `{"method" => "thread/resume", "id" => @thread_resume_id, "params" => %{"threadId" => id, "cwd" => workspace}}` and classify the reply:
  - `{:ok, %{"thread" => %{"id" => ^id}}}` → `{:ok, id, true}`.
  - `{:ok, %{"thread" => %{"id" => other}}}` → log a warning in the wording of `handshake.ex:60-63` and return `{:ok, other, false}`.
  - `{:error, reason}` → log a warning in the wording of `handshake.ex:65-67`, emit `Aiur.Perf.event(:app_server_resume_fallback, backend:, thread_id:, reason:)`, then `start_thread/…` and `{:ok, id, false}`.
- Set `resumed:` on the session map from that tuple; today the Claude adapter does not set the key, so add `resumed: false` on the fresh path too.
- `@thread_resume_id 4` (or reuse `@thread_start_id` only if the sidecar cannot see two requests in flight; prefer a distinct id).
- Do not send `dynamicTools` on `thread/resume`; the sidecar keeps the tool set from the original start. If the sidecar reports it lost them (error code from PSO-011), fall back to `thread/start`.
- `Aiur.Claude.CodingAgent` wrapper: no change; the registry keeps `resumable: false` for `claude`, so the runner never passes the option.

## Non-goals

- Changing the codex adapter or `SessionResume`.
- Sidecar-side resume (PSO-011).
- Cross-host resume (`SessionHandle.load/3` already refuses).

## Existing owner and reuse target

Extend `Aiur.AppServer.GenericBackend` (PSO-001). Reuse `Aiur.Codex.Handshake.resume_outcome/2` by calling it directly (it is public) rather than duplicating the classification.

## Contract and invariants

- A resume miss never strands an issue: every branch ends in a started thread or the same error `thread/start` would have produced.
- The session handle written after the first turn carries `backend` equal to the registry key (`paseo-claude`) and `thread_id` equal to the Paseo agent id, because the sidecar returns the agent id as the thread id (DEC-004).
- `TurnPrompt.first_turn_mode/2` sees `resumed: true` and issues the continuation prompt rather than the cold-start prompt (verify in `src/lib/aiur/agent_runner/turn_prompt.ex:47`).

### Requirements

- PSO-007-R1. `thread/resume` is sent iff `opts[:resume_thread_id]` is present.
- PSO-007-R2. Same-id reply sets `resumed: true`; different-id reply sets `resumed: false` with a warning; error falls back to `thread/start` with `resumed: false`.
- PSO-007-R3. `SessionHandle` persists the Paseo thread id after the first turn and `load/3` returns it for the same backend key and host.
- PSO-007-R4. The `claude` wrapper never emits `thread/resume`.

## Refreshable implementation notes

- The fake app-server scripts in `src/test/aiur/claude/coding_agent_test.exs:405-480` match on substrings of the incoming line; add a `*'"thread/resume"'*)` case that echoes the scripted reply.
- Use `Rpc.with_timeout_response/5` for the resume reply like `await_response/2` does; a timeout is a `:fallback`.
- Log lines must not include the workspace path or the thread id beyond what codex logs today (`thread_id=` is logged there; keep parity).

### Key technical decisions

- KTD-1. Reuse `Codex.Handshake.resume_outcome/2` rather than a second classifier, so the two app-server adapters agree on what "resumed" means.
- KTD-2. Distinct request id for `thread/resume` so the fake server and the sidecar can distinguish the two handshakes in logs.
- KTD-3. `dynamicTools` are not re-sent on resume; the sidecar keeps them per agent (PSO-011 contract). This keeps the resume frame identical to aiur-claude's documented shape.

## Acceptance and verification

### Agent gate

- `src/test/aiur/app_server/generic_backend_test.exs` additions:
  1. Resumed path: fake answers `thread/resume` with the same id; `session.resumed == true`, `session.thread_id == id`, no `thread/start` frame recorded.
  2. Fresh-id path: fake answers with another id; `resumed == false`, warning logged, `thread_id` is the returned id.
  3. Error path: fake answers a JSON-RPC error; a `thread/start` frame follows and `resumed == false`.
  4. Timeout path: fake ignores `thread/resume`; falls back to `thread/start` within `agent_read_timeout_ms`.
  5. No option: no `thread/resume` frame is sent.
  6. Handle persisted: after `run_turn/4`, `SessionHandle.load(identifier, "paseo-claude")` returns the thread id; `load(identifier, "claude")` returns `:none`.
  7. `Aiur.Claude.CodingAgent.start_session/2` with a stray `resume_thread_id` in opts still sends `thread/start` only (the wrapper drops the option, or the registry gate keeps it out; assert the frame).
- `make all` green.

### At-merge gate

- CI green on the exact head.

### Human/manual evidence

- With PSO-011 landed: restart aiur mid-run on a `model:paseo-claude` issue; `aiur status --json` shows the same Paseo agent id before and after (00-design.md section 12, step 5).

## Failure, security, migration, and accessibility cases

- A handle for a backend that has since been disabled in config is ignored by `load_resume_thread_id/3` because the backend is not resumable-and-dispatchable; verify no crash.
- No secrets; thread ids are opaque agent ids.
- No migration; `SessionHandle` schema unchanged.

## Surfaces

- Reads: `opts[:resume_thread_id]`.
- Writes: `generic_backend.ex`, tests.
- Contracts: `Aiur.CodingAgent.Backend` resume contract; `thread/resume` frame shape in 00-design.md section 6.

## Sibling boundaries and open gates

PSO-001 owns the module this extends. PSO-011 owns the sidecar's `thread/resume` handler and the agent lookup by id. PSO-012 proves the restart path end to end.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the approved planning commit linked in this issue's preamble):

- [Design and decisions](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/00-design.md)
- [Spike report](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/01-spike-report.md)
- [Pack index](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/README.md)
- [Requirements plan](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/plans/2026-09-09-001-feat-paseo-integration-plan.md)
- Your issue's native parent is the Build Order root; native `blockedBy` edges are the dependency graph — the root issue renders the full picture.
