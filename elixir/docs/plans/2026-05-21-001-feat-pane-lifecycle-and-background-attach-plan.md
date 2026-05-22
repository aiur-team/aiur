---
title: feat: Pane lifecycle, background attach, autonomous loop, and shutdown hardening
type: feat
status: active
date: 2026-05-21
deepened: 2026-05-21
origin: elixir/docs/brainstorms/2026-05-21-aiur-pane-lifecycle-and-background-attach-requirements.md
---

# feat: Pane lifecycle, background attach, autonomous loop, and shutdown hardening

## Overview

Yesterday's pre-warm work delivered the infrastructure (warm server, attach hand-off, session writer, shutdown chokepoint, boot-time GC) but the first interactive run surfaced six behavioral defects. This plan converts the architecture from a single-pane, one-shot hand-off model into a **persistent, multi-pane background-attach model** with an autonomous agent loop, complete history-replay correctness, leak-free titles, and three layers of session-cleanup defense.

---

## Problem Frame

Six issues from the first interactive run of the pre-warm feature (see origin):

1. **R1** — Closing a chat pane permanently destroys the tmux pane; reopening is a full re-attach. User wants close = hide, open = un-hide.
2. **R2** — Prior IssueLog history does not appear when a pane opens; the user sees an empty chat or one user-style blue bubble. Root cause: `PaneManager.warm_hand_off/3` calls `WarmAttach.take_over/3` immediately after `SessionWriterRegistry.ensure/2`, before async `replay_history` writes rows; and no TUI-refresh fires after writes.
3. **R3** — Codex agents only advance work when the user types. Root cause: `Aiur.AgentRunner.run_queue_item_turn` finishes a user-driven turn, drains operator messages, and falls into `wait_for_operator_message` — never re-evaluating `continue_with_issue?`.
4. **R4** — Only one pane benefits from pre-warm. Subsequent agent opens use a cold path. User wants every agent's pane background-attached in a hidden window, with the selected agent jumping the queue.
5. **R5** — On quit, especially abrupt quit (Ctrl+C, terminal close, parent-bash exit), Aiur-owned opencode sessions leak. The BEAM cleanup path works for graceful shutdown but a second line of defense is needed.
6. **R6** — The strings `_warm` and `_placeholder` leak into the visible TUI (input-bar suffix, model area). Origin found via probe that opencode 1.15.6 has **no session-rename endpoint** — the only path is to create sessions with their real title from the start.

---

## Requirements Trace

- R1. Closing a chat pane MUST hide (move to hidden tmux window) without destroying the opencode-attach process, opencode session, or SessionWriter. Reopen MUST be a tmux-only swap (<100 ms).
- R2. First open MUST render prior IssueLog history as `role: "assistant"` messages, visible before the TUI displays the session.
- R3. Codex agents MUST run autonomously against assigned IssueLog work; user messages are interjections, not the trigger.
- R4. Every agent MUST be background-attached after boot; user selection MUST jump the queue.
- R5. All Aiur-owned opencode sessions MUST be reaped on quit (catchable signals via BEAM, abrupt termination via bash trap, hard kill via next-run boot-time GC).
- R6. The strings `_warm` and `_placeholder` MUST never appear in any visible part of the TUI.

**Origin actors:** A1 (developer), A2 (codex agent), A3 (opencode TUI/server)
**Origin acceptance examples:** AE1 (close=hide), AE2 (history visible), AE3 (autonomy survives close+reopen), AE4 (background attach <100 ms swap), AE5 (Ctrl+C reaps sessions), AE6 (no `_warm`/`_placeholder` leaks)

---

## Scope Boundaries

- **Not in scope:** Survival of panes across aiur restarts. Fresh boot starts from zero attached panes; the boot-time GC reaps any stragglers from prior runs.
- **Not in scope:** Eviction of resident opencode-attach processes when the agent list grows. Assume N ≤ 10 agents for now.
- **Not in scope:** User-configurable pre-warm count or concurrency. Single-inflight background attach is the v1 default; structure leaves room to widen later.
- **Not in scope:** Embedding any change in the opencode binary or fork. opencode 1.15.6 is a fixed black box.
- **Not in scope:** UI affordance to show background-attach progress (e.g., spinner on un-attached list rows). Logged but invisible to the user — fine for v1.

### Deferred to Follow-Up Work

