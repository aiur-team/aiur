---
title: "feat: RC read-only follow-along, lossless reverse handoff, default-mode config, handoff bug fixes"
type: feat
status: active
date: 2026-06-08
origin: docs/brainstorms/2026-06-08-rc-dual-surface-handoff-requirements.md
---

# feat: RC read-only follow-along, lossless reverse handoff, default-mode config, handoff bug fixes

## Overview

Simultaneous dual-**chat** is impossible (the `claude` binary binds each session's input queue to one source; see memory `rc-cloud-mediated`). So we keep the `r` toggle and make the surrounding experience as good as the constraint allows:

1. **Read-only follow-along** — while RC is on, aiur's opencode view mirrors the live RC transcript instead of going blank.
2. **Lossless reverse handoff** — pressing `r` to turn RC off spins up a local agent that *resumes the actual RC transcript* (`claude --resume <sessionId>`), not a fresh dispatch.
3. **Default-mode config** — a `.aiurconfig` knob to auto-launch every agent into RC from the start.
4. **Fix the 5 RC handoff bugs**, especially the blocking orphaned-process bug (duplicate PR #252 hazard).

---

## Problem Frame

aiur orchestrates autonomous Claude coding agents. Two execution models: a headless driver (`aiur-claude` → `symphony-claude` app-server → `claude --print … --session-id/--resume`, fed into aiur's opencode chat pane via the HTTP Bridge) and Remote Control (`claude remote-control`, cloud-driven from the Claude app). The `r` key hands an agent between them, today mutually exclusively.

The current handoff is lossy and leaky: forward (local→RC) primes a `CLAUDE.local.md` file with a stale/role-less context, the opencode pane goes blank under RC, the reverse (RC→local) re-dispatches a *fresh* agent discarding the RC conversation, and the outgoing headless `claude` OS process is not reliably killed (it kept running ~2 min and opened a duplicate PR). See origin: docs/brainstorms/2026-06-08-rc-dual-surface-handoff-requirements.md.

---

## Requirements Trace

- R1. Read-only follow-along: while an agent is in RC mode (`remote_control.status in [:launching, :on]`), the opencode pane shows the live RC transcript, updating as it grows; no input affordance; a clear "mirror / read-only" indicator.
- R2. Lossless reverse handoff: on `r`-off, the new local agent resumes the actual RC transcript via `claude --resume <sessionId>`; fall back to fresh re-dispatch if the sessionId is unavailable.
- R3. `agent.default_mode` config (`"opencode"` default | `"remote"`): when `remote`, auto-launch the `r`-on path once the agent has a workspace. Documented tradeoff: no autonomous progress until a human drives it.
- R4. Fix the 5 handoff bugs: (#1) kill the orphaned outgoing `claude` OS process on handoff and confirm it's dead; (#2) receiving forward-RC session has a clear initial task message; (#3) "Recent progress" recomputed fresh at handoff; (#4) explicit "your role now" field; (#5) consistent workpad identity for the handoff session.

**Origin actors:** Operator (drives `r`, follows agents), Dev/integrator (sets `default_mode`).
**Origin flows:** Forward handoff (local→RC), Reverse handoff (RC→local), Follow-along (RC→opencode mirror), Auto-launch (dispatch→RC).

---

## Scope Boundaries

- Not reverse-engineering Anthropic's cloud relay for true dual-chat (infeasible, out of scope).
- No separate "attend" trigger for lazy RC switching — `default_mode=remote` auto-launches at workspace-ready (decided in origin).
- No multi-machine RC — v1 stays local-only; remote `worker_host` agents remain gated out of RC (orchestrator `remote_control_on/2`).
- Follow-along is read-only mirror only; it does not attempt to inject operator input into the RC session.

### Deferred to Follow-Up Work

- Seed `/ce-compound` learnings for the RC handoff-teardown pattern after this lands (`docs/solutions/` does not yet exist in this repo).

---

## Context & Research

### Relevant Code and Patterns

- **Projects-dir / transcript helpers (to extract):** `src/lib/aiur/claude/remote_control.ex` — `workspace_slug/1`, `default_projects_dir/0` (private), `resolve_transcript_path/1`, `newest_transcript/2`, `read_transcript/1`, `transcript_matches_cwd?/2`. No `bridge-pointer.json` reader exists anywhere.
- **Opencode chat pane data flow:** opencode tmux pane (`Aiur.PaneManager.open_conversation/3` from `src/lib/aiur/agent_list/app.ex`) → HTTP Bridge `src/lib/aiur/opencode/bridge.ex` (`POST /v1/chat/completions`) → `src/lib/aiur/opencode/chat_completions.ex` (`stream_codex_turn/3` → `codex_turn_stream_loop/5`, subscribes `AgentPubSub.subscribe_agent/1`, converts `{:transcript_event, %{role:, body:}}` to SSE). Transcript events come from `src/lib/aiur/agent_pubsub.ex` `broadcast_transcript/2`. Persistence/replay: `Aiur.Opencode.SessionWriter`, `replay_message_as_stream/3`.
- **Live-stream open marker (RISK):** the live SSE loop is opened by an `__aiur_turn__:<id>` marker posted by `Aiur.AgentRunner` at turn start. Under RC there is no AgentRunner → no marker. Follow-along must emit synthetic turn markers (open/deltas/done) or rely on SessionWriter replay.
- **Config:** Ecto schema `src/lib/aiur/config/schema.ex` (`Agent` embed is the template: `field` + `cast` list + `validate_*`). Reader pattern in `src/lib/aiur/config.ex` (e.g. `agent_kind/0`). `claude:` settings are ad-hoc via `Config.section("claude")` — but `default_mode` belongs in the validated `Agent` embed, not there.
- **Dispatch / workspace-ready seam:** `src/lib/aiur/orchestrator.ex` `do_dispatch_issue/4` → `dispatch_to_worker/4` → `spawn_issue_on_worker_host/5` (entry built with `workspace_path: nil`); workspace arrives in `handle_info({:worker_runtime_info, issue_id, runtime_info}, …)` (sets `:workspace_path`). RC launch path: `remote_control_on/2` (capability-gated) → `launch_remote_control/2` → `do_launch_remote_control/2`. Reverse: `remote_control_off/2` (currently `do_dispatch_issue(state, issue, nil, nil)` fresh).
- **Process teardown:** `src/lib/aiur/claude/coding_agent.ex` `stop_port/1` (Port.close only), `port_metadata/1` emits `claude_app_server_pid` (string, currently unconsumed). Codex parallel: `codex_app_server_pid` plumbed via `integrate_codex_update/2` + `codex_app_server_pid_for_update/2` (display only, not killed). Kill primitive: `RemoteControl.graceful_kill/1` (integer pid, SIGTERM→2s→SIGKILL).
- **App-server (sibling repo):** `~/github/claude-app-server` = `symphony-claude`. `src/server.ts` `buildClaudeArgs` (~460-481) uses `--session-id` (first turn) / `--resume <cliSessionId>` (continuation) / `--resume … --fork-session` (fork). Per-turn spawn of `claude --print --output-format stream-json`.

### Institutional Learnings

- **`rc-cloud-mediated`** (memory): foundational constraint; `bridge-pointer.json` schema `{sessionId, environmentId, source, pid, procStart}`; both modes write `~/.claude/projects/<slug>/<uuid>.jsonl`. Keep `r` as surface-switch; unify only the read-only VIEW.
- **`feedback_chat_text_latency_root_causes`** (memory): if the mirror shows no text, first rule out (1) label race in `--test` reset and (2) synchronous `__aiur_turn__:` marker fan-out (must be fire-and-forget `Task.start`) before debugging new tail code.
- **`feedback_render_state_takes_explicit`** (memory): new `App` state fields must be added to BOTH `init/1` and the `render/1` `Map.take/Map.put` pipeline or the renderer silently sees defaults.
- **`docs/plans/2026-05-28-001-feat-deactivated-state-plan.md`**: prior art for killing a task while keeping the running entry; use `put_in/3` to mutate entry state and `refresh_tracked_set/1` (excluding the id) so in-flight events from the killed task don't corrupt state — apply the same gate-drop after killing the orphaned driver.
- **`docs/plans/2026-05-25-002-feat-chat-pane-followups-plan.md`** (R5): reap-chain + verification technique (`lsof -p <BEAM pid>`); `Port.close` does NOT kill `:spawn_executable` children — verify the pid is gone after `graceful_kill`.
- **`feedback_perf_logging`** (memory): emit always-on `aiur_perf phase=… elapsed_ms=… wall_ms=… identifier=…` lines for new lifecycle events (follow-along first-render, handoff teardown start/done, orphan-kill confirmed). Never gate on `--debug`.

### External References

- None. Entirely internal aiur + `claude` CLI architecture; no new framework surface.

---

## Key Technical Decisions

- **Shared `Aiur.Claude.Projects` module:** extract the projects-dir/transcript helpers out of `RemoteControl` and add a `bridge-pointer.json` reader, so follow-along (R1) and reverse handoff (R2) share one tested resolver instead of duplicating slug/path logic.
- **Follow-along reuses the AgentPubSub → Bridge path:** a tailer GenServer re-broadcasts new jsonl records, wrapped in **synthetic turn markers** that replicate the full AgentRunner turn protocol (`ActiveTurns.put` + opencode POST of the `__aiur_turn__:` marker + `broadcast_transcript` + `aiur_turn_done`) so the existing SSE loop opens/streams/closes (resolving the no-AgentRunner gap). **Whether `chat_completions.ex` needs changes is a hypothesis to confirm in a pre-implementation spike, NOT a settled decision** — the SSE loop gates on `ActiveTurns.lookup == :active` and `format_delta` (chat_completions.ex:160) does no ANSI/SSE sanitization today, so at minimum sanitization lands somewhere on this path. Exact marker mechanics deferred to implementation.
- **Reverse handoff via `--resume`, with text-handoff fallback:** read `sessionId` from `bridge-pointer.json`; thread a `resume_session_id` through `AgentRunner` → `Claude.CodingAgent` → app-server so it runs `claude --resume <sessionId>`. If sessionId is missing OR resume proves unusable for RC transcripts (see Risks), fall back to the existing fresh re-dispatch (never strand the issue).
- **`default_mode` in the Ecto `Agent` embed:** backend-agnostic, already validated; reader `Config.agent_default_mode/0`. Default `"opencode"` = no behavior change.
- **Auto-launch at workspace-ready, not at spawn:** call `remote_control_on/2` inside the `:worker_runtime_info` handler after `:workspace_path` is set, satisfying the existing `is_nil(workspace_path)` gate and reusing all capability gating.
- **Orphan kill = extract the already-arriving pid + explicit descendant kill:** the port is `bash -lc "aiur-claude …"` (coding_agent.ex:184-196); `bash -c` execs the single command, `aiur-claude` is `exec node …`, so the **captured os_pid is the `node` app-server itself** (one pid via the exec chain, no separate bash parent). The offender is the **`claude --print` child that `node` spawns fresh per turn** and that actually commits/comments/opens PRs; `node` has no `process.on('SIGTERM')` handler, so SIGTERM to `node` reparents the in-flight `claude` child to init and it runs to completion (the duplicate-PR class). So: kill `node`'s descendants (the `claude` child), and **verify the `claude` child is gone**, not just `node`. **Hazard: do NOT blindly `kill -<signal> -<pgid>`** — BEAM port children are not guaranteed to be in their own process group, so a group kill may hit the BEAM's own group and take down aiur. Either spawn the driver in an isolated pgid (`setsid`) first and then group-kill, or enumerate+reap `node`'s descendants by pid (`pgrep -P`/`/proc`). (A symphony-claude-side SIGTERM handler that aborts the active turn is an acceptable alternative for U6.)

---

## Open Questions

### Resolved During Planning

- Reverse-handoff fidelity → lossless `--resume` (origin decision).
- Default-mode semantics → auto-launch RC at workspace-ready (origin decision).
- Where `default_mode` lives → Ecto `Agent` embed (research).
- How follow-along renders without an AgentRunner → synthetic turn markers over the existing AgentPubSub path, but the markers must replicate the full turn protocol (`ActiveTurns.put` + opencode POST + `aiur_turn_done`), not just `broadcast_transcript` (review correction).

### Strategic / Scope — for operator decision (surfaced by doc-review, NOT yet decided)

- **Is `default_mode=remote` worth building?** Its own documented behavior is zero autonomous progress until a human drives it from the Claude app — arguably counter to aiur's autonomous-orchestrator identity, and across multi-slot dispatch it parks N agents waiting on manual attention. No incident/request motivates it (unlike Bug #1). Options: (a) build as planned; (b) drop U7; (c) build but add a loud "parked, awaiting human" indicator + per-issue opt-out. **Recommend (c) or defer.**
- **Is lossless `--resume` (U5/U6 + cross-repo coupling) justified vs. the enriched text handoff (U3)?** U3 already gives task/progress/role/workpad. The marginal fidelity of literal transcript resume may not justify entangling two repos. The U0 gate naturally answers this: if resume forks/refuses, U3 is the answer anyway.
- **Sequencing:** Bug #1/U2 + U3 are the only items with a real incident behind them. Consider shipping U2+U3 first (decoupled), then U0 → (U1/U4/U5/U6/U7) as a second wave gated on the resume spike.
- **U1 module extraction** — `Aiur.Claude.Projects`'s only consumers (U4, U5) are in this same PR; the extraction + delegation wrapper may be premature abstraction. Alternative: add the two new functions directly to `remote_control.ex` and extract later when a third consumer appears. Low stakes; implementer's call.

### Deferred to Implementation

- **`claude --resume` viability + which identifier it accepts** — promoted to the **U0 gate** (blocks U5/U6); verify with a scratch session before building. Fallback is enriched text handoff.
- Exact synthetic-turn-marker format and whether the tailer should also persist via `SessionWriter` for re-attach — depends on observing `ChatCompletions`/`AgentRunner` runtime behavior.
- Whether the app-server needs a new RPC param or can infer resume from an existing `thread/resume` with an external id (U6 detail).
- Exact debounce/poll interval for the jsonl tailer.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

```
r ON (forward)                         r OFF (reverse, lossless)
  build_handoff -> CLAUDE.local.md       Projects.read_bridge_pointer(ws) -> sessionId
  graceful_kill(claude_app_server_pid)   stop RC server (graceful_kill)
  start `claude remote-control`          dispatch local agent w/ resume_session_id=sessionId
  start FollowAlong tailer  ───────┐       app-server: claude --resume <sessionId>
                                   │       (fallback: fresh do_dispatch_issue if no sessionId)
   FollowAlong GenServer           │
     tail ~/.claude/projects/<slug>/<sessionId>.jsonl
     new record -> synthetic turn open
                -> broadcast_transcript(identifier, {role, body})
                -> synthetic turn done
     (opencode pane renders via existing Bridge SSE loop, read-only)

default_mode=remote:
  :worker_runtime_info sets workspace_path -> if remote: remote_control_on/2  (== pressing r)
```

---

## Implementation Units

- [ ] U0. **Resume-viability gate (spike, blocks U5/U6)**

**Goal:** Prove or disprove that a local headless `claude --resume <id>` can load an RC-originated transcript, and determine WHICH identifier it accepts, before any reverse-handoff interface is designed.

**Requirements:** R2 (de-risks)

**Dependencies:** None

**Approach:**
- Against a scratch RC session (NOT the operator's live workspace-99 session): capture `bridge-pointer.json` (`sessionId` = `session_…`) and the on-disk transcript UUID. Run `claude --resume <bridge sessionId>` and `claude --resume <transcript UUID>` in headless `--print` mode and observe: does either load the conversation, and does it CONTINUE the same session or create a divergent fork?
- Record the answer in this plan (and memory). 

**Decision point:**
- **Pass** (a known identifier resumes the real transcript) → build U1 path resolution, U5, U6 on that identifier.
- **Fail** (resume forks or refuses an externally-created session) → **CUT U6, descope U5 to the enriched-text-handoff fallback (U3 already delivers task/progress/role).** The "lossless reverse handoff" headline becomes "enriched text handoff." Surface this branch to the operator rather than discovering it mid-U6.

**Verification:** A resumed turn references an RC-side edit/turn AND reuses the same session id (true resume, not fork).

---

- [ ] U1. **Shared `Aiur.Claude.Projects` resolver + bridge-pointer reader**

**Goal:** One tested module that resolves a workspace to its `~/.claude/projects/<slug>` dir, reads/parses transcripts, and reads `bridge-pointer.json` → `{sessionId, environmentId, source, pid, procStart}`.

**Requirements:** R1, R2

**Dependencies:** None

**Files:**
- Create: `src/lib/aiur/claude/projects.ex`
- Modify: `src/lib/aiur/claude/remote_control.ex` (delegate to the new module; keep existing public behavior)
- Test: `src/test/aiur/claude/projects_test.exs`

**Approach:**
- Move `workspace_slug/1`, `default_projects_dir/0`, `resolve_transcript_path/1`, `newest_transcript/2`, `read_transcript/1`, `transcript_matches_cwd?/2` into `Aiur.Claude.Projects` as public functions; have `RemoteControl` delegate so `build_handoff/1` and its tests keep working.
- Add `read_bridge_pointer/1` (workspace → `{:ok, map} | {:error, reason}`). **Have it validate `sessionId` against the expected format (e.g. `~r/^[A-Za-z0-9_-]+$/`, fixed length) and document which returned fields are log-safe (NOT `sessionId`/`environmentId`) — callers thread `sessionId` into a spawned command (U5) and into log lines, so an unvalidated value is an argument-injection / token-leak vector.**
- **Resolve transcripts by cwd + mtime, NOT by the bridge `sessionId`.** Verified on disk: `bridge-pointer.json`'s `sessionId` is the `session_…` form, while transcript jsonl files are UUID-named and the bridge token appears in **zero** records — so a `transcript_path_for_session/2` keyed on the bridge sessionId has no valid implementation. Expose the existing newest-transcript-by-cwd resolver instead. (Whether `--resume` consumes the bridge token, the UUID, or neither is the U0 gate below.)
- Accept a `projects_dir:` override option (mirror the `transcript_path:` test override already used in `remote_control_test.exs`).
- **Guard against path traversal:** after building the slug path, assert it stays under `projects_dir`/`~/.claude/projects` before any read (workspace paths with `../` must not escape).

**Patterns to follow:** existing private helpers in `remote_control.ex`; `transcript_path:`/`projects_dir:` injection style.

**Test scenarios:**
- Happy path: workspace path → correct slug (`/` and `.` → `-`).
- Happy path: `read_bridge_pointer/1` parses a temp `bridge-pointer.json` into the documented keys.
- Edge case: missing `bridge-pointer.json` → `{:error, :not_found}`; malformed JSON → `{:error, _}`.
- Edge case: `sessionId` failing the format validation → `{:error, _}` (not passed downstream).
- Edge case: workspace path containing `../` → resolved path stays under the projects dir or is rejected (no traversal).
- Edge case: `newest_transcript` picks the newest `.jsonl` whose records' `cwd` matches the workspace; ignores non-matching cwd.
- Edge case: empty projects dir → `{:error, _}` (no crash).

**Verification:** `RemoteControl.build_handoff/1` tests still pass via delegation; new module tests pass.

---

- [ ] U2. **Bug #1 — kill the orphaned outgoing `claude` driver on handoff**

**Goal:** Record the headless `claude` app-server OS pid in the running entry and explicitly `graceful_kill` it during handoff teardown; confirm it's dead.

**Requirements:** R4 (#1)

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur/orchestrator.ex` (extract the pid in `integrate_codex_update/2`; kill the driver's `claude` descendant in `do_launch_remote_control/2`)
- Test: `src/test/aiur/orchestrator_remote_control_test.exs`

**Approach:**
- **The pid already arrives at the orchestrator — only the extraction clause is missing.** Verified: `emit_message(:session_started, …, metadata)` (coding_agent.ex:837-839) merges `claude_app_server_pid` (from `port_metadata/1`) into the message; `codex_message_handler` → `send_codex_update` → `{:codex_worker_update, issue_id, message}` (agent_runner.ex:220-226, 319-322) delivers it to the orchestrator; `integrate_codex_update/2` (orchestrator.ex:3974-4001) then calls `codex_app_server_pid_for_update/2`. **But that function (orchestrator.ex:4004-4015) only pattern-matches the `:codex_app_server_pid` key — the `:claude_app_server_pid` key falls through to the `(existing, _update)` no-op clause and is silently dropped.** Fix = add a clause matching `%{claude_app_server_pid: pid}` (mirroring the existing codex clauses, with the same binary/integer/list coercion) so the pid is stored in the running entry. No new message channel and no `coding_agent.ex`/`agent_runner.ex` change is needed — do NOT "add the update path."
- In `do_launch_remote_control/2`, the current order is `write_remote_control_handoff` (orchestrator.ex:3716) → `terminate_task(pid)` (3723); `terminate_task` kills only the AgentRunner BEAM process, and `Port.close` does NOT kill the OS `node`/`claude` descendants (this is the orphan). After `terminate_task` and the monitor flush, if a `claude_app_server_pid` is present, **kill `node`'s `claude` descendant** (see Key Technical Decisions — the os_pid is `node`, the offender is its `claude --print` child; do not blind-kill a process group that may include the BEAM). `RemoteControl.graceful_kill/1` only handles a single pid today, so either reap descendants by pid or isolate the pgid first. **Before killing, verify pid ownership** (compare against the bridge-pointer `procStart`, or check `/proc/<pid>/cmdline` contains `node`/`claude`) to avoid SIGKILLing a recycled pid; bound the pid (reject `<= 1`). **Clear `:claude_app_server_pid` from the entry on normal port close/exit** so a stale pid is never carried into a later handoff.
- Apply the deactivated-state gate-drop: ensure `refresh_tracked_set/1` excludes the id so in-flight events from the just-killed driver don't pass the publisher gate (prevents the duplicate-comment/PR class). Note the residual window: events already dispatched at the publisher before the refresh are not retroactively gated.
- Emit `aiur_perf` lines: teardown start/done, orphan-kill confirmed. **Do NOT log `sessionId`, `environmentId`, or anything derivable from the RC session URL (capability token); use `issue_id` as the identifier.**

**Patterns to follow:** `docs/plans/2026-05-28-001-feat-deactivated-state-plan.md` (kill-task-keep-entry); the existing `codex_app_server_pid_for_update/2` clauses (orchestrator.ex:4004-4015) — add a `:claude_app_server_pid` sibling clause; `RemoteControl.graceful_kill/1`.

**Test scenarios:**
- Unit: a `:codex_worker_update` carrying `%{claude_app_server_pid: pid}` stores the pid in the running entry (today it is dropped — this is the regression-anchoring test).
- Happy path: handoff with a known `claude_app_server_pid` kills the driver's `claude` descendant (assert via an injected kill seam / captured pid).
- Edge case: `claude_app_server_pid` nil → no kill attempted, handoff still succeeds.
- Edge case: stale/recycled pid — ownership check fails → no kill, warning logged.
- Integration: after handoff, the running entry has `pid: nil`, `ref: nil`, RC `:launching`, and the app-server pid is cleared.
- Regression: events arriving from the killed driver after teardown do not re-dispatch or post (gate-drop holds).

**Verification:** With a real spawned child in a manual run, the **`claude --print` grandchild** (not just the node parent) is gone after handoff (`pgrep -P`/`ps --ppid` to confirm no surviving descendant); no duplicate PRs/comments.

**Execution note:** Manual repro first (per bug-fix TDD), then a failing test, then the fix.

---

- [ ] U3. **Forward handoff enrichment — bugs #2/#3/#4/#5**

**Goal:** The forward-RC `CLAUDE.local.md` reliably gives the receiving session a clear initial task (#2), fresh progress (#3), an explicit role line (#4), and a consistent workpad identity (#5).

**Requirements:** R4 (#2, #3, #4, #5)

**Dependencies:** None. (Not a hard U1 dependency — `build_handoff/1` already self-resolves the transcript via `resolve_transcript_path` → `newest_transcript`. If U1 lands first, delegate; otherwise U3 stands alone.)

**Files:**
- Modify: `src/lib/aiur/claude/remote_control.ex` (`build_handoff/1`, `write_remote_control_handoff` caller in `orchestrator.ex`)
- Test: `src/test/aiur/claude/remote_control_test.exs`

**Approach:**
- #3: **Verify the bug before coding the fix (bug-fix TDD).** `build_handoff/1` (remote_control.ex:276-286) ALREADY recomputes "Recent progress" live from `newest_transcript` — there is no cached snapshot, so the "stale progress" framing is suspect. The concrete candidate root cause is the call order: `write_remote_control_handoff` (orchestrator.ex:3716) runs BEFORE `terminate_task` (3723), so an in-flight headless turn's last output may not be flushed to the jsonl when the handoff is read. Manually reproduce, confirm which (if either) is the real cause, then fix — do not assume a cache exists.
- #2: ensure a non-empty initial task/instruction block is always present (derive from the issue + latest transcript turn).
- #4: add a "Your role now" line stating the receiving agent's current responsibility.
- #5: include a stable workpad identity convention for the handoff session. **Undefined in both origin and plan — resolve before implementing: what IS the workpad identity (workspace path? slug? a UUID written into `CLAUDE.local.md`?). Without a concrete definition the #5 test passes trivially.** Proposed: reuse the workspace slug already used for the projects dir so follow-along and handoff share one identity.
- Keep the `<<<AIUR_HANDOFF_DATA` fencing for untrusted transcript content.

**Patterns to follow:** existing `build_handoff/1` structure and fencing.

**Test scenarios:**
- Happy path: handoff text contains the issue task, a fresh progress snippet (reflecting the newest transcript), a role line, and the workpad identity.
- Edge case: empty/missing transcript → handoff still contains task + role (no crash, no empty inbox).
- Edge case: transcript with embedded newlines/code fences stays fenced and doesn't break the markdown structure.

**Verification:** Inspecting `CLAUDE.local.md` after a forward handoff shows all four fields populated and current.

---

- [ ] U4. **Read-only follow-along tailer (R1)**

**Goal:** While RC is on, mirror the live RC transcript into the opencode pane (read-only) by tailing the session jsonl and re-broadcasting via AgentPubSub.

**Requirements:** R1

**Dependencies:** U1

**Files:**
- Create: `src/lib/aiur/claude/follow_along.ex` (GenServer tailer)
- Modify: `src/lib/aiur/orchestrator.ex` (start tailer on RC-on in `do_launch_remote_control/2`; stop on RC-off/teardown)
- Modify: `src/lib/aiur/agent_list/app.ex` and `src/lib/aiur/agent_list/renderer.ex` (read-only "mirror" indicator; plumb new state field through BOTH `init/1` and `render/1`)
- Test: `src/test/aiur/claude/follow_along_test.exs`, `src/test/aiur/agent_list/` (indicator render)

- Tailer resolves the session jsonl via `Projects` (newest transcript by cwd — the bridge `sessionId` does not name the jsonl; see U1), and polls/`:file` watches for new records.
- **The "synthetic turn markers" are NOT just `broadcast_transcript` calls** — the SSE loop in `chat_completions.ex` gates on `ActiveTurns.lookup(identifier, turn_id) == :active` (else it closes immediately with `:not_found`) and closes ONLY on `{:aiur_turn_done, identifier, turn_id, reason}`. So per synthetic turn the tailer must replicate the full `AgentRunner` protocol: (1) `ActiveTurns.put(identifier, synthetic_turn_id)`, (2) POST the `__aiur_turn__:<id>` marker to each attached opencode-serve session (this is what opens the SSE back to the bridge), (3) `broadcast_transcript(identifier, {role, body})` deltas, (4) broadcast `{:aiur_turn_done, identifier, synthetic_turn_id, :done}`. **Treat "chat_completions.ex needs no changes" as a hypothesis to confirm in a pre-implementation spike, not a settled decision.** Decide turn granularity (one synthetic turn per RC turn, not per record) so the SSE closes promptly instead of riding the 10-minute watchdog. If this proves brittle, fall back to `SessionWriter` replay (post-hoc render of completed turns), which needs no live-stream protocol.
- **Sanitize `body` before broadcasting (must-do, not conditional)** — strip/escape ANSI control sequences and SSE frame delimiters. RC transcript content is agent-generated (cloud-influenced) and flows verbatim into the TUI renderer. Verified: `chat_completions.ex`'s `format_delta` (chat_completions.ex:160) does NO sanitization today, so the mirror path is currently unguarded — sanitize in the tailer before broadcast (or add it to `format_delta`, but then audit every existing producer for behavior change).
- Mark the pane/row read-only in state so no input affordance is shown while RC owns the queue.
- Emit `aiur_perf` first-render line (no session URL / sessionId in the line).
- Marker fan-out must be fire-and-forget (`Task.start`) per the chat-latency learning.
- Ensure the tailer is stopped on RC-off/teardown so it cannot outlive its RC session and broadcast stale content into the wrong pane.

**Patterns to follow:** `agent_pubsub.ex` `broadcast_transcript/2`; AgentRunner turn-marker shape; render-state two-step plumbing (`feedback_render_state_takes_explicit`).

**Test scenarios:**
- Happy path: appending a user+assistant record pair to the tailed jsonl broadcasts matching `{:transcript_event, …}` messages to a subscriber.
- Edge case: tailer started when the jsonl doesn't exist yet → waits, then picks it up on creation (RC transcript appears only after a cloud client connects).
- Edge case: partial/rolling writes (incomplete trailing line) don't crash or double-emit.
- Edge case: stopping the tailer on RC-off halts broadcasts; no leak after teardown.
- Render: an RC-mode row/pane shows the read-only mirror indicator and no input affordance; a headless row does not.

**Verification:** Manual — `r` on a live agent shows the RC conversation streaming read-only in opencode.

---

- [ ] U5. **Lossless reverse handoff wiring in aiur (R2)**

**Goal:** On `r`-off, resume the actual RC transcript in a new local agent instead of a fresh dispatch.

**Requirements:** R2

**Dependencies:** U0 (resume-viability gate — see Open Questions), U1. **U6 is a SOFT dependency, not hard:** U5 ships and works via the fresh-dispatch fallback whether or not U6 is deployed; the `--resume` path goes live only once U6 lands. Do not block U5's merge on U6.

**Files:**
- Modify: `src/lib/aiur/orchestrator.ex` (`remote_control_off/2`: read sessionId, pass `resume_session_id` into re-dispatch; fallback to fresh)
- Modify: `src/lib/aiur/agent_runner.ex` and `src/lib/aiur/claude/coding_agent.ex` (thread `resume_session_id` to the app-server command)
- Modify: `src/lib/aiur/claude/config.ex` / spawn path (add a test injection seam for the resume command, mirroring `:remote_control_command`)
- Test: `src/test/aiur/orchestrator_remote_control_test.exs`

**Approach:**
- In `remote_control_off/2`, before re-dispatch: `Projects.read_bridge_pointer(workspace)` → the resume identifier (**which identifier `--resume` actually accepts — bridge `sessionId`, transcript UUID, or neither — is the U0 gate; the bridge token does not name the jsonl, so do not assume it is the resume key**); tear down the RC server (existing `stop_running_remote_control`), then dispatch the local agent carrying `resume_session_id`.
- Thread the option through `AgentRunner` → `Claude.CodingAgent` so the app-server is told to resume that external session id (consumes U6). **Validate the id (U1 format check) before it reaches the spawned command — argument-injection guard.**
- Fallback: if no/invalid sessionId (or U6 unavailable, or U0 failed), keep current `do_dispatch_issue(state, issue, nil, nil)` fresh dispatch. **Surface the fallback to the operator (UI indicator/log) so a silent degrade to a fresh agent is visible.**
- Reverse handoff continues to delete `CLAUDE.local.md` as today — the resume path replaces the **reverse** text-priming. This does NOT conflict with U3: forward handoff still writes the enriched `CLAUDE.local.md`; reverse handoff consumes-then-deletes it.

**Patterns to follow:** existing `remote_control_off/2`; `maybe_put_rc_command/1` injection seam.

**Test scenarios:**
- Happy path: `r`-off with a readable `bridge-pointer.json` dispatches a local agent whose spawn carries `resume_session_id=<sessionId>` (assert via injected command capture).
- Edge case: missing/malformed bridge-pointer → falls back to fresh dispatch; issue is not stranded.
- Integration: after `r`-off, running entry has RC cleared and a live local driver pid; the resumed agent's first transcript references prior RC turns (manual).

**Verification:** Manual — after `r`-off, the local agent answers a follow-up that depends on RC-side context/edits.

---

- [ ] U6. **app-server: resume an externally-supplied session id (R2)**

**Target repo:** `claude-app-server` (`its-everdred/claude-app-server`, local at `~/github/claude-app-server`)

**Goal:** Let aiur start a thread that resumes an external `cliSessionId` so the driver runs `claude --resume <sessionId>`.

**Requirements:** R2

**Dependencies:** **U0 (resume-viability gate) — do NOT design this unit's RPC/param interface until U0 proves `--resume` loads an RC transcript with a known identifier.** If U0 fails, U6 is CUT and U5 ships on the text-handoff fallback. (U5 consumes U6 when present.)

**Bonus (optional, ties to U2):** since this repo owns the per-turn `claude --print` spawn, add a `process.on('SIGTERM')` handler that aborts the active turn (`proc.kill` already exists per-turn at server.ts ~304/394). That gives aiur a clean way to reap the grandchild on handoff instead of relying solely on a process-group kill.

**Files:**
- Modify: `src/server.ts` (`buildClaudeArgs` and the thread start/resume RPC handling)
- Modify: `src/protocol.ts` / `src/types.ts` (param to carry an external resume session id) if needed
- Test: app-server's existing test harness (`test-client.mjs` / `test-real.mjs` pattern)

**Approach:**
- Add a way (new param on thread start, or a `thread/resume`-with-external-id path) for the caller to supply a `cliSessionId` that isn't one this server created, so the first turn emits `--resume <id>` instead of `--session-id <new>`.
- Keep existing fork/continuation behavior unchanged.

**Patterns to follow:** existing `buildClaudeArgs` `--resume`/`--fork-session` branches (server.ts ~460-481); existing thread/start, thread/resume RPCs.

**Test scenarios:**
- Happy path: starting a thread with an external resume id produces `claude … --resume <id>` args.
- Edge case: no resume id → unchanged `--session-id` first-turn behavior.
- Regression: fork and same-thread continuation still build the correct args.

**Verification:** A turn against a pre-existing session id continues that conversation (manual, against a real prior session).

**Execution note:** First manually verify `claude --resume <RC-sessionId>` loads an RC-originated transcript at all (see Risks) before finalizing this unit's interface.

---

- [ ] U7. **`agent.default_mode` config + auto-launch RC at workspace-ready (R3)**

**Goal:** New `.aiurconfig` setting; when `remote`, auto-run the `r`-on path once the agent has a workspace.

**Requirements:** R3

**Dependencies:** None. (Auto-launch fires when the agent first gets a workspace and has never been headless, so it does NOT go through U2's handoff-teardown path — the prior U2 dependency was spurious.)

**Files:**
- Modify: `src/lib/aiur/config/schema.ex` (`Agent` embed: `field(:default_mode, :string, default: "opencode")`, add to `cast`, `validate_inclusion(:default_mode, ["opencode", "remote"])`)
- Modify: `src/lib/aiur/config.ex` (`agent_default_mode/0` reader)
- Modify: `src/lib/aiur/orchestrator.ex` (`:worker_runtime_info` handler: after `:workspace_path` set, if `agent_default_mode()=="remote"` and not already RC, call `remote_control_on/2`)
- Modify: `src/test/support/test_support.exs` (`write_workflow_file!/2`: write `default_mode` into the agent section)
- Test: `src/test/aiur/workspace_and_config_test.exs`, `src/test/aiur/orchestrator_remote_control_test.exs`

**Approach:**
- Schema field + reader following the `:kind`/`agent_kind/0` template. (Confirm the `Agent` embed accepts a new field without a migration and won't reject existing `.aiurconfig` files on parse/rewrite.)
- Auto-launch in the `:worker_runtime_info` handler (workspace guaranteed present there); discard `remote_control_on/2`'s reply, keep its new state.
- **Guard against double-fire:** `:worker_runtime_info` has no idempotency and may arrive twice (re-emit/reconnect). Check `remote_control_active_entry?` before invoking `remote_control_on/2` so a second message doesn't re-run teardown. This guard belongs in U7's code path, not just System-Wide Impact.
- Document the autonomy tradeoff in the config docs/comment.

**Patterns to follow:** `Agent` embed `:kind`; `Config.agent_kind/0`; `remote_control_on/2` gating.

**Test scenarios:**
- Happy path (schema): `.aiurconfig` with `agent.default_mode: "remote"` parses; `Config.agent_default_mode/0` returns `"remote"`.
- Edge case: unset → defaults to `"opencode"`; invalid value → changeset validation error.
- Integration: with `default_mode=remote`, a dispatched agent receiving `:worker_runtime_info` transitions into RC (`remote_control_on/2` invoked once); with `opencode`, it does not.
- Edge case: two `:worker_runtime_info` messages for a remote-default agent invoke `remote_control_on/2` exactly once (double-fire guard).
- Edge case: `default_mode=remote` but backend/worker_host makes RC unsupported → stays headless (gating respected), no crash.

**Verification:** Manual — set `default_mode=remote`, dispatch an issue, confirm it launches into RC with follow-along.

---

## System-Wide Impact

- **Interaction graph:** `:worker_runtime_info` handler now branches into RC launch; `do_launch_remote_control/2` now also kills the app-server pid and starts the follow-along tailer; `remote_control_off/2` now reads bridge-pointer and threads resume.
- **Error propagation:** bridge-pointer read failure and resume-unavailable both fall back to fresh dispatch (never strand an issue); kill failures are logged but don't block handoff.
- **State lifecycle risks:** orphaned driver events post-teardown (mitigated by gate-drop); tailer leaks on teardown (explicit stop); duplicate launch if `:worker_runtime_info` fires twice (guard on `remote_control_active_entry?`).
- **API surface parity:** `claude_app_server_pid` now plumbed like `codex_app_server_pid`; keep dashboard display consistent.
- **Integration coverage:** auto-launch (config→dispatch→RC), follow-along (jsonl→PubSub→SSE), reverse handoff (bridge-pointer→resume) each cross layers and need integration-level tests, not just mocks.
- **Unchanged invariants:** `r` toggle semantics, forward-RC via `CLAUDE.local.md` (enriched, not replaced), remote-`worker_host` RC gating, default behavior when `default_mode` unset.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| `claude --resume` may not load an RC transcript, or the bridge `sessionId` may be the wrong identifier (it names no jsonl on disk) | **U0 gate** resolves both before U5/U6 are built; on failure, cut U6 and descope U5 to enriched text handoff |
| Orphan kill hits the bash/node parent, not the `claude --print` grandchild that opens duplicate PRs | Kill the process group (or add a symphony-claude SIGTERM handler, U6 bonus); verify the grandchild is gone, not the parent |
| Follow-along SSE won't open/close without the full turn protocol (`ActiveTurns.put` + opencode POST + `aiur_turn_done`), not just `broadcast_transcript` | U4 replicates the AgentRunner protocol; "no changes to chat_completions" is a hypothesis to confirm; SessionWriter-replay fallback |
| Killing a stale/recycled pid (pid reuse between capture and kill) | Verify pid ownership (`procStart`/`/proc/<pid>/cmdline`) before kill; clear `:claude_app_server_pid` on normal port close |
| `sessionId` from a file injected into a spawned command / leaked into logs | U1 format-validates `sessionId`; never log `sessionId`/`environmentId`/session URL; pass as a distinct argv element |
| Untrusted RC jsonl content rendered verbatim in TUI | Sanitize ANSI/SSE sequences in `body` before broadcast (or confirm `chat_completions.ex` already does) |
| RC transcript jsonl appears only after a cloud client connects | Tailer tolerates a missing file and starts on creation |
| New `App` state fields silently default in renderer | Two-step `init/1` + `render/1` plumbing per learning; renderer test asserts the indicator |
| App-server change ships in a sibling repo | U6 is a SOFT dependency; U5 falls back to fresh dispatch until U6 is deployed (don't send `resume_session_id` to an old app-server that silently ignores it → split-brain; gate the resume path on a deployed-U6 signal) |

---

## Documentation / Operational Notes

- Document `agent.default_mode` in the `.aiurconfig` reference, including the "no autonomous progress until driven" tradeoff for `remote`.
- Add `aiur_perf` lines for follow-along first-render, handoff teardown start/done, and orphan-kill confirmation. **These lines MUST NOT include `sessionId`, `environmentId`, or any value derivable from the RC session URL (capability token) — use `issue_id` as the identifier.**
- **Log-leak audit (done):** the existing `Logger.info(… session_id=…)` lines in `agent_runner.ex` (e.g. :441, :469) print the *headless turn id* (`thread_id-turn_id` from `coding_agent.ex`), NOT the RC session URL or the bridge `sessionId`/`environmentId` — they are not the capability-token leak vector and need no change. The leak vector to avoid in NEW code is logging the RC `session_url`, bridge `sessionId`, or `environmentId`.

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-06-08-rc-dual-surface-handoff-requirements.md](docs/brainstorms/2026-06-08-rc-dual-surface-handoff-requirements.md)
- Related code: `src/lib/aiur/claude/remote_control.ex`, `src/lib/aiur/orchestrator.ex`, `src/lib/aiur/opencode/chat_completions.ex`, `src/lib/aiur/config/schema.ex`, `src/lib/aiur/claude/coding_agent.ex`
- Prior plans: `docs/plans/2026-05-28-001-feat-deactivated-state-plan.md`, `docs/plans/2026-05-25-002-feat-chat-pane-followups-plan.md`
- Memory: `rc-cloud-mediated`, `feedback_chat_text_latency_root_causes`, `feedback_render_state_takes_explicit`, `feedback_perf_logging`
