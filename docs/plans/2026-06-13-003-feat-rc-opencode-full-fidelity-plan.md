---
title: "feat: RC-claude opencode pane full-conversation fidelity"
type: feat
status: active
date: 2026-06-13
origin: docs/brainstorms/2026-06-13-rc-opencode-full-fidelity-requirements.md
---

# feat: RC-claude opencode pane full-conversation fidelity

## Overview

For an RC-claude agent, make the opencode chat pane a faithful, full view of the same conversation the Claude remote-control (RC) channel shows. Today the opencode pane is reconstructed from three hook signals only (`UserPromptSubmit`, `PostToolUse` tool-name, `Stop` final message) and reads as a different, thinner log. This plan drives the opencode display from the claude transcript jsonl — reusing the already-built `Aiur.Claude.TranscriptTailer` + `Aiur.Claude.Transcript` — while hooks keep doing turn detection/control. The result is two views of one conversation.

The heavy lifting already exists: `Aiur.Claude.Transcript.extract_disk_record/2` maps every record type to a role (text→`:assistant`, thinking→`:reasoning`, Bash→`:command`, edits→`:tool` w/ diff, tool_result→`:tool` output, user prompt→`:user`, RC-app `queued_command` attachment→`:user` `origin: :remote`), the opencode renderer already supports those roles, and `session_writer` already dedups plain `:user` events and replays history on attach. The missing piece is simply **running the tailer for RC-claude hook sessions**, which the hook-based turn-detection switch stopped doing.

---

## Problem Frame

One claude process per RC-claude issue; the RC channel and the opencode pane are two views of it. The opencode view is a sparse skeleton because `drive_turn_via_hooks` emits only `→ Tool` rows (no I/O) and the single final assistant message per turn — it never runs the transcript tailer that the pre-hooks path (`drive_turn_via_transcript`) used for display. Operators read this as "two different agents." See origin: `docs/brainstorms/2026-06-13-rc-opencode-full-fidelity-requirements.md`. Pinned task #27, axis 2. Not a regression from the prompt-submit fix (`d98dd4f`).

---

## Requirements Trace

- R1. Opencode shows full parity content for RC-claude: user prompts, thinking (`:reasoning`), intermediate assistant text (`:assistant`), tool calls with inputs **and** outputs (`:command`/`:tool`), in transcript order.
- R2. Opening the opencode pane mid-conversation replays the full prior conversation (backfill).
- R3. Single display source — no double-render of tool rows or the final message.
- R4. Read-only — display never re-sends or re-prompts the agent.
- R5. Display-only failure isolation — any jsonl flush-lag / partial-line / unknown-block / missing-file / tailer crash degrades gracefully and never affects turn detection or the agent run.
- R6. Session-rotation aware — follow the current session's `transcript_path` when `session_id` rotates mid-run.
- R7. Large tool outputs / thinking blocks are capped to keep the pane readable.

**Origin acceptance examples:** the origin's success criteria — live `--test3` parity, mid-convo backfill, simulated-jsonl-failure isolation, green gate — map to R1/R2, R2, R5, and the verification gate respectively.

---

## Scope Boundaries