- Persisting Aiur-owned session IDs across aiur runs (issue #63 — log-storage consolidation) — not load-bearing for this plan.
- Capturing institutional learnings from this plan via `/ce-compound` once it lands.

---

## Context & Research

### Relevant Code and Patterns

- `elixir/lib/aiur/pane_manager.ex` — owns visible-pane state, currently destroys panes on close. R1 and R7 ride here.
- `elixir/lib/aiur/opencode/warm_attach.ex` — current first-open warm hand-off; pattern to follow for per-agent attach state machine.
- `elixir/lib/aiur/opencode/warm_server.ex` — neutral-cwd opencode serve + boot-time GC; stays mostly as-is.
- `elixir/lib/aiur/opencode/session_writer.ex` — per-identifier SQLite writer; `handle_continue(:boot, ...)` runs `replay_history` async — the source of R2's timing race.
- `elixir/lib/aiur/opencode/session_writer_registry.ex` — `Registry + DynamicSupervisor` with idempotent `ensure/2`; pattern reused for the new attach-state registry.
- `elixir/lib/aiur/agent_runner.ex` — `do_run_codex_turns/10` recurses on `continue_with_issue?` after a normal turn but NOT after `run_queue_item_turn`. R3's surgical fix.
- `elixir/lib/aiur/opencode/chat_completions.ex` — handles the `__aiur_stream__:<msg_id>` synthetic-marker round-trip used to nudge the opencode TUI after direct SQLite writes (verified path).
- `elixir/lib/aiur/tmux.ex` — wraps tmux subcommands; gets a new `move_pane_hidden/2`.
- `scripts/aiur` — bash wrapper that boots the BEAM; gets a session-id tempfile and an `EXIT INT TERM HUP` trap.
- `elixir/lib/aiur/shutdown.ex` — existing chokepoint; integrate session-id tempfile lifecycle.

### Institutional Learnings

- `elixir/docs/plans/2026-05-20-001-feat-opencode-prewarm-and-history-injection-plan.md` — verified facts to re-use:
  - `tmux join-pane` (and equivalently `move-pane`) preserves PID, pane ID, and PTY across windows on the aiur-owned socket.
  - opencode TUI does **not** refresh on direct SQLite writes alone. Two known refresh paths: a `POST /tui/select-session` round-trip and the `__aiur_stream__:<msg_id>` synthetic-user marker via the bridge.
  - WAL-mode SQLite + `:exqlite` with `PRAGMA busy_timeout=5000` is the proven concurrency story.
  - Per-identifier `GenServer + top-level Registry + top-level DynamicSupervisor` with idempotent `ensure/2` is the project's accepted pattern (mirrors `Aiur.IssueLog`).
  - `Aiur.Shutdown.shutdown/2` is the single chokepoint for `q`-key, CLI shutdown, and `Application.stop/1`.
- `elixir/docs/notes/opencode-row-shapes-1.15.6.md` — opencode strictly validates `AssistantMessage` schema on `GET /session/<id>/message`; the existing `Aiur.Opencode.Protocol` row builders are correct. No schema change needed for this plan.

### External References

- opencode 1.15.6 session CLI (`mise exec -- opencode session --help`) — `list` and `delete` only. **No rename.** Resolves origin Q3.
- tmux man page — `move-pane -d` (and `join-pane -d`) detaches/doesn't-select; suitable for invisible visible↔hidden movement.

---

## Key Technical Decisions

- **Persistent-pane model.** Each agent identifier owns exactly one tmux pane and one opencode-attach process for the lifetime of the aiur run. The pane lives in the hidden warm window by default; opening moves it to the visible window via `tmux move-pane -d`; closing moves it back. The opencode session and SessionWriter survive across all open/close cycles.

- **Background-attach queue: single-inflight, user-priority preemption.** A new `Aiur.Opencode.AttachQueue` GenServer iterates the agent identifier list and runs one attach at a time into the hidden window. When the user selects an agent, the queue raises that identifier's priority: if its attach is currently in flight, the in-progress pane is **moved to the visible window immediately** so the user watches the final rendering stages; if it has not started yet, it jumps the front of the queue. After the selected pane is visible and rendered, the queue resumes background work. (Resolves origin Q1.)

- **Sessions are created with the agent's real title from the start, AND the warm-server's identifier no longer leaks into the model `name` field.** Because opencode 1.15.6 lacks a rename endpoint (probed during planning, resolves Q3), the only safe path is to never set a placeholder title.
  - The visible "Build Aiur _warm" string the user reported is **not** the session title — it is `Protocol.opencode_json/1`'s `"name" => "Aiur #{identifier}"` field at `elixir/lib/aiur/opencode/protocol.ex:84`, sourced from the identifier used to launch each opencode-attach. When that identifier is `"_warm"`, the name renders as "Aiur _warm". Fixing R6 therefore requires TWO changes:
    1. Set the per-session `title` to the agent's identifier when calling `ApiClient.create_session/3`.
    2. Change the **identifier used to render `Protocol.opencode_json/1`** when attaching per-agent panes so it never reads `"_warm"` or `"_placeholder"`. Each agent gets its real identifier (e.g. `"issue-42"`) baked into its model JSON at attach time.
  - The warm-server's own `"_warm"` boot identifier stays purely server-side (used for the neutral-cwd `opencode serve` instance) and never gets used to spawn a user-visible opencode-attach pane.

- **History replay must complete before the TUI selects the session.** Today, `SessionWriter.init` runs `replay_history` async via `handle_continue(:boot, ...)`; the hand-off proceeds in parallel. The fix has two parts: (a) `SessionWriter` exposes a synchronous `await_replay/2` that returns once replay is fully committed; (b) `PaneManager.open` (and the AttachQueue) call `await_replay` before issuing `POST /tui/select-session`. After `select-session`, fire one synthetic `__aiur_stream__` round-trip via the bridge as a refresh nudge, so the TUI re-reads rows it might have already cached.

- **Autonomous loop: re-check `continue_with_issue?` after every turn, including user-driven turns.** Today `do_run_codex_turns/10` only recurses after a normal codex turn; `run_queue_item_turn` returns to `wait_for_operator_message` without re-evaluating. Fix: after `run_queue_item_turn` finishes, re-evaluate `continue_with_issue?` and recurse if true. The agent then keeps working whether the user typed or not. User messages remain interjections — they queue as operator items and get drained between turns, but they don't gate progress.

- **Shutdown defense-in-depth, three layers.**
  1. **BEAM signal handlers** (catchable: SIGINT, SIGTERM, SIGHUP) route into `Aiur.Shutdown.shutdown/2` → `SessionWriterRegistry.delete_all/1` → `Supervisor.stop` → `System.halt`.
  2. **Bash trap** in `scripts/aiur` reads a session-id tempfile written by `SessionWriter.ensure/2` and runs `mise exec -- opencode session delete <id>` for each one on EXIT/INT/TERM/HUP. Survives any failure of layer 1.
  3. **Boot-time GC** in `Aiur.Opencode.WarmServer` (already shipped) reaps anything layers 1 and 2 missed — survives SIGKILL/OOM/power-loss.
  The tempfile is the load-bearing addition: layer 2 can't enumerate the BEAM's in-memory registry, so the IDs must be on disk.

- **Tmux primitive: `move-pane -d`.** Replaces the existing `join-pane` for visible↔hidden moves. The `-d` flag means "do not select" — the pane reattaches in the target window without stealing focus. Bidirectional, idempotent, preserves PID and PTY (verified via tmux docs and yesterday's spike).

- **Structured logging contract (cross-cutting, all units).** Manual CLI verification (U11) depends on grep-able state-transition logs. Every new subsystem MUST emit one log line per state transition using the format `<subsystem> phase=<state> [key=value ...]`. Existing subsystems already follow this (`opencode_warm_server phase=ready`, `opencode_session_writer phase=ready`). New subsystems extend it:
  - `opencode_hidden_window phase=ready|create_failed window=<name>`
  - `opencode_agent_attach phase=session_created|writer_started|tmux_spawned|replay_complete|tui_selected|ready identifier=<id> session_id=<id> pane_id=<id>`
  - `opencode_attach_queue phase=enqueued|inflight_start|inflight_done|priority_jump|cancel identifier=<id>`
  - `aiur_pane_manager phase=open_warm|open_hidden|open_priority|close_hide|close_cancel identifier=<id> pane_id=<id>`
  - `aiur_autonomous_loop phase=recheck|recurse|wait identifier=<id> issue=<id>`
  - `aiur_shutdown phase=cleanup|delete_session|supervisor_stop session_id=<id>`
  Every phase line should be `Logger.info` (or `:debug` for high-frequency lines like per-row writes). Use these as the verification primitives in U11.

- **No new top-level Registry.** The persistent-pane state extends `SessionWriterRegistry`'s value map (already keyed by identifier) with an additional struct field for tmux pane ID and attach status. Avoids parallel registries that could drift.

---

## Open Questions

### Resolved During Planning

- **Q1 (concurrency)** — Background attach uses single-inflight. Yields preemptively when user selects an un-attached agent.
- **Q2 (user message routing)** — Confirmed: user messages enter `Orchestrator.send_operator_message` → `AgentQueue` → `agent_runner.run_queue_item_turn`. The bug is in the post-turn continuation, not the routing.
- **Q3 (rename API)** — opencode 1.15.6 has no rename endpoint or CLI subcommand. Decision: always create sessions with the agent's real title from the start.
- **Q4 (tmux primitive)** — `tmux move-pane -d -s <pane> -t <window>` is the right primitive. Existing `join-pane -d` is functionally equivalent; we standardize on `move-pane` because the verb matches our intent.

### Deferred to Implementation

- Exact field names for the new `PersistentPaneState` struct (`status :: :pending | :attaching | :ready | :hidden | :visible | :replaying`, etc.) — will refine when wiring AttachQueue state transitions.
- Whether to send the `__aiur_stream__` refresh nudge unconditionally after history replay, or only when at least one row was written. Decide by observation during U6 testing.
- Exact path for the session-id tempfile (`$XDG_RUNTIME_DIR/aiur-<pid>-sessions` vs `/tmp/aiur-<pid>-sessions`) — pick at implementation time based on what survives the bash trap reliably.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

### State machine for a single agent's pane

```
[absent]
   │ AttachQueue picks this identifier
   ▼
[creating-session] ── POST /session (real title) ──▶ [session-ready]
                                                         │
                                                         │ spawn opencode-attach in hidden window
                                                         ▼
                                                  [tmux-attached]
                                                         │
                                                         │ await SessionWriter.await_replay
                                                         ▼
                                                  [history-replayed]
                                                         │
                                                         │ POST /tui/select-session
                                                         │ __aiur_stream__ refresh nudge
                                                         ▼
                                                     [hidden-ready] ◀──────┐
                                                         │                 │
                                              user open │                 │ user close
                                                         ▼                 │
                                                     [visible] ────────────┘
```

`hidden-ready` and `visible` are the two long-lived states. Open and close are symmetric tmux `move-pane -d` invocations against the existing pane ID. Nothing tears down between them.

### Priority preemption in AttachQueue

```
queue: [a1, a2, a3, a4]              user clicks a3 mid-attach of a2:
inflight: a2 (state: tmux-attached)   ─▶ a2 finishes its replay+nudge
                                          a2 lands in hidden-ready
                                          a3 jumps queue head
                                          a3 starts attach with priority flag

priority flag (a3): after [tmux-attached], skip the hidden-ready stop and
                    promote pane to visible window as soon as replay finishes
```

### Shutdown defense layers

```
   ┌─ Layer 1: BEAM signal handler ─────────────┐
   │   SIGINT/SIGTERM/SIGHUP → Aiur.Shutdown    │
   │   → SessionWriterRegistry.delete_all       │  catchable, includes Ctrl+C
   │   → Supervisor.stop → System.halt          │  in foreground terminal
   └────────────────────────────────────────────┘
   ┌─ Layer 2: bash trap in scripts/aiur ───────┐
   │   trap on EXIT INT TERM HUP                │
   │   reads $XDG_RUNTIME_DIR/aiur-$pid-sessions│  parent terminal close,
   │   loops opencode session delete <id>       │  bash crash, panic exit
   └────────────────────────────────────────────┘
   ┌─ Layer 3: boot-time GC (shipped) ──────────┐
   │   WarmServer enumerates Aiur-owned         │
   │   sessions on next aiur run; deletes any   │  SIGKILL, OOM, power loss
   │   not in active SessionWriterRegistry      │
   └────────────────────────────────────────────┘
```

---

## Implementation Units

- [ ] U1. **Add `Aiur.Tmux.move_pane_hidden/2` and `move_pane_visible/2`**

**Goal:** Provide a tmux primitive that moves a running pane between visible and hidden windows without re-spawning the underlying process.

**Requirements:** R1, R4

**Dependencies:** None

**Files:**
- Modify: `elixir/lib/aiur/tmux.ex`
- Test: `elixir/test/aiur/tmux_test.exs`

**Approach:**
- Wrap `tmux move-pane -d -s <pane_id> -t <window>`.
- `move_pane_hidden/2` takes a pane ID and the hidden warm window name.
- `move_pane_visible/2` takes a pane ID and the visible window name; the call sequence may also need to set the window's layout afterward — read `PaneManager.apply_layout/1` for the existing reflow approach.
- Both functions are idempotent: moving a pane to the window it's already in is a no-op.

**Patterns to follow:**
- Existing `Aiur.Tmux.join_pane/3` for the GenServer call/cmd flow.

**Test scenarios:**
- Happy path: pane currently in window A, call `move_pane_hidden/2` → tmux reports pane is in window B. Pane PID unchanged.
- Edge case: pane already in target window → returns `:ok`, no tmux state change.
- Error path: pane ID does not exist → returns `{:error, _}`, no crash.

**Verification:** `mix test test/aiur/tmux_test.exs` passes; manual tmux smoke shows a pane moving between windows without process restart.

---

- [ ] U2. **Add `SessionWriter.await_replay/2` synchronization barrier**

**Goal:** Give callers (PaneManager, AttachQueue) a synchronization point that returns only after the writer's history replay has fully committed to SQLite.

**Requirements:** R2

**Dependencies:** None

**Files:**
- Modify: `elixir/lib/aiur/opencode/session_writer.ex`
- Test: `elixir/test/aiur/opencode/session_writer_test.exs`

**Approach (revised after feasibility review):**
- `replay_history/1` (`elixir/lib/aiur/opencode/session_writer.ex:111-140`) is **already synchronous** inside `handle_continue(:boot, ...)` (line 65-69) — no async tasks, no `send(self(), ...)`, no outstanding writes when it returns. The GenServer message queue is FIFO, so any `GenServer.call` arriving after `SessionWriterRegistry.ensure/2` returns will be processed only **after** `handle_continue(:boot, ...)` completes.
- The implementation is therefore a one-line `handle_call(:await_replay, _from, state), do: {:reply, :ok, state}`. GenServer queue ordering gives the barrier guarantee for free; no `replay_status` field, no awaiter list, no transition-event plumbing.
- Document the dependency on `handle_continue` ordering in the module so a future reader doesn't make replay async without revisiting the barrier.

**Patterns to follow:**
- Existing simple `handle_call` patterns in `SessionWriter`.

**Test scenarios:**
- Covers AE2. Happy path: writer with 5 IssueLog history entries → `await_replay` returns `:ok` and `Db.fetch_messages` returns 5 assistant-role rows.
- Edge case: empty history → `await_replay` returns `:ok`, zero rows in DB.
- Edge case: `await_replay` called after the writer is fully booted → returns `:ok` immediately.
- Regression guard: if `replay_history` is ever made async, this test must fail — assert the writer's mailbox is empty after `await_replay`.

**Verification:** Test suite green; rows are committed to SQLite before any `await_replay` returns.

---

- [ ] U3. **`Aiur.Opencode.PersistentPane` state struct + Registry extension**

**Goal:** Track each agent identifier's tmux pane ID, attach status, and visibility state in a single source of truth that all subsystems consult.

**Requirements:** R1, R4

**Dependencies:** None

**Files:**
- Create: `elixir/lib/aiur/opencode/persistent_pane.ex` (struct + helpers)
- Modify: `elixir/lib/aiur/opencode/session_writer_registry.ex` (extend `Entry` struct)
- Test: `elixir/test/aiur/opencode/persistent_pane_test.exs`

**Approach:**
- Define `PersistentPane.t()` with fields: `identifier`, `session_id`, `pane_id` (nil until attached), `status` (`:pending | :attaching | :hidden | :visible`), `attached_at`.
- Extend `SessionWriterRegistry.Entry` to embed a `PersistentPane` value or replace its raw fields. The registry remains the single map keyed by identifier.
- Add registry helpers: `get_persistent_pane/1`, `set_status/2`, `set_pane_id/2`.
- No behavior change yet — this is the data substrate U4 and U7 ride on.

**Patterns to follow:**
- `Aiur.IssueLog.Registry` and `SessionWriterRegistry` for value-map idioms.

**Test scenarios:**
- Happy path: register an entry, set pane id, transition status → reads return updated values.
- Edge case: lookup before registration → returns `{:error, :not_found}`.

**Verification:** Test suite green; existing SessionWriter tests still pass.

---

- [ ] U4a. **Ensure hidden warm window exists at boot**

**Goal:** Create the hidden tmux window that holds every background opencode-attach pane, exactly once, before any agent attach runs. Today this happens as a side effect of `WarmAttach.start_link/1`; U4 removes that worker, so the window-creation step must be hoisted into its own boot-time action.

**Requirements:** R1, R4

**Dependencies:** None

**Files:**
- Create: `elixir/lib/aiur/opencode/hidden_window.ex` (small module owning the hidden-window name + ensure-exists helper)
- Modify: `elixir/lib/aiur/opencode/prewarm_supervisor.ex` (add `HiddenWindow` child or call its `ensure/0` from supervisor `init`)
- Modify: `elixir/lib/aiur/opencode/warm_attach.ex` (remove `Tmux.new_hidden_window` call once U4a owns it)
- Test: `elixir/test/aiur/opencode/hidden_window_test.exs`

**Approach:**
- `HiddenWindow.ensure/0` calls `Aiur.Tmux.new_hidden_window/3` once at boot. The window name is a module attribute (e.g. `@hidden_window "_aiur_warm"`); single source of truth that `AgentAttach` and `Tmux.move_pane_hidden/2` read from.
- Idempotent: if the window already exists (e.g. on supervisor restart), reuse it. Today `Tmux.new_hidden_window/3` already handles this; verify and re-export the guarantee.
- Ordering: `HiddenWindow` must be ready before `AttachQueue` starts processing. Express this through the supervisor's child order (or by making `AttachQueue.init` call `HiddenWindow.ensure/0` synchronously).

**Patterns to follow:**
- Existing `WarmAttach.start_link/1` hidden-window creation sequence.
- `Aiur.Tmux.new_hidden_window/3` for the actual tmux call.

**Test scenarios:**
- Happy path: `HiddenWindow.ensure/0` called on a fresh tmux session → window with the configured name appears in `tmux list-windows`.
- Idempotence: `ensure/0` called twice → second call is a no-op, no duplicate window.
- Edge case: window pre-exists from a prior aiur run on the same socket → `ensure/0` returns `:ok`, reuses it.

**Verification:** Test suite green; manual `tmux list-windows -t <aiur-socket>` shows the hidden window present after boot.

---

- [ ] U4. **Convert `WarmAttach` into per-identifier `AgentAttach` worker**

**Goal:** Replace the single-shot WarmAttach pattern with a per-agent attach worker that creates a session with the **real title**, spawns an opencode-attach into the hidden window, awaits replay, selects the session, fires a refresh nudge, and registers the pane as `:hidden`.

**Requirements:** R1, R2, R4, R6

**Dependencies:** U1, U2, U3, U4a

**Files:**
- Create: `elixir/lib/aiur/opencode/agent_attach.ex`
- Modify: `elixir/lib/aiur/opencode/warm_attach.ex` (slim down or delete; the warm-server-side neutral pane no longer needs to pre-attach a placeholder session)
- Modify: `elixir/lib/aiur/opencode/prewarm_supervisor.ex` (drop WarmAttach child if removed)
- Test: `elixir/test/aiur/opencode/agent_attach_test.exs`

**Approach:**
- `AgentAttach.attach/2` takes an identifier and a `:priority | :background` mode.
- Sequence per the state diagram above:
  1. Generate per-agent opencode config via `Aiur.Opencode.Protocol.opencode_json/1`, passing the agent's real identifier (e.g. `"issue-42"`) so the `"name"` field renders as `"Aiur issue-42"` — never `"Aiur _warm"`.
  2. `ApiClient.create_session(base_url, real_title, opts)` — `real_title` is the agent's identifier or its display label.
  3. `SessionWriterRegistry.ensure/2` — spawns SessionWriter; replay runs synchronously inside `handle_continue(:boot, ...)`.
  4. `Tmux.spawn_pane_in_hidden_window/2` (or extend the existing helper) — runs `opencode attach <session_id>` in the hidden warm window, using the per-agent config so `Protocol`'s `"name"` field is correct from the first paint.
  5. `SessionWriter.await_replay/2` (U2 barrier).
  6. `ApiClient.select_session(base_url, session_id)`.
  7. Fire one `__aiur_stream__:<refresh_marker>` via the bridge to nudge the TUI to re-fetch.
  8. Register the pane in the registry with status `:hidden`. The `:priority | :background` mode is **only** an output hint returned to AttachQueue; AgentAttach itself always ends in `:hidden`. AttachQueue is responsible for promoting to visible by calling `Tmux.move_pane_visible/2` after `AgentAttach.attach/2` returns successfully — this is the cleaner option (b) from the feasibility review.

**Execution note:** This is the heart of the new attach model. Add an integration test that proves history is visible in SQLite **and** rendered in the TUI buffer before the select-session call returns.

**Patterns to follow:**
- Existing `WarmAttach.take_over/3` for the select-session + nudge sequence.

**Test scenarios:**
- Covers AE2. Identifier with 3 IssueLog history entries → attach completes, all 3 rendered as assistant-role rows in SQLite, TUI shows them after select-session + nudge.
- Covers AE6 (partial). Identifier `"issue-42"` → resulting session's `title` is `"issue-42"` (or its display label), and the rendered `Protocol.opencode_json/1` `"name"` field is `"Aiur issue-42"` — never `"Aiur _warm"` or `"Aiur _placeholder"`.
- Happy path: identifier with 3 history entries → attach completes, pane registered `:hidden`, real title set on session.
- Edge case: identifier with empty history → attach completes, zero replay rows, pane registered.
- Edge case: opencode `create_session` fails → AgentAttach returns `{:error, _}`, registry not corrupted, no orphan pane.
- Error path: tmux spawn fails → session created in opencode but not registered in PersistentPane; cleanup deletes the session.
- Integration: after attach, `Db.fetch_messages` returns the replayed rows AND the TUI has been selected to that session.

**Verification:** Test suite green; manually attaching one agent shows correct title, full history, and no `_warm`/`_placeholder` in the TUI.

---

- [ ] U5. **`Aiur.Opencode.AttachQueue` GenServer**

**Goal:** Enumerate the agent identifier list at boot, run `AgentAttach.attach/2` one at a time in the background, and yield to user-priority requests.

**Requirements:** R4

**Dependencies:** U4, U4a

**Files:**
- Create: `elixir/lib/aiur/opencode/attach_queue.ex`
- Modify: `elixir/lib/aiur/opencode/prewarm_supervisor.ex` (add AttachQueue child)
- Modify: `elixir/lib/aiur.ex` (wire into application supervisor — already routes via `PrewarmSupervisor`)
- Test: `elixir/test/aiur/opencode/attach_queue_test.exs`

**Approach:**
- State: `pending_queue` (list of identifiers), `inflight` (identifier or nil), `priority` (identifier or nil).
- On `:start_background`: pop next from `pending_queue`, set `inflight`, spawn `AgentAttach.attach(id, :background)`.
- On `{:request_priority, id}` (chosen approach: **post-return promotion**, option (b) from feasibility review — AgentAttach stays a one-shot function call; no mid-attach flag polling):
  - If `inflight == id`: record `id` in `pending_promotions` set, return `:ok`. When AgentAttach returns successfully, AttachQueue checks the set and calls `Tmux.move_pane_visible/2` itself.
  - If `id` is in `pending_queue`: remove it, push to front, also add to `pending_promotions`. When it eventually attaches, AttachQueue promotes it on return.
  - If `id` already in `:hidden` registry: AttachQueue returns `:already_attached`; PaneManager directly calls `move_pane_visible`.
- On `{:cancel, id}` (when user closes a pane mid-attach — see U6): record `id` in `cancellations` set. If `inflight == id`, the AgentAttach is allowed to complete (single-inflight serialization), but on return AttachQueue treats it as if it had been `:background` (no promotion) — the pane ends up `:hidden` and PaneManager does not move it to visible.
- On AgentAttach completion: clear `inflight`, drain `pending_promotions` for that id (if any) via `move_pane_visible`, start next pending.
- Tolerate empty agent list at boot (no-op until identifiers are added).

**Patterns to follow:**
- `Aiur.Orchestrator` for poll-cycle GenServer idioms; `WarmAttach.handle_call` for serialized state transitions.

**Test scenarios:**
- Happy path: 4 agents added → all four end up in `:hidden` status, one at a time.
- Priority pre-empt (mid-attach): agent A in flight, request priority on A → A's pane promoted to visible after replay; B/C/D still queued.
- Priority pre-empt (queued): A in flight, request priority on C → A finishes background, C jumps front, B/D follow.
- Priority on already-attached: A in `:hidden`, request priority on A → registry sees `:hidden`, AttachQueue returns `:already_attached`, caller (PaneManager) directly moves pane to visible.
- Empty queue: no agents → queue idles, no errors.
- Concurrent priorities: two priority requests in quick succession → both serviced in order (second waits for first to complete).

**Verification:** Test suite green; manual: open agent 3 first, watch 1/2/4 attach in background, switch sub-100 ms thereafter.

---

- [ ] U6. **Rewire `PaneManager.open/close` for persistent panes**

**Goal:** Make open and close pure tmux moves against pre-attached panes; eliminate the cold-attach fallback that destroys panes on close.

**Requirements:** R1, R4

**Dependencies:** U3, U5

**Files:**
- Modify: `elixir/lib/aiur/pane_manager.ex`
- Modify: `elixir/lib/aiur/agent_list/app.ex` (close keypress handler — verify it routes through PaneManager, not direct tmux kill)
- Test: `elixir/test/aiur/pane_manager_test.exs`

**Approach:**
- **Open path:** look up the identifier in PersistentPane registry.
  - `:visible` — no-op (already showing).
  - `:hidden` — `Tmux.move_pane_visible/2`, update status, apply layout.
  - `:attaching` (mid-attach in AttachQueue) — call `AttachQueue.request_priority(id)`, register a callback that fires `move_pane_visible` once the attach reaches `:hidden`.
  - `:pending` (not started) — call `AttachQueue.request_priority(id)` to jump the queue; same callback.
- **Close path:** for the closing identifier, look up the registry status.
  - `:visible` — `Tmux.move_pane_hidden/2`, update status to `:hidden`.
  - `:attaching` — call `AttachQueue.cancel(id)` (records cancellation; AgentAttach completes, AttachQueue does NOT promote the result to visible). PaneManager registers no pane move. Once attach completes, the pane lives in the hidden window as `:hidden` — exactly what close intends.
  - `:hidden` — defensive no-op.
  - `:pending` — call `AttachQueue.cancel(id)`; the id is dropped from the front-of-queue promotion. AgentAttach hasn't run yet, so nothing to move; the pane will attach background when its slot arrives, ending in `:hidden`.
- **Do NOT** call `Tmux.kill_pane`, `SessionWriter` stop, or `ApiClient.delete_session` in any close branch. Pane and session survive.
- Remove the existing cold-attach fallback once verified the new path is reliable.

**Patterns to follow:**
- Current `PaneManager.warm_hand_off/3` for layout reflow.

**Test scenarios:**
- Covers AE1. Open agent #42, type, close, reopen → same pane id, same session id, same conversation visible.
- Covers AE4. Selected agent #3 while 1/2/4 background-attach → #3 visible <100 ms after queue completes its priority promotion; 1/2/4 still register `:hidden`.
- Edge case: open identifier with no AttachQueue entry yet (race during boot) → priority request triggers attach; pane appears once ready.
- Edge case: open while pane already `:visible` → no-op, no tmux command issued.
- Edge case: close already-hidden pane (defensive) → no-op.
- Edge case: close pane while its identifier is `:attaching` in AttachQueue → AttachQueue.cancel/1 is called; AgentAttach completes; pane registers as `:hidden` without ever appearing in visible window.
- Edge case: close pane while its identifier is `:pending` in AttachQueue → cancel removes any priority promotion; pane eventually attaches background.

**Verification:** Test suite green; manual cycle through AE1 + AE4 successfully.

---

- [ ] U7. **Autonomous loop: re-evaluate `continue_with_issue?` after operator turns**

**Goal:** After an agent processes a user message via `run_queue_item_turn`, re-check `continue_with_issue?` and recurse into the codex loop if the issue is still active.

**Requirements:** R3

**Dependencies:** None

**Files:**
- Modify: `elixir/lib/aiur/agent_runner.ex`
- Test: `elixir/test/aiur/agent_runner_test.exs`

**Approach (revised after feasibility review):**
- `run_queue_item_turn/6` does NOT have `issue_state_fetcher` in scope, so the recheck cannot live there directly. The fix instead matches the existing `wait_for_resume/3` template in `elixir/lib/aiur/agent_runner.ex:399-431`, which already does the recheck-after-side-channel pattern.
- Locus: `do_run_codex_turns/10` (around `elixir/lib/aiur/agent_runner.ex:301-367`). After the call site that invokes `drain_operator_messages` (and from there `run_queue_item_turn`), re-evaluate `continue_with_issue?` using the in-scope `issue_state_fetcher` and recurse if the issue is still active.
- This mirrors how normal-turn completion already recurses (line ~384). The bug today is that the operator-turn branch returns from the inner call without re-entering the recursion check at the outer level.
- If false (issue completed, paused, or in a terminal state), fall back to `wait_for_operator_message` as today.

**Execution note:** Add a failing test first that asserts: agent processes a user message, completes the operator turn, and **without further input** runs at least one more codex turn against the same active issue.

**Patterns to follow:**
- The existing recursion in `do_run_codex_turns/10` after normal-turn completion.

**Test scenarios:**
- Covers AE3. Issue active → user sends operator message → agent processes it → agent runs at least one more turn autonomously without prompting.
- Issue moves to paused mid-operator-turn → agent does not recurse; falls back to wait.
- Max turns reached after operator turn → no recursion; returns `:ok`.
- No operator messages pending → standard recursion path unchanged.

**Verification:** Test suite green; manually, an agent that was sitting idle continues advancing after one user interjection.

---

- [ ] U8. **Session-id tempfile + bash trap in `scripts/aiur`**

**Goal:** Layer-2 cleanup that survives any failure of the BEAM-side shutdown path, including parent-bash exit and panic.

**Requirements:** R5

**Dependencies:** None

**Files:**
- Modify: `elixir/lib/aiur/opencode/session_writer.ex` (append session_id on ensure)
- Modify: `elixir/lib/aiur/shutdown.ex` (clear tempfile on graceful exit)
- Modify: `scripts/aiur` (trap EXIT INT TERM HUP; consume tempfile; **replace `exec tmux attach` with non-exec invocation**)
- Test: `elixir/test/aiur/opencode/session_writer_test.exs` (tempfile append)
- Test: shell-based smoke test or manual verification for the trap

**Approach (revised after feasibility review):**
- **Critical prerequisite:** `scripts/aiur:972` currently uses `exec "$tmux_bin" ... attach -t "$session"`. The `exec` replaces the bash process with tmux, so any trap installed before it **never fires** on normal exit. This unit MUST first change that line to a non-exec invocation:
  ```
  "$tmux_bin" -L "$socket" ... attach -t "$session"
  cleanup_status=$?
  __aiur_cleanup
  exit $cleanup_status
  ```
  Bash stays resident, the trap runs on EXIT/INT/TERM/HUP, then the script exits with tmux's status. The existing `trap 'rm -f "$startup_capture"' EXIT` (line 917) is preserved by chaining cleanup steps in `__aiur_cleanup`.
- On `SessionWriter.init`, after `ApiClient.create_session`, append the new session ID (one per line) to `$AIUR_SESSION_TMPFILE`.
- `scripts/aiur`:
  - Compute `AIUR_SESSION_TMPFILE="${XDG_RUNTIME_DIR:-/tmp}/aiur-$$-sessions"` early (before BEAM launch).
  - **Export** it (`export AIUR_SESSION_TMPFILE=...`) — the export survives into the tmux pane where the BEAM runs, even though the BEAM's own `$$` differs from bash's. The bash trap reads the file the BEAM wrote.
  - `trap '__aiur_cleanup' EXIT INT TERM HUP`. The handler reads the tempfile, runs `mise exec -- opencode session delete <id>` for each id (best-effort, parallel `&` with a bounded `wait`), then removes the tempfile.
- `Aiur.Shutdown.cleanup/1` truncates the tempfile (not delete — keep the file so the trap finds it but is a no-op) on graceful exit. The BEAM already reaped the sessions; the bash trap finds an empty file and no-ops.

**Patterns to follow:**
- Existing `trap 'rm -f "$startup_capture"' EXIT` at `scripts/aiur:917` — chain rather than replace.

**Test scenarios:**
- Covers AE5. Run aiur with two attached sessions, Ctrl+C → bash trap fires, both sessions deleted, `opencode session list` empty.
- Run aiur, `kill -9` the BEAM pid (NOT the parent bash) → BEAM dies, bash trap fires on bash exit, sessions cleaned. Verify by checking `opencode session list`.
- Run aiur, exit cleanly via `q` → BEAM reaps sessions, tempfile emptied, bash trap finds nothing to do.
- Run aiur with no sessions → trap is a no-op.

**Verification:** Manual CLI verification with `mise exec -- opencode session list` after each scenario. Required by the session goal hook.

---

- [ ] U9. **Audit + assert no `_warm` / `_placeholder` titles ever leak**

**Goal:** Defense-in-depth assertion that no opencode session created during an aiur run carries a placeholder title.

**Requirements:** R6

**Dependencies:** U4

**Files:**
- Modify: `elixir/lib/aiur/opencode/warm_server.ex` (verify the neutral server's session, if any, is not surfaced to the TUI; rename or eliminate the "_warm" marker if it's stored as a session title)
- Modify: `elixir/lib/aiur/opencode/api_client.ex` (consider adding a debug guard in `create_session/3` that logs a warning if the title is `_warm`, `_placeholder`, or empty)
- Test: `elixir/test/aiur/opencode/warm_server_test.exs`

**Approach:**
- Audit every callsite of `ApiClient.create_session` in the codebase.
- Audit every callsite that sets a `modelID` or `providerID` that might surface in the input bar — this is where the "Build Aiur _warm" string likely comes from. Check `Aiur.Opencode.Protocol.assistant_message_data/1` and any session-creation opts that set the model ID.
- The "Build Aiur" prefix appears to be the model name; "_warm" is the model identifier. Confirm and rename the model ID to the agent's identifier (or to a stable user-facing label like "aiur") so no internal name leaks.
- After audit, add a test that creates a SessionWriter for each test fixture identifier and asserts the resulting session's `title` and `model` fields contain neither `_warm` nor `_placeholder`.

**Test scenarios:**
- Covers AE6. Spawn 4 agent attaches via AgentAttach → for each session, assert `title` and `model.id` do not contain `_warm` or `_placeholder`.
- WarmServer's own server-marker session (if any) is either deleted before any user-visible attach completes, OR its title is set to a user-acceptable label.

**Verification:** Test suite green; manual TUI inspection shows no leaks in any pane.

---

- [ ] U10. **BEAM signal handler wiring + verify Ctrl+C path**

**Goal:** Ensure SIGINT/SIGTERM/SIGHUP delivered to the BEAM trigger `Aiur.Shutdown.shutdown/2` before halt.

**Requirements:** R5

**Dependencies:** U8

**Files:**
- Modify: `elixir/lib/aiur.ex` (signal handler registration via `:os.set_signal/2` if needed)
- Modify: `elixir/lib/aiur/cli.ex` (ensure `wait_for_shutdown` covers the signal-triggered exit)
- Test: `elixir/test/aiur/shutdown_test.exs` (extend with signal scenario if testable)

**Approach:**
- Verify the current BEAM behavior: by default, SIGINT in a foreground terminal causes the BEAM to begin orderly shutdown via `init:stop/0`, which triggers `Application.stop/1` (already wired to `Aiur.Shutdown.cleanup/1`).
- If observation shows SIGINT bypasses `Application.stop` (e.g., the BEAM does a hard halt), register an explicit handler with `:os.set_signal/2` that routes into `Aiur.Shutdown.shutdown/2`.
- Verify SIGTERM and SIGHUP similarly.

**Test scenarios:**
- Manual: `kill -INT $BEAM_PID` → `Aiur.Shutdown.cleanup` runs (visible in logs), sessions cleaned.
- Manual: `kill -TERM $BEAM_PID` → same.
- Manual: `kill -HUP $BEAM_PID` → same.
- Manual: `kill -KILL $BEAM_PID` → BEAM dies immediately; bash trap (U8) cleans up.

**Verification:** Manual CLI verification with `opencode session list` after each signal scenario.

---

- [ ] U11. **End-to-end manual CLI verification of all 6 issues**

**Goal:** Confirm via `scripts/aiur` and `opencode session list` that AE1 through AE6 all hold.

**Requirements:** All

**Dependencies:** U1–U10

**Files:** none (verification only)

**Approach:**
- Clean slate: `mise exec -- opencode session list` shows zero before each scenario.
- Run through AE1, AE2, AE3, AE4, AE5, AE6 in order.
- Log results in the PR description.

**Test expectation:** Manual end-to-end. Required by the session goal hook.

**Verification:** All 6 acceptance examples observably hold; `opencode session list` shows zero leaks at the end.

---

## System-Wide Impact

- **Interaction graph:** PaneManager ↔ AttachQueue ↔ AgentAttach ↔ SessionWriter ↔ Tmux ↔ ApiClient. PaneManager close path no longer touches SessionWriter or ApiClient. AttachQueue is the new orchestrator for non-user-driven pane work.
- **Error propagation:** AttachQueue treats individual AgentAttach failures as best-effort — logs, drops the identifier, continues. Failed attaches do not block the queue. PaneManager open against a failed identifier surfaces a clear error to the user (TUI status line or stderr).
- **State lifecycle risks:** PersistentPane registry must not leak: every successful create-session must be paired with either a delete-session on shutdown OR a tempfile entry the bash trap can consume. The `SessionWriter.init` ordering matters — the tempfile append happens AFTER `create_session` returns successfully, never before.
- **API surface parity:** No external API surface changes. All changes internal to the BEAM and the bash launcher.
- **Integration coverage:** Three integration paths require explicit testing — (a) end-to-end attach with history rendering, (b) close→open cycle preserving session, (c) Ctrl+C with multiple resident sessions.
- **Unchanged invariants:** `Aiur.IssueLog`, `Aiur.Orchestrator`, the `/v1/chat/completions` bridge route, and the opencode SQLite schema are not changed by this plan.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| tmux `move-pane -d` resizes or kills the pane unexpectedly under certain layouts | Spike test in U1 with the real warm-window + visible-window layout; revert to `join-pane` if `move-pane` misbehaves. Both have the same flag semantics. |
| `__aiur_stream__` refresh nudge no longer reliably refreshes the TUI after a future opencode bump | Keep the `select-session` round-trip as a redundant nudge in U4; if both fail, fall back to a brief `await` + reselect cycle. |
| `await_replay/2` blocks indefinitely if SessionWriter crashes mid-replay | Use a `timeout` parameter; on timeout, log a warning and proceed with attach (degraded — user sees empty pane). Test scenario explicit. |
| Bash trap doesn't run because aiur was launched via something other than `scripts/aiur` (e.g., direct `mix run`) | Document that `scripts/aiur` is the supported entry point; mention in CLI startup banner if `AIUR_SESSION_TMPFILE` is unset. |
| Boot-time GC false positives — deletes a session a user actually created with `opencode` outside Aiur | GC already filters by `model.providerID == "aiur"` (verified). No change here. |
| Autonomous loop fix introduces infinite-recursion if `continue_with_issue?` is buggy | Existing path after normal turn already recurses with this exact check; reusing the same helper for operator turns inherits its bug-free behavior. Add a max-recursion guard if the existing helper lacks one. |
| `tmux move-pane` away from the visible window leaves the layout in an inconsistent state | After every move, call `PaneManager.apply_layout/1` (existing helper) to reflow. Covered in U6 tests. |

---

## Documentation / Operational Notes

- Update CLI banner or `--help` to mention that interactive mode requires launch via `scripts/aiur` for the full cleanup guarantees.
- After landing, run `/ce-compound` to capture: the persistent-pane model, the bash-trap pattern, the rename-fallback-via-create, the `await_replay` synchronization technique, and the autonomous-loop fix locus.
- No new env vars exposed externally — `AIUR_SESSION_TMPFILE` is internal between `scripts/aiur` and the BEAM.

---

## Sources & References

- **Origin document:** [elixir/docs/brainstorms/2026-05-21-aiur-pane-lifecycle-and-background-attach-requirements.md](elixir/docs/brainstorms/2026-05-21-aiur-pane-lifecycle-and-background-attach-requirements.md)
- Prior plan (parent infrastructure): `elixir/docs/plans/2026-05-20-001-feat-opencode-prewarm-and-history-injection-plan.md`
- opencode row schema reference: `elixir/docs/notes/opencode-row-shapes-1.15.6.md`
- opencode 1.15.6 CLI: probed during planning — no session rename.
- tmux man page: `move-pane`, `join-pane` (`-d` semantics).
