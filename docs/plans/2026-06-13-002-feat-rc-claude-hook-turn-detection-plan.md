---
title: "feat: RC-claude hook-based turn detection"
type: feat
status: active
date: 2026-06-13
---

# feat: RC-claude hook-based turn detection

## Overview

The `claude-repl` backend (interactive `claude --remote-control`, used for the dual-chat
RC agents) detects turn completion and reads the agent's response by polling claude's
`~/.claude/projects/<slug>/*.jsonl` transcript. Controlled experiments proved claude
v2.1.177 flushes that transcript **lazily** (only after multi-turn accumulation), so
aiur's 15s cold-start poll always times out → `:no_transcript` → the agent fails every
turn and gives up. Result: RC-claude never runs autopilot, and operator messages sent
from the opencode pane are never received/answered.

Replace transcript polling with **claude hooks** — an official, structured, version-stable
mechanism that fires reliably in interactive `--remote-control` mode (verified):
`UserPromptSubmit` (input received), `PostToolUse` (live progress / heartbeat), `Stop`
(turn done + `last_assistant_message`). Hooks POST their JSON to the aiur dashboard; aiur
drives turn detection and bridge rendering off those events, with **no completion
timeout** so minutes-long silent turns are handled.

This plan covers ONLY RC-claude (Bug 1). Codex + non-RC claude real-time consumption and
the bridge double-dispatch are pinned for later work.

---

## Problem Frame

- Interactive `claude --remote-control` emits **no structured stdout** — RC is only
  available in the interactive REPL, and `--output-format stream-json` is `--print`-only
  (mutually exclusive). So aiur fell back to reading claude's transcript file.
- claude v2.1.177 writes that file lazily (experiments: a short turn answers in the pane
  but writes no `.jsonl` for 30s+, even after `/exit`; a long 39-turn session did write
  one). aiur's `await_transcript` (`@transcript_wait_ms` 15s) fails turn 1 → retries fresh
  → never accumulates → gives up after 3.
- Verified the fix mechanism: with a `Stop`/`UserPromptSubmit` hook configured via
  `--settings`, both fire in `--remote-control` mode, per turn, as JSON carrying
  `session_id`, `cwd`, and `last_assistant_message` — with no transcript file present.

---

## Requirements Trace

- R1. RC-claude runs **autopilot by default** (RC is an additional I/O channel, not a
  handoff — see memory `rc_autonomy_invariant`).
- R2. An operator message sent from the **opencode pane** is received and answered by the
  RC-claude agent (the core Bug 1 failure).
- R3. An operator message sent from the **RC channel** continues to work.
- R4. Turn detection has **no completion timeout** — a turn that works silently for
  minutes is not failed; liveness comes from pane state + tool-hook heartbeats, not a clock.
- R5. Live progress streams to the opencode pane during long turns (`PostToolUse`).
- R6. `Stop` publishes turn completion + the final assistant message to the bridge.
- R7. Full gate stays green (compile `--warnings-as-errors`, test, credo `--strict`,
  dialyzer); verified end-to-end via controlled claude spawn + `aiurdev --test3`.

---

## Scope Boundaries

- RC-claude (`claude-repl` backend) only. Codex and non-RC claude are unchanged.
- Not removing the transcript code paths used by non-RC/headless flows — only bypassing
  transcript-based turn detection for the RC REPL.

### Deferred to Follow-Up Work