- RC-claude (`claude --remote-control`, hook-driven) agents only.
- Out (separate, #27 axis 1): real-time operator-message consumption for codex + non-RC claude; the opencode bridge double-dispatch. Codex already streams its own rich transcript and is untouched.
- No new opencode rendering — the roles (`:reasoning`, `:tool` w/ I/O, `:command`, `:assistant`, `:user`) already render.
- Turn detection / control stays on hooks (unchanged from the recent fix).

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/claude/transcript_tailer.ex` — built, robust GenServer: byte-offset tailing, partial-line safe, truncation/replacement reset, `:from :start|:end`, `interval_ms` (timer) or sync `poll/1`, `on_message` + `on_turn_end`. Its moduledoc explicitly names this the "dual-chat fan-out" mechanism.
- `src/lib/aiur/claude/transcript.ex` — `extract_disk_record/2` maps every on-disk record/block to a role (incl. thinking→`:reasoning`, tool I/O, RC-app `queued_command`→`:user` `origin: :remote`).
- `src/lib/aiur/claude/repl_agent.ex` — `start_turn_tailer/4` (`:853`) shows the tailer wiring; `drive_turn_via_hooks` (`:487`), `await_hook_turn` (`:529`), `maybe_emit_tool_progress` (`:592`) and `finish_hook_turn` assistant emit (`:600`) are the sparse emissions to remove; `emit_transcript/2` (`:995`).
- `src/lib/aiur/claude/hook_events.ex` — `normalize/1` (`:74`) builds the event; currently lacks `transcript_path`.
- `src/lib/aiur/agent_runner.ex` — `run_codex_turns/5` (`:411`) resolves backend + `rc?`, starts the session (`:433`), runs `do_run_codex_turns`; `codex_message_handler/6` (`:244`) builds the run's `on_message`; `maybe_broadcast_transcript` (`:254`) → `transcript_event_from` (`:281`) → `AgentPubSub.broadcast_transcript`.
- `src/lib/aiur/opencode/session_writer.ex` — `:173` keeps `:user` `origin: :remote`, `:187` drops plain `:user` (dedup already handled); `:494`/`:749` render `:reasoning`/`:tool`/etc.
- `src/lib/aiur/opencode/chat_completions.ex` — `:436` renders the rich roles; `:500` italic `:reasoning`; `:473` `:tool` I/O. Replay/backfill via `src/lib/aiur/opencode/db.ex` `replay_history` + `protocol.ex` `:replay_root`.

### Institutional Learnings

- `project_rc_opencode_sparse_mirror` — the bug; one agent, two fidelities.
- `feedback_repl_backfill_display_only` — the tailer/replay is DISPLAY-only; never re-prompt the agent.
- `project_bug1_no_transcript_root` — lazy flush broke timing-critical turn *detection*; it is tolerable for lag-tolerant *display*.
- `project_rc_prompt_submit_paste_race` — recent submit fix; do not disturb hook turn detection.

---

## Key Technical Decisions

- **Reuse, don't rebuild.** `TranscriptTailer` + `Transcript.extract_disk_record/2` already do tailing + full record→role mapping. The work is running the tailer for hook sessions and wiring lifetime — not new parsing or rendering.
- **Responsibility split.** Hooks = turn detection/control (unchanged). A run-scoped transcript tailer = display (full convo). The two are independent (pubsub vs file); no coupling.
- **Run-scoped, not per-turn.** A per-turn `:from :start` tailer would re-read the whole jsonl every turn (duplicates). Host one tailer for the agent run, `:from :start` once (backfill), then continuous tailing across turns.
- **Self-targeting via hooks.** The display tailer learns `transcript_path` from hook events (added to the normalized event) and retargets on change — handling lazy-flush (start when the path first appears) and session rotation (`d01d5f9e`→`955a9c15`) uniformly.
- **Display-only isolation.** The tailer runs as a separate, supervised/unlinked process; its crash or any parse error degrades the view but never propagates to the runner task or hook turn loop. `TranscriptTailer.decode/1` already skips malformed lines.
- **Dedup by deletion.** Remove the sparse hook display emissions so the tailer is the single display source. Plain `:user` dedup is already handled downstream by `session_writer`.

---

## Open Questions

### Resolved During Planning

- Where does the tailer's output reach opencode? Via the run's `on_message` → `maybe_broadcast_transcript` → `broadcast_transcript` → `session_writer` (the existing transcript-backend path).
- How is backfill achieved? `:from :start` emits the whole jsonl; `session_writer` persists and opencode replays on attach. No new backfill code.
- How is user-message double-render avoided? `session_writer` already drops plain `:user` (`:187`); RC-app messages arrive as `:user` `origin: :remote` and are kept.

### Deferred to Implementation

- Exact host/supervision for the run-scoped tailer (Registry keyed by identifier vs. threaded through the session vs. a child under the runner task's supervisor) — pick the lowest-friction option that guarantees one-per-run lifetime + clean stop. U2/U3 specify behavior, not the registry mechanism.
- Exact truncation thresholds for very large tool outputs / thinking (R7) — set once real output sizes are observed in `--test3`; cap in the emit path or rendering.
- Whether `interval_ms` default (400ms) needs tuning for perceived latency vs. load — measure in U5.

---

## Implementation Units

- [ ] U1. **Carry `transcript_path` on normalized hook events**

**Goal:** The display tailer can learn the active session's jsonl path from hooks.

**Requirements:** R1, R6

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur/claude/hook_events.ex` (add `transcript_path` to `@type event` and `normalize/1`)
- Test: `src/test/aiur/claude/hook_events_test.exs`

**Approach:**
- Extract `string_or_nil(Map.get(raw, "transcript_path"))` into the normalized event alongside `session_id`/`cwd`. No behavior change to dispatch/broadcast.

**Patterns to follow:** the existing `session_id`/`cwd` extraction in `normalize/1`.

**Test scenarios:**
- Happy path: a PostToolUse/Stop raw payload with `transcript_path` → normalized event carries it.
- Edge case: missing `transcript_path` key → `nil`, no crash.

**Verification:** normalized hook events expose `transcript_path`; existing hook_events tests stay green.

---

- [ ] U2. **`Aiur.Claude.DisplayTailer` — run-scoped, hook-driven transcript display**

**Goal:** A display-only process that mirrors the full claude transcript into the run's `on_message`, learning and following `transcript_path` from hooks.

**Requirements:** R1, R2, R4, R5, R6, R7

**Dependencies:** U1

**Files:**
- Create: `src/lib/aiur/claude/display_tailer.ex`
- Test: `src/test/aiur/claude/display_tailer_test.exs`

**Approach:**
- GenServer started with `identifier` + `on_message`. Subscribes to `Aiur.Claude.HookEvents.subscribe(identifier)`.
- On the first hook carrying a `transcript_path` (that exists), start an internal `TranscriptTailer` with `from: :start` (backfill), `interval_ms:` the default, `turn_id: nil`, `on_message:` a wrapper that forwards each event through the run's `on_message` as a display transcript event (mirror `emit_transcript/2`'s `%{event: :transcript, transcript_event: event}` shape so it flows through `maybe_broadcast_transcript`). `on_turn_end:` is a no-op (hooks own turn completion).
- On a later hook whose `transcript_path` differs from the current target (session rotation), stop the old `TranscriptTailer` and start a fresh one (`from: :start`) on the new path.
- Read-only (R4): never sends keys / never calls any agent-input path.
- Failure isolation (R5): trap exits / supervise the inner tailer; a tailer crash or a missing/short file is logged and retried on the next hook, never raised. Malformed lines are already skipped by `TranscriptTailer`.
- Large content (R7): cap oversized `:reasoning`/`:tool` `output` bodies (truncate with an elision marker) before forwarding — thresholds deferred.

