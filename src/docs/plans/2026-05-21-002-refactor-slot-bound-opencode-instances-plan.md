---
title: refactor: Slot-bound opencode instances with lazy chain pre-warm
type: refactor
status: active
date: 2026-05-21
deepened: 2026-05-21
origin: elixir/docs/brainstorms/2026-05-21-slot-bound-opencode-instances-requirements.md
---

# refactor: Slot-bound opencode instances with lazy chain pre-warm

## Overview

Replaces the per-agent `AttachQueue` / `AgentAttach` orchestration with a per-slot opencode instance model. Each pane slot owns one opencode-serve + one opencode-attach process for the lifetime of an aiur run. Opening a pane is `/tui/select-session` plus a tmux `move-pane -d` swap. SessionWriters stay global, one per agent, writing the shared opencode SQLite.

Pre-warming runs as a chain: slot 1 boots at aiur start; slot N+1 begins booting once slot N is ready and its `opencode.json` declares every currently-active agent identifier. Total instances pre-warmed equals the conversation slot count (`2 × max_vertical_panes − 1`).

The refactor also fixes five real bugs surfaced in production (duplicate sessions per agent, bridge-token 401s, indicator drift, variable open latency, `_placeholder` leak), and DELETES `AttachQueue`, `AgentAttach`, the per-agent `PersistentPane` registry value, and `SessionWriterRegistry.regenerate_workspace_config` — the slot model makes them unnecessary. The net diff is expected to be negative lines.

---

## Problem Frame

The previous round (origin: `2026-05-21-aiur-pane-lifecycle-and-background-attach-requirements.md`) shipped a "one warm opencode-serve + per-agent attaches in a hidden window" model. Live use surfaced six bugs that all trace to one root cause: opencode instances were bound to *agents*, but the natural resource boundary in this UI is a *pane slot*. Slots are stable and bounded (`S = 2 × max_vertical_panes − 1`); agents come and go. Binding the wrong axis forced AttachQueue to invent priority preemption, cancellation, and per-agent ghost sessions to compensate.

Slot-binding eliminates those problems:
- One opencode instance per slot → never more than one session per agent open at the serve level → no duplicates (R2).
- Each slot's `opencode.json` is materialized once at slot boot with every active agent identifier → no `Model not found` errors → no `_warm` leak in opencode's "Did you mean: issue-_warm?" message (R6 from prior round).
- A single apiKey per slot, never rotated → no `unauthorized` 401s (R4).
- Open and close become tmux move-pane operations against an already-attached process → ≤100 ms every time (R5).
- A periodic poll of each slot's active session keeps the agent-list circle indicator aligned with reality (R3).
- Pre-warm chain (slot N → slot N+1 only when N reaches ready) gives the user the best perceived latency without the boot CPU spike of starting all N in parallel (R6).

---

## Requirements Trace

- R1. Per-slot opencode instances (origin R1.1–R1.5)
- R2. Single opencode session per agent, ever (origin R2.1–R2.3)
- R3. Indicator follows currently-visible session, not historical opens (origin R3.1–R3.4)
- R4. Bridge token authentication never fails for live workspaces (origin R4.1–R4.3)
- R5. Open/close instant after slot is warm (origin R5.1–R5.4)
- R6. Lazy chain pre-warm (origin R6.1–R6.5)
- R7. Delete dead code; net-negative LOC (origin R7.1–R7.5)

**Origin actors:** A1 (developer), A2 (codex agent), A3 (opencode instance)

**Origin acceptance examples:**
- AE1 (boot interactive within 1s), AE2 (open agent in slot 1 ≤100 ms), AE3 (open agent in slot 2 ≤100 ms), AE4 (close + re-open within slot ≤100 ms), AE5 (Ctrl+P switch moves circle within 1s), AE6 (no duplicates, no placeholder titles), AE7 (back-to-back fills every slot at ≤100 ms each), AE8 (no agents → all slots cold), AE9 (no `unauthorized` 401s)

---

## Scope Boundaries

- Mid-run agent additions are accepted as **degraded** in already-warm slots: opencode-serve does not hot-reload `opencode.json`, and forcing a slot serve restart on every new agent would defeat R5. The slot's existing serve will not know the new agent until the slot is fully reset (e.g. between aiur runs). This is acceptable because new agents are rare and the cold-attach fallback path still works.
- Persisting slot state across aiur restarts is not in scope. Each boot starts cold.
- Configurable pre-warm depth is not in scope; total = `slot_count`.

### Deferred to Follow-Up Work

- **Origin R6.4** (mid-run agent additions reach already-warm slots): silently dropped from this pass; explicitly deferred. opencode-serve does not hot-reload `opencode.json`, and forcing a slot serve restart on every new agent would defeat R5 (≤100 ms opens). The slot's existing serve will not know the new agent until it's restarted (e.g. between aiur runs or via an opt-in "rescan" command). Planned for a separate pass once usage data tells us how often mid-run additions matter.
- A user-facing "slot status" indicator (cold / warming / ready) — only if real-world use reveals it's needed.

---

## Context & Research

### Relevant Code and Patterns

- `elixir/lib/aiur/pane_manager.ex` — owns slot allocation today; `slot_count/1 = max_vertical_panes * 2 − 1`. `cycle_index` round-robins. The slot-bound refactor reuses the slot data structure and removes most other complexity here.
- `elixir/lib/aiur/opencode/server.ex` — wraps `opencode serve` as a Port-managed process. Reusable as-is for per-slot serves.
- `elixir/lib/aiur/opencode/workspace_setup.ex` — `materialize_prewarm/2` writes `opencode.json` for one workspace. Will be repurposed for per-slot workspaces (`materialize_slot/3`).
- `elixir/lib/aiur/opencode/protocol.ex` — `opencode_json/1` already accepts `:extra_identifiers` to seed multiple agents in the provider models map; that's exactly what each slot needs.
- `elixir/lib/aiur/opencode/session_writer_registry.ex` — global per-agent SessionWriters. Stays. Drop the per-agent `regenerate_workspace_config/2` helper (no longer needed; slots own their workspace files).
- `elixir/lib/aiur/opencode/token_registry.ex` — currently keyed by `{token, identifier}`. Will be rekeyed by token alone.
- `elixir/lib/aiur/opencode/chat_completions.ex` — `TokenRegistry.valid?(token, identifier)` callsite (line 316) becomes `TokenRegistry.valid?(token)`.
- `elixir/lib/aiur/agent_list/app.ex` + `elixir/lib/aiur/agent_list/renderer.ex` — circle indicator currently keyed by `open_pane_ids` (set of identifiers that have ever opened a pane). Rekey to `visible_sessions` (map slot_index → identifier).
- `elixir/lib/aiur/opencode/api_client.ex` — `select_session/2` for setting the active session per slot.