- Codex + non-RC claude real-time operator-message consumption (pinned).
- Bridge double-dispatch (coalesce defense re-fires on continuation-marker requests).
- Bug 2 (Ctrl+C) — already fixed and shipped (U1 of the prior plan).

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/claude/repl_agent.ex` — `run_turn`, `await_transcript`,
  `start_turn_tailer`, `await_turn`, `build_command`, `send_operator_message`. The pane is
  already read here (`input_echoes?`/`pane_alive?`), so reading pane state is established.
- `src/lib/aiur/claude/transcript_tailer.ex` — the current jsonl tailer (to be bypassed
  for RC turn detection; may stay for backfill).
- `src/lib/aiur_web/controllers/observability_api_controller.ex` + `router.ex` — existing
  dashboard API + `pane_interrupt`/`messages` actions to mirror for the hook endpoint.
- `src/lib/aiur/agent_pubsub.ex` — `broadcast_transcript`/`broadcast_turn_event` and the
  per-agent topic the opencode bridge subscribes to (`ChatCompletions.stream_codex_turn`).
- `src/lib/aiur/agent_runner.ex` — `do_run_codex_turns` etc. drive `CodingAgent.run_turn`;
  turn lifecycle + `open/close_aiur_turn_streams` feed the bridge.

### Institutional Learnings

- `project_bug1_no_transcript_root` — the transcript-lazy-flush root cause + experiments.
- `rc_autonomy_invariant`, `rc_cloud_mediated` — RC is takeover/extra-channel; agent
  self-drives.
- `feedback_test3_cost_discipline` — kill `--test3` as soon as evidence is captured.

### Verified Hook Behavior (controlled experiments, claude v2.1.177 --remote-control)

- `UserPromptSubmit` payload: `{session_id, transcript_path, cwd, permission_mode,
  hook_event_name, prompt}`.
- `Stop` payload: `{session_id, transcript_path, cwd, hook_event_name, stop_hook_active,
  last_assistant_message, ...}`. Fires per turn (verified 2 turns; 2s and 5s).
- Hooks fire with NO transcript file present → fully decoupled from transcript timing.

---

## Key Technical Decisions

- **Per-agent `--settings` file with the identifier baked into the hook URL.** aiur
  generates the workspace, so it knows the identifier; the hook POSTs to
  `/<identifier>/claude-hook`. This is the cwd→agent binding (each workspace's settings
  carries its own agent's URL); the payload `cwd` is a cross-check. Unambiguous, no
  registry lookup race.
- **Hook command must be stdout-silent, fast, fire-and-forget, exit 0.** `UserPromptSubmit`
  and `Stop` hook *stdout* is interpreted by claude (adds context / can block stopping), so
  the command must emit nothing to stdout and always exit 0:
  `curl -s -o /dev/null -m 2 -X POST <url> --data-binary @- >/dev/null 2>&1; exit 0`.
- **No completion timeout.** The Stop event is the only completion signal. The run waits on
  hook events + `pane_alive?` liveness; remove the 15s transcript wait as a failure path.
  Optionally keep a very generous absolute ceiling (e.g., existing `@turn_timeout` at
  minutes) purely as a backstop, reset by any PostToolUse heartbeat.
- **Bridge content from hook events.** Map `UserPromptSubmit`→user transcript event,
  `PostToolUse`→progress/tool transcript event, `Stop`→assistant transcript event +
  turn-done. Reuse `AgentPubSub.broadcast_transcript` so the existing bridge renders them.
- **Transport = HTTP POST to the local dashboard** (the claude REPL is local even for
  remote workers, so `127.0.0.1:<port>` is reachable). Mirrors the existing pane-interrupt
  control path.

---

## Open Questions

### Resolved During Planning

- cwd vs session_id correlation → per-agent settings with identifier in the URL; cwd is a
  cross-check (honors the "correlate by cwd" intent without a lookup race).
- Streaming granularity → `Stop.last_assistant_message` is the final answer (satisfies the
  round-trip R2/R6); `PostToolUse` supplies live progress (R5). No assistant-delta hook
  exists, so intra-message streaming is out of scope (final message + tool progress only).

### Resolved During Deepening

- **Endpoint→run-process transport = Phoenix.PubSub**, topic `claude_hook:<identifier>`.
  The `run_turn` process subscribes at turn start; the endpoint broadcasts the normalized
  event. Reuses the existing `Aiur.PubSub` infra (same as `AgentPubSub`); the run process
  already sits in a `receive` loop, so events land in its mailbox alongside `pane` ticks.
- **Operator-message receipt (R2 confirmation) = match `UserPromptSubmit.prompt` to the
  queued operator text.** When a `UserPromptSubmit` arrives whose `prompt` matches a
  pending operator item's text, mark that item delivered — a precise "received" signal that
  also distinguishes the autopilot prompt from an operator message folded into the same turn.
- **Thinking-only long turns** (no tools → no `PostToolUse` heartbeat): liveness falls back
  to `pane_alive?` plus the generous absolute ceiling; a `Stop` always closes the turn, and
  a dropped `Stop` is caught by the ceiling (not a tight timeout).

### Deferred to Implementation

- Whether to keep the TranscriptTailer running in parallel for richer backfill, or drop it
  for RC entirely — decide once hook rendering is confirmed sufficient.
- Exact `turn_ids` source now that there is no transcript at send time (derive from
  `session_id` once the first hook event arrives, vs a synthetic id) — settle in U3.

---

## Implementation Units

- [ ] U1. **Dashboard claude-hook ingest endpoint**

**Goal:** Receive claude hook events over HTTP and route them to the right agent's turn.

**Requirements:** R2, R3, R6

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur_web/controllers/observability_api_controller.ex` (new `claude_hook` action)
- Modify: `src/lib/aiur_web/router.ex` (`POST /api/v1/:identifier/claude-hook`)
- Create: `src/lib/aiur/claude/hook_events.ex` (parse + normalize the event; dispatch to the agent)
- Test: `src/test/aiur_web/controllers/observability_api_controller_test.exs`,
  `src/test/aiur/claude/hook_events_test.exs`

