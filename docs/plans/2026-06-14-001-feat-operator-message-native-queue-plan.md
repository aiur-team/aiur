---
title: "feat: Operator-message parity — opencode pane == claude RC native queue"
type: feat
status: active
date: 2026-06-14
origin: docs/brainstorms/2026-06-14-operator-message-native-queue-requirements.md
---

# feat: Operator-message parity — opencode pane == claude RC native queue

## Overview

Make an operator message typed into the aiur **opencode** tmux pane reach a `claude-repl` agent exactly the way claude's **RC** (remote-control) UI delivers it: as the operator's raw text, once, consumed at the agent's next turn boundary. Today the opencode path forwards opencode's `<system-reminder>` wrapper (which tells claude to "continue with your tasks" instead of answering) and forwards it **twice**, and it clears the pending indicator at accept-time rather than when claude actually reads the message. RC works because it bypasses all of this and sends raw text to claude's native input.

This is **not** a queue re-architecture. `claude-repl` already delivers immediately into the pane and lets claude's native queue fold the message in (`src/lib/aiur/coding_agent.ex` — `immediate_delivery: true, safe_checkpoints: []`). We remove the two defects that make opencode diverge from RC.

---

## Problem Frame

Two operator surfaces talk to a `claude-repl` agent:

- **RC** — claude's own `https://claude.ai/code/session_…` UI. Sends raw text to claude's native input. Works (answers "456" in <10s).
- **opencode** — aiur's tmux pane → opencode binary → aiur bridge (`src/lib/aiur/opencode/chat_completions.ex`) → `send_keys` paste into the claude pane. Broken: "respond exactly 123" is delivered (wrapped + doubled) but never answered, and the pane shows it as sent/read before claude consumes it.

Root cause (verified in source + opencode 1.15.6 binary; see origin doc): opencode wraps operator text in `<system-reminder>` envelopes — a benign idle form (`Message sent at <UTC>` + raw text) and a harmful mid-stream form (`The user sent the following message: <RAW>  Please address this message and continue with your tasks.`). The bridge forwards the wrapper verbatim, and forwards the message on **two** paths (primary `stream_turn` + coalesce `dispatch_shadowed_operator_texts`). Separately, the bridge acks the operator SSE at accept-time (`chat_completions.ex` ~638–662), so the pane stops indicating "pending" before claude reads the message.

---

## Requirements Trace

