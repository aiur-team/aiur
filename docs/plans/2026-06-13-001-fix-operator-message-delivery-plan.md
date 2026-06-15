---
title: "fix: Operator-message delivery and Ctrl+C session safety"
type: fix
status: active
date: 2026-06-13
---

# fix: Operator-message delivery and Ctrl+C session safety

## Overview

Three operator-message bugs surfaced in manual `--test3` testing, all rooted in how
operator input reaches an agent and how Ctrl+C is handled. Root causes are already
established from log analysis of the 2026-06-13 09:16–09:18 run (issue 101 = claude
remote-control REPL, 99/100 = codex). This plan fixes them safely, test-first, keeping
the build green.

The dominant defect (Bug 2) is destructive: a Ctrl+C whose dashboard call is slow
degrades to a hard `kill-pane`, which cascades to `:repl_gone` and a fresh-session
re-dispatch — the "conversation reset / new remote notification, starting over" the
operator saw. Bug 2 is fixed first because it can mask and amplify Bugs 1 and 3.

---

## Problem Frame

- **Bug 2 (HIGH):** `scripts/aiur-pane-ctrlc` curls `POST /api/v1/pane/interrupt` with
  `curl -m 2`. The orchestrator's `pane_interrupt` `GenServer.call` is serialized behind
  the single Orchestrator mailbox and took ~2.4s under load (POST 09:18:15.825 → reply
  09:18:18.263). curl timed out at 2s → the helper treated it as failure and ran
  `close_pane()` → **`kill-pane %9`** on the live opencode pane. Evidence:
  `/tmp/aiur-ctrlc.log` → `16:18:17Z ctrlc pane_id=%9 action=close_pane reason=curl_failed`.
  That kill → `Writer crashed (epipe)` → the REPL turn observed `:repl_gone` →
  `Aiur.AgentRunner.transient_run_error?/1` classifies `:repl_gone` transient → orchestrator
  re-dispatched a fresh claude session (`Dispatching issue to agent: 101 ... attempt=1`).
  Separately, the *first* Ctrl+C (09:16:03) legitimately returned `:paused` because
  `queue_depth` was 0 — the 3-state correctly falls to `:pause`, but it mismatched the
  operator's "drain" intent.
- **Bug 3 (HIGH):** text typed into a codex pane never reached aiur. Messages to 99/100
  produced **zero** `AgentChat.send` events; only 101 flushed once
  (`coalesced_operator_text identifier=101`). opencode holds typed input in its TUI-local
  queue and only POSTs it to the bridge when it opens a new chat-completion (a turn /
  segment marker). The segment-flush (`segment_boundary?` / `idle_segment_boundary?` in
  `src/lib/aiur/opencode/chat_completions.ex`) did not fire for the codex turns, so the
  input never left opencode.
- **Bug 1 (MED-HIGH):** for the claude-repl backend (`immediate_delivery: true`), a flushed
  opencode message is typed straight into claude's native input queue
  (`src/lib/aiur/claude/repl_agent.ex`), which folds it in at the next boundary without
  interrupting. During long autonomous work it is subordinated; when the turn/pane died
  (Bug 2) it was never answered. "Remote control answered" was incidental ordering (the RC
  copy was 370ms earlier in the same native queue).

---

## Requirements Trace

- R1. A Ctrl+C on a chat pane must NEVER destroy a live agent session or reset the
  conversation as a side effect of dashboard latency.
- R2. A genuinely unreachable dashboard may still degrade Ctrl+C gracefully, but
  non-destructively (hide, not kill) wherever the session would otherwise be lost.
- R3. Operator text typed into a codex agent's opencode pane must reach the agent and
  produce a visible response within a bounded time, not sit queued indefinitely.
- R4. Operator text typed into a claude-repl agent's opencode pane must produce a visible
  agent response, honoring the native-queue design (do not cut the agent off mid-work by
  default — see existing principle, memory `repl_native_message_ux`).
- R5. The full gate stays green (compile `--warnings-as-errors`, test, credo `--strict`,
  dialyzer) and the fixes are confirmed end-to-end via `aiurdev --test3`.

---

## Scope Boundaries

- Not changing the 3-state Ctrl+C *decision* semantics (drain/pause/close) — only the
  helper's degradation behavior and the call's latency exposure.
- Not redesigning the opencode bridge-as-LLM architecture — Bug 3 is a flush-reliability
  fix, not a re-architecture.
- Not changing the native-queue delivery principle for claude-repl (R4 respects it).

### Deferred to Follow-Up Work

- ProcessReaper logs `received unexpected message in handle_info/2: {'EXIT', #Port<...>, normal}`
  during shutdown, and `Aiur.Opencode.Server.terminate/2` raises `:erlang.port_close badarg`
  on an already-closed port (`src/lib/aiur/opencode/server.ex:113`). These are
  shutdown-time log noise unrelated to the three bugs; capture separately.