### Institutional Learnings

From `elixir/docs/plans/2026-05-20-001-feat-opencode-prewarm-and-history-injection-plan.md` and `elixir/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md`:

- **opencode TUI does not refresh on direct SQLite writes alone.** `POST /tui/select-session` round-trip and the `__aiur_stream__:<msg_id>` synthetic-user marker via the bridge are the proven refresh paths. Direct `/tui/publish` of `EventMessagePartDelta` is rejected by opencode 1.15.6.
- **tmux primitive: `move-pane -d -s <pane> -t <window>`** preserves PID, PTY, and pane id across windows. `-d` prevents focus steal. Always call `PaneManager.apply_layout/1` after a move.
- **OTP release build, not escript** — `bin/aiur` is a thin shim into the assembled release so `exqlite/priv/sqlite3_nif.so` loads.
- **Three-layer shutdown defense** — BEAM signal handler → bash trap → boot-time GC. Don't regress.
- **WAL-mode SQLite + `:exqlite` + `PRAGMA busy_timeout=5000`** is the proven concurrency story for multiple opencode-serve writers against the shared db.
- **Per-identifier `Registry + DynamicSupervisor` with idempotent `ensure/2`** is the project's accepted pattern.
- **Structured logging: `<subsystem> phase=<state> elapsed_ms=<N>`** — slot N+1 pre-warm gate (R6.3) greps for slot N's `phase=ready`.

### Probed opencode 1.15.6 behavior (resolves origin Q1/Q2)

- **Q1 — Session-change event:** opencode does NOT emit a session-change event on `/event` when its TUI's active session changes (e.g. Ctrl+P). There is no `/tui/control/status` endpoint exposing the current session id. → Decision: each slot's polling loop (Slot GenServer) periodically calls `GET /session/<id>` for its known-active session and a brief enumeration to detect change. See U10 design.
- **Q2 — opencode.json hot reload:** opencode-serve reads `opencode.json` once at startup. Adding a new model to the file after serve start is NOT picked up. → Decision: each slot seeds `opencode.json` with every currently-active identifier at slot boot. Mid-run additions are deferred (scope).

---

## Key Technical Decisions