**Technical design:** *(directional, not implementation spec)*
```
DisplayTailer(identifier, on_message)
  subscribe claude_hook:identifier
  on {:claude_hook, _, %{transcript_path: p}} when p != current and File.exists?(p):
     stop inner tailer if any
     inner = TranscriptTailer.start_link(path: p, from: :start, turn_id: nil,
               on_message: fn ev -> on_message.(%{event: :transcript, transcript_event: cap(ev)}) end,
               on_turn_end: noop)
     current = p
```

**Patterns to follow:** `start_turn_tailer/4` in `repl_agent.ex`; `HookEvents.subscribe/1`; `emit_transcript/2`.

**Test scenarios:**
- Happy path: feed a temp jsonl (user prompt, thinking, assistant text, tool_use, tool_result), dispatch a hook naming it → forwarded `on_message` receives `:user`, `:reasoning`, `:assistant`, `:command`/`:tool` (input), `:tool` (output) events in order.
- Backfill (R2): jsonl pre-populated before the first hook → first read emits the full history (`from: :start`).
- Session rotation (R6): a second hook with a different `transcript_path` → tailer retargets and emits the new file from its start; old file no longer tailed.
- Failure isolation (R5): hook names a non-existent path → no crash, no events, recovers when a valid path arrives; a garbage/partial line in the jsonl is skipped without crashing.
- Read-only (R4): no tmux/send-keys/agent-input calls occur (assert via mock or absence).
- Large content (R7): an oversized tool output is truncated with an elision marker.