---

## Context & Research

### Relevant Code and Patterns

- `scripts/aiur-pane-ctrlc` — the Ctrl+C bridge helper; `close_pane()` (destructive),
  `hide_pane()` (non-destructive, already used for unexpected responses at the tail).
- `src/lib/aiur/orchestrator.ex` — `pane_interrupt` / `pane_interrupt_by_pane_id`
  handle_calls (5s internal timeout), `pane_interrupt_reply`, `perform_pane_interrupt`,
  `pane_interrupt_action/2`.
- `src/lib/aiur/agent_runner.ex` — `transient_run_error?/1` (`:repl_gone` → transient
  re-dispatch); `open_aiur_turn_streams` / `close_aiur_turn_streams`.
- `src/lib/aiur/opencode/chat_completions.ex` — `stream_codex_turn`,
  `codex_turn_stream_loop`, `close_segment`, `segment_boundary?/3`,
  `idle_segment_boundary?/6`, `originating_writer/2`, `segment_threshold_ms/0`,
  `dispatch_user_text`, `dispatch_shadowed_operator_texts`.
- `src/lib/aiur/coding_agent.ex` — backend capability registry (`claude-repl`
  `immediate_delivery: true`; `codex` checkpoint delivery, `safe_checkpoints`
  `[:notification, :tool_result]`).

### Institutional Learnings

- `repl_native_message_ux` (memory): claude-repl operator messages use claude's NATIVE
  queue — forward keystrokes, never cut the agent off mid-work by default. R4 honors this.
- `rc_autonomy_invariant` (memory): RC is a takeover channel, not a handoff; the agent
  still self-drives. Bug 1's fix must not turn every operator message into a hard interrupt.

---

## Key Technical Decisions

- **Ctrl+C degradation distinguishes "busy" from "down".** A curl *timeout* (exit 28)
  means aiur is alive and the interrupt is likely still processing — keep the pane open,
  never kill. Only a genuine connection failure (refused/no route) degrades, and then to a
  *hide* (session survives), not a destructive kill. (R1, R2)
- **Curl timeout must exceed the server-side call timeout.** The orchestrator handle_call
  uses a 5s internal `GenServer.call` timeout; the helper's `-m 2` is below it, so it can
  abandon a call that would have succeeded. Raise it above 5s (target `-m 8`). (R1)
- **Bug 1 is largely downstream of Bug 2.** Once a stray kill can't kill the session, the
  native-queue message survives to the next boundary and claude answers it. Plan verifies
  residual behavior before adding any new nudge — no design change unless the live repro
  shows the message still isn't answered with the turn intact. (R4)
- **Bug 3's exact flush-failure mode is an execution-time discovery.** Because the codex
  message never reached aiur, logs can't distinguish (a) `originating_writer` unresolved →
  segmentation disabled, (b) no active turn when typed → no marker → opencode never POSTs,
  or (c) threshold/boundary never reached. A short instrumented live repro picks the fix.

---

## Open Questions

### Resolved During Planning

- Should an opencode message to a claude-repl agent hard-interrupt to force a response?
  **No** — honor the native-queue principle (R4). Fix the session-destruction (Bug 2) and
  re-check; only revisit if a turn-intact message still goes unanswered.

### Deferred to Implementation

- Exact codex flush-failure mode (writer-unresolved vs no-active-turn vs threshold) —
  determined by the U4 instrumented repro before its fix lands.
- Whether the stray `kill-pane %9` alone cascades to full tmux-server death, or whether the
  observed total teardown also involved the launcher exiting — confirmed during the U1/U2
  live repro.

---

## Implementation Units

- [ ] U1. **Harden aiur-pane-ctrlc against slow-call degradation**

**Goal:** A Ctrl+C whose dashboard call is slow or times out never runs a destructive
`kill-pane`; degradation is non-destructive.

**Requirements:** R1, R2

**Dependencies:** None

**Files:**
- Modify: `scripts/aiur-pane-ctrlc`
- Test: `src/test/...` not applicable (POSIX shell helper); see Verification for the
  manual/bats-free check. If a shell-test harness exists, add `test/scripts/aiur-pane-ctrlc.bats`.

**Approach:**
- Capture curl's exit status instead of collapsing all failures to `close_pane`.
- Exit 28 (timeout): log `action=keep_open reason=curl_timeout`, exit 0 — leave the pane
  open; the server-side interrupt is likely still completing.
- Genuine connection failure (refused/host-unreachable): degrade to `hide_pane` (session and
  attach survive), not `kill-pane`. Kill remains only the last-resort if hide itself fails.
- Raise the interrupt curl's `-m` above the orchestrator's 5s call timeout (target `-m 8`).
  Keep the breadcrumb log line for every branch.