- **Slot-keyed Registry + DynamicSupervisor.** Mirror the existing `SessionWriterRegistry` pattern. `Aiur.Opencode.SlotRegistry` is keyed by `slot_index :: 1..S`. The slot value stores `%Slot.State{}` (status, base_url, pane_id, active_identifier, opencode_os_pid).
- **One workspace per slot, not per agent.** Path: `~/.local/share/aiur/opencode-slot-{N}`. opencode.json is seeded once at slot boot with every currently-active identifier as a model. New agents do not trigger workspace rewrites — slot will see them on next aiur boot.
- **Token simplification.** `Aiur.Opencode.TokenRegistry` changes its key from `{token, identifier}` to `token`. Stores `token → slot_index`. `TokenRegistry.valid?/1` becomes a single-arg existence check. The bridge looks up the identifier off the chat-completions request body's `model` field (existing `identifier_from_model/1`), separately from token validation. This kills the rotation-causes-401 bug and eliminates ~30 lines of per-identifier token bookkeeping.
- **Chain pre-warm via a thin policy module.** `Aiur.Opencode.SlotPolicy` subscribes to slot phase changes on PubSub. When slot N broadcasts `phase=ready`, policy asks `SlotSupervisor` to start slot N+1. Maximum slots = `slot_count`. No agents → first slot still pre-warms, just with an empty models map; agents added later get the cold-attach fallback (which uses on-demand session creation against the warmed slot's serve).
- **Active-session polling, not events.** Each `Slot` GenServer runs a `:poll` self-message every 500 ms when visible. It calls a lightweight opencode HTTP endpoint (or compares `GET /session` snapshot) to detect Ctrl+P-initiated session switches. When the active session id changes, slot broadcasts `{:slot_session_changed, slot_index, new_identifier}` on `Aiur.PubSub`. AgentList subscribes and updates `visible_sessions`. Hidden slots stop polling.
- **PaneManager becomes a thin allocator.** Open: pick least-recently-used available slot via `SlotSupervisor.acquire/1`, call `Slot.select(slot, identifier)`, then `Tmux.move_pane_visible/2`. Close: `Tmux.move_pane_hidden/2`, call `Slot.deselect(slot)`, release. The "cycle_index" round-robin from today's code is dropped — slot allocation is explicit.
- **HiddenWindow simplified.** Still creates the hidden warm window once at boot (keeps the keep-alive sleep pane), but Slot uses `Tmux.split_pane` against the keep-alive pane to spawn its opencode-attach (silent split, no focus steal). Deletion of `AttachQueue`/`AgentAttach` removes most of the pre-warm orchestration code.
- **SessionWriter is unchanged.** It stays per-agent, writing to the shared opencode SQLite. Slots all read the same db; SessionWriter doesn't need to know which slot will display a given agent.
- **Bridge round-trip refresh.** When `Slot.select` is called and the writer has just replayed history, the slot fires one `__aiur_stream__:<refresh>` synthetic message through the bridge to force the TUI to re-fetch — same trick as prior round, scoped to one call per open.

---

## Open Questions

### Resolved During Planning

- **Q1** (session-change event): No native event. Use 500 ms polling per visible slot.
- **Q2** (opencode.json hot reload): Not supported. Seed all current agents at slot boot; defer mid-run additions.
- **Q3** (`unauthorized` source): `regenerate_workspace_config` rotates the token but opencode-serve keeps the old apiKey. Fix by simplifying TokenRegistry to token-only validity (see Key Technical Decisions).
- **Q4** (placeholder origin): `WarmServer`'s `@placeholder_title` is a GC exclusion artifact; remaining `_placeholder` sessions in `opencode session list` likely come from prior aiur runs that crashed with the WarmAttach placeholder session (now deleted in code) before reaping. Slot model never creates a placeholder. Boot-time GC will need to drop the `_placeholder` exclusion.

### Deferred to Implementation

- Exact polling endpoint for active session (probe in U10 first; commit to keybind-fallback if probe finds nothing).
- Whether SlotPolicy can be a simple GenServer subscribing to PubSub, or if it needs to be a Supervisor child of SlotSupervisor with `:transient` restart. Decide based on what fits the existing supervisor tree best.
- Exact glyph for "cold" vs "warm" slots in any diagnostic logging. Use phase-line logging only at first; no user-facing slot-status UI in this pass.
- Exact field name(s) for the simplified `SessionWriterRegistry` value after `PersistentPane` is removed in U9. Most likely a plain `%{session_id: String.t()}` map, but the implementer should choose between that and the bare string based on which results in less consumer-site code change. Constraint: `Aiur.Shutdown.cleanup` MUST keep working with whatever shape `delete_all/1` returns.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

### Supervisor tree (changed parts)

```
Aiur.Application
├── ... (PubSub, Registries, SessionWriter machinery — unchanged)
├── Aiur.Opencode.TokenRegistry      ← simplified to token-only key
├── Aiur.Opencode.SessionSupervisor  ← unchanged (per-agent SessionWriter children)
├── Aiur.Opencode.BridgeSupervisor   ← unchanged
└── cli_children (when --interactive):
    ├── Aiur.Tmux                    ← unchanged
    ├── Aiur.PaneManager             ← simplified: allocator only
    ├── Aiur.Opencode.PrewarmSupervisor   ← restructured
    │   ├── Aiur.Opencode.HiddenWindow    ← trigger moves to init/1 (no warm_server_ready)
    │   ├── Aiur.Opencode.SlotRegistry    ← NEW (Registry keys: :unique)
    │   ├── Aiur.Opencode.SlotSupervisor  ← NEW (DynamicSupervisor of Slot workers)
    │   └── Aiur.Opencode.SlotPolicy      ← NEW (chain pre-warm orchestrator)
    └── ...

DELETED:
- Aiur.Opencode.WarmServer          (replaced by per-slot Slot.handle_continue;
                                     its boot-time GC migrates to Aiur.Opencode.SessionGC)
- Aiur.Opencode.AttachQueue
- Aiur.Opencode.AgentAttach
- Aiur.Opencode.PersistentPane (struct)  (SessionWriter's Registry value
                                          becomes a plain map)
- SessionWriterRegistry.regenerate_workspace_config/2
- TokenRegistry per-identifier indexing (replaced by token-only key + generation)
```

### Slot state machine

```
[cold]
   │ SlotPolicy.start_slot(N)
   ▼
[booting] ─── materialize_slot(N, agent_ids) ──▶ [serve_starting]
                                                      │
                                                      │ opencode serve ready
                                                      ▼
                                                 [attach_spawning]
                                                      │
                                                      │ Tmux.split_pane (hidden window)
                                                      ▼
                                                 [ready] ◀───────────┐
                                                      │              │
                                       Slot.select(id)│              │ Slot.deselect
                                                      ▼              │
                                                 [active(id)] ───────┘
                                                  + polling on
                                                  + visible window
```

`phase=ready` is the gate SlotPolicy listens for to start slot N+1.

### Per-slot lifecycle on user pane open

```
PaneManager.open(identifier)
   │
   ├─ SlotSupervisor.acquire_slot/0  ─▶ slot_pid (LRU available slot)
   │
   ├─ Slot.select(slot_pid, identifier)
   │    │
   │    ├─ ensure SessionWriter for identifier exists (replay history)
   │    ├─ ApiClient.select_session(slot.base_url, session_id)
   │    ├─ fire one __aiur_stream__ refresh through bridge
   │    ├─ start active-session polling (500ms)
   │    └─ broadcast {:slot_session_changed, slot_index, identifier}
   │
   ├─ Tmux.move_pane_visible(slot.pane_id, agents_window)
   │
   └─ AgentList receives :slot_session_changed → updates visible_sessions → re-renders circle
```

---

## Implementation Units

> **U1** was folded into U10 (probe + implement together). U-ID `U1` is intentionally unused; per the plan's U-ID stability rule, gaps are preserved rather than renumbered.

- [ ] U2. **`Aiur.Opencode.TokenRegistry` — simplify to token-only validity**

**Goal:** Remove the per-identifier token binding. Tokens become a flat set keyed by token, value `{slot_index, inserted_at}`. `valid?/1` is single-arg.

**Requirements:** R4.1, R4.2, R4.3 (origin AE9)

**Dependencies:** None

**Files:**
- Modify: `elixir/lib/aiur/opencode/token_registry.ex`
- Modify: `elixir/lib/aiur/opencode/chat_completions.ex` (line 316 — call `valid?(token)` instead of `valid?(token, identifier)`)
- Modify: `elixir/lib/aiur/opencode/workspace_setup.ex` (line 73 — drop identifier arg from `put`)
- Modify: `elixir/lib/aiur/opencode/pane_session.ex` (line 86 — drop identifier arg from `delete`)
- Modify: `elixir/lib/aiur/opencode/session_writer_registry.ex` (line 196 in `regenerate_workspace_config` — note: this whole helper is removed in U9, so this call vanishes with it; leave a brief comment for the U9 implementer)
- Test: `elixir/test/aiur/opencode/token_registry_test.exs` (existing tests assert the two-arg shape; rewrite for token-only validity)

**Approach:**
- Change ETS table from `{key={token, identifier}, value=meta}` to `{key=token, value={slot_index, generation, inserted_at}}`
- `put(token, slot_index, generation)` replaces `put(token, identifier)`. Generation is bumped by the slot on each serve restart so old tokens can be aged out without affecting still-live ones.
- `valid?(token)` returns `true` if the token is present in the table (no identifier binding)
- `delete(token)` for direct cleanup
- `delete_stale(slot_index, current_generation)` removes only tokens for this slot whose generation is < current — used after a serve restart so an overlapping window keeps the old token valid until the new attach is fully loaded.
- **Bridge 401 mitigation (origin R4.3, AE9):** On a slot serve restart, the slot follows this strict overlap order to avoid any request seeing an empty-registry window: (a) bump generation counter; (b) `put(new_token, slot_index, new_generation)`; (c) start new opencode-serve with new apiKey; (d) once the new attach reports ready, `delete_stale(slot_index, new_generation)` sweeps the old token. Requests arriving anywhere in (b)–(d) succeed because both old and new tokens are valid.
- Update `Aiur.Opencode.ChatCompletions` to extract identifier from request body's `model` field (already does via `identifier_from_model/1`) and check token validity separately

**Patterns to follow:**
- Existing ETS table pattern in `token_registry.ex`

**Test scenarios:**
- Covers AE9. Happy path: `put(token, 1, 1)`, then `valid?(token)` returns true; `valid?("unknown")` returns false.
- `put(token, 1, 1)` then `delete(token)`: `valid?(token)` returns false.
- Generation overlap: `put(token_a, 1, 1)` then `put(token_b, 1, 2)` — BOTH valid until `delete_stale(1, 2)` runs; after sweep only `token_b` remains valid. This proves the 401-free serve restart contract.
- `delete_stale(1, 5)` with mixed-generation entries — only entries for slot 1 with generation < 5 are removed; entries for other slots untouched.
- Regression: rapid `put/delete/put` for the same token (slot serve restart simulation) — new token validates, old does not.

**Verification:** All callers updated; bridge never sees `unauthorized` for a token that was put in this registry.

---

- [ ] U3. **`Aiur.Opencode.SlotRegistry` — slot-keyed Registry**

**Goal:** Provide `1..S → slot_pid` resolution for SlotSupervisor / SlotPolicy / PaneManager. Mirrors `Aiur.Opencode.SessionWriterRegistry.Registry` shape but keyed by slot_index.

**Requirements:** R1.1, R1.5

**Dependencies:** None

**Files:**
- Create: `elixir/lib/aiur/opencode/slot_registry.ex` (small module exposing `lookup/1`, `register_self/1`)
- Modify: `elixir/lib/aiur.ex` (start `{Registry, keys: :unique, name: Aiur.Opencode.SlotRegistry.Registry}` in cli_children)
- Test: `elixir/test/aiur/opencode/slot_registry_test.exs`

**Approach:**
- Standard Elixir Registry, keys: `:unique`, name `Aiur.Opencode.SlotRegistry.Registry`
- The wrapper module exposes a small public API so callers don't need to touch Registry directly

**Patterns to follow:**
- `Aiur.Opencode.SessionWriterRegistry`

**Test scenarios:**
- Happy path: process A registers slot 1; lookup(1) returns A's pid.
- Edge case: lookup(99) returns `:not_found`.
- Edge case: process A dies; lookup(1) eventually returns `:not_found` (Registry handles the unregister).

**Verification:** `mix test test/aiur/opencode/slot_registry_test.exs` passes.

---

- [ ] U4. **`Aiur.Opencode.Slot` GenServer — per-slot lifecycle**

**Goal:** Each slot owns its opencode-serve + opencode-attach pane. State machine: `cold → booting → serve_starting → attach_spawning → ready → active(identifier) ↔ ready` (close returns to ready, not cold).

**Requirements:** R1.1–R1.5, R2.2, R5.1, R5.2, R5.3

**Dependencies:** U2 (TokenRegistry), U3 (SlotRegistry)

**Files:**
- Create: `elixir/lib/aiur/opencode/slot.ex`
- Modify: `elixir/lib/aiur/opencode/workspace_setup.ex` (add `materialize_slot/3` taking slot_index, bridge_url, agent_identifiers)
- Test: `elixir/test/aiur/opencode/slot_test.exs`

**Approach:**
- `start_link(slot_index, opts)` — registers with `SlotRegistry`, transitions through state machine via `handle_continue`
- On boot:
  1. Compute workspace path (`opencode_slot_workspace_path/1` — `~/.local/share/aiur/opencode-slot-#{N}` by default)
  2. Query `Aiur.AgentDirectory.list_agents/0` to get current identifiers
  3. `WorkspaceSetup.materialize_slot(slot_index, bridge_url, identifiers)` — writes opencode.json with all known agents in models map, registers token with TokenRegistry
  4. `Aiur.Opencode.Server.start_link/1` spawns opencode-serve on a random port, awaits ready
  5. `Aiur.Tmux.split_pane(keep_alive_pane, :horizontal, 50, attach_cmd, silent: true)` spawns opencode-attach in hidden window
  6. Broadcast `{:slot_ready, slot_index}` on `Aiur.PubSub` topic `"opencode:slots"`
  7. State → `:ready`
- API:
  - `Slot.select(slot_pid, identifier)` — ensures SessionWriter, calls `select_session`, fires refresh nudge, starts polling, broadcasts `{:slot_session_changed, slot_index, identifier}`; returns `{:ok, pane_id}`
  - `Slot.deselect(slot_pid)` — stops polling, broadcasts `{:slot_session_changed, slot_index, nil}`
  - `Slot.snapshot(slot_pid)` — current state for debugging / introspection
- Polling: when `:active(identifier)`, set `:poll_session` self-message every 500 ms. Compare current session id (from opencode) against state's `active_identifier`. On change, broadcast `{:slot_session_changed, slot_index, new_identifier}` and update state.

**Execution note:** Add a failing test first for state-machine transitions before wiring real opencode-serve / tmux processes. Use a `:test` transport / mock for the heavy IO so unit tests stay fast.

**Patterns to follow:**
- `Aiur.Opencode.SessionWriter` for the GenServer + Registry + DynamicSupervisor pattern
- `Aiur.Opencode.Server` for opencode-serve lifecycle
- `Aiur.Opencode.AgentAttach` (about to be deleted) for the create-session + select + nudge sequence — port the working bits here

**Test scenarios:**
- Happy path: `Slot.start_link(1, …)` → state reaches `:ready` and broadcasts `{:slot_ready, 1}`.
- Covers AE2. `Slot.select(pid, "issue-5")` → returns `{:ok, pane_id}`; opencode.json declares `issue-5` as a model; `TokenRegistry.valid?(token)` returns true.
- Covers AE4. `Slot.deselect(pid)` then `Slot.select(pid, "issue-7")` → state cycles through `:ready → :active("issue-7")` without rebuilding the serve.
- Edge case: `Slot.select` called when state is `:active("issue-5")` → no-op (or switches to new identifier in same call).
- Polling: simulate opencode returning a different session id than state's active_identifier → slot broadcasts `:slot_session_changed`.
- Failure: opencode-serve fails to start → state stays `:cold` or transitions to `:failed`; slot does not register pane id; SlotPolicy can detect and skip.
- Integration: spawn two real slots in parallel against a real tmux socket; both reach `:ready` and have distinct pane ids.

**Verification:** `mix test test/aiur/opencode/slot_test.exs` green; manual smoke: launch aiur, observe `opencode_slot phase=ready slot=1` and `slot=2` in log.

---

- [ ] U5. **`Aiur.Opencode.SlotSupervisor` — DynamicSupervisor**

**Goal:** Spawn `Slot` workers under a `DynamicSupervisor`. Exposes `acquire_slot/0` (returns LRU available slot's pid + index) and `release_slot/1`.

**Requirements:** R1.5, R6.1

**Dependencies:** U3, U4

**Files:**
- Create: `elixir/lib/aiur/opencode/slot_supervisor.ex`
- Modify: `elixir/lib/aiur/opencode/prewarm_supervisor.ex` (add `SlotSupervisor` as child; remove obsolete children — see U13)
- Test: `elixir/test/aiur/opencode/slot_supervisor_test.exs`

**Approach:**
- `DynamicSupervisor.start_link/2` with `strategy: :one_for_one`
- `start_slot(index)` calls `start_child` with `Slot` child spec for that index
- `acquire_slot/0` queries SlotRegistry for slots in `:ready` state, picks one via simple LRU (track `released_at` timestamp on each slot), returns `{slot_index, slot_pid}` or `{:error, :no_ready_slot}`
- `release_slot/1` notifies the slot to deselect (state returns to `:ready`) and stamps `released_at`
- Total slot count = `Aiur.Config.max_vertical_panes() * 2 - 1`

**Patterns to follow:**
- `Aiur.Opencode.SessionSupervisor` (existing DynamicSupervisor)

**Test scenarios:**
- Happy path: start 3 slots; `acquire_slot` returns one in `:ready`; subsequent calls return the others; 4th call returns `{:error, :no_ready_slot}` (only 3 exist).
- LRU: `acquire → release` cycle preserves least-recently-released-first ordering.
- Concurrent: two callers `acquire_slot` simultaneously → never get the same slot.
- Slot crash: a slot worker dies; supervisor restarts it (`:transient`); SlotRegistry reflects the new pid.

**Verification:** Test suite green; `Aiur.Opencode.SlotSupervisor.acquire_slot/0` succeeds in manual smoke after slots reach `:ready`.

---

- [ ] U6. **`Aiur.Opencode.SlotPolicy` — chain pre-warm orchestrator**

**Goal:** Listens for `:slot_ready` broadcasts on `Aiur.PubSub` topic `"opencode:slots"`. When slot N becomes ready, asks SlotSupervisor to start slot N+1. Stops at `slot_count`. At boot, starts slot 1.

**Requirements:** R6.1, R6.2, R6.3

**Dependencies:** U4, U5

**Files:**
- Create: `elixir/lib/aiur/opencode/slot_policy.ex`
- Modify: `elixir/lib/aiur/opencode/prewarm_supervisor.ex` (add as child after SlotSupervisor)
- Test: `elixir/test/aiur/opencode/slot_policy_test.exs`

**Approach:**
- GenServer that on `init` calls `SlotSupervisor.start_slot(1)` and subscribes to `Aiur.PubSub` topic `"opencode:slots"`
- `handle_info({:slot_ready, n}, state)`:
  - If `n < slot_count`: `SlotSupervisor.start_slot(n + 1)`, log `opencode_slot_policy phase=chain_advance slot=#{n+1}`
  - If `n >= slot_count`: log `opencode_slot_policy phase=chain_complete`, no-op
- Idempotent: receiving `:slot_ready` for the same N twice does not start N+1 twice

**Test scenarios:**
- Covers AE7, AE8. Happy path: start policy with `slot_count=3`; broadcast `{:slot_ready, 1}` → policy calls `start_slot(2)`; broadcast `{:slot_ready, 2}` → `start_slot(3)`; broadcast `{:slot_ready, 3}` → no further calls.
- Boot: policy `init` triggers `start_slot(1)` exactly once.
- Idempotence: duplicate `{:slot_ready, 1}` → policy does not call `start_slot(2)` twice.

**Verification:** Test suite green; manual smoke: log shows `opencode_slot phase=ready slot=1, 2, 3, …` in chronological order (not all simultaneously at boot).

---

- [ ] U7. **`Aiur.PaneManager` — collapse to thin allocator**

**Goal:** Replace open/close orchestration with calls into `Slot.select` / `Slot.deselect` plus tmux moves. Delete all per-agent registry chatter.

**Requirements:** R1.3, R1.4, R5.1, R5.2

**Dependencies:** U4, U5

**Files:**
- Modify: `elixir/lib/aiur/pane_manager.ex` (rewrite open/close handlers)
- Delete: any reference to `PersistentPane`, `SessionWriterRegistry.update_pane`, `AttachQueue` callbacks
- Test: `elixir/test/aiur/pane_manager_test.exs` (update existing tests)

**Approach:**
- `open(identifier)`:
  1. If identifier already visible: re-focus that pane (idempotent open)
  2. `SlotSupervisor.acquire_slot/0` → `{slot_index, slot_pid}`
     - If `{:error, :no_ready_slot}` (chain pre-warm hasn't reached a free slot yet): fall back to the legacy `PaneSession.start/2` cold-attach path INSIDE PaneManager (existing behavior at `pane_manager.ex:497-536`). The caller never sees an error. The cold-attach path stays available for this race window AND for the case where slot count is exceeded by visible-pane requests.
  3. `Slot.select(slot_pid, identifier)` → `{:ok, pane_id}`
  4. `Tmux.move_pane_visible(pane_id, window_target)`
  5. Apply layout
- `close(identifier)`:
  1. Find the slot showing this identifier in PaneManager's state
  2. `Tmux.move_pane_hidden(pane_id, hidden_window)`
  3. `Slot.deselect(slot_pid)`
  4. `SlotSupervisor.release_slot(slot_index)`
- Drop `cycle_index`, `slot_panes` round-robin, identifier-to-pane mapping (replaced by slot-keyed Registry).
- Keep: window_target resolution, layout reflow, the cold-attach fallback escape hatch.
- `Aiur.AgentList.App` callers (e.g. `app.ex:174`) still call `_ = PaneManager.open_conversation(…)`; they do not need to learn the slot model or handle a new error class. PaneManager hides the slot-vs-cold decision entirely.

**Execution note:** Characterization tests first — capture current behavior (especially the close-from-opencode `:pane_died` path) before rewriting, so we don't regress edge cases.

**Patterns to follow:**
- Existing `apply_layout/1` helper.

**Test scenarios:**
- Covers AE2, AE4. Open "issue-5" → returns `{:ok, pane_id}`; slot 1 now in `:active("issue-5")`; pane visible.
- Close "issue-5" → pane hidden; slot 1 back to `:ready`; SlotSupervisor sees slot 1 as available.
- Open again (same id): re-acquire slot (may not be slot 1 if LRU picked another), select, show; same SessionWriter still running.
- Edge case (cold fallback): open "issue-7" when `SlotSupervisor.acquire_slot/0` returns `{:error, :no_ready_slot}` → PaneManager falls back to `PaneSession.start/2` cold path internally; caller still gets `{:ok, pane_id}`. No error escapes.
- Edge case: opencode pane dies (`:tmux_event :pane_died`) → forget that slot's pane state; slot goes to `:failed`; SlotPolicy detects and restarts the slot.

**Verification:** Existing `pane_manager_test.exs` cases pass; manual smoke: open, close, reopen all complete in <100 ms after slot is ready.

---

- [ ] U8. **AgentList visible-sessions tracking + circle indicator rerender**

**Goal:** Replace `open_pane_ids` (set of identifiers that have ever opened a pane) with `visible_sessions` (map slot_index → identifier). Re-render circle on `{:slot_session_changed, slot_index, identifier}`.

**Requirements:** R3.1, R3.2, R3.3, R3.4

**Dependencies:** U4 (Slot broadcasts the event)

**Files:**
- Modify: `elixir/lib/aiur/agent_list/app.ex` (replace open_pane_ids handling)
- Modify: `elixir/lib/aiur/agent_list/renderer.ex` (circle predicate)
- Test: `elixir/test/aiur/agent_list/app_test.exs`

**Approach:**
- App subscribes to `Aiur.PubSub` topic `"opencode:slots"` at init
- On `handle_info({:slot_session_changed, slot_index, identifier_or_nil}, state)`:
  - Update `state.visible_sessions = Map.put(state.visible_sessions, slot_index, identifier_or_nil)` (nil clears the entry)
  - Re-render
- Renderer's `open_pane_marker/2` becomes `visible_session_marker/2`:
  - Returns `●` if `identifier ∈ MapSet.new(Map.values(visible_sessions))`
  - Returns spaces otherwise
- Delete `open_pane_ids` field and `initial_open_pane_ids/1` helper

**Test scenarios:**
- Covers AE5. Receive `{:slot_session_changed, 1, "issue-5"}` → circle shows for issue-5.
- Receive `{:slot_session_changed, 1, "issue-7"}` (Ctrl+P switch) → circle moves from issue-5 to issue-7.
- Receive `{:slot_session_changed, 1, nil}` (close) → circle disappears from issue-7.
- Multiple slots: `{:slot_session_changed, 1, "issue-5"}` + `{:slot_session_changed, 2, "issue-7"}` → both circles visible.

**Verification:** Test suite green; manual smoke: open agent #5, press Ctrl+P inside opencode and switch to agent #7 — circle moves within ~1 s.

---

- [ ] U9. **Delete obsolete modules + migrate WarmServer's GC + drop PersistentPane + restructure PrewarmSupervisor**

**Goal:** Remove every artifact of the per-agent attach model AND move the lifecycle pieces that lived inside `WarmServer` to their new homes. One consolidated commit so the supervisor tree never has a "broken middle state" where GC vanished but `_placeholder` exclusion was already removed.

**Requirements:** R2.2, R7.1–R7.5; also resolves origin Q4 (`_placeholder` GC exclusion)

**Dependencies:** U4–U8 wired and passing tests first (don't delete until replacement is proven). U2 must be merged so token rotation is gone.

**Files:**
- Delete: `elixir/lib/aiur/opencode/attach_queue.ex` + `elixir/test/aiur/opencode/attach_queue_test.exs`
- Delete: `elixir/lib/aiur/opencode/agent_attach.ex` + any matching test
- Delete: `elixir/lib/aiur/opencode/warm_server.ex` (its GC code migrates — see Approach)
- Create: `elixir/lib/aiur/opencode/session_gc.ex` (new home for boot-time GC, formerly inside WarmServer)
- Modify: `elixir/lib/aiur/opencode/hidden_window.ex` (replace the `:warm_server_ready` PubSub trigger — see Approach)
- Modify: `elixir/lib/aiur/opencode/session_writer.ex` (replace `PersistentPane`-typed Registry value with a simple `%{session_id: String.t()}` map; remove `update_pane/2` GenServer call which is no longer needed)
- Modify: `elixir/lib/aiur/opencode/session_writer_registry.ex` (Registry value type, `all/0`, `delete_all/1`, `get_pane/1` shape; drop `regenerate_workspace_config/2`)
- Modify: `elixir/lib/aiur/opencode/persistent_pane.ex` → DELETE the file once `session_writer.ex` no longer references the struct (verify with grep first)
- Modify: `elixir/lib/aiur/opencode/prewarm_supervisor.ex` — final children list:
  1. `Aiur.Opencode.HiddenWindow` (now triggered by application start, not `:warm_server_ready`)
  2. `{Registry, keys: :unique, name: Aiur.Opencode.SlotRegistry.Registry}`
  3. `Aiur.Opencode.SlotSupervisor`
  4. `Aiur.Opencode.SlotPolicy` (the policy launches the first `Slot`; first `Slot` triggers `SessionGC` once it's `:ready` and has a `base_url`)
- Modify: `elixir/lib/aiur/shutdown.ex` (docstring referenced `WarmServer.terminate/2` — update to `Slot.terminate/2`)
- Modify: `elixir/lib/aiur.ex` (remove any direct references)
- Test: `elixir/test/aiur/opencode/session_gc_test.exs` (new; covers `_placeholder` deletion AND active-identifier preservation)

**Approach:**
1. **Migrate boot-time GC out of `WarmServer`** BEFORE deleting it. The current `warm_server.ex:139-180` houses `gc_leftover_sessions/1` and `aiur_orphan?/2`. Lift these into `Aiur.Opencode.SessionGC` as a `run/1` function. The new home is called by the first `Slot` once it has its `base_url` (the slot's own opencode-serve is the GC's HTTP target). Drop the `title != @placeholder_title` exclusion in `aiur_orphan?/2` — the slot model never creates a `_placeholder` session, so any session with that title is leftover from a crashed prior run and SHOULD be GC'd. Use `Aiur.Orchestrator.list_active_identifiers/0` as the active-set source (matches the existing implementation at `warm_server.ex:140`; do NOT switch to `Aiur.AgentDirectory.list_agents/0` — they may diverge).
2. **HiddenWindow trigger change.** Today `hidden_window.ex:6` (and its `handle_info({:warm_server_ready, …}, …)` clause) waits for WarmServer's broadcast before creating the hidden tmux window. After WarmServer is gone, no such event fires. Change HiddenWindow's startup to act on `init/1` directly (it doesn't need a warm-server URL — it just needs tmux to exist). The Slot worker explicitly waits on `HiddenWindow.ensure/0` before its first `split_pane` so the window is available.
3. **Replace `PersistentPane` Registry value.** SessionWriter currently registers `%PersistentPane{}` (see `session_writer.ex:23,40-46,78,131`). Switch the value to a plain `%{session_id: String.t()}` map (or just the bare session id, matching the pre-`PersistentPane` shape). Adjust `SessionWriterRegistry.lookup/1`, `all/0`, `delete_all/1`, and `get_pane/1` to the new shape. The "current pane_id" used to live on this struct; it now lives in `Slot.State` instead. Confirm no other callers of `PersistentPane` exist via `grep -rn PersistentPane elixir/`.
4. **Verify cleanup completeness.** After steps 1-3:
   - `grep -r "AttachQueue\|AgentAttach\|WarmServer\|regenerate_workspace_config\|PersistentPane" elixir/` returns ZERO matches (the prior search had 76 occurrences).
   - `mix compile --warnings-as-errors` passes.
   - Full `mix test` suite passes.

**Test scenarios:**
- Covers AE6 (R2.2). Pre-seed opencode SQLite with a session titled `_placeholder` and `model.providerID == "aiur"`. Run `Aiur.Opencode.SessionGC.run(base_url)`. Assert that session is deleted; assert any session whose title matches an entry in `Aiur.Orchestrator.list_active_identifiers/0` is preserved; assert sessions with `model.providerID != "aiur"` are untouched.
- Pre-seed: session titled `issue-99` (no longer active) with `providerID=aiur` → deleted.
- Pre-seed: session titled `issue-5` (in active set) → preserved.
- Pre-seed: session with `providerID=anthropic` → preserved.
- Test expectation for the bulk deletion: only "compile clean + full suite green + the SessionGC scenarios above". Module removals are structural.

**Verification:**
- `grep -r "AttachQueue\|AgentAttach\|WarmServer\|regenerate_workspace_config\|PersistentPane" elixir/` returns zero matches
- `git diff --shortstat HEAD~1..HEAD -- elixir/lib/aiur/opencode/ elixir/lib/aiur/pane_manager.ex` shows net-negative lines (T7 in origin)
- Full suite green
- Manual smoke: launch aiur from a state with `_placeholder` sessions on disk; `opencode session list` shows zero `_placeholder` titles after boot

---

- [ ] U10. **Probe + implement active-session polling in `Slot` (absorbs former U1)**

**Goal:** Detect Ctrl+P-initiated session changes within an opencode pane and broadcast them. Pick the polling mechanism by probing opencode 1.15.6 first; commit to a fallback if no native endpoint exists.

**Requirements:** R3.2; AE5

**Dependencies:** U4 (Slot baseline). Can be implemented LAST in the unit chain — every other AE works without it. R3.2 / AE5 is the only one that needs polling.

**Files:**
- Modify: `elixir/lib/aiur/opencode/slot.ex` (add poll loop)
- Modify: `elixir/lib/aiur/opencode/api_client.ex` (new helper if endpoint exists)
- Modify: `elixir/lib/aiur/opencode/workspace_setup.ex` (write a custom Ctrl+P binding into opencode.json IF probe fails — fallback path only)
- Modify: `elixir/docs/notes/opencode-row-shapes-1.15.6.md` (append a one-paragraph note documenting the chosen mechanism)
- Test: `elixir/test/aiur/opencode/slot_test.exs` (extend with polling scenario)

**Approach:**
1. **Probe step (former U1, run before writing the poll loop):** Launch a throwaway `opencode serve` against a sample workspace and probe `GET /tui/control/status`, `GET /session/<id>`, and `GET /session` listing for any field that reveals "the session id the attached TUI is currently displaying". Document findings in the notes file. Probe must produce a binary decision: native endpoint exists → use that single GET; native endpoint absent → drop to fallback.
2. **Native-endpoint path (preferred):** Add a small `ApiClient.active_session_id/1` helper. When Slot transitions to `:active(identifier)`, send `Process.send_after(self(), :poll_session, 500)`. In the handler: compare endpoint result against state's `active_identifier`; on change, broadcast `{:slot_session_changed, slot_index, new_identifier}`.
3. **Fallback path (only if probe finds nothing):** Inject a custom Ctrl+P keybinding into each slot's `opencode.json` that POSTs the new session id back to aiur's bridge via a hidden helper endpoint. Implementation cost is higher; only take this branch if the probe confirms there is no read-only "current session" endpoint.
4. When Slot transitions back to `:ready`: stop polling (poll handler returns without rescheduling if state isn't `:active`).
5. Configurable interval via app config (default 500 ms). Run the HTTP call inside a `Task` so a slow opencode response can't block the Slot GenServer mailbox.

**Note:** Aiur-initiated session changes (via `Slot.select`) already broadcast `:slot_session_changed` directly inside U4. The polling in this unit covers ONLY the externally-initiated Ctrl+P case. AE5 is the only AE that needs U10 — every other AE passes with U2-U9 alone, so U10 can land last.

**Test scenarios:**
- Covers AE5. Polling sees a new session id → broadcasts new identifier.
- No change: polling sees same session id → no broadcast.
- Deselect mid-poll: state changes to `:ready`, polling handler observes and does not reschedule.
- Backpressure: opencode HTTP slow (1s) → poll interval respects the previous call returning before scheduling next.

**Verification:** Unit test passes; manual smoke: open agent #5, Ctrl+P, switch to agent #7 → agent list circle moves to #7 within ~1 s.

---

- [ ] U12. **Tests for current bugs (T1–T7 from origin)**

**Goal:** Each bug surfaced in the prior round becomes a regression test before it can recur.

**Requirements:** All

**Dependencies:** U2–U11

**Files:**
- Test: `elixir/test/aiur/opencode/regression_test.exs` (or split across existing files where appropriate)

**Approach:** Implement these explicit cases:

- T1 (R2.1): Drive aiur boot + slot pre-warm; assert `opencode session list` length equals `Aiur.AgentDirectory.list_agents/0` length.
- T2 (R2.2): After boot, assert no session has title matching `_warm|_placeholder|^Aiur _`.
- T3 (R3.2): Send a `{:slot_session_changed, 1, "issue-7"}` PubSub event; assert AgentList state's visible_sessions reflects within 1 s and re-renders with circle next to issue-7.
- T4 (R4.3): Materialize a slot, extract apiKey from its `opencode.json`, POST `/v1/chat/completions` with that token to the bridge; assert 200 (not 401).
- T5 (R5.1): Open a pane after slot is `:ready`; assert wall-time ≤100 ms (log-line `aiur_pane_manager phase=open_visible open_ms=<N>` parsed in test).
- T6 (R6.3): Boot test fixture aiur; assert log shows `opencode_slot phase=ready slot=1` BEFORE `opencode_slot phase=ready slot=2`.
- T7 (R7.5): `git diff --shortstat <base>..HEAD -- elixir/lib/aiur/opencode/ elixir/lib/aiur/pane_manager.ex` shows more deletions than insertions.

**Verification:** All seven assertions pass against the final code.

---

- [ ] U14. **End-to-end CLI verification (T1–T7 + AE1–AE9)**

**Goal:** Drive `scripts/aiur` end-to-end and verify every acceptance example.

**Requirements:** All

**Dependencies:** U2–U13

**Files:** none (verification only). Optionally extend `scripts/verify-u11.sh` or write `scripts/verify-slot-bound.sh`.

**Approach:**
- Use the verification recipe from `handoff.md` (driving-tmux session + capture-pane + log greps)
- Walk each AE:
  - AE1 boot interactive within 1 s — agent_list renders before slot pre-warm completes
  - AE2/AE3/AE4 open + reopen + slot 2 open all ≤100 ms — measured via phase logs
  - AE5 Ctrl+P inside opencode — circle moves in agent list within 1 s
  - AE6 no duplicate or `_placeholder` sessions — `opencode session list | grep _placeholder` empty; counts match agent count
  - AE7 fill all slots — every open ≤100 ms; final count = `slot_count`
  - AE8 zero agents at boot — slot 1 starts but is idle; no session creates
  - AE9 chat with an agent — no `unauthorized` 401 in log
- Document each pass with quoted log evidence in a verification report at `elixir/docs/notes/2026-05-21-slot-bound-verification.md`

**Verification:** All 9 acceptance examples PASS with cited evidence.

---

## System-Wide Impact

- **Interaction graph:** AgentList ← `:slot_session_changed` PubSub ← Slot polling. PaneManager → SlotSupervisor.acquire/release → Slot.select/deselect → Tmux. SessionWriter (unchanged) reads/writes shared SQLite, all slots see the same session state.
- **Error propagation:** Slot crash → DynamicSupervisor restart → SlotPolicy may need to re-trigger pre-warm for the restarted slot. PaneManager.open on a crashed slot returns `{:error, :no_ready_slot}` and AgentList displays a brief error.
- **State lifecycle risks:** Tokens get rotated on slot serve restart; existing pane apiKeys must be invalidated via `TokenRegistry.delete_for_slot(N)` before the new token is registered, else the bridge would accept a stale token briefly.
- **API surface parity:** External: none. Bridge `/v1/chat/completions` request shape unchanged. Internal: PaneManager.open signature unchanged.
- **Integration coverage:** The Slot's poll-and-broadcast loop crosses three layers (HTTP poll → state update → PubSub broadcast → AgentList render). Cover with an integration test that uses a mock opencode HTTP response and asserts the chain.
- **Unchanged invariants:** SessionWriter per-agent semantics, IssueLog, `Aiur.Orchestrator`, bridge route paths, opencode SQLite schema.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| The chosen "active session" polling endpoint (U10's probe) returns slowly under load, blocking the Slot GenServer mailbox | Run poll inside a `Task` so a slow opencode response cannot block the Slot. Default 500 ms interval is configurable. |
| Mid-run agent additions cannot reach a warmed slot because opencode-serve doesn't reload `opencode.json` | Documented as deferred (origin R6.4 in the Deferred-to-Follow-Up Work block). Cold-attach path via `PaneSession` (kept as fallback inside PaneManager) still works for any new agent the user opens. |
| Slot pre-warm chain stops because slot N never reaches `:ready` (opencode-serve crash, tmux failure) | SlotPolicy logs the gap (`phase=chain_stalled slot=N`); operator can `aiur stop && aiur` to recover. Restart logic per-slot is built in via DynamicSupervisor. |
| Workspace dir overflow if max_vertical_panes is large | Slot workspace dirs are bounded (small JSON + theme files). Even at slot_count=15 this is trivial. |
| Token simplification breaks an edge case where the bridge differentiated agents via token | The bridge already routes by model name in the request body (`identifier_from_model/1`). Token-only validity does not lose information — covered by existing bridge tests after U2's rewrite. |
| Slot polling overhead with `slot_count=5` panes visible: 10 HTTP calls/sec | Negligible (loopback HTTP). Logged at `:debug`. |
| Active session detection probe (U10) discovers there's NO reliable endpoint and we must implement a workaround | U10's Approach commits to the fallback path (custom Ctrl+P binding in slot's `opencode.json` that POSTs to aiur). The fallback is sized in U10's file list. |
| **Bridge token cleanup ordering** — chat-completion requests arriving during a slot serve restart get 401 if old token is revoked before new attach is loaded | **Fully addressed** by U2's generation counter design. Strict overlap order (bump gen → put new token → start serve → confirm attach ready → sweep stale gens) guarantees no empty-registry window. Tested in U2 scenarios. |
| HiddenWindow startup no longer has a warm-server-ready trigger after U9 deletes WarmServer | U9 explicitly rewires HiddenWindow to act on `init/1` directly (it only needs tmux, not opencode). Documented in U9 Approach step 2. |
| Active-set source disagreement: U9's GC uses `Aiur.Orchestrator.list_active_identifiers/0` while other code paths might call `Aiur.AgentDirectory.list_agents/0` | U9 explicitly mandates `list_active_identifiers/0` (matches existing implementation at `warm_server.ex:140`). Implementer should not silently swap APIs. |

---

## Documentation / Operational Notes

- Update `handoff.md` once the slot model lands — most of the prior handoff becomes obsolete.
- Run `/ce-compound` after landing to capture the "agents-vs-slots binding" lesson; this is the second iteration on opencode lifecycle and the wrong-binding lesson deserves a durable learning doc.
- End-of-pipeline `/ce-code-review` per the user's request — focus areas: total LOC delta, dead code removal, slot state machine clarity, polling-loop simplicity.

---

## Sources & References

- **Origin document:** [elixir/docs/brainstorms/2026-05-21-slot-bound-opencode-instances-requirements.md](elixir/docs/brainstorms/2026-05-21-slot-bound-opencode-instances-requirements.md)
- Prior plan (the model this supersedes): `elixir/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md`
- Earlier substrate plan: `elixir/docs/plans/2026-05-20-001-feat-opencode-prewarm-and-history-injection-plan.md`
- opencode 1.15.6 schema notes: `elixir/docs/notes/opencode-row-shapes-1.15.6.md`
- Prior handoff for the previous round's state: `handoff.md`