**Approach:**
- Action reads the raw JSON body, normalizes `{hook_event_name, cwd, session_id,
  prompt, last_assistant_message, tool_name/tool_input}`.
- Dispatch to the agent identified by the path `:identifier`; cross-check `cwd`.
- Unknown/inactive agent → 200 no-op (never error claude's hook; a non-200 or stderr could
  disrupt the session).
- Dispatch mechanism delegated to `HookEvents` (registry/PubSub chosen in U3).

**Test scenarios:**
- Happy path: a `Stop` POST for an active identifier → parsed, dispatched, 200.
- Edge: `UserPromptSubmit` and `PostToolUse` events parse and dispatch.
- Error: unknown identifier or malformed body → 200 no-op, no crash.
- Edge: empty `last_assistant_message` → handled (no nil crash).

**Verification:** `curl`-ing a sample Stop payload to the endpoint dispatches a turn-done
to a registered test process and returns 200.

---

- [ ] U2. **Inject claude hooks via --settings**

**Goal:** Spawn the RC REPL with hooks that POST lifecycle events to the dashboard.

**Requirements:** R1, R2, R5, R6

**Dependencies:** U1 (endpoint must exist for the URL)

**Files:**
- Modify: `src/lib/aiur/claude/repl_agent.ex` (`build_command` adds `--settings <path>`;
  generate the settings file at spawn)
- Create: `src/lib/aiur/claude/hook_settings.ex` (build the settings JSON for an
  identifier + dashboard URL)
- Test: `src/test/aiur/claude/hook_settings_test.exs`,
  `src/test/aiur/claude/repl_agent_test.exs`

**Approach:**
- `HookSettings.write/2` produces a settings JSON with `UserPromptSubmit`, `PostToolUse`,
  `Stop` hooks; each command POSTs the event stdin to `<dashboard>/api/v1/<id>/claude-hook`.
- Command is stdout-silent, `-m 2`, exit 0 (see Key Decisions — this is load-bearing).
- `build_command` writes the file to a per-agent path and appends `--settings <path>`.
- Dashboard URL resolved from the published control URL (same source the tmux Ctrl+C path
  uses).

**Test scenarios:**
- Happy path: generated JSON has all three hook event keys with the correct POST URL.
- Edge: the hook command string emits nothing to stdout and ends with `exit 0` (assert via
  string contract — this guards the claude-stdout gotcha).
- Happy path: `build_command` for an RC session includes `--settings <path>` and still
  carries `--remote-control`/`--permission-mode`/`--model`.
- Edge: non-RC session does not get hooks wired (scope guard).

**Verification:** A spawned RC session's settings file exists and contains the three hooks
pointing at the live dashboard.

---

- [ ] U3. **Hook-driven turn detection in ReplAgent**

**Goal:** Replace transcript polling with hook-event-driven completion; no timeout.

**Requirements:** R1, R2, R3, R4

**Dependencies:** U1, U2

**Files:**
- Modify: `src/lib/aiur/claude/repl_agent.ex` (`run_turn`/`await_turn`; bypass
  `await_transcript`+tailer for RC turn detection)
- Modify: `src/lib/aiur/claude/hook_events.ex` (deliver events to the waiting run process)
- Test: `src/test/aiur/claude/repl_agent_test.exs`

**Approach:**
- On turn start: send the prompt (existing `confirm_typed`/Enter), then register this
  run process to receive hook events for the identifier (Registry or PubSub — chosen here).
- Receive loop: `UserPromptSubmit` → mark received (log/emit); `PostToolUse` → emit a
  progress message (`on_message`) and reset the heartbeat; `Stop` → finish the turn with
  `last_assistant_message`.
- Liveness: keep `pane_alive?` → `{:error, :repl_gone}` on pane death. Remove the 15s
  transcript wait. Optional generous absolute ceiling, reset by any PostToolUse.
- Capture `session_id`/`transcript_path` from events for resume/backfill.

**Execution note:** Test-first for the receive-loop state machine (Stop completes,
PostToolUse heartbeats, no premature timeout).