**Patterns to follow:**
- The existing `hide_pane()` fallback already used for unexpected responses (tail of the
  script); reuse it instead of `close_pane()` for recoverable failures.

**Test scenarios:**
- Happy path: dashboard replies `interrupted`/`paused`/`send_interrupt` within timeout →
  unchanged behavior (keep open / forward Esc).
- Error path: curl exits 28 (timeout) → pane stays open, breadcrumb `reason=curl_timeout`,
  no `kill-pane` issued.
- Error path: curl exits with connection-refused → `hide_pane` attempted, `kill-pane` only
  if hide fails.
- Edge case: empty `pane_id` or empty `control_url` → existing benign exits preserved.

**Verification:**
- A simulated slow/unreachable dashboard (point the helper at a dead port, or a sleeping
  stub) never produces a `kill-pane` for the live pane; the breadcrumb log shows the new
  non-destructive branches.

---

- [ ] U2. **Make pane_interrupt latency-safe end to end**

**Goal:** Close the residual race so even a worst-case-slow orchestrator can't strand the
helper, and confirm the stray-kill cascade is gone.

**Requirements:** R1, R5

**Dependencies:** U1

**Files:**
- Modify: `src/lib/aiur/orchestrator.ex` (only if the live repro shows pane_interrupt
  blocking avoidably; e.g., compute the 3-state decision without waiting on slow work)
- Modify: `src/lib/aiur/agent_runner.ex` (guard: an operator-initiated pane kill should not
  silently re-dispatch a fresh session — evaluate whether `:repl_gone` during active
  operator interaction should surface to the operator rather than restart)
- Test: `src/test/aiur/orchestrator_test.exs`, `src/test/aiur/agent_runner_test.exs`

**Approach:**
- First reproduce live (instrumented) to measure `pane_interrupt` latency and confirm U1
  alone prevents the destructive cascade. If U1 fully resolves Bug 2, keep U2 minimal
  (a regression test only).
- If latency is still a hazard, reduce what `pane_interrupt` does on the orchestrator
  mailbox (the decision needs only paused?, queue_depth/working? — all cheap reads) so the
  call returns well under the curl timeout.
- Decide whether `:repl_gone` should remain blanket-transient: a flaky-link drop should
  re-dispatch (existing intent), but a pane death immediately following an operator Ctrl+C
  should not silently reset the conversation. Prefer the smallest guard that preserves the
  flaky-link resilience.

**Execution note:** Start with a live `--test3` repro to confirm U1's effect before
touching orchestrator/runner code; only add code that the repro proves necessary.

**Test scenarios:**
- Happy path: `pane_interrupt` returns its 3-state decision within a tight bound under a
  simulated busy orchestrator.
- Integration: an operator-initiated pane kill does not produce a fresh-session
  re-dispatch (or surfaces it to the operator instead of silently restarting).
- Regression: a genuine flaky-link `:repl_gone` (no preceding operator interrupt) still
  re-dispatches as before.

**Verification:**
- Live `--test3`: pressing Ctrl+C repeatedly on a busy agent's pane never resets the
  conversation; the agent keeps its session.

---

- [ ] U3. **Reproduce and fix codex opencode-input flush**

**Goal:** Text typed into a codex pane reaches the agent and yields a visible response
within a bounded time.

**Requirements:** R3

**Dependencies:** None (independent of U1/U2; sequence after them to test on a stable session)

**Files:**
- Modify: `src/lib/aiur/opencode/chat_completions.ex` (flush cadence — once the repro
  identifies the failure mode)
- Possibly modify: `src/lib/aiur/agent_runner.ex` (turn-marker cadence when a codex agent
  is idle/between turns so opencode has a completion to flush into)
- Test: `src/test/aiur/opencode/chat_completions_test.exs`

**Approach:**
- Instrument and live-repro: send a message to a codex agent's pane and capture whether
  `originating_writer` resolves, whether an aiur turn is active, and whether
  `segment_boundary?`/`idle_segment_boundary?` ever evaluate true for that turn.
