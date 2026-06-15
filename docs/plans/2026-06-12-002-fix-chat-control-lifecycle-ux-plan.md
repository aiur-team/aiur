---
title: "fix: Chat, control & lifecycle UX (7 issues)"
type: fix
status: active
date: 2026-06-12
origin: docs/brainstorms/2026-06-12-chat-control-lifecycle-ux-requirements.md
deepened: 2026-06-12
---

# fix: Chat, Control & Lifecycle UX (7 issues)

## Overview

Seven operator-facing fixes on branch `kevin/repl-dualchat` (PR #256): standard
chat queue semantics via segmented turn streams, a pause that actually stops
the agent, a centralized process reaper so closing aiur always kills agents,
Ctrl+C 3-state verification + a Ctrl+Q close-without-pause key, reopen-
reattach, remote-message attribution verification, ticket-212 cleanup, and the
agent-list `??????` flicker.

**Ordering is deliberate: the complex/high-value units come first** (U1-U4) so
that if a session ends early, the remaining units (U5-U10) are small,
self-contained, and safe for a later/cheaper session to pick up independently.
(The 7 operator-reported issues map onto 10 implementation units — several
issues split into a build unit plus a verification unit.)

---

## Problem Frame

See origin doc (`docs/brainstorms/2026-06-12-chat-control-lifecycle-ux-requirements.md`)
— it contains the full verified research basis with file:line citations. Key
facts the implementer must internalize before starting:

1. The opencode bridge holds ONE SSE open per autonomous agent turn
   (`stream_codex_turn/3` in `src/lib/aiur/opencode/chat_completions.ex`).
   opencode will not send typed user input while its completion request is in
   flight; it queues it TUI-locally (QUEUED badge), invisible to aiur. That —
   not the codex wrapper — is why operator messages stall. **No codex-wrapper
   rewrite is needed**: codex already injects aiur-queued messages mid-turn at
   safe checkpoints (`safe_checkpoint_handler/2` in
   `src/lib/aiur/agent_runner.ex`), and claude-repl types them into the live
   REPL immediately (`await_turn/6` in `src/lib/aiur/claude/repl_agent.ex`).
2. Codex handles `{:pause_agent, _}` mid-turn (receive_loop in
   `src/lib/aiur/codex/coding_agent.ex` → JSON-RPC `turn/interrupt` →
   `{:paused, …}`), but **claude-repl's `await_turn/6` has no `{:pause_agent}`
   clause** — pause requests rot in the Task mailbox until the turn ends.
3. Shutdown cleanup spans six layers; REPL/headless subtrees are reaped
   (`kill_repl_session/1` in `src/lib/aiur/orchestrator.ex`), but codex
   app-server grandchildren rely on `stop_port/1`
   (`src/lib/aiur/codex/coding_agent.ex`) which only runs on graceful
   turn-completion paths. Brutal kills orphan them. This is the recurring
   "agents survive aiur exit" bug.
4. Ctrl+C 3-state is already implemented for both backends
   (`pane_interrupt_action/2` + `pane_interrupt_action_no_pane/2` in
   `src/lib/aiur/orchestrator.ex`, helper `scripts/aiur-pane-ctrlc`, tmux
   binding in `scripts/aiur.tmux.conf`). Remaining work is verification,
   gap-fixing, Ctrl+Q, and reopen-reattach — NOT a rebuild.
5. Remote-origin attribution was fixed in commit `3901217`
   (`queued_command` attachment → `origin: :remote` →
   `SessionWriter.write_user_message`); the suspected residual gap is the
   idle-agent path where claude may write a plain `type:"user"` record that
   carries no origin tag and is currently dropped.

---

## Requirements Trace

From origin doc: R1 (212 cleanup), R2 (flicker), R3-R5 (queue semantics),
R6-R7 (attribution), R8-R10 (Ctrl+C/Ctrl+Q/reattach), R11-R13 (exit kills
agents, registry, --bg), R14-R15 (pause).

**Origin actors:** A1 (operator), A2 (agent), A3 (implementing agent)
**Origin acceptance examples:** AE1 (R3-R5), AE2 (R8), AE3 (R14-R15),
AE4 (R6), AE5 (R11)

---

## Scope Boundaries

- No opencode fork/patch; only keystrokes, serve HTTP API, SQLite, and
  synthetic markers.
- R0 autonomy invariant: operator input steers; agent never blocks on it.
- Keep existing Ctrl+C decision tables; verify/extend, don't rebuild.
- Headless-claude fallback keeps working; no new chat UX for it.
- `kill -9`/OOM recovery stays boot-time GC (SessionGC) — out of scope.
- Don't break codex; `:immediate` delivery + REPL transport stay gated on
  `claude-repl`.
- RC session URL never logged (capability token).
- Live Claude-app (Remote Control) verification steps are operator-driven;
  the implementing agent does everything else via `scripts/aiurdev --test3
  --force` + logs.

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/opencode/chat_completions.ex` — bridge; `stream_codex_turn/3`,
  `codex_turn_stream_loop/5`, `@turn_marker_regex`, fast-close operator SSE
  (`stream_turn/3`).
- `src/lib/aiur/agent_runner.ex` — `open_aiur_turn_streams/1`,
  `post_aiur_turn_markers/4` (injectable `post_fn` test pattern),
  `safe_checkpoint_handler/2`, `do_run_codex_turns/10` `{:paused, _}` branch,
  `wait_for_resume/3`.
- `src/lib/aiur/opencode/active_turns.ex` — ActiveTurns registry; the
  WORKING/IDLE signal.
- `src/lib/aiur/claude/repl_agent.ex` — `await_turn/6`, `interrupt/1`
  (`Tmux.send_interrupt/2`), `send_operator_message/2`.
- `src/lib/aiur/codex/coding_agent.ex` — `receive_loop` `{:pause_agent}`
  clause + `handle_pause_request` + `interrupt_turn/2`: the pause-parity model
  for U3. `stop_port/1` tree-reap pattern for U4.
- `src/lib/aiur/orchestrator.ex` — `pane_interrupt_reply/2`,
  `perform_pane_interrupt/5`, `send_pause_control_message`,
  `kill_repl_session/1`, `terminate/2`.
- `src/lib/aiur/shutdown.ex` — the shutdown chokepoint `cleanup/1`.
- `src/lib/aiur/claude/remote_control.ex` — `graceful_kill_tree/1`,
  `reap_workspace_agents/2`.
- `src/lib/aiur/claude/transcript.ex` — `extract_disk_record/2`,
  `extract_user_record/2`, `extract_attachment_record/2`.
- `src/lib/aiur/opencode/session_writer.ex` — `write_user_message/2`, user-
  event drop clause.
- `src/lib/aiur/agent_list/renderer.ex` — events block, `clip_and_pad`,
  `truncate_visual`, OSC 8 handling, `event_subject_id` `"?"` fallback.
- `scripts/aiur-pane-ctrlc`, `scripts/aiur.tmux.conf` — Ctrl+C bridge.
- `scripts/aiurdev` — traps, `run_or_attach_foreground`, bg services.
- Existing prior plan (partially implemented, fold remaining work in):
  `docs/plans/2026-06-12-001-feat-opencode-control-boundary-plan.md` (its
  Unit 1 is DONE on branch; its Unit 3 = this plan's U6).

### Institutional Learnings (from memory/handoff)

- Operator messages use the agent's NATIVE queue; never cut an agent off
  mid-work by default.
- Backfill/replay is display-only; never re-prompts the agent.
- "No agent text" regressions: check label race in `--test` reset and sync
  marker fan-out in AgentRunner first.
- New fields on `Aiur.AgentList.App` state must be added to `render/1`'s
  `Map.take`/`Map.put` pipeline or the renderer never sees them.
- Kill `--test3` runs as soon as logs are collected (token cost), but not
  before evidence is captured.
- Implementation loop: implement → test → lint → small commits (3-7 words) →
  push after every commit. Never merge without explicit operator approval.

---

## Key Technical Decisions

- **Segmented turn streams (not auto-abort, not codex-wrapper rewrite):**
  opencode's input queue is TUI-local; the only reliable flush signal aiur
  controls is closing the in-flight completion. Segmentation reuses the
  existing marker machinery and fixes latency for both backends. (origin: Key
  Decisions)
- **Continuation markers carry the parent turn id:** segment markers are
  `__aiur_turn__:<parent>-s<N>`; the bridge strips the `-s<N>` suffix and
  treats the parent id as the single source of truth in ActiveTurns and for
  `{:aiur_turn_done, …}` matching. No new ActiveTurns entries per segment.
  NOTE (verified): `@turn_marker_regex` already accepts `-` so the suffixed
  marker matches, but the captured id is the FULL suffixed string —
  `ActiveTurns.lookup/2` is an exact `{identifier, turn_id}` ETS lookup, so
  the bridge MUST strip the suffix before lookup or every segment closes as
  phantom.
- **Continuations go to the ORIGINATING writer only (not fan-out):** with
  N≥2 attached panes, fanning continuations to every writer multiplies
  segment streams combinatorially per boundary. Resolve the caller's writer
  via `caller_base_url(conn)` + `SessionWriterRegistry.lookup(identifier,
  base_url)` — the same machinery `resolve_session_for_replay/2` uses.
  Initial turn markers keep their existing all-writers fan-out.
- **Marker-before-close ordering + coalescing defense:** the bridge posts the
  continuation marker BEFORE closing the current SSE so opencode's queue
  holds `[operator msg?, marker]` and flushes in order. DEFENSE (gating):
  `last_user_text/1` takes only the LAST user message — if opencode coalesces
  queued items into one request, the marker would be last and the operator
  text silently dropped. U1 must therefore, when the routed text is a marker,
  scan the request body's other user messages and dispatch any non-marker
  operator text to `AgentChat.send` before opening the segment stream.
- **Pause = interrupt-then-hold for both backends:** claude-repl mirrors
  codex's `{:pause_agent}` handling: send `ReplAgent.interrupt/1` (tmux C-c),
  await the resulting turn end, return `{:paused, %{request_id: …}}` so the
  existing AgentRunner `{:paused}` branch (restore queue items, write pause
  log, `wait_for_resume`) takes over unchanged.
- **Central `Aiur.ProcessReaper`:** one registry of agent OS pids/pane ids,
  registered at spawn and unregistered at clean stop; reaped first in
  `Aiur.Shutdown.cleanup/1` and in `Orchestrator.terminate/2`. Existing
  per-backend reapers remain as defense in depth; the registry becomes the
  correctness-critical path.
- **Ctrl+Q closes without pausing; Esc stays native to opencode** (origin Key
  Decisions; operator-chosen).
- **Diagnose-before-fix for the flicker:** capture raw pane bytes first; fix
  only the verified cause.

---

## Open Questions

### Resolved During Planning

- Which layer owns segmentation: the bridge (it sees the stream and the
  elapsed clock); AgentRunner only exposes marker-posting, extracted into a
  shared helper module so the bridge can post continuations without a
  circular dependency.
- Is a codex-wrapper rewrite needed for R5: no — checkpoint injection already
  exists; parity is achieved at the bridge layer.

### Deferred to Implementation

- Exact segment-boundary threshold (suggest 20s elapsed + tool-result
  boundary; tune live) — depends on observed marker round-trip cost.
- Whether opencode coalesces multiple queued inputs into one completion —
  verify live in U2; affects nothing structurally.
- Idle-path RC transcript record shape (U7 experiment decides the fix shape).
- Whether the `:repl_gone` reopen path hits "no tmux server" in steady state
  (U6 gate, carried from prior plan).
- Identity of the `??????` bytes (U9 diagnosis).

---

## High-Level Technical Design

> *Directional guidance for review, not implementation specification.*

Segmented turn streams (U1):

```
AgentRunner.run_turn(turn T)
  ActiveTurns.put(id, T); TurnMarkers.post(id, "T")          # segment 0
  ... agent works; transcript events fan out via AgentPubSub ...

Bridge (per segment SSE, marker "T" or "T-sN"):
  parent = strip_segment_suffix(marker)                       # "T"
  ActiveTurns.lookup(id, parent)  -> :active | closed/phantom
  loop:
    transcript_event -> stream delta
      if segment_boundary?(event, elapsed_since_open, threshold):
        TurnMarkers.post(id, "T-s<N+1>")   # BEFORE closing
        close SSE finish_reason="stop"     # opencode flushes its queue:
                                           #   queued operator text -> stream_turn (fast close)
                                           #   "T-s<N+1>" -> next segment SSE opens
    {:aiur_turn_done, id, T, reason} -> finalize (last segment)
```

Pause parity (U3): claude-repl `await_turn` gains the same shape codex has —
`{:pause_agent, rid}` → interrupt live turn → confirm turn end → `{:paused,
%{request_id: rid}}` → AgentRunner's existing paused branch.

Process reaper (U4): `spawn → ProcessReaper.register(kind, os_pid/pane_id)`,
`clean stop → unregister`, `Shutdown.cleanup/1 + Orchestrator.terminate/2 →
ProcessReaper.reap_all()` (graceful_kill_tree per pid, kill_pane per pane).

---

## Implementation Units

### Phase 1 — complex core (do these first)

- [x] U1. **Segmented turn streams in the opencode bridge**
  *(Gating experiment PASSED live 2026-06-12: a POST mid-completion is HELD
  by opencode — no 409, no concurrent completion — survives client abort,
  and fires its own completion in order once the in-flight one closes
  (logs: `turn_stream_close t1` → 550ms → `turn_stream_phantom texp99`).
  Implemented: suffix parse via TurnMarkers, originating-writer-only
  continuations, event+idle boundary decisions (empty continuation segments
  never idle-close — no marker churn), symmetric coalescing defenses
  scoped to the trailing user batch. Live verification pending operator
  go-ahead.)*

**Goal:** Close the per-turn SSE at safe boundaries and resume via
continuation markers so opencode flushes queued operator input within
seconds, not whole turns.

**Requirements:** R3, R4, R5 (AE1)

**Dependencies:** None

**Files:**
- Create: `src/lib/aiur/opencode/turn_markers.ex` (extract
  `post_aiur_turn_markers/4` + new `post_continuation/4`; keep injectable
  `post_fn`)
- Modify: `src/lib/aiur/agent_runner.ex` (delegate marker posting to the new
  module; no behavior change)
- Modify: `src/lib/aiur/opencode/chat_completions.ex` (parse `-s<N>` suffix;
  segment clock; boundary decision; post-continuation-then-close)
- Test: `src/test/aiur/opencode/chat_completions_test.exs`
- Test: `src/test/aiur/opencode/turn_markers_test.exs`
- Test: `src/test/aiur/agent_runner_test.exs` (marker delegation still green)

**Approach:**
- GATING PRE-VERIFICATION (do first, one live run — this is the decisive
  experiment; do not write code until it passes): while a completion is in
  flight for a session, POST a synthetic marker message to that session via
  `ApiClient.post_message` and then let the SSE close. Record: (a) does the
  POST queue, block, 409, or open a CONCURRENT completion? (b) what is the
  flush order relative to TUI-typed text queued before and after the POST?
  (c) does opencode coalesce queued items into one completion request? Note:
  `api_client.ex`'s own doc warns POST "triggers a chat-completion
  roundtrip" — no existing code path posts into a session mid-completion, so
  this behavior is genuinely unknown. If opencode opens a concurrent
  completion instead of queueing, STOP — the segmentation design needs
  rework (escape hatch: fall back to a coarser design where the bridge
  closes only on heartbeat-idle and the runner posts the next segment marker
  from `close/open_aiur_turn_streams`).
- Marker grammar: parent `t<base36>`, segments `t<base36>-s1`, `-s2`, …
  (`@turn_marker_regex` already allows `-`; captured id = full suffixed
  string). Bridge derives `parent_turn_id` by stripping a trailing `-s\d+`
  BEFORE `ActiveTurns.lookup/2` (exact-key ETS lookup — unstripped ids close
  as phantom) and matches `{:aiur_turn_done, _, parent, _}` on the parent.
- Coalescing defense (SYMMETRIC — both orderings): when the routed (last)
  user text is a turn marker, scan the body's other user messages for
  non-marker operator text and dispatch it via `AgentChat.send` before
  opening the segment stream. AND when the routed text is non-marker
  operator text, scan the body for a marker user message and open the
  segment stream for it after dispatching — otherwise a "marker not last"
  coalescing order silently drops the continuation instead of the message.
- Extract a pure decision function, e.g.
  `segment_boundary?(role, payload, elapsed_ms, silent_ms, threshold_ms)`:
  true when (a) the streamed event is a tool-result/command boundary AND
  elapsed ≥ threshold, OR (b) evaluated on a `:heartbeat` tick with elapsed ≥
  threshold AND no event for ≥ one heartbeat (closing during silence splits
  nothing; this honors origin R4's idle-cadence clause — a silent 5-minute
  tool run must not hold input QUEUED). Threshold is an app-env (default
  ~20_000ms).
- Boundary detection must handle BOTH backends' event shapes — codex
  tool-result payloads and claude-repl `:tool`/`:command` events (the bridge
  already accepts both via `transcript_delta/2`).
- In `codex_turn_stream_loop`: track `segment_opened_at` + `seg_n` + last-
  event time. On a boundary: `TurnMarkers.post_continuation(identifier,
  parent, seg_n + 1, writer)` (originating writer only — resolve via
  `caller_base_url(conn)`) THEN `chunk(conn, completion_id, nil, "stop")` and
  return. Each segment SSE is a fresh request process, so per-request
  subscription setup is unchanged.
- Continuation-post failure fallback: retry once; on second failure log and
  let the turn fall back to SQL-only rendering (the watchdog/turn-done close
  machinery still fires) — state this as an accepted degradation.
- Phantom safety: a continuation whose parent is `{:closed, reason}` renders
  the finalize text for non-`:done` reasons (so `:input_required` notices
  aren't lost in the gap window) and closes silently for `:done`/`:not_found`.
- Heartbeat unchanged for keepalive; it additionally drives branch (b) of the
  boundary decision.
- `__aiur_stream__`/nudge markers untouched.
- Known accepted loss: transcript events broadcast during the small
  close→reopen gap render only via SessionWriter's SQL history, not the live
  stream. Verification includes diffing live pane vs SQL history once.

**Execution note:** Test-first on the pure pieces (suffix parse, boundary
decision) before touching the receive loop.

**Patterns to follow:**
- `post_aiur_turn_markers/4`'s injectable `post_fn` + `Task.start` fan-out.
- `transcript_delta/2` extraction precedent (pure, `@doc false`, tested
  without Plug).

**Test scenarios:**
- Happy path: `parse_turn_marker("t1abc-s3")` → `{parent: "t1abc", seg: 3}`;
  bare `"t1abc"` → seg 0; `t1abc-s3` lookup hits ActiveTurns under `t1abc`.
- Happy path: `segment_boundary?` true for tool-result event at elapsed ≥
  threshold; false below threshold; false for `:assistant` prose mid-thought;
  true on heartbeat tick with elapsed ≥ threshold + event-silence; true for
  claude-repl-shaped `:tool`/`:command` events.
- Happy path: `post_continuation` posts `__aiur_turn__:t1abc-s2` to ONLY the
  originating writer via injected `post_fn` (contrast with
  `post_aiur_turn_markers`' all-writers fan-out — keep both tested).
- Happy path (coalescing defense): request body whose last user message is a
  marker but contains an earlier non-marker user message → operator text is
  dispatched to AgentChat AND the segment stream opens (sit beside the
  `"transcript_delta/2"` describe in `chat_completions_test.exs`).
- Edge: continuation for `{:closed, :done}` parent → silent "stop" close;
  for `{:closed, :input_required}` → renders the awaiting-approval notice.
- Edge: `:aiur_turn_done` arriving for the parent while a segment is open →
  finalize with the done reason (existing behavior, now matched on parent).
- Edge: continuation post fails twice → loop closes normally; no crash.
- Integration (Covers AE1): with a fake AgentPubSub feed, a boundary event
  after threshold causes exactly one continuation post then an SSE close
  with finish_reason "stop".
- Regression: `agent_runner_test.exs` `"post_aiur_turn_markers/4"` describe
  stays green after the extraction to `TurnMarkers`.

**Verification:**
- `mise exec -- mix test` green from `src/`.
- Live (`scripts/aiurdev --test3 --force`): type a message into a working
  agent's opencode pane → QUEUED clears within one segment boundary (worst
  case = the longest single tool call or silent stretch, bounded by the
  heartbeat-idle close), message renders as user turn, agent incorporates it
  at next checkpoint. Confirm one logical turn renders as multiple assistant
  messages without errors, and `src/log/` shows
  `turn_stream_open`/`turn_stream_close` pairs per segment.
- Continuation markers are NOT visible in the live opencode pane during a
  segmented turn (marker hiding is theme-dependent per `protocol.ex`; a long
  turn posts many markers, so visibility is a U1 blocker, not a U6 cleanup).
  Also diff live pane content vs SQL history once to size the gap-window
  loss.

---

- [ ] U2. **End-to-end queue-latency verification (both backends)**

**Goal:** Prove R3/R5 hold for codex AND claude-repl after U1; close any
delivery-policy gaps found.

**Requirements:** R3, R5 (AE1)

**Dependencies:** U1

**Files:**
- Test: `src/test/aiur/orchestrator_status_test.exs` (extend only if a gap is
  found)
- Possibly modify: `src/lib/aiur/orchestrator.ex` `normalize_delivery_request`
  (only if live evidence shows a policy gap)

**Approach:**
- Live matrix on `--test3`: {codex issue 99/100, claude-repl issue 101} ×
  {agent mid-tool, agent between tools, agent idle/paused}. For each: time
  from Enter → user row renders → agent consumes.
- Watch for opencode coalescing multiple queued messages; document observed
  behavior in the PR/handoff notes.
- claude-repl path is `:immediate` (typed into pane); codex is `:checkpoint`
  injection — both should now start within seconds of the segment close.

**Test scenarios:**
- Test expectation: none beyond gap-driven additions — this is a verification
  unit; evidence is the live matrix + existing suites staying green.

**Verification:**
- Written latency matrix (in PR description or handoff notes) showing worst
  case ≤ one tool-use/checkpoint window for both backends.

---

- [x] U3. **Pause actually pauses claude-repl (codex parity)**

**Goal:** A pause request stops a mid-turn claude-repl agent within one
interrupt window instead of rotting in the mailbox.

**Requirements:** R14, R15 (AE3)

**Dependencies:** None (independent of U1)

**Files:**
- Modify: `src/lib/aiur/claude/repl_agent.ex` (`await_turn/6` AND
  `finish_turn/5` — see Approach; changing only `await_turn` ships a
  `FunctionClauseError` on every pause)
- Test: `src/test/aiur/claude/repl_agent_test.exs`
- Test: `src/test/aiur/orchestrator_status_test.exs` (pause/resume flow for a
  claude-repl-shaped running entry, if not already covered)

**Approach:**
- LIVE PRE-CHECK (one run, before coding): C-c a mid-turn claude REPL once
  and confirm the transcript gains a record that `TranscriptTailer`'s
  `on_turn_end` fires on, and how quickly. The existing `:interrupt` path is
  fire-and-forget — it proves C-c lands, NOT that a tailer-visible turn end
  follows. This decides whether step 2 below ever resolves naturally.
- Add a `{:pause_agent, request_id}` clause to `await_turn/6`'s `receive`:
  1. `interrupt(session)` (sends C-c via `Tmux.send_interrupt/2` — already
     tested machinery).
  2. Continue polling the tailer until `{:turn_end, turn_id, _}` (bounded by
     a short pause-confirm deadline, e.g. reuse `poll_ms`/existing deadline)
     so the transcript turn closes.
  3. DEADLINE EXPIRY: if the deadline fires without a turn_end, return
     `{:paused, …}` ANYWAY with a logged `pause_confirm_timeout` (mirrors
     codex's `no_active_turn` tolerance). Do NOT return
     `{:error, :turn_timeout}` (would book a failed turn / re-dispatch) and
     do NOT keep looping (pause would hang).
  4. Return `{:paused, %{request_id: request_id, turn_id: turn_id,
     session_id: …}}` — include `:session_id`: AgentRunner's paused branch
     reads `pause_payload[:session_id]` for its log line. Reuse the
     `"<thread_id>-<turn_id>"` shape `finish_turn/5` builds.
- REQUIRED: also add a `finish_turn({:paused, payload}, on_message,
  session_id, thread_id, turn_id)` clause. `await_turn`'s result does NOT
  reach AgentRunner directly — it pipes through `finish_turn/5`, which today
  has only `:ok` and `{:error, _}` clauses; without the new clause every
  pause crashes with `FunctionClauseError`. The new clause emits a pause
  event and returns `{:paused, payload}` with `:session_id` merged in.
  (`stop_tailer/1` already runs before `finish_turn` — no tailer leak.)
- The `{:paused, map()}` return is already in the `Aiur.CodingAgent`
  behaviour spec and is returned today by both headless backends — ReplAgent
  is the only backend missing it.
- AgentRunner's existing `{:paused, _}` branches (`do_run_codex_turns` and
  `run_queue_item_turn`) then restore delivered queue items, write the pause
  log, flip control state, and park in `wait_for_resume/3` /
  `wait_for_operator_message/5` — no AgentRunner changes expected.
  `turn_done_reason({:paused, _})` → `:input_required` also closes the
  bridge stream correctly via `close_aiur_turn_streams/3`.
- Mirror codex semantics: if the turn ends naturally before the interrupt
  lands, still return `{:paused, …}` (codex treats "no active turn" as
  success — see `no_active_turn_error?` handling).
- Resume: `wait_for_resume` → `continue_issue_turn` re-prompts the same
  persistent REPL session — verify the REPL accepts a new prompt after C-c
  (it does for the existing `:interrupt` queue-drain path).

**Execution note:** Write the failing repl_agent test first (pause request
mid-await → interrupt sent → `{:paused, …}` returned).

**Patterns to follow:**
- `src/lib/aiur/codex/coding_agent.ex` `handle_pause_request` /
  `continue_after_turn_interrupted` (the parity model).
- Existing mocked-tmux tests in `repl_agent_test.exs`.

**Test scenarios:**
- Happy path (Covers AE3): `{:pause_agent, 42}` delivered mid `await_turn` →
  mock tmux records a `send_interrupt`; `run_turn` (not just `await_turn`)
  returns `{:paused, %{request_id: 42, …}}` — this exercises the new
  `finish_turn` clause.
- Edge: pause-confirm deadline expires with no turn_end → still
  `{:paused, …}` + `pause_confirm_timeout` logged.
- Edge: pause arrives after `{:turn_end, …}` is already in the mailbox →
  turn-end clause wins; pause is consumed post-turn by the runner's
  `drain_operator_messages` (existing "Agent already paused" path) — no
  crash, no double interrupt.
- Edge: interrupt send fails (tmux error) → still park as paused rather than
  crash the turn; log the failure.
- Integration: orchestrator `pause_agent/1` on a claude-repl entry mid-turn →
  control status `:paused` AND runner returns `{:paused, …}` (extend
  orchestrator pause tests with a fake backend if scaffolding allows).

**Verification:**
- Live: pause issue 101 from opencode (Ctrl+C while idle queue) and from the
  agent list; `src/log/aiur.101.log` + `chat.101.ansi` show NO new tool/work
  events after the pause until resume. Resume with Space continues the issue.

---

- [x] U4. **Central process reaper — exit always kills all agents**

**Goal:** One registry of every agent OS process/pane, reaped through one
chokepoint, so no agent survives any non-`kill -9` aiur exit.

**Requirements:** R11, R12 (AE5)

**Dependencies:** None

**Files:**
- Create: `src/lib/aiur/process_reaper.ex`
- Create: `src/test/aiur/process_reaper_test.exs`
- Modify: `src/lib/aiur.ex` (the OTP app module `Aiur.Application` lives
  here — there is NO `src/lib/aiur/application.ex`). Insert the reaper child
  BEFORE `{Task.Supervisor, name: Aiur.TaskSupervisor}` (children stop in
  reverse order, so the reaper outlives runner tasks/ports).
  SIGTERM HOOK (decided): implement `Aiur.Application.prep_stop/1` to run
  the full kind-ordered cleanup BEFORE tree teardown; the reaper's
  `terminate/2` then reaps only leftovers. Rationale: `stop/1` already calls
  `Shutdown.cleanup()` but runs AFTER the tree is down — the reaper and the
  serves are dead by then, so `delete_all`'s HTTP deletes fail and the
  kind-ordering invariant can't hold on that path. Keep the `stop/1` call as
  a final best-effort (it's harmless when `prep_stop` already ran).
- Modify: `src/lib/aiur/shutdown.ex` (`cleanup/1` calls the reaper — see
  kind-ordering below)
- Modify: `src/lib/aiur/orchestrator.ex` (`terminate/2` also calls reap as a
  best-effort accelerator; keep `kill_repl_session/1` as defense in depth)
- Modify (registration points — verified spawn sites):
  - `src/lib/aiur/claude/repl_agent.ex` — pane spawned in `start_session/2`
    (`Tmux.new_hidden_window`), os pid captured in `finish_start/2` via
    `Tmux.pane_pid`; session fields `pane_id`/`os_pid`. The pane runs
    `exec claude`, so the pane pid IS the kill target. Unregister in
    `stop_session/1`.
  - `src/lib/aiur/claude/coding_agent.ex` — headless backend: spawned by
    `start_session/2` → `start_port/1`; os pid from `port_metadata/1`
    (`metadata.claude_app_server_pid`).
  - `src/lib/aiur/codex/coding_agent.ex` — app-server: `start_port/3`
    (local `Port.open` / remote via `SSH.start_port`); os pid from
    `port_metadata/2` (`metadata.codex_app_server_pid`). Unregister in
    `stop_port/1`.
  - `src/lib/aiur/opencode/slot.ex` + `src/lib/aiur/opencode/server.ex` —
    serve: `handle_continue(:start_serve, …)` → `Server.start_link/1`;
    `Server.await_ready/2` returns `{:ok, base_url, os_pid}` (the os_pid is
    currently DISCARDED at the call site — capture it). Attach pane:
    `mark_ready_with_attach_pane/1` and `respawn_attach_with_session/2`
    (`state.pane_id`). Unregister panes on slot-owned kills/rebuilds.
- Test: `src/test/aiur/process_reaper_test.exs`; shutdown-ordering coverage
  beside `src/test/aiur/regression/shutdown_cleanup_test.exs`

**Approach:**
- Reaper = GenServer owning an ETS table: `register(kind, ref, meta)` /
  `unregister(ref)` / `reap(kinds, opts)` with injectable killers
  (default `&RemoteControl.graceful_kill_tree/1` for pids,
  `&Aiur.Tmux.kill_pane/1` for panes) for tests.
  `ref` is `{:os_pid, pid}` or `{:pane, pane_id}`; `kind` is `:agent`
  (REPL/headless/codex trees, chat panes) or `:serve` (opencode-serve).
- **PID TYPE TRAP:** the port_metadata fields store pids as STRINGS
  (`to_string(os_pid)` — `codex_app_server_pid`, `claude_app_server_pid`),
  but `graceful_kill_tree/1` only has `nil` and `is_integer` clauses — a
  string pid raises, the wrap swallows it, and the reap silently kills
  nothing while injected-killer tests stay green. Normalize to integers at
  registration (and verify `Tmux.pane_pid`'s return type for the REPL path).
- **Kind-ordered shutdown** (prevents breaking session deletion):
  `Shutdown.cleanup/1` order = `reap([:agent])` →
  `SessionWriterRegistry.delete_all` (needs live serves for its HTTP
  deletes) → `reap([:serve])` → existing sweeps.
- **Reap in the reaper's own `terminate/2`:** trap exits; child spec
  `shutdown: 30_000`. This is the backstop that runs on EVERY supervised
  shutdown path, including SIGTERM where `Shutdown.cleanup` may never run
  before the tree falls. `Orchestrator.terminate/2`'s call stays best-effort
  (its own 5s shutdown window can't fit a slow multi-pid graceful reap).
- **Pid-reuse guard:** store an expected `/proc/<pid>/cmdline` (or comm)
  substring in `meta` at registration; verify before each kill (injectable
  reader). A mismatch means the pid was recycled — skip, log.
- **Draining mode is SHUTDOWN-SCOPED, not first-reap-latched:** `reap(kinds,
  drain: true)` only from `Shutdown.cleanup/1` and the reaper's own
  `terminate/2`; `Orchestrator.terminate/2` calls `reap(…, drain: false)`.
  After a draining reap, `register/3` kills the incoming ref immediately
  (closes the "task respawns an agent between cleanup and tree teardown"
  window). WHY THE SCOPE MATTERS: `Orchestrator.terminate/2` also runs on a
  supervised crash-and-restart — a latched drain on the app-lifetime reaper
  would then kill every agent the restarted orchestrator spawns, a silent
  total outage no injected-killer test catches.
- Crash-path entries (registering process died) are KEPT — an orphan is
  exactly what the reaper exists to kill; the cmdline guard makes that safe.
  The spawn→register crash window is explicitly NOT covered by the registry;
  it remains assigned to the retained `reap_workspace_agents` pgrep layer.
- `reap` is idempotent, never raises (wrap per-entry kills like
  `Shutdown.safely/2`).
- Keep ALL existing reap layers; the registry is additive and becomes the
  primary path. Do not delete `kill_repl_session`, `stop_port` tree-reap,
  `sweep_own_panes`, or bash traps.
- Registration happens in the SPAWN path, immediately after pid/pane known.

**Patterns to follow:**
- `stop_port/1` tree-reap (`graceful_kill_tree` before `Port.close`).
- `Shutdown.safely/2` error swallowing.
- Injectable-function test style from `post_aiur_turn_markers/4` /
  `apply_label_reset/5`.

**Test scenarios:**
- Happy path: register two `:agent` os_pids + one pane; `reap([:agent])`
  with injected killers kills exactly those and empties their entries;
  `:serve` entries untouched.
- Happy path: unregister then reap → unregistered ref not killed.
- Happy path: cmdline guard — meta expects `"codex"`, injected reader
  returns `"vim"` → skip + log, no kill.
- Edge: killer raises on first entry → remaining entries still reaped; reap
  returns `:ok`.
- Edge: double reap → second call no-ops; register after a `drain: true`
  reap → incoming ref killed immediately; register after a `drain: false`
  reap (orchestrator-terminate path) → still registers normally (no latch).
- Edge: a string os_pid registered against the REAL default killer
  signature → either normalized at registration or killed correctly — pins
  the pid-type trap.
- Integration: `Shutdown.cleanup/1` ordering `reap([:agent])` → `delete_all`
  → `reap([:serve])` — assert via injected recorder.
- Integration: codex `stop_port/1` unregisters its os_pid (no double-kill).
- Integration: reaper `terminate/2` reaps remaining entries (trap_exit,
  injected killers).

**Verification:**
- Live (Covers AE5): boot `--test3`, wait until all three agents are
  mid-work, quit aiur from the agent list. Within ~10s, TWO passes:
  (1) `pgrep -af 'claude|codex|opencode' | grep aiur-workspaces` → empty
  (agent trees); (2) bare `pgrep -af opencode` diffed against pre-quit
  output (serve/attach processes carry no workspace path in argv, so the
  workspace-filtered grep alone can false-pass). No `aiurdev-orangekid`
  panes left. Repeat with SIGTERM to the BEAM.

---

### Phase 2 — control surface

- [x] U5. **Ctrl+Q close-without-pause + Ctrl+C live verification**
  *(Code landed (`07d3a3f`): C-q binding with pane-0 no-op. Live Ctrl+C/
  Ctrl+Q matrix is operator-verified — tmux send-keys input-driving did not
  reach the TUI input loop in this session's run, so pane-interaction tests
  fall to the operator checklist in handoff.md.)*

**Goal:** Bind Ctrl+Q to close a chat pane without touching agent state;
verify the full Ctrl+C 3-state matrix live and fix gaps found.

**Requirements:** R8, R9 (AE2)

**Dependencies:** U3 (pause must truly pause for the idle branch to verify)

**Files:**
- Modify: `scripts/aiur.tmux.conf` — add `bind-key -n C-q` with an if-shell
  on `pane_index == 0`: pane 0 → NO-OP (do NOT copy the C-c binding's pane-0
  branch — that branch is `kill-session` and would tear down the whole TUI);
  non-zero panes → plain `kill-pane`
- Modify: `src/lib/aiur/agent_list/renderer.ex` footer keybind hint if the
  footer enumerates pane keys (check `@keybinds_full`)
- Test: shell-level check mirroring `scripts/verify-ctrlc-binding.sh` if that
  harness pattern fits (`scripts/verify-ctrlc-binding.sh` exists — follow it)

**Approach:**
- Ctrl+Q = the pre-bridge close behavior (kill-pane; PaneManager reconciles —
  see commit `c1ed4fc`). No orchestrator round-trip, no state mutation, so
  the agent keeps working — exactly "close without pausing".
- Do NOT touch the C-c binding or `scripts/aiur-pane-ctrlc`.
- Esc remains unbound at the tmux layer (native opencode interrupt).

**Test scenarios:**
- Happy path: C-q on a chat pane closes only that pane; agent-list pane keeps
  running; ActiveTurns still shows the agent working.
- Edge: C-q on pane 0 (agent list) must NOT kill the session (guard like C-c
  binding's pane-0 branch — decide: no-op is acceptable).
- Live matrix (Covers AE2): Ctrl+C with queued msg+working → drains, keeps
  working, pane open; Ctrl+C idle → paused, pane open; Ctrl+C paused →
  closed, still paused; Ctrl+Q anytime → closed, agent state unchanged.

**Verification:**
- `/tmp/aiur-ctrlc.log` breadcrumbs match the matrix; reopening after C-q
  shows the agent never paused.

---

- [x] U6. **Reopen reattaches the persisted opencode session (`:repl_gone`)**
  *(Resolved without new code, 2026-06-12: for codex/opencode agents,
  close (Ctrl+Q / `close_pane`) only kills the slot's ATTACH pane — the
  slot's `:poll_session` death path respawns it and the opencode session
  persists, so reopen reattaches by design. `:repl_gone` is claude-repl
  only, and there the pane IS the agent process (`exec claude`) — the
  operator's chat pane is the opencode attach pane, never the hidden REPL
  pane, so a chat-pane close cannot kill the REPL; if the REPL pane truly
  dies the OS process is gone and re-dispatch IS the correct recovery.
  Live confirmation of the reopen path lands with the final verification
  run.)*

**Goal:** Closing a pane never costs session continuity: reopening resumes
the same opencode session instead of a fresh dispatch.

**Requirements:** R10

**Dependencies:** U1, U5. The U1 dependency is load-bearing: segmentation
multiplies persisted rows (per-segment assistant messages + marker user rows
+ SessionWriter's parallel grouped copy). A same-session reattach renders all
of them, so this unit must decide the single render source for reattach
(e.g., SessionWriter skips live-bridged sessions, or duplication is
consciously accepted and documented) and verify "reattach after a segmented
turn renders no duplicate content and no visible markers". An unanswered
final marker must not trigger phantom completions per reattach (the existing
phantom path covers this — verify).

**Files:**
- Modify: `src/lib/aiur/agent_runner.ex` (`transient_run_error?(:repl_gone)`
  recovery routing)
- Modify: `src/lib/aiur/orchestrator.ex` (re-dispatch vs reattach decision)
- Investigate: `src/lib/aiur/opencode/attach_pool.ex` attach-hit path,
  `src/lib/aiur/claude/repl_agent.ex` `:repl_gone` raise site
- Test: `src/test/aiur/agent_runner_test.exs`, orchestrator re-dispatch test

**Approach:**
- This is Unit 3 of `docs/plans/2026-06-12-001-feat-opencode-control-boundary-plan.md`
  verbatim — keep its gating: FIRST repro on-device whether a steady-state
  close→reopen hits "no server running" (that capture smelled like harness
  teardown). If steady-state reattach is clean once fresh-dispatch stops,
  route opencode/codex RC `:repl_gone` to reattach-by-session_id and stop
  treating it as dispatch-worthy. If the tmux-server-gone failure IS
  steady-state, split that into a separate follow-up plan — do not widen
  this unit.

**Test scenarios:**
- Happy path: close pane → reopen → same `session_id` in logs
  (`attach_pool_hit`), no new dispatch, transcript history intact.
- Edge: reopen after the agent finished its turn while closed → renders
  backfilled history (display-only; no re-prompt — guardrail from memory).

**Verification:**
- Live close/reopen cycle on a working agent keeps `session_id` stable and
  produces no `:repl_gone; re-dispatch` log line.

---

- [ ] U7. **Remote-message attribution: idle-path gap + dual-surface verify**
  *(BLOCKED upstream, 2026-06-12: claude CLI 2.1.175's interactive REPL
  writes NO conversation records to `~/.claude/projects/<slug>/*.jsonl`
  (only `ai-title`; verified with aiur's exact launch flags, multiple
  turns, and on exit) while headless/sdk-cli sessions write normally. The
  entire REPL transcript-tail path — turn-end detection, chat mirroring,
  and this unit's attribution flow — sees nothing until claude is pinned/
  fixed or the REPL gains an sdk-style entrypoint. The 3901217 attribution
  fix and tests remain correct for when records flow again.)*

**Goal:** RC-app messages always render as user turns in opencode (mid-turn
AND idle); pane-typed messages visible on the Claude app side.

**Requirements:** R6, R7 (AE4)

**Dependencies:** None

**Files:**
- Investigate first (live experiment, operator-driven for the RC sends)
- Possibly modify: `src/lib/aiur/claude/transcript.ex`
  (`extract_user_record/2` origin disambiguation)
- Possibly modify: `src/lib/aiur/claude/repl_agent.ex` (record the texts aiur
  itself typed, so pane-typed user records can be told apart from remote
  ones)
- Possibly modify: `src/lib/aiur/opencode/session_writer.ex`
- Test: `src/test/aiur/claude/transcript_test.exs`,
  `src/test/aiur/opencode/session_writer_test.exs`

**Approach:**
- Experiment: operator sends an RC message while issue 101's agent is (a)
  mid-turn and (b) idle/paused. Capture the fresh
  `~/.claude/projects/<slug>/<uuid>.jsonl` records for both.
- If the idle path produces a `queued_command` attachment too → no code
  change; mark R6 verified.
- If it produces a plain `type:"user"` record: pane-typed prompts are ALSO
  plain user records, so disambiguate by provenance — aiur knows every text
  it typed into the pane (`send_prompt`/`send_operator_message`); keep a
  short-lived per-session set of sent texts and tag user records NOT in that
  set as `origin: :remote`. Sketch only — final shape after the experiment.
- R7 (opencode→app): expected free (typed into the REPL = native user turn);
  operator verifies in the app.

**Test scenarios:**
- Happy path: `extract_attachment_record` keeps tagging `queued_command` →
  `origin: :remote` (existing tests stay green).
- Happy path (if gap confirmed): a user record whose text was NOT aiur-typed
  → `origin: :remote` event → SessionWriter writes a user row; an aiur-typed
  text → dropped (no double render).
- Edge: identical text sent from both surfaces in one session → document
  chosen behavior (set-with-counts or timestamp window) — implementer picks
  the simplest correct shape.
- Covers AE4 via the live matrix.

**Verification:**
- Live AE4 matrix passes; no `💬`-prefixed assistant-speech rendering of
  operator words anywhere.

---

### Phase 3 — cleanup & polish (safe for a later session)

- [x] U8. **Ticket-212 sweep + tracker-state cleanup**

**Goal:** Zero 212 references in test plumbing; tracker state clean.

**Requirements:** R1

**Dependencies:** None

**Files:**
- Verify-only: `src/lib/aiur/test_reset.ex`, `scripts/aiurdev`,
  `.aiur-test-tickets.json`, `src/lib/mix/tasks/aiur.test.reset.ex`
- Delete: `src/log/aiur.212.subscriptions.json` (untracked runtime artifact)
- Tracker: strip `agent:*` labels from GitHub issue 212 and close it
  (`gh issue edit 212 --remove-label …` + `gh issue close 212`) — confirm
  with operator before closing if in doubt. KNOWN BUG: `gh … edit` can
  silently fail with a classic-Projects GraphQL error on this repo; if the
  labels survive, patch via REST instead
  (`gh api -X DELETE repos/{owner}/{repo}/issues/212/labels/<label>`)

**Approach:**
- `rg -n '212|golden' src scripts .aiur-test-tickets.json` (excluding deps/
  log) must show only incidental matches (e.g. the unrelated
  `agent_runner_test.exs` fixture id "212" — rename it to a neutral id like
  "412" to kill future grep noise).
- Confirm `--test` resets exactly ticket 99 (`maybe_execute(Enum.take(tickets,
  1), …)`) and `--test3` exactly 99/100/101.

**Test scenarios:**
- Test expectation: none — verification/cleanup unit; existing
  `test_reset_test.exs` suite must stay green.

**Verification:**
- Grep output clean; `gh issue view 212` shows closed/label-free; a `--test`
  dry-run names only issue 99.

---

- [ ] U9. **Agent-list `??????` flicker — diagnose, then fix the verified cause**

**Goal:** No transient `?` runs in the agent-list pane during initial load.

**Requirements:** R2

**Dependencies:** None

**Files:**
- Diagnosis first; then likely one of:
  `src/lib/aiur/agent_list/renderer.ex`, `src/lib/aiur/agent_list/app.ex`
- Test: `src/test/aiur/agent_list/renderer_test.exs` (exists; sibling files
  `app_test.exs`, `debug_events_ticker_test.exs` cover the events ticker)

**Approach:**
- Reproduce + capture BYTES, not impressions: from the wrapper tmux, run
  `tmux -L aiurdev-<user> pipe-pane -t <agent-list pane> -o 'cat >>
  /tmp/aiur-frames.bin'` during boot of `--test3`; or pass a tee `write_fun`
  in a dev-only branch. Find the exact byte sequence rendering as `?`s and
  its screen position.
- Ranked suspects (fix ONLY what the capture confirms):
  1. OSC 8 hyperlink wrappers in event rows (`link_ticket_id`/
     `link_verb_phrase`) — a split or unsupported escape renders literal
     bytes; commit `0e4f650` already fixed one truncation case, a sibling
     path may remain (check `clip_and_pad` vs `truncate_visual` usage for
     event rows vs other rows).
  2. Braille spinner frames (`@spinner_frames`) or emoji width mismatch
     rendering as `?` under the inner tmux's terminfo during early boot
     (UTF-8 not yet negotiated).
  3. `event_subject_id` `"?"` fallback firing for early events whose
     identifiers haven't loaded (would be single `?`s, one per row).
- The fix must come with a renderer unit test that pins the failing input
  (e.g. an event row that previously emitted a broken escape at a given
  width renders clean output).

**Test scenarios:**
- Happy path: regression test reproducing the captured bad input → clean
  padded row, no orphan escape bytes, `visual_width` of output ==
  inner_width.
- Edge: narrowest width (`inner_width < 14` divider fallback) with linked
  event rows.

**Verification:**
- Boot `--test3` twice; visually clean load; the byte capture shows no `?`
  runs in the divider/events region.

---

- [ ] U10. **`--bg` / auto-attach verification**

**Goal:** Confirm R13 behavior; fix only if broken.

**Requirements:** R13

**Dependencies:** U4 (shutdown semantics settled first)

**Files:**
- Verify-only: `scripts/aiurdev` (`run_or_attach_foreground`,
  `background_running`, `restart_*_background`)

**Approach:**
- Matrix: (1) `aiurdev --bg` → headless instance runs, agents dispatch;
  (2) `aiurdev` while bg runs → attaches (no double BEAM/port-4000 clash);
  (3) quitting the attached foreground does NOT kill the bg service's agents
  (only `aiurdev stop` does);
  (4) `aiurdev stop` kills everything (ties into U4's reaper).
- Document observed behavior in handoff notes; file fixes as a follow-up
  only if (2) or (4) fail.

**Test scenarios:**
- Test expectation: none — shell-level verification unit.

**Verification:**
- The 4-step matrix passes and is recorded.

---

## System-Wide Impact

- **Interaction graph:** U1 touches every opencode chat pane's rendering path
  (both backends); regressions show as missing/duplicated agent text — check
  memory `chat-text-latency` causes (label race, marker fan-out) before
  blaming U1's segmentation.
- **Error propagation:** segment-close failures must degrade to the
  pre-segmentation behavior (one long SSE, watchdog close) — never crash the
  bridge handler (`chunk/4` already swallows write-closed).
- **State lifecycle risks:** U4's registry must never double-kill a pid that
  a clean-stop path already reaped (unregister-on-clean-stop + idempotent
  reap). U3's interrupt must not fire on an already-ended turn (mirror codex
  `no_active_turn` tolerance).
- **API surface parity:** the dashboard/HTTP control API
  (`observability_api_controller.ex`) already passes `send_interrupt`
  through; no new actions added by this plan.
- **Integration coverage:** AE1/AE2/AE3/AE5 live matrices are the
  cross-layer proof; unit tests alone cannot prove opencode's queue-flush
  ordering.
- **Unchanged invariants:** R0 autonomy; headless fallback; codex JSON-RPC
  contract; `:immediate` delivery gating on claude-repl; RC URL secrecy;
  `:interactive_cli` gate on workspace sweeps; existing Ctrl+C decision
  tables.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| opencode coalesces queued input so the marker (last user msg) shadows the operator text — silent message DROP | Gating pre-verification in U1 + coalescing defense (scan body for non-marker user text, dispatch before streaming) + dedicated test |
| Continuation fan-out multiplies streams with N≥2 attached panes | Continuations go to originating writer only (`caller_base_url` resolution); initial markers keep fan-out |
| Content broadcast in the close→reopen gap missing from live pane | Accepted degradation (SQL history has it); one-time live-vs-SQL diff in U1 verification |
| Segmented rendering looks chattier (many assistant bubbles) | Accepted in origin doc (R4); boundary rule requires a real tool boundary or genuine silence, so segments map to natural chat blocks |
| Reattach (U6) renders duplicated segment/marker/SessionWriter rows | U6 depends on U1; explicit render-source decision + dedup verification in U6 |
| SIGTERM path runs `Application.stop` after the reaper is gone | Reaper reaps in its own `terminate/2` (trap_exit, 30s shutdown budget); `prep_stop` considered as earlier hook |
| Reaping serves before session deletion breaks `delete_all` HTTP calls | Kind-ordered reap: `:agent` → `delete_all` → `:serve` |
| C-c to the REPL mid-tool leaves claude in a weird sub-state | Same primitive the shipped `:interrupt` drain path uses; U3 keeps the bounded turn-end wait + logs failure instead of crashing |
| Reaper kills a pid reused by the OS after agent exit | cmdline/comm guard verified before every kill (injectable reader); crash-path entries kept but guarded; existing layers unchanged |
| U6's tmux-server-gone failure is steady-state | Gated investigation; split to follow-up plan rather than widening |
| `--test3` token burn during verification loops | Kill runs as soon as evidence is captured (memory guardrail); batch verifications per run (U2+U5+U7 matrices can share one run) |

---

## Documentation / Operational Notes

- Update `handoff.md` after each phase (the operator relies on it for session
  continuity).
- Commit style: small commits, 3-7-word messages, push after every commit;
  never mention "codex"/"AI" in messages (product terms like opencode/Claude/
  Remote Control are fine). Never merge PR #256 without explicit operator
  approval.
- Local gate: `make -C src MIX='mise exec -- mix' all` before pushing
  substantial changes.

---

## Sources & References

- **Origin document:** `docs/brainstorms/2026-06-12-chat-control-lifecycle-ux-requirements.md`
- Prior plan folded in: `docs/plans/2026-06-12-001-feat-opencode-control-boundary-plan.md`
- Prior parity plan: `docs/plans/2026-06-10-001-fix-rc-shutdown-interrupt-parity-plan.md`
- PR #256 `Add Claude REPL dual-chat driver`
- Key commits: `f1189f5` (212 removal), `3901217` (remote user turns),
  `f85daba` (Ctrl+C → opencode interrupt), `e523326` (Ctrl+C bridge),
  `fe22829` (codex tree reap), `0e4f650` (event-line truncation)