**Verification:** given hooks + a transcript file, the run's `on_message` receives the full, ordered, role-mapped conversation; the process survives bad input.

---

- [ ] U3. **Wire `DisplayTailer` into the agent run for RC-claude**

**Goal:** Start one `DisplayTailer` per RC-claude agent run with the run's `on_message`; stop it at run end.

**Requirements:** R1, R2, R3, R5

**Dependencies:** U2

**Files:**
- Modify: `src/lib/aiur/agent_runner.ex` (`run_codex_turns/5` / `do_run_codex_turns` — start/stop around the turn loop, gated on `rc?` and `claude-repl` backend)
- Test: `src/test/aiur/agent_runner_test.exs`

**Approach:**
- For a hook-driven RC claude-repl session (the same condition that injects hooks / sets `identifier`), start a `DisplayTailer` with `issue.identifier` and the run's `message_handler` (`codex_message_handler/6`) before the turn loop; ensure it is stopped in the loop's teardown (mirror the `after`/cleanup the session uses). One per run, keyed by identifier.
- Non-RC / codex / non-hook sessions: do not start it (unchanged behavior; codex already streams).

**Patterns to follow:** how the session + `message_handler` are constructed in `run_codex_turns`; existing teardown/`after` cleanup in the runner.

**Test scenarios:**
- Happy path: an RC claude-repl run starts a `DisplayTailer` (assert started with the run identifier + on_message); a codex run does not.
- Lifecycle (R5): when the run ends/errors, the `DisplayTailer` is stopped (no orphan process).
- Integration: a transcript event forwarded by the tailer reaches `maybe_broadcast_transcript` (i.e., the wiring to opencode is intact).

**Verification:** RC-claude runs have a live display tailer feeding opencode; other backends are unaffected; no orphaned tailers after the run.

---

- [ ] U4. **Remove the sparse hook display emissions (single display source)**

**Goal:** Stop emitting the `→ Tool` rows and the single final assistant message from the hook turn loop so the tailer is the only thing painting the conversation (R3) — without losing turn-completion control.

**Requirements:** R3

**Dependencies:** U3

**Files:**
- Modify: `src/lib/aiur/claude/repl_agent.ex` (drop the display emit in `maybe_emit_tool_progress` `:592` and the `:assistant` emit in `finish_hook_turn` `:600`)
- Test: `src/test/aiur/claude/repl_agent_test.exs`

**Approach:**
- Keep all **control** emissions: `:turn_completed`, `:turn_paused`, `:turn_ended_with_error`, deadline/heartbeat resets, and the `Stop`-driven completion return value (the runner still needs `last_assistant_message` for its own bookkeeping — keep returning it in the result, just stop broadcasting it as a display transcript event).
- Remove only the two DISPLAY transcript emissions. `await_hook_turn` still consumes PostToolUse for heartbeat/deadline reset; it just no longer paints `→ Tool`.
- Land with U3 so there is never a window where display is empty (tailer must be live first).

**Patterns to follow:** the existing separation of `emit/3` (control) vs `emit_transcript/2` (display) in `repl_agent.ex`.

**Test scenarios:**
- Happy path: a hook-driven turn still completes on `Stop` and returns `last_assistant_message` in the result (control intact), but no `:tool`/`:assistant` display transcript event is emitted from the hook loop (update the existing hook tests that assert `→ Bash`/assistant rows — those assertions move to the DisplayTailer tests).
- Regression: PostToolUse still resets the backstop deadline / heartbeat (no false `:turn_timeout`).

