---
date: 2026-06-12
topic: chat-control-lifecycle-ux
---

# Chat, Control & Lifecycle UX Fixes (7 issues)

## Problem Frame

Operators driving aiur's agent chat panes hit seven UX/correctness defects: stale
test-ticket plumbing (#212), a flickering `??????` artifact in the agent list,
operator messages stuck QUEUED for whole autonomous turns, Remote-Control-app
messages mis-attributed as agent speech, an incompletely-verified Ctrl+C 3-state
UX, agents that outlive aiur's exit, and a pause that doesn't actually stop the
agent. Together they break the "standard claude/codex chat" mental model the
product targets. Most groundwork exists on branch `kevin/repl-dualchat`
(PR #256); this brainstorm scopes the remaining fixes.

**Research basis (verified against code this session):**
- The golden-ticket 212 code was already removed in commit `f1189f5`; `--test`
  now resets only pinned ticket 99 (`src/lib/aiur/test_reset.ex:101-118`,
  `.aiur-test-tickets.json`). GitHub issue 212 itself is still OPEN with
  `agent:in-progress` + stale artifact `src/log/aiur.212.subscriptions.json`.
- The opencode bridge holds ONE SSE open per autonomous turn
  (`src/lib/aiur/opencode/chat_completions.ex` `stream_codex_turn/3`); opencode
  will not send typed input while its completion request is in flight, so
  messages sit in opencode's TUI-local queue, invisible to aiur (proven in
  `docs/brainstorms/2026-06-12-opencode-control-boundary-requirements.md`).
- Codex already injects aiur-queued operator messages mid-turn at safe
  checkpoints (`tool_result`/`notification` — `src/lib/aiur/agent_runner.ex`
  `safe_checkpoint_handler/2`); claude-repl types them into the live pane
  immediately (`src/lib/aiur/claude/repl_agent.ex` `await_turn/6`).
- Remote-origin user turns are already persisted as real user rows (commit
  `3901217`): `queued_command` attachment → `origin: :remote`
  (`src/lib/aiur/claude/transcript.ex:117-133`) → `SessionWriter`
  `write_user_message/2`; the bridge drops all `:user` events from the
  assistant stream.
- Ctrl+C 3-state is implemented for both the REPL backend (queue-depth based)
  and the no-pane codex/opencode backend (ActiveTurns-based `:send_interrupt`
  forwarding Esc) — `src/lib/aiur/orchestrator.ex:3593-3696`,
  `scripts/aiur-pane-ctrlc`, tmux `C-c` binding in `scripts/aiur.tmux.conf`.
- Codex handles `{:pause_agent}` mid-turn via JSON-RPC `turn/interrupt`
  (`src/lib/aiur/codex/coding_agent.ex:435,854-907`); **claude-repl's
  `await_turn/6` has no `{:pause_agent}` clause** — the pause request sits in
  the Task mailbox until the turn ends, and nothing interrupts the live REPL.
- Shutdown cleanup is spread across 6 layers (bash traps in `scripts/aiurdev`,
  `Aiur.Shutdown.cleanup/1`, `Orchestrator.terminate/2` → `kill_repl_session/1`,
  Slot/HiddenWindow terminate, SessionGC, per-backend reapers). REPL + headless
  subtrees are reaped; codex app-server grandchildren rely on `stop_port/1`
  which only runs on graceful turn-done paths.

---

## Actors

- A1. Operator: drives agents from the aiur TUI, opencode chat panes, and the
  Claude Remote Control app; expects standard agent-chat semantics.
- A2. Agent (codex or claude-repl backend): self-drives a GitHub issue
  end-to-end; must keep autonomy (R0 invariant) while accepting operator input.
- A3. Implementing agent (cheaper model): executes the plan; needs unambiguous,
  verifiable units.

---

## Requirements

**1 — Test-ticket 212 cleanup**
- R1. No aiur code path, config, doc-default, or test fixture references ticket
  212 as a test ticket; `--test` operates on ticket 99 only and `--test3` on
  99/100/101 only. (Code believed clean post-`f1189f5`; verify, then clean
  tracker state: strip agent labels from / close GitHub issue 212, remove stale
  `src/log/aiur.212.subscriptions.json`.)

**2 — Agent-list `??????` flicker**
- R2. During initial load (and steady state), no transient runs of `?`
  characters appear in the agent-list pane between the agent table and the
  events block ("oldest" divider region). Diagnose first (capture raw bytes via
  `write_fun` tee or `tmux capture-pane -e` during boot); suspects: OSC 8
  hyperlink sequences in event rows, braille spinner / emoji width fallback,
  `event_subject_id` `"?"` fallback (`src/lib/aiur/agent_list/renderer.ex:1482`).
  Fix the verified cause only.

**3 — Standard chat queue semantics (segmented turn streams)**
- R3. An operator message typed in an opencode pane reaches the agent without
  manual intervention in at most "current tool use / safe checkpoint" time —
  never "whole feature turn" time. Target UX: consumed immediately in most
  cases; at worst queued until the current tool call completes.
- R4. The bridge's per-turn SSE is segmented: it closes at safe-checkpoint
  boundaries (and on a bounded idle/heartbeat cadence) and a fresh turn-marker
  segment resumes streaming, so opencode flushes its queued input between
  segments. One logical agent turn may render as multiple assistant messages —
  acceptable.
- R5. Both backends behave the same from the operator's seat: message lands →
  codex injects at next checkpoint via existing `:deliver_text` path;
  claude-repl types it into the live REPL immediately. No bespoke delivery UI.

**4 — Remote-message attribution & dual-surface mirroring**
- R6. A message sent from the Claude Remote Control app renders in the opencode
  pane as a standard user message (never agent speech, never `💬`-prefixed
  assistant text). Believed fixed by `3901217`; verify live, including the
  idle-agent case where claude may persist the remote message as a plain
  `type:"user"` record instead of a `queued_command` attachment (gap: such
  records carry no `origin: :remote` and are currently dropped by
  SessionWriter).
- R7. A message typed in the opencode pane appears in the Claude app
  conversation as a user message (expected free via native REPL queue; verify
  live).

**5 — Ctrl+C 3-state + close-without-pause key**
- R8. In an opencode chat pane: Ctrl+C with work in flight → interrupt + drain
  full message queue, agent continues, pane stays open; Ctrl+C when idle →
  pause, pane stays open; Ctrl+C when paused → close pane, agent stays paused.
  (Implemented on branch; needs live verification + gap-fixing, not a rebuild.)
- R9. Ctrl+Q in an opencode chat pane closes the pane WITHOUT pausing the
  agent. Esc stays native to opencode (it is opencode's interrupt key and the
  bridge's forwarded interrupt mechanism) — Esc is NOT intercepted at the tmux
  layer.
- R10. Closing a pane never kills the agent session; reopening reattaches the
  same opencode session (no `:repl_gone` fresh dispatch). (Unit 3 of
  `docs/plans/2026-06-12-001-feat-opencode-control-boundary-plan.md`, still
  open.)

**6 — Exit always kills all agents**
- R11. When aiur exits by any non-`kill -9` path (quit key, Ctrl+C on agent
  list, SIGTERM, fatal error), no agent OS process survives: REPL panes, codex
  app-server trees, opencode serve/attach processes, headless claude trees.
- R12. Process ownership is centralized: every spawned agent OS process (pid
  and/or pane id) is registered at spawn in one registry and reaped through one
  shutdown chokepoint, replacing per-backend ad-hoc reaping as the
  correctness-critical path (existing layers may remain as defense in depth).
- R13. `aiur --bg` runs headless; a subsequent foreground `aiur` attaches to
  the running bg instance instead of double-launching. (Believed implemented in
  `scripts/aiurdev` `run_or_attach_foreground`; verify and fix only if broken.)
  A `--bg` instance is excluded from R11 — only its own exit kills its agents.

**7 — Pause actually pauses**
- R14. Pausing an agent (from opencode Ctrl+C-idle, agent-list Space, or any
  pause path) stops agent work within one safe-interrupt window for BOTH
  backends: codex via existing `turn/interrupt`; claude-repl needs a
  `{:pause_agent}` clause in `await_turn/6` that interrupts the live REPL turn
  (Ctrl+C to pane) and parks the runner in the paused wait loop.
- R15. A paused agent does no further tool calls / emits no new transcript work
  events until resumed (Space, or a new operator message per existing resume
  semantics).

---

## Acceptance Examples

- AE1. **Covers R3-R5.** Agent mid-feature on autopilot; operator types "use
  zod instead" in the opencode pane. Within one tool-call boundary the message
  leaves QUEUED, renders as a user turn, and the agent's next output
  acknowledges/incorporates it. Same observable behavior whether issue runs
  codex or claude-repl.
- AE2. **Covers R8.** Operator message QUEUED in opencode + agent mid-tool →
  Ctrl+C once → message(s) all deliver, agent continues working, pane open, no
  paused badge.
- AE3. **Covers R14-R15.** Claude-remote agent (ticket 101) working; operator
  Ctrl+C with empty queue → pause. Transcript shows no new tool/work events
  until resume.
- AE4. **Covers R6.** Operator sends "hello" from the Claude app while the
  agent is BOTH (a) mid-turn and (b) idle/paused. Both render in opencode as
  user messages.
- AE5. **Covers R11.** Operator quits aiur while 3 agents are mid-turn
  (codex + claude-repl mix). `pgrep` for claude/codex/opencode/node processes
  under aiur's workspaces returns nothing within ~10s.

---

## Success Criteria

- Operator can chat with a working agent like a normal claude/codex session:
  type → consumed at worst by next tool boundary; Ctrl+C/Ctrl+Q/pause behave
  per R8/R9/R14.
- A full `--test3 --force` run completes with zero references to 212, no `?`
  flicker, dual-surface user attribution correct, and no surviving processes
  after quit.
- The implementing agent can execute the plan unit-by-unit with each unit
  carrying its own test/verification gate, without re-deriving design.

---

## Scope Boundaries

- No opencode fork or patches; only its public surfaces (keystrokes, serve
  API, SQLite, markers).
- No change to R0 autonomy: operator input steers, never becomes required.
- No redesign of the agent-list TUI beyond the flicker fix.
- Headless-claude fallback backend stays working but gets no new chat UX.
- `kill -9`/OOM recovery stays boot-time GC (existing SessionGC), not in scope.
- Existing Ctrl+C 3-state decision tables are kept (verify/fix, not rebuild).

---

## Key Decisions

- Ctrl+Q (not Esc) is the close-without-pause key: Esc is opencode's native
  interrupt and the bridge's interrupt vehicle; intercepting it would break
  in-TUI Esc semantics.
- Segmented turn streams over auto-abort detection: opencode's input queue is
  TUI-local and likely invisible server-side; segmentation uses existing
  marker machinery and fixes latency for both backends.
- Centralized process registry + single reap chokepoint is the fix-shape for
  R11/R12 (operator pre-approved a refactor to stop the recurring bug).
- Pause = interrupt-then-hold for both backends (true stop, not cosmetic
  status flip).

---

## Dependencies / Assumptions

- opencode flushes queued input promptly once the in-flight completion closes
  (observed: flush happened at SSE teardown; segment-close is the same signal).
- Claude REPL Ctrl+C (via `Tmux.send_interrupt/2`) cleanly cuts a turn and
  preserves the session for later input (already used by the `:interrupt`
  path).
- Live verification of RC-app flows is operator-driven (existing guardrail);
  the implementing agent verifies everything else via `--test3` + logs.

---

## Outstanding Questions

### Deferred to Planning

- [Affects R4][Technical] Exact segment-boundary rule (every checkpoint vs
  checkpoint-after-N-seconds) and how AgentRunner posts continuation markers
  without racing the queued user message.
- [Affects R2][Needs research] Identity of the `?` bytes — must be captured at
  runtime before any fix.
- [Affects R6][Needs research] What claude writes to the transcript when an RC
  message arrives while idle (plain `user` record vs `queued_command`
  attachment) — decides whether a disambiguation heuristic is needed.
- [Affects R12][Technical] Registry shape (new GenServer/ETS vs extending
  running-entry bookkeeping) and which existing layers demote to
  defense-in-depth.
- [Affects R9][Technical] Whether Ctrl+Q can bind cleanly in
  `scripts/aiur.tmux.conf` without colliding with opencode keybinds.

## Next Steps

-> /ce-plan for structured implementation planning