- Fix the specific failure mode:
  - writer-unresolved → fix `originating_writer`/`caller_base_url` resolution for codex serves;
  - no-active-turn-when-typed → ensure a path exists for opencode to deliver input to an
    idle codex agent (e.g., a lightweight marker/poll so typed text isn't stranded);
  - threshold/boundary-never-hit → tighten the idle/segment cadence so a quiet codex turn
    still flushes typed input promptly.
- Keep the pure boundary predicates pure (they already have unit tests); extend those
  tests for the chosen fix.

**Execution note:** Live instrumented repro first — the fix target is unknown until the
repro identifies which of the three modes applies.

**Test scenarios:**
- Happy path: with an active codex turn, a typed operator message flushes and is dispatched
  (`dispatch_user_text` → `AgentChat.send`) within the bounded window.
- Edge case: `segment_boundary?` / `idle_segment_boundary?` truth tables extended for the
  chosen cadence (e.g., quiet turn still flushes after threshold).
- Error path: `originating_writer` unresolved degrades to the long-held SSE without
  dropping the typed input silently.
- Integration: a flushed codex operator message produces a follow-up codex turn whose
  response renders in the pane.

**Verification:**
- Live `--test3`: typing a message to a codex agent yields a visible agent reply; logs show
  the `AgentChat.send issue=<codex-id>` the prior run lacked.

---

- [ ] U4. **Verify and, if needed, guarantee claude-repl visible response**

**Goal:** An opencode message to a claude-repl agent produces a visible response, honoring
the native-queue principle.

**Requirements:** R4

**Dependencies:** U1, U2 (Bug 1 is largely downstream of Bug 2)

**Files:**
- Possibly modify: `src/lib/aiur/claude/repl_agent.ex` (only if a turn-intact message still
  goes unanswered — e.g., ensure the native-queue submit reliably lands)
- Test: `src/test/aiur/claude/repl_agent_test.exs`

**Approach:**
- After U1/U2, live-repro: send an opencode message to a claude-repl agent mid-turn and
  confirm claude answers at its next boundary (turn no longer dies).
- If it still doesn't answer with the turn intact, investigate the `send_keys_literal` +
  `Enter` submit path (sanitization, submit reliability) — fix only the delivery, do not
  add a hard interrupt (R4 / `repl_native_message_ux`).

**Execution note:** Verification-led; code change only if the repro proves a turn-intact
gap remains.

**Test scenarios:**
- Happy path: a sanitized operator message is typed and submitted once (single trailing
  Enter) into the REPL pane.
- Edge case: message with control bytes is sanitized to a single submit (existing behavior
  preserved).
- Integration: with the turn intact, an injected operator message is answered at the next
  native boundary.

**Verification:**
- Live `--test3`: typing a message to the claude-repl agent yields a visible answer without
  cutting off its in-flight work.

---

- [ ] U5. **Green the gate and lint pass**

**Goal:** Restore full gate green after the feature fixes are confirmed working.

**Requirements:** R5

**Dependencies:** U1–U4

**Files:**
- Modify: any files needing `@spec`/credo/dialyzer cleanup introduced by U1–U4.

**Approach:**
- Per project convention, hold lint until features are confirmed working, then run
  compile `--warnings-as-errors`, test, credo `--strict`, dialyzer; fix findings.

**Test expectation:** none — this unit only restores tooling green; behavior is covered by
U1–U4 tests.

**Verification:**
- `make -C src ... all` (or equivalent) green; PR CI green.

---

## System-Wide Impact

- **Interaction graph:** Ctrl+C path spans tmux binding → `aiur-pane-ctrlc` → dashboard
  controller → `Orchestrator.pane_interrupt*` → `AgentRunner`. The opencode-input path spans
  opencode TUI → `ChatCompletions` bridge → `AgentChat.send` → `Orchestrator` queue →
  `AgentRunner` → backend adapter.
- **Error propagation:** `:repl_gone` currently propagates to a transient re-dispatch; U2
  reconsiders that for the operator-kill case only.
- **State lifecycle risks:** killing a live pane breaks SessionWriter pipes (epipe) and the
  REPL session; the fix removes the destructive trigger.
- **API surface parity:** both the opencode-pane path and the dashboard LiveView path call
  `AgentChat.send`; verify Bug 3's flush fix doesn't regress the LiveView path.
- **Unchanged invariants:** the 3-state Ctrl+C decision semantics, the native-queue claude
  delivery principle, and the bridge-as-LLM architecture are unchanged.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| U2/U3/U4 depend on live `--test3` discovery; behavior may differ from log inference | Each is sequenced behind an instrumented repro; code lands only when the repro confirms the mode |
| Loosening `:repl_gone` transient handling could weaken flaky-link resilience | Guard only the operator-initiated-kill case; keep blanket transient for genuine drops |
| Tightening codex flush cadence could churn markers on long quiet runs | Reuse the existing `streamed? or seg_n == 0` gate; extend unit truth tables |
| `--test3` runs burn real-agent tokens | Kill the run as soon as repro/repro-fix is captured (memory `test3_cost_discipline`) |

---

## Sources & References

- Debug evidence: `src/log/aiur.log` (09:16–09:18 run), `/tmp/aiur-ctrlc.log` breadcrumbs.
- Related code: `scripts/aiur-pane-ctrlc`, `src/lib/aiur/opencode/chat_completions.ex`,
  `src/lib/aiur/orchestrator.ex`, `src/lib/aiur/agent_runner.ex`,
  `src/lib/aiur/claude/repl_agent.ex`.
- Memories: `repl_native_message_ux`, `rc_autonomy_invariant`, `test3_cost_discipline`.