- R1. An opencode operator message reaches claude as the operator's **raw text only** (no `<system-reminder>` / "continue with your tasks" wrapper), identical to what RC sends. (origin SC1, SC2)
- R2. The opencode pane keeps indicating the message is **pending/unread** until claude actually consumes it (matching `UserPromptSubmit` hook), then clears. (origin SC3, task #37)
- R3. A message sent from either surface renders **once**, attributed correctly, in **both** views (opencode pane + claude transcript). (origin SC4)
- R4. Default mid-turn behavior stays native: **queue and fold at the next turn boundary**; never cut the agent off; interrupt (Ctrl+C to the pane) remains the explicit out-of-band stop. (origin Goal 4)
- R5. Codex and non-RC/headless claude operator-message behavior is **unchanged**. (origin SC5)
- R6 (adjacent, trivial). The operator-visible model label for issue 101 reads `sonnet`, matching the already-correct process model. (origin "Adjacent fixes")

**Origin acceptance example (canonical gate):** typing `pause and respond exactly "123"` in the opencode pane while the agent is mid-turn → the agent answers `123` at the next turn boundary, identical to typing it in the RC UI.

---

## Scope Boundaries

- **Codex and non-RC/headless claude delivery** — untouched. The shared `AgentQueue`/`delivery_policy` machinery stays; we change *what text* the bridge forwards and *when* it acks, not the queue. (Tasks #25/#27 remain pinned.)
- **No new queue, no removal of the shared queue.** For `claude-repl` the queue is already a thin immediate pass-through.
- **No programmatic RC-channel send.** aiur has no handle on claude's RC channel (`src/lib/aiur/claude/remote_control.ex` only parses the session URL). RC stays the user-driven claude.ai UI.
- **Bridge streaming/turn-marker model** (the held-open `__aiur_turn__`/`__aiur_stream__` SSE rendering) is not redesigned — only extended where U2 needs a read signal.

### Deferred to Follow-Up Work

- **TUI mojibake flicker** (intermittent `?????`/`??` on box-drawing + emoji glyphs — header icons over `AIUR`, the `oldest` divider). Needs its own repro: confirm whether it reproduces outside `--test3`, then a separate `fix:` plan. Hypothesis: partial flush of multibyte UTF-8 in the renderer or a render/encoding race possibly aggravated by the `--test3` screen recorder. Not entangled with this plan.

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/opencode/chat_completions.ex` — the "bridge as LLM." Operator-text entry: `handle_identified_text/4` (raw-text path → `stream_turn` → `send_operator`), `dispatch_shadowed_operator_texts/2` (coalesce path), `trailing_user_texts/1`, `message_user_text/1`, `last_user_text/1`, `validate_body/1`. SSE ack at `stream_turn` / `non_stream_turn` (closes with `finish_reason: "stop"` on `AgentChat.send` accept).
- `src/lib/aiur/claude/repl_agent.ex` — `send_operator_message/2` pastes via `Tmux.send_keys_literal` + `Tmux.send_enter` (native-queue delivery); `sanitize_pane_input/1` collapses control bytes.
- `src/lib/aiur/coding_agent.ex` — backend capability registry; `claude-repl` is `immediate_delivery: true, safe_checkpoints: []`.
- `src/lib/aiur/claude/hook_events.ex` — `UserPromptSubmit` normalization + per-agent PubSub topic (`subscribe/1`, `topic/1`); carries the submitted `prompt`. This is the **read signal** source for U2.
- `src/lib/aiur/claude/display_tailer.ex` + `src/lib/aiur/opencode/session_writer.ex` — transcript mirror into opencode (display-only); session_writer already drops plain `:user` events and keeps `origin: remote`. Relevant to U3 dedupe.
- `src/lib/aiur/agent_chat.ex` — `AgentChat.send/3` facade; broadcasts a `:user` transcript event on accept.

### Institutional Learnings (operator/session memory)

- REPL operator messages should use claude's **native queue** (forward keystrokes; no bespoke delivery; don't cut the agent off mid-work by default) — this plan realizes that intent by removing the wrapper, not by adding delivery logic.
- opencode was historically a **sparse hook-only mirror**; it is now a full transcript view via the DisplayTailer — so U3 must guard against double-rendering opencode's own echo plus the tailer reflection.
- The DisplayTailer/backfill is **display-only** — never re-prompts or re-sends. U2/U3 must not introduce a send from the display path.
- RC prompt submit has a **paste→Enter race** (Enter must wait for the paste to land); U1's normalization must not reintroduce early submit, and must keep `send_operator_message/2`'s single explicit Enter.

### External References

- opencode 1.15.6 binary (`~/.local/share/mise/installs/opencode/1.15.6/opencode`) — wrapper template confirmed verbatim: `["<system-reminder>","The user sent the following message:",<RAW>,"","Please address this message and continue with your tasks.","</system-reminder>"].join("\n")`, plus opencode's own `SYSTEM_REMINDER_RE = /<system-reminder>([\s\S]*?)<\/system-reminder>/g`. Version is pinned via mise, so the template is a stable contract.

---

## Key Technical Decisions

- **Normalize at one choke point, over the trailing-user batch.** Rather than patch the primary and coalesce paths separately, route all `claude-repl` operator-text forwarding through a single "extract raw → dedupe → forward once" helper applied to `trailing_user_texts`. This fixes both the wrapper and the double-send together.
- **Extraction, not avoidance.** Strip `<system-reminder>…</system-reminder>` envelopes and recover the inner operator text (both opencode forms). Chosen over reworking the bridge's held-open turn-stream model to make opencode think it's idle (high risk; origin spike rejected it).
- **Read signal = `UserPromptSubmit` hook.** The bridge (or the orchestrator-side delivery record) correlates the pending operator message to the next `UserPromptSubmit` whose `prompt` contains the raw text, and only then resolves the pending/QUEUED state. Bounded by the existing `@watchdog_ms`; on timeout, fall back to today's accept-time close (best-effort) so a very long turn can't wedge the SSE.
- **Backend-gated.** All changes apply only when the target backend is `claude-repl`; codex/non-RC claude keep current behavior (R5).

---

## Open Questions

### Resolved During Planning

- *How do we get the operator's raw text past opencode's wrapper?* — Deterministic extraction of the `<system-reminder>` envelope (template is version-pinned). (origin spike)
- *Drop the bespoke queue?* — No; for `claude-repl` it's already an immediate pass-through. Fix the wrapper + ack, keep the queue.
- *Interrupt vs queue default?* — Queue & fold at boundary (native); interrupt stays explicit. (origin decision)

### Deferred to Implementation

- **Exact opencode UI transition for U2.** Whether holding the operator SSE open keeps the pane in a "pending" state (vs spinner vs timestamped-sent) is opencode-UI runtime behavior — must be confirmed by manual `aiurdev --test` observation, not assumed. If holding the SSE does not produce the desired "unread until consumed" affordance, fall back to correlating the read signal to a lightweight pane re-render. Resolve by observation during U2.
- **Correlation robustness** when two operator messages are in flight or text repeats — final matching key (raw-text contains vs a per-message token) settled against real `UserPromptSubmit` payloads.
- **Where "opus" surfaces to the operator** (U4) — confirm whether it's the `.aiurconfig` `version` label, a render label, or the agent self-identifying; fix the actual surface.

---

## Implementation Units

- [ ] U1. **Normalize opencode operator text → raw, once**

**Goal:** The bridge forwards the operator's genuine raw text to claude (no `<system-reminder>` wrapper), exactly once — eliminating both the "continue with your tasks" corruption and the double-send.

**Requirements:** R1, R3 (partial), R4

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur/opencode/chat_completions.ex`
- Test: `src/test/aiur/opencode/chat_completions_test.exs`

**Approach:**
- Add a pure normalization helper: given a user-message string, strip `<system-reminder>…</system-reminder>` blocks and recover the operator's raw text for both opencode forms — idle (`Message sent at <UTC>.` reminder followed by raw text) and mid-stream (`The user sent the following message:\n<RAW>\n\nPlease address this message and continue with your tasks.`). If the message is *entirely* a synthetic reminder with no recoverable user text, drop it.
- Apply normalization at the single forwarding choke point for operator text. Collect `trailing_user_texts`, exclude aiur's own `__aiur_turn__`/`__aiur_stream__` markers (existing `synthetic_marker_text?`), normalize each, drop empties, **dedupe**, and forward each once via `send_operator`. This unifies the primary (`stream_turn`) and coalesce (`dispatch_shadowed_operator_texts`) paths so a message is not sent both wrapped and raw.
- Preserve the existing single-Enter submit semantics downstream (`repl_agent.ex` `send_operator_message/2`) — do not change paste/Enter timing (paste-race learning).

**Patterns to follow:**
- Existing batch helpers `trailing_user_texts/1`, `synthetic_marker_text?/1`, `validate_body/1` in the same module.

**Test scenarios:**
- Happy path: mid-stream wrapper input → forwards exactly `pause and respond exactly "123"` (Covers AE: the canonical "123" gate at the unit level).
- Happy path: idle wrapper (`Message sent at <UTC>` + raw) → forwards the raw text only.
- Edge case: already-raw text (no reminder) → forwarded unchanged.
- Edge case: multiple/nested `<system-reminder>` blocks → all stripped, inner user text preserved.
- Edge case: message that is purely a synthetic reminder with no user text → dropped (no send).
- Edge case: trailing batch containing the same operator message in both wrapped and raw form → **one** `send_operator` call (dedupe).
- Edge case: `__aiur_turn__`/`__aiur_stream__` markers in the batch → never forwarded as operator text (unchanged).

**Verification:** Bridge unit tests pass; for a wrapped input the recorded `send_operator`/`AgentChat.send` body equals the operator's raw text and fires once.

---

- [ ] U2. **Clear the pending indicator on actual read (UserPromptSubmit), not on accept**

**Goal:** The opencode pane reflects the operator message as unread/pending until claude consumes it; it resolves when the matching `UserPromptSubmit` hook fires (or a bounded fallback).

**Requirements:** R2

**Dependencies:** U1 (correlation matches on the normalized raw text)

**Files:**
- Modify: `src/lib/aiur/opencode/chat_completions.ex` (operator SSE lifecycle: `stream_turn/3`, `non_stream_turn/3`)
- Modify (if needed for correlation): `src/lib/aiur/operator_wait_log.ex`
- Test: `src/test/aiur/opencode/chat_completions_test.exs`

**Approach:**
- Replace the accept-time `finish_reason: "stop"` close (after `AgentChat.send` returns `{:ok, _}`) with a wait on the read signal: subscribe to the agent's claude-hook topic (`HookEvents.subscribe/1`) and resolve the SSE when a `UserPromptSubmit` arrives whose `prompt` contains the forwarded raw text.
- Bound the wait by the existing `@watchdog_ms`; on timeout (e.g., turn longer than the bound, or hook unavailable), close as today so the SSE can never wedge. Keep the agent's eventual *response* streaming on the existing turn-marker path (unchanged).
- Backend-gate: only `claude-repl` (which emits hooks) takes the wait; other backends keep accept-time close (R5).

**Execution note:** Confirm the opencode-pane UI transition by manual `aiurdev --test` observation before declaring done — this unit's success is a rendered-pane behavior, not a log line (AGENTS.md manual-testing rule).

**Patterns to follow:**
- `HookEvents.subscribe/1` + receive loop, mirroring how `DisplayTailer`/run-turn consume hook events; `@watchdog_ms` bounding already present in the module.

**Test scenarios:**
- Happy path: operator message forwarded; a matching `UserPromptSubmit` arrives → SSE resolves (pending cleared) only then.
- Error/timeout: no matching hook within the watchdog bound → SSE closes via fallback (no hang).
- Integration: the read-signal wait does not block or reorder the agent's response stream on the turn-marker path.
- Edge case: non-`claude-repl` backend → unchanged accept-time close.

**Verification:** Unit tests prove resolve-on-hook vs fallback-on-timeout; manual `--test` shows the pane keeps the message pending until the agent picks it up, then clears.

---

- [ ] U3. **Single, correctly-attributed render across both surfaces**

**Goal:** A message from either surface appears once in the opencode pane and once in the claude transcript view, attributed to the operator — no doubles from opencode's own echo plus the DisplayTailer reflection.

**Requirements:** R3

**Dependencies:** U1 (raw text now matches across echo and transcript, enabling text-based dedupe)

**Files:**
- Modify: `src/lib/aiur/opencode/session_writer.ex`
- Verify/adjust: `src/lib/aiur/opencode/chat_completions.ex` (`transcript_delta/2` `:user` drop), `src/lib/aiur/claude/display_tailer.ex`
- Test: `src/test/aiur/opencode/session_writer_test.exs`

**Approach:**
- Confirm the existing `:user`-drop dedupe (session_writer drops plain `:user`, keeps `origin: remote`) still holds once U1 makes the forwarded text equal to opencode's own echo and to what claude writes to its transcript. Adjust the dedupe key if the previous wrapped-vs-raw mismatch was masking a double.
- RC-typed messages (claude writes them to its transcript) must surface in the opencode pane via the tailer exactly once, attributed as operator/remote.

**Test scenarios:**
- Integration: opencode-typed message → appears once in the opencode pane (operator echo retained; tailer reflection of the same text deduped).
- Integration: RC-typed message → appears once in the opencode pane via the tailer, attributed to the operator.
- Edge case: agent assistant/tool transcript events still render (dedupe scoped to operator `:user` text only).

**Verification:** session_writer tests assert single render + attribution; manual `--test` shows no double operator lines in either view.

---

- [ ] U4. **Align operator-visible model label to sonnet**

**Goal:** Remove the misleading "opus" the operator sees for issue 101; the process is already `sonnet`.

**Requirements:** R6

**Dependencies:** None

**Files:**
- Modify: `.aiurconfig` (the `claude.version` label, currently `opus-4-8`)
- (Investigate first) any render surface that shows the label to the operator.

**Approach:**
- Confirm where "opus" surfaces (config `version` label vs a render label vs agent self-identification). If it's the `.aiurconfig` `version` label, set it to match the active model (or remove it so nothing stale shows). If "opus" comes only from the agent self-identifying, note that the process model is already `sonnet` and no code change applies.

**Test scenarios:** `Test expectation: none — config/label alignment; no behavioral change.` (Verify by reading the operator-facing surface after the change.)

**Verification:** The operator-facing model indicator for 101 reads `sonnet`; no functional change to model selection (already `--model sonnet`).

---

## System-Wide Impact

- **Interaction graph:** opencode bridge ↔ `AgentChat.send` ↔ orchestrator queue ↔ `repl_agent` pane paste; claude hooks ↔ bridge (new read-signal subscription in U2). Codex/non-RC paths must remain on their current accept-time close (backend gate).
- **Error propagation:** U2's read-signal wait must be best-effort — a missing/late hook falls back to close, never hangs the SSE or the operator pane.
- **State lifecycle risks:** double-send (fixed in U1); double-render (addressed in U3); SSE wedging on long turns (bounded by `@watchdog_ms` in U2).
- **API surface parity:** the three operator entry surfaces (dashboard LiveView, HTTP API, opencode bridge) still converge on `Orchestrator.send_operator_message`; only the opencode bridge's text-normalization + ack-timing change. Dashboard/HTTP messages are already raw (no opencode wrapper), so they are unaffected.
- **Unchanged invariants:** `claude-repl` delivery stays immediate-paste + native-fold (`coding_agent.ex` capabilities unchanged); `repl_agent.send_operator_message/2` single-Enter submit unchanged; DisplayTailer stays display-only.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| opencode changes its wrapper template in a future version | Version is mise-pinned (1.15.6); normalization is tolerant (strips any `<system-reminder>` block, falls back to forwarding text as-is if no template matches) so a new format degrades to "raw-ish," not breakage. Add a focused test capturing the exact 1.15.6 templates. |
| Holding the operator SSE for U2 produces an unexpected opencode UI state | Gate behind manual `--test` observation; bounded by `@watchdog_ms`; fallback to accept-time close preserves today's behavior. |
| Read-signal correlation mismatches with repeated/identical messages | Resolve final matching key against real `UserPromptSubmit` payloads at implementation; default to raw-text-contains with a short in-flight window. |
| Regressing codex / non-RC claude | All changes backend-gated to `claude-repl`; R5 regression scenarios in U2 tests; dashboard/HTTP surfaces send raw text already. |

---

## Documentation / Operational Notes

- Update the origin requirements doc status to "planned" once this plan is accepted.
- Manual-test gate (AGENTS.md): launch `scripts/aiurdev --test`, open the opencode pane on a `claude-repl` agent, send the canonical "123" message mid-turn, and observe the rendered answer + pending-indicator behavior — logs alone do not satisfy the gate.

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-06-14-operator-message-native-queue-requirements.md](docs/brainstorms/2026-06-14-operator-message-native-queue-requirements.md)
- Related code: `src/lib/aiur/opencode/chat_completions.ex`, `src/lib/aiur/claude/repl_agent.ex`, `src/lib/aiur/coding_agent.ex`, `src/lib/aiur/claude/hook_events.ex`, `src/lib/aiur/opencode/session_writer.ex`
- Prior (separate) effort: `docs/plans/2026-06-13-003-feat-rc-opencode-full-fidelity-plan.md` (display fidelity — distinct from this delivery-parity work)