**Verification:** the hook loop emits control events only; the existing hook turn-detection + heartbeat behavior is unchanged; no double-render with the tailer.

---

- [ ] U5. **Live parity verification + failure-injection check**

**Goal:** Prove the two views match in a real run and that display failure is isolated.

**Requirements:** R1, R2, R5, plus the gate

**Dependencies:** U1–U4

**Files:**
- Test: covered by U2–U4 unit tests; this unit is manual/live verification + any integration test gaps found.

**Approach:**
- `aiurdev --test3`, open issue 101, drive a turn; capture the opencode pane and compare against the RC channel / the claude transcript jsonl: thinking, tool I/O, intermediate text, final answer all present and ordered (R1). Open the pane mid-conversation and confirm full backfill (R2).
- Failure injection (R5): point/observe a truncated or garbage transcript line (or briefly a missing file across a session rotation) and confirm the pane thins/empties but the agent run + hook turn detection continue with no crash / no `:repl_gone`.
- Cost discipline: tear down the run promptly once evidence is captured.

**Test scenarios:**
- Covers the origin success criteria: live parity, backfill, failure isolation, green gate (compile / test / credo / dialyzer).

**Verification:** opencode pane and RC channel read as two views of one conversation; injected jsonl faults do not affect the agent; full gate green.

---

## System-Wide Impact

- **Interaction graph:** new `DisplayTailer` subscribes to `claude_hook:<identifier>` (additional pubsub subscriber alongside `drive_turn_via_hooks`); emits via the run's `on_message` → `maybe_broadcast_transcript` → opencode `session_writer`. No change to hook turn detection or control flow.
- **Error propagation:** display tailer is isolated — failures must not reach the runner task or hook loop (R5).
- **State lifecycle risks:** one tailer per run; must be stopped on run end/error (no orphan); offset/target reset on session rotation; backfill `:from :start` must run once per target (not per turn) to avoid duplicate history.
- **API surface parity:** RC-claude only. Codex/non-RC unchanged (already rich). Non-RC claude (transcript backend) already runs the tailer via `drive_turn_via_transcript` — unaffected.
- **Unchanged invariants:** hook-based turn detection/heartbeat/completion (the recent fix), the prompt-submit paste-wait, and the operator-message native-queue delivery all stay as-is. This plan only adds a display feed and removes two display emissions.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| jsonl schema drift thins the view | Display-only — degrades gracefully; `Transcript`/`TranscriptTailer` already skip unknown blocks/bad lines; covered by R5 tests |
| Lazy-flush makes display lag the RC view | Acceptable for display; tailer catches up; not on the control path |
| Per-turn restart re-reads whole jsonl (duplicate history) | Run-scoped tailer with persistent offset; `:from :start` once per target (U2/U3) |
| Removing sparse emissions before the tailer is live → empty pane window | U4 depends on U3; land together so the tailer is the live source first |
| Orphaned tailer process after run | Explicit stop in runner teardown (U3 lifecycle test) |
| Huge tool outputs / thinking flood the pane | Cap/truncate in the emit path (R7); thresholds tuned in U5 |
| Session rotation strands display on a stale jsonl | Retarget on `transcript_path` change (U2, R6) |

---

## Sources & References

- **Origin document:** docs/brainstorms/2026-06-13-rc-opencode-full-fidelity-requirements.md
- Related code: `src/lib/aiur/claude/transcript_tailer.ex`, `src/lib/aiur/claude/transcript.ex`, `src/lib/aiur/claude/repl_agent.ex`, `src/lib/aiur/claude/hook_events.ex`, `src/lib/aiur/agent_runner.ex`, `src/lib/aiur/opencode/session_writer.ex`, `src/lib/aiur/opencode/chat_completions.ex`
- Related work: plan `2026-06-13-002` (hook turn detection), commit `d98dd4f` (paste-wait submit fix); pinned task #27 axis 2