**Test scenarios:**
- Happy path: a `Stop` event completes the turn; result carries `last_assistant_message`.
- Integration: `PostToolUse` events emit progress and reset the heartbeat; a long gap
  between them (minutes) with the pane alive does NOT fail the turn (R4).
- Error: pane death mid-turn → `{:error, :repl_gone}` (existing transient behavior).
- Edge: a `Stop` with empty message still completes (no crash; renders nothing).

**Verification:** In a controlled spawn, sending a prompt yields a turn that completes on
the Stop event with the correct response, with no transcript file involved.

---

- [ ] U4. **Bridge rendering from hook events**

**Goal:** The opencode pane shows received → progress → response from hook events.

**Requirements:** R2, R5, R6

**Dependencies:** U1, U3

**Files:**
- Modify: `src/lib/aiur/claude/hook_events.ex` and/or `src/lib/aiur/agent_runner.ex`
  (broadcast hook-derived transcript events)
- Test: `src/test/aiur/claude/hook_events_test.exs`

**Approach:**
- `UserPromptSubmit` → `AgentPubSub.broadcast_transcript(id, transcript_event(:user, prompt))`.
- `PostToolUse` → a progress/tool transcript event (dim/`→ tool` styling consistent with
  the bridge's existing rows).
- `Stop` → `transcript_event(:assistant, last_assistant_message)` + the existing
  turn-done lifecycle so the bridge closes the assistant message.
- Ensure operator-message round-trip: the opencode-typed message reaches claude (existing
  `send_operator_message` into the pane), `UserPromptSubmit` confirms receipt, `Stop`
  renders the answer back in the pane.

**Test scenarios:**
- Happy path: each event type produces the expected transcript broadcast.
- Integration: an operator message → `UserPromptSubmit` (user row) then `Stop` (assistant
  row) render in order.

**Verification:** With an opencode pane attached in `--test3`, a typed message shows the
user line, live tool progress, then the assistant answer.

---

- [ ] U5. **End-to-end manual verification + gate green**

**Goal:** Prove the full flow in a real run and restore tooling green.

**Requirements:** R1–R7

**Dependencies:** U1–U4

**Files:** any `@spec`/credo/dialyzer cleanup from U1–U4.

**Approach:**
- Controlled claude spawn: confirm hooks POST to the dashboard and a turn completes on Stop.
- `aiurdev --test3`: confirm RC-claude (101) runs autopilot (no `:no_transcript` loop);
  an opencode-pane message is received + answered; an RC-channel message works; PostToolUse
  progress streams; Stop publishes completion + final message. Kill the run once captured.
- Run compile `--warnings-as-errors`, test, credo `--strict`, dialyzer; fix findings.

**Test expectation:** none (verification + tooling); behavior covered by U1–U4.

**Verification:** Green gate; a real `--test3` run shows 101 stable and answering opencode
messages, with no `Agent run failed: :no_transcript`.

---

## System-Wide Impact

- **Interaction graph:** new inbound path claude hook → dashboard endpoint → HookEvents →
  ReplAgent run process + AgentPubSub → opencode bridge. Mirrors the existing pane-interrupt
  control path and the bridge's transcript subscription.
- **Error propagation:** the hook endpoint must NEVER error claude (always 200); a
  dropped/late hook must degrade to pane-liveness, not a false turn failure.
- **State lifecycle:** removing the 15s transcript failure removes the re-dispatch loop;
  `:repl_gone` stays the genuine failure.
- **Unchanged invariants:** non-RC/headless backends, codex, the bridge protocol, and the
  RC autonomy invariant are unchanged.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Hook stdout disrupts claude (context injection / blocked stop) | Command emits nothing to stdout, `exit 0`; asserted in U2 tests |
| Slow/failed hook curl stalls claude | `-m 2`, fire-and-forget, exit 0 regardless |
| Late/dropped hook event hangs the turn | pane-liveness backstop + generous absolute ceiling reset by heartbeats |
| claude changes the hook payload contract | hooks are documented/stable; normalize defensively, no crash on missing keys |
| `--test3` burns real-agent tokens | kill immediately after evidence (memory `test3_cost_discipline`) |

---

## Sources & References

- Experiments + root cause: memory `project_bug1_no_transcript_root`.
- Code: `src/lib/aiur/claude/repl_agent.ex`, `src/lib/aiur/agent_pubsub.ex`,
  `src/lib/aiur_web/controllers/observability_api_controller.ex`.
- Prior plan (Bug 2 fixed, Bug 3 pinned): `docs/plans/2026-06-13-001-fix-operator-message-delivery-plan.md`.
