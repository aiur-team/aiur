---
title: refactor: Queue pane opens, on-demand slot models, fix pane title
type: refactor
status: active
date: 2026-05-21
origin: elixir/docs/brainstorms/2026-05-21-pane-attach-queue-and-on-demand-models-requirements.md
---

# refactor: Queue pane opens, on-demand slot models, fix pane title

## Overview

Three bugs surfaced in live use of the slot-bound opencode work (`elixir/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md`) plus one model simplification. This plan fixes the pane title leak, eliminates the pre-warm race by queueing opens instead of falling back to cold-attach, and drops the "every slot knows every agent" seeding so slots grow their models map only when the user actually attaches an agent. A new `a` keybind in the agent list adds explicit "attach to focused pane" so multi-agent panes are a deliberate user choice, not an accident of background seeding.

Expected net diff is **negative**: deletes `Aiur.Opencode.PaneSession` (the legacy cold-attach module), the cold-attach branch in `PaneManager`, the orchestrator-wait in `Slot.handle_continue(:start_serve)`, and the full-list seeding in `WorkspaceSetup.materialize_slot/5`. Adds a small FIFO open queue in PaneManager and one new keybind path.

---

## Problem Frame

Live use surfaced three concrete bugs and one model issue (origin: `elixir/docs/brainstorms/2026-05-21-pane-attach-queue-and-on-demand-models-requirements.md`):

1. **Title bug.** Every chat pane chrome renders `Build · Aiur · Aiur`. Cause: `elixir/lib/aiur/opencode/protocol.ex:86` declares every model with `name: "Aiur"`, AND the provider's own `name` is also `"Aiur"` (line 93). opencode renders `<provider.name> · <model.name>`, producing the collision.

2. **Pre-warm race.** Opening agents faster than chain pre-warm produces inconsistent results — first agent works, second silently fails to open, third lands in an unexpected tmux pane with no logs. Cause: `SlotSupervisor.acquire_slot/0` returns `{:error, :no_ready_slot}` whenever no slot is currently `:ready`; `PaneManager.open_opencode_pane/4` falls back to `PaneSession.start` (a parallel opencode-serve + tmux split path). The cold-attach branch's race semantics during chain pre-warm are buggy.

3. **Session-list bleed.** Opening a third agent shows ALL three sessions in that pane's Ctrl+P picker. Cause: every slot's `opencode.json` is seeded with every active agent identifier (`WorkspaceSetup.materialize_slot/5` passes `agent_identifiers = list_active_identifiers()`). Combined with the shared SQLite at `~/.local/share/opencode/opencode.db`, opencode sees every aiur agent as an available model in every slot.

The model simplification: slots start with an empty models map and grow only when the user explicitly attaches an agent (via `Enter` on agent list = new pane, or `a` = attach to focused pane). This deletes the wait-for-orchestrator boot delay and the full-list seeding entirely.

---

## Requirements Trace

- **R1.1** Pane chrome shows agent identifier (e.g. `issue-13`), not `Aiur`
- **R1.2** Provider name MAY stay `aiur`; model name MUST NOT
- **R2.1** `PaneManager.open` always replies meaningfully regardless of pre-warm timing
- **R2.2** Opens are queued FIFO when no slot is ready; dequeued on `:slot_ready`
- **R2.3** Legacy cold-attach path (`PaneSession`) is DELETED — single open path only
- **R2.4** Queued open times out (60 s) if pre-warm never produces a slot
- **R3.1** `materialize_slot` does NOT accept a "seed with all agents" argument
- **R3.2** Slot grows models map incrementally on identifier_miss — adds only the missing one
- **R3.3** `wait_for_active_identifiers/2` is DELETED; boot to interactive ≤ 4 s
- **R3.4** Existing Ctrl+P bleed across panes is OUT OF SCOPE (opencode-level concern)
- **R4.1** `a` keybind in agent list attaches selected agent to currently-focused pane
- **R4.2** With no focused pane, `a` falls through to `Enter` behavior (open in next slot)
- **R4.3** Previously-attached agent's SessionWriter stays alive; session persists in SQLite

**Origin actors:** A1 (developer), A2 (codex agent), A3 (opencode-serve), A4 (opencode-attach TUI)
**Origin flows:** F1 (queued first open), F2 (quick succession during boot), F3 (warm select, no rebuild), F4 (cold select with incremental rebuild), F5 (manual attach to focused pane)
**Origin acceptance examples:** AE1 (title), AE2 (race repro), AE3 (boot speed + empty models map), AE4 (single-identifier models map after select), AE5 (multi-identifier after manual attach), AE6 (attach keybind UX), AE7 (60 s timeout)

---

## Scope Boundaries

- Filtering opencode's Ctrl+P session picker (would require modifying opencode itself — not user-blocking)
- Per-slot SQLite isolation (would require opencode-serve flag we don't control)
- Auto-refresh of agent list during long pre-warm (already handled by the freeze fix's PubSub-cached poll state)
- Session sharing across slots (each agent's SessionWriter remains identifier-keyed globally — opening an already-visible agent re-focuses its existing pane, already implemented in `PaneManager.handle_call({:open, ...})` at line 173)
- Per-pane title customization beyond the identifier string (e.g. ticket title lookup) — defer until cheap lookup path emerges

---

## Context & Research

### Relevant Code and Patterns

- **`elixir/lib/aiur/opencode/protocol.ex:62-99`** — `opencode_json/1` builds the models map. Lines 80-86 set `name: "Aiur"` for every issue model; line 93 sets provider `name: "Aiur"`. R1 changes line 86 only.
- **`elixir/lib/aiur/opencode/workspace_setup.ex:55-110`** — `materialize_slot/5` accepts `agent_identifiers` list and passes through to `opencode_json/1` as `extra_identifiers`. R3.1 changes signature.
- **`elixir/lib/aiur/opencode/slot.ex:164-200`** — `handle_continue(:start_serve, state)` calls `wait_for_active_identifiers/2` (line ~310-345) before `materialize_slot`. R3.3 deletes the wait + the helper.
- **`elixir/lib/aiur/opencode/slot.ex:483-516`** — `schedule_serve_rebuild/2` is invoked on identifier_miss; currently rebuilds with full agent list via `wait_for_active_identifiers`. R3.2 changes it to track and rebuild with only the union of `state.known_identifiers ∪ {missing_identifier}`.
- **`elixir/lib/aiur/pane_manager.ex:340-401`** — `open_opencode_pane/4` falls back to `cold_attach/4` when no slot is `:ready`. R2.2/R2.3 replace with FIFO queue + dequeue-on-broadcast.
- **`elixir/lib/aiur/pane_manager.ex:404-449`** — `cold_attach/4` + `opencode_workspace_for/1` are the legacy escape hatch. R2.3 deletes them.
- **`elixir/lib/aiur/opencode/pane_session.ex`** — only caller is `pane_manager.ex:392`. Per `grep -rn PaneSession lib/`, the module becomes unreferenced after R2.3.
- **`elixir/lib/aiur/agent_list/input.ex:89-104`** — single-byte keybind dispatch table. `a` is currently unbound; R4.1 adds it.
- **`elixir/lib/aiur/agent_list/app.ex`** — public functions `select_previous/1`, `select_next/1`, `activate/1`, `toggle_pause/1`, etc. R4 adds `attach_selected/1` mirroring `activate/1`.

### Institutional Learnings

From prior plans:
- **OTP release build is required** (`mix release --overwrite`); escript can't load `:exqlite` NIFs. Don't regress.
- **`SlotPolicy.handle_info({:slot_ready, N}, ...)` is the canonical event for "a new slot just transitioned to `:ready`"** (lib/aiur/opencode/slot_policy.ex). PaneManager's open-queue subscribes to the same `Aiur.PubSub` topic `Aiur.Opencode.Slot.slots_topic()` and pattern-matches on the same tuple.
- **Generation-counter token overlap is load-bearing for slot serve restarts** (`elixir/lib/aiur/opencode/slot.ex`). The R3.2 incremental rebuild must keep the existing bump-then-sweep order — do not invent a parallel restart path.
- **Phoenix.PubSub broadcasts cannot reach a process that subscribed AFTER the broadcast fired.** The FIFO queue must drain on the SlotPolicy's NEXT `:slot_ready` broadcast — slots already ready before PaneManager started subscribing won't trigger a replay. PaneManager subscribes at init; relevant `:slot_ready` events fire LATER as the chain advances. Safe.
- **`safe_call` wraps GenServer.call in catch-all** but does NOT prevent the call from blocking the caller's mailbox. The freeze fix from the prior round explicitly removed sync orchestrator calls from the render path. R4.1 must follow the same discipline — `attach_selected` posts a message to PaneManager via cast or via call with a generous timeout, never blocks the render tick.

### External References

- None. All code is local; opencode 1.15.6 behavior is well-understood from prior probes.

---

## Key Technical Decisions

- **Pane title rendering.** Use literal agent identifier (e.g. `issue-13`) as the model name in `opencode.json`. Provider name stays `aiur` so opencode renders `aiur · issue-13` in the chat chrome. Rationale: no extra lookup path needed, identifier is what already flows through the slot model, matches the existing per-model key name in the models map.
- **Open queue lives in PaneManager state, not a separate GenServer.** The queue is at most `slot_count` deep, drained synchronously from `handle_info({:slot_ready, ...}, ...)`. A new GenServer is unjustified overhead.
- **Dequeue order: FIFO.** A `:queue` data structure (Erlang built-in) is the right shape — efficient push/pop, ordered. Latest-wins would surprise users who fire opens during boot.
- **Open queue subscription is permanent**, not just-in-time. PaneManager subscribes to `Aiur.Opencode.Slot.slots_topic()` at init; the queue may be empty most of the time but the subscription's overhead is one PubSub registration. No subscribe/unsubscribe churn.
- **`materialize_slot/5` signature changes** (drops the `agent_identifiers` positional param OR changes default to `[]`). The slot's `known_identifiers` MapSet seeds from `[]` at boot, not from the orchestrator's full list.
- **Incremental rebuild on identifier_miss** keeps a running `state.known_identifiers` MapSet. Rebuild computes `MapSet.put(known, missing_identifier)` and passes that as the new models map. No call to `list_active_identifiers/0` ever.
- **"Focused pane" definition for R4.1.** PaneManager tracks `last_attached_pane_id` — the pane id from the most recent successful `open_opencode_pane` or `attach_to_pane` call. Reset to `nil` on close. This is the implicit "I've been working in this pane" pointer. No tmux probe needed.
- **Attach behavior when no focused pane (R4.2).** `a` falls through to the same code path as `Enter` (open in next slot). Simpler than a refuse-with-message UX.
- **Timeout for queued opens (R2.4).** 60 s default. If the chain stalls indefinitely (e.g. opencode binary missing), the user gets `{:error, :no_ready_slot}` and the AgentList can render a transient error.
- **AgentList.attach_selected/1 dispatches to PaneManager.attach/2** via `GenServer.call` with a 65 s timeout (slightly above the queue timeout so the call sees the timeout's reply rather than its own).

---

## Open Questions

### Resolved During Planning

- **Title rendering format**: literal `issue-13` (no orchestrator title fetch).
- **Keybind**: `a` (verified free in `input.ex`).
- **"Focused pane" definition**: most-recently-opened/attached chat pane, tracked in `PaneManager.state.last_attached_pane_id`.
- **Queue overlap semantics**: FIFO. Hitting Enter on a different agent while one is queued enqueues alongside; both eventually open.
- **Empty models map at boot**: opencode 1.15.6 accepts an empty `provider.models` map per prior probes (warm server in the deleted WarmServer used a single `_warm` identifier). For safety the slot keeps its `_slot-N` sentinel identifier in the models map at boot, so the map is never literally empty.

### Deferred to Implementation

- Exact log line for `phase=open_queued`: implementer chooses format; must include `identifier=` and `queue_depth=`.
- Whether `Slot.snapshot/1` needs to expose `known_identifiers` for diagnostics (probably yes for `aiur` debug commands, but no caller in this plan requires it).
- Whether to fold the `_slot-N` sentinel out of the models map entirely if opencode tolerates an empty map (probe with a one-line API call during U2; if accepted, drop the sentinel).

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

### PaneManager open path with FIFO queue

```
PaneManager.handle_call({:open, identifier, _cmd, _opts}, from, state)
   │
   ├── already visible? (identifier_to_pane has identifier)
   │     → refocus existing pane, {:reply, {:ok, pane_id}, state}
   │
   └── try acquire_slot
        │
        ├── {slot_index, slot_pid}
        │     → Slot.select + move_pane_visible + record_slot_pane
        │     → {:reply, {:ok, pane_id}, state with last_attached_pane_id}
        │
        └── {:error, :no_ready_slot}
              → enqueue {identifier, from, timer_ref}, log phase=open_queued
              → {:noreply, state}  (caller blocks on GenServer.call)

PaneManager.handle_info({:slot_ready, _index}, state)
   │
   └── drain queue head:
         loop:
           if queue empty: stop
           pop {identifier, from, timer_ref}
           cancel timer
           try acquire_slot
             ok      → Slot.select + reply + record; advance loop
             error   → re-enqueue at head; stop (next :slot_ready will retry)

PaneManager.handle_info({:open_queue_timeout, identifier}, state)
   │
   └── find entry by identifier; if still queued, drop + GenServer.reply(from, {:error, :no_ready_slot})
```

### Slot identifier_miss with incremental rebuild

```
Slot.handle_call({:select, identifier}, from, state)
   │
   ├── identifier ∈ state.known_identifiers
   │     → do_select, broadcast :slot_session_changed, schedule_poll, reply
   │
   └── identifier ∉ state.known_identifiers
         │
         ├── compute new_known = MapSet.put(state.known_identifiers, identifier)
         ├── store pending_select = {from, identifier}
         ├── stop opencode-serve, delete token, bump generation
         ├── send self() :rebuild_now
         └── {:noreply, state with status=:booting, known_identifiers=new_known}

Slot.handle_info(:rebuild_now, state)
   │
   └── {:noreply, state, {:continue, :start_serve}}

Slot.handle_continue(:start_serve, state)
   │
   └── materialize_slot(workspace, bridge_url, MapSet.to_list(state.known_identifiers), slot_index, generation)
       → start serve → spawn attach → drain_pending_select → reply
```

Key difference from current code: `materialize_slot` is called with `MapSet.to_list(state.known_identifiers)` — never with `list_active_identifiers/0`. The set only grows when select fires for a missing identifier.

---

## Implementation Units

- [ ] U1. **Title fix: model name uses agent identifier**

**Goal:** Stop opencode chat chrome from rendering `Build · Aiur · Aiur`. Replace the hardcoded model name with the agent identifier so the chrome reads `Build · issue-13 · 100ms` (or equivalent showing the identifier).

**Requirements:** R1.1, R1.2; AE1.

**Dependencies:** None.

**Files:**
- Modify: `elixir/lib/aiur/opencode/protocol.ex` (line 86 — the `Map.new(all_ids, fn id -> {"issue-#{id}", %{"name" => "Aiur"}} end)` literal)
- Test: `elixir/test/aiur/opencode/protocol_test.exs` (existing — add or extend a test for the model name field)

**Approach:**
- Change `name: "Aiur"` to `name: "issue-#{id}"` in the models map literal at line 86 of `protocol.ex`. The model KEY (`"issue-#{id}"`) and model NAME now match.
- Provider name (`name: "Aiur"` at line 93) stays — the provider rendering is the `aiur` prefix in the chrome, which is correct and not the bug.
- No bridge change required — bridge routes by `identifier_from_model/1` on the request body's `model` field, which is unaffected.

**Patterns to follow:**
- The existing `opencode_json/1` function shape; just change the inner literal.

**Test scenarios:**
- Covers AE1. Happy path: `Protocol.opencode_json(%{bridge_url: "http://x", bridge_token: "t", identifier: "_slot-1", model_prefix: "aiur", opencode_os_pid: nil, extra_identifiers: ["13"]})` → the `models["issue-13"]` map has `name: "issue-13"`, not `name: "Aiur"`.
- Edge case: empty `extra_identifiers` → only the slot's sentinel identifier in the models map, named after itself.

**Verification:**
- Test passes. Manual: opening any agent in aiur after this lands shows `Build · issue-N · …` in the chat chrome.

---

- [ ] U2. **Drop full-list seeding + orchestrator wait**

**Goal:** Slot 1 boots in ~3 s with an empty models map (just the `_slot-1` sentinel). No call to `list_active_identifiers/0` during slot startup.

**Requirements:** R3.1, R3.3; AE3.

**Dependencies:** None.

**Files:**
- Modify: `elixir/lib/aiur/opencode/workspace_setup.ex` (signature of `materialize_slot/5` — drop the `agent_identifiers` positional param or default it to `[]`)
- Modify: `elixir/lib/aiur/opencode/slot.ex` (delete `wait_for_active_identifiers/2` helper, delete the call from `handle_continue(:start_serve, state)`, change the call site to pass `[]` for agent_identifiers, and seed `state.known_identifiers` from `MapSet.new()`)
- Test: `elixir/test/aiur/opencode/workspace_setup_test.exs` (add or extend — if no test exists, create with a single round-trip on the materialize output)
- Test: `elixir/test/aiur/opencode/slot_test.exs` (update the boot-state-machine smoke test if it asserts on the wait)

**Approach:**
- Change `materialize_slot(workspace, bridge_url, agent_identifiers, slot_index, generation)` to either: (a) `materialize_slot(workspace, bridge_url, slot_index, generation)` and have the caller pass `extra_identifiers = []` to `opencode_json`, OR (b) keep the 5-arity but always have `Slot` pass `[]` for that arg. Choose (a) if the caller graph allows; (b) is fine if not.
- Delete `Slot.wait_for_active_identifiers/2` (private helper).
- Delete the `phase=agents_ready` log emission (or keep with `agent_count=0` — it's no longer informative, prefer delete).
- Replace `state.known_identifiers = MapSet.new()` at init (already true via struct default; verify it's not overridden).
- Slot boot timing: `phase=init → materialize_slot (empty models) → start serve → await_ready → spawn_attach → phase=ready`. No wait step. Target: boot-to-`phase=ready slot=1` ≤ 4 s.

**Patterns to follow:**
- Existing `Slot.handle_continue(:start_serve, ...)` body; surgical edit.

**Test scenarios:**
- Covers AE3. Happy path: launch aiur; slot 1 reaches `phase=ready` in elapsed_ms ≤ 4000 (was ~13000 with the wait).
- Edge case: aiur with zero active agents — slot 1 still boots in same window; no behavioral difference.
- Inspect `~/.local/share/aiur/opencode-slot-1/opencode.json` immediately after slot 1 `phase=ready` and BEFORE any user open: the `provider.aiur.models` map has exactly one key (`issue-_slot-1`), no `issue-N` keys for any agent identifier.

**Verification:**
- Slot 1 `phase=ready` log line shows `elapsed_ms ≤ 4000`. `opencode.json` inspection shows no agent identifiers seeded.

---

- [ ] U3. **Incremental rebuild on identifier_miss**

**Goal:** When `Slot.select/2` is called for an identifier not in the slot's `known_identifiers`, the rebuild adds JUST that one identifier (not the full orchestrator list).

**Requirements:** R3.2; AE4.

**Dependencies:** U2.

**Files:**
- Modify: `elixir/lib/aiur/opencode/slot.ex` — `schedule_serve_rebuild/2` no longer resets `known_identifiers` to `MapSet.new()`; instead it computes the new set as `MapSet.put(state.known_identifiers, missing_identifier)` before stopping the serve. `handle_continue(:start_serve, state)` passes `MapSet.to_list(state.known_identifiers)` to `materialize_slot`.
- Test: `elixir/test/aiur/opencode/slot_test.exs` (extend with a known_identifiers tracking scenario)

**Approach:**
- `schedule_serve_rebuild(state, {from, identifier})` modifies the state transition: replace `known_identifiers: MapSet.new()` with `known_identifiers: MapSet.put(state.known_identifiers, identifier)`. This is the only behavior change in this unit.
- `handle_continue(:start_serve, state)` builds `agent_ids = MapSet.to_list(state.known_identifiers)` instead of calling `wait_for_active_identifiers`. After U2 this is already the case for boot; this unit ensures it also holds for rebuild.
- After a single rebuild for identifier "issue-13", `state.known_identifiers = MapSet.new(["issue-13"])`. A second rebuild for "issue-7" produces `MapSet.new(["issue-13", "issue-7"])`. The accumulation is what makes R4 (manual attach) work without restarting again for previously-attached agents.

**Patterns to follow:**
- Existing `schedule_serve_rebuild/2` — surgical edits only.

**Test scenarios:**
- Covers AE4. Happy path: spawn a Slot at index 1; call `Slot.select(pid, "issue-13")` (triggers rebuild). After rebuild, inspect the slot's `opencode.json` — `provider.aiur.models` has exactly `["issue-_slot-1", "issue-13"]`, no other identifiers.
- Edge case: call `Slot.select(pid, "issue-13")` twice in a row → first triggers rebuild; second is warm (no rebuild). Verify via timestamps in the log.
- Edge case: call `Slot.select(pid, "issue-13")`, then `Slot.select(pid, "issue-7")` → two sequential rebuilds; final models map has both identifiers; no other agents.

**Verification:**
- After each select for a new identifier, `opencode.json` contains exactly the union of selected identifiers + the sentinel — never the full orchestrator list.

---

- [ ] U4. **PaneManager FIFO open queue + cold-attach branch removed**

**Goal:** PaneManager always replies meaningfully to `open` even when no slot is ready, by queueing the intent and draining on `:slot_ready` broadcasts. Cold-attach is gone.

**Requirements:** R2.1, R2.2, R2.3, R2.4; AE2, AE7.

**Dependencies:** U2 (boot speed makes queue depth bounded), U3 (incremental rebuild is the warm-path after a queue drain).

**Execution note:** Characterization-first. Capture today's open behavior (specifically the cold-attach fallback's tmux-pane-landing locations and SessionWriter side-effects) in a regression-style test before the rewrite, so the new path can be compared against it.

**Files:**
- Modify: `elixir/lib/aiur/pane_manager.ex`:
  - Add `open_queue: :queue.new()` and `open_queue_timers: %{}` (identifier → timer ref) and `last_attached_pane_id: nil` to the struct.
  - In `init/1`, subscribe to `Aiur.Opencode.Slot.slots_topic()` via `Phoenix.PubSub.subscribe/2`.
  - Rewrite `open_opencode_pane/4`: try acquire_slot → on `{slot_index, slot_pid}` proceed as today; on `{:error, :no_ready_slot}` enqueue + start a 60s timer + return `{:noreply, ...}` (caller blocks).
  - Add `handle_info({:slot_ready, _index}, state)` — drain queue head while a slot is ready; for each dequeued entry, run the same select+move_visible flow and `GenServer.reply(from, …)`. If acquire fails mid-drain (e.g. another open just took the slot), re-push the entry at the head and break the loop.
  - Add `handle_info({:open_queue_timeout, identifier}, state)` — if entry still queued, drop + reply with `{:error, :no_ready_slot}`.
  - Update successful open to record `state.last_attached_pane_id = pane_id` (for R4 in U6).
  - Delete `cold_attach/4` and `opencode_workspace_for/1`.
  - Delete the `_ = AttachQueue.cancel(identifier)` and `PaneSession`-related comments.
- Test: `elixir/test/aiur/pane_manager_test.exs` (add scenarios for queue-during-boot + 60 s timeout + drain ordering)

**Approach:**
- Queue uses `:queue` for O(1) head pop + tail push.
- Timer per queued entry via `Process.send_after(self(), {:open_queue_timeout, identifier}, 60_000)`. Cancel on dequeue.
- When the user opens the SAME identifier twice while queued, second open should refuse with `{:error, :already_queued}` OR coalesce — choose during implementation; default coalesce (return same eventual reply to both `from`s). If implementation finds coalesce hard to express cleanly, just refuse the duplicate.
- `handle_info({:slot_ready, _index}, state)` runs the drain loop synchronously inside the PaneManager mailbox. Drains 1 entry per `:slot_ready` broadcast in v1 — multi-drain optimization deferred until measured need.
- Cold-attach removal: line 392 `Aiur.Opencode.PaneSession.start(identifier, workspace)` and surrounding error handling block is gone. `cold_attach/4` private helper deleted entirely. `opencode_workspace_for/1` deleted if no other caller.

**Patterns to follow:**
- Existing `handle_info({:tmux_event, ...}, state)` shape for non-reply handlers.
- Existing `AgentPubSub.broadcast_status_change(identifier, :pane_opened)` after successful open — keep.

**Test scenarios:**
- Covers AE2. Happy path (race repro): subscribe to PubSub, broadcast 3 `:open` GenServer.calls in quick succession before any `:slot_ready`; broadcast `{:slot_ready, 1}` then `{:slot_ready, 2}` then `{:slot_ready, 3}`; assert all 3 calls receive `{:ok, pane_id}` in FIFO order.
- Edge case: open with no slot ready → after 60 s, `:open_queue_timeout` fires → caller gets `{:error, :no_ready_slot}`.
- Covers AE7. Force `Slot.select` to fail (mock); queued open eventually times out instead of hanging forever.
- Idempotence: opening already-visible identifier from `state.identifier_to_pane` → re-focus path, no queue interaction.
- Drain ordering: enqueue id_A then id_B; broadcast `{:slot_ready, 1}`; only id_A drains. Broadcast `{:slot_ready, 2}`; id_B drains. (Per the "1-per-broadcast" v1 simplification.)
- Log assertion: queued opens emit `aiur_pane_manager phase=open_queued identifier=<id> queue_depth=<N>` log lines.
- Integration: after this unit lands, `grep -rn PaneSession lib/` returns only the file itself (no callers). U5 then deletes the file.

**Verification:**
- Race repro AE2 passes with all 3 panes appearing in user-typed order. No pane appears in an unexpected window. Slot 1 acquires id_A; slot 2 acquires id_B; slot 3 acquires id_C. Log shows queue depth fluctuating up to 2.

---

- [ ] U5. **Delete `Aiur.Opencode.PaneSession`**

**Goal:** With U4's cold-attach branch removed, `PaneSession` is unreferenced. Delete the module + tests + workspace dir helper.

**Requirements:** R2.3 completion.

**Dependencies:** U4 (PaneSession is still referenced until U4 lands).

**Files:**
- Delete: `elixir/lib/aiur/opencode/pane_session.ex`
- Delete: `elixir/test/aiur/opencode/pane_session_test.exs` if it exists
- Modify: `elixir/lib/aiur/opencode/workspace_setup.ex` — drop the `# Legacy callers (WarmServer, PaneSession) ...` comment at line 113-115, and inline-or-remove the legacy `TokenRegistry.put(token, 0, 1)` call (since PaneSession was the last non-Slot caller of `materialize/5`)
- Modify: `elixir/lib/aiur/opencode/server.ex` — drop the comment at line 15 referencing "PaneSession's 30s budget"

**Approach:**
- `grep -rn "PaneSession\|pane_session" elixir/ test/` should return zero matches after this unit.
- `mix compile --warnings-as-errors` passes.
- Full test suite passes.

**Test scenarios:**
- Test expectation: none — pure deletion. The U4 test suite is the behavioral cover.

**Verification:**
- `grep` is clean, compile is clean, suite is green.

---

- [ ] U6. **Attach-to-focused-pane keybind**

**Goal:** Pressing `a` on a selected agent in the agent list attaches that agent to the currently-focused chat pane (slot rematerializes + reattaches), instead of opening a new pane.

**Requirements:** R4.1, R4.2, R4.3; AE6.

**Dependencies:** U3 (rebuild path is the slot-side implementation of "rematerialize with another identifier"), U4 (PaneManager state.last_attached_pane_id is populated by the queue/open path).

**Files:**
- Modify: `elixir/lib/aiur/agent_list/input.ex` — add `defp dispatch("a", target, _input_fun), do: App.attach_selected(target)` to the keybind table at line ~104.
- Modify: `elixir/lib/aiur/agent_list/app.ex` — add public `attach_selected/1` mirroring `activate/1`. Resolves the selected agent identifier; calls `PaneManager.attach(pane_manager, identifier)`. On `{:error, :no_focused_pane}` falls through to `activate/1` (per R4.2).
- Modify: `elixir/lib/aiur/pane_manager.ex` — add `attach(server, identifier)` API + `handle_call({:attach, identifier}, from, state)` clause. Looks up `state.last_attached_pane_id`. If nil → `{:reply, {:error, :no_focused_pane}, state}` (caller can fall through). Else finds the slot owning that pane (via `state.identifier_to_pane` reverse lookup or `SlotRegistry`), calls `Slot.select(slot_pid, identifier)` (which auto-rebuilds via U3), updates `state.identifier_to_pane` (removing the old identifier's mapping for that pane id, adding the new), `Tmux` move not needed since pane is already visible.
- Test: `elixir/test/aiur/pane_manager_test.exs` (attach path)
- Test: `elixir/test/aiur/agent_list/app_test.exs` if it exists, or add coverage for `attach_selected/1`

**Approach:**
- "Focused pane" = `state.last_attached_pane_id`. Set on every successful open in U4. Reset to `nil` on close.
- The slot the pane belongs to is found by walking `SlotRegistry.all()` and matching `Slot.snapshot(pid).pane_id == last_attached_pane_id`.
- `Slot.select` is the same call PaneManager.open uses internally. For a NEW identifier in that slot, U3's rebuild path fires. For the PREVIOUSLY-attached identifier, this is a warm path.
- The previously-attached agent's SessionWriter stays alive (it's identifier-keyed in `SessionWriterRegistry`, not slot-keyed). When the user later attaches that agent again (in any slot), `ensure/2` returns the existing writer. R4.3 satisfied.
- `attach_selected/1` is implemented as a `GenServer.call` to the agent_list (cast → AgentList → call to PaneManager). Use a 65 s timeout so the call sees PaneManager's 60 s queue timeout reply if the slot rebuild times out.
- The render path is NOT involved (no synchronous orchestrator call) — the freeze fix from prior round is preserved.

**Patterns to follow:**
- Existing `App.activate/1` and its `PaneManager.open_conversation/2` dispatch.
- Existing keybind row in `input.ex` (single-byte `defp dispatch` clause).

**Test scenarios:**
- Covers AE6. Happy path: open issue-13 in slot 1 → state.last_attached_pane_id = %2. User highlights issue-7, presses `a`. `attach_selected/1` finds slot 1 owns %2, calls `Slot.select(slot1_pid, "issue-7")` (triggers rebuild per U3). After rebuild, pane %2 still visible in same tmux location, now showing issue-7's session chrome.
- Edge case: `a` with no open chat panes (`last_attached_pane_id == nil`) → falls through to `activate/1` (opens new pane). Verify via PaneManager log: `phase=attach_no_focused → open_visible`.
- Edge case: `a` with the SAME identifier as currently visible → no-op (slot already in `:active(identifier)` per `Slot.snapshot`; warm `Slot.select` is idempotent).
- Edge case: close the focused pane (`last_attached_pane_id` reset to `nil`), then press `a` → falls through to open-new-pane.
- Integration: after `a`, `state.identifier_to_pane` has the new identifier mapped to the SAME pane id; the old identifier's mapping for that pane id is removed.

**Verification:**
- AE6 manual: open one agent, press `a` on another → same tmux pane swaps to the new agent within ~5 s.

---

- [ ] U7. **Regression tests for AE1–AE7**

**Goal:** Each origin Acceptance Example becomes a runnable assertion before the manual verification pass.

**Requirements:** All; AE1–AE7.

**Dependencies:** U1–U6.

**Files:**
- Test: `elixir/test/aiur/regression/pane_attach_queue_test.exs` (new file) — consolidated regression coverage.

**Approach:**
- One ExUnit `describe` block per AE.
- AE3 + AE5 require inspecting on-disk `opencode.json`; use a tempdir + the existing `WorkspaceSetup` helper.
- AE2 + AE7 require driving PaneManager + a fake `Aiur.Opencode.Slot` via `:meck` or a small Mock module that implements the same `Slot` API surface (`select/2`, `deselect/1`, `snapshot/1`). Pattern: prior round already used Slot.snapshot returning `%{status: :ready}` for SlotSupervisor.acquire_slot — same approach here.
- AE1 + AE4 are pure unit-level on `Protocol.opencode_json/1`.

**Test scenarios:**
- One per AE, named `test "AE<N> ..."`.

**Verification:**
- `mix test test/aiur/regression/pane_attach_queue_test.exs` all green.

---

- [ ] U8. **Manual CLI verification + verification report**

**Goal:** Drive `scripts/aiur` end-to-end and walk every AE with quoted log evidence. Update verification report.

**Requirements:** All; AE1–AE7.

**Dependencies:** U1–U7.

**Files:**
- Modify: `elixir/docs/notes/2026-05-21-slot-bound-verification.md` (append a Round-3 section with these results) OR create `elixir/docs/notes/2026-05-21-pane-attach-queue-verification.md`.

**Approach:**
- Walk each AE in sequence:
  - AE1: inspect chat chrome content via `tmux capture-pane`
  - AE2: open 3 agents within 1 second using `tmux send-keys` script; verify all panes appear in order, no missing pane
  - AE3: measure boot time via log greps + inspect `opencode-slot-1/opencode.json` for empty agent map
  - AE4: open one agent, inspect `opencode.json` for single identifier
  - AE5: trigger rebuild via `a` attach, inspect `opencode.json` for two identifiers
  - AE6: `a` keybind manual UX
  - AE7: simulate failure (break opencode path), verify 60 s timeout reply
- Each AE result: PASS / PARTIAL / NOT TESTED + cited log line.

**Verification:**
- 7/7 AEs PASS or PARTIAL with documented reason for any PARTIAL.

---

## System-Wide Impact

- **Interaction graph:** PaneManager now has 4 inbound paths (`{:open, ...}`, `{:close, ...}`, `{:attach, ...}`, `:slot_ready` info) + PubSub subscription. Slot's `:select` is unchanged from R3.2's perspective; the rebuild path is the same machinery as before but driven incrementally. AgentList gains one outbound call to PaneManager (`attach`).
- **Error propagation:** Open path returns `{:error, :no_ready_slot}` on timeout; AgentList may want to render a transient error toast (out of scope but should be considered). Attach path returns `{:error, :no_focused_pane}` and falls through to open in AgentList.
- **State lifecycle risks:** Open queue entries hold `from` references — if PaneManager crashes mid-queue, the queued callers see GenServer crash signals. Acceptable since PaneManager is `:permanent` under cli supervisor; restart triggers full app restart.
- **API surface parity:** No external API change. `PaneManager.open_conversation` and `PaneManager.close_conversation` keep their existing signatures and semantics. New `PaneManager.attach/2` API is internal to AgentList.
- **Integration coverage:** PubSub-driven dequeue must work end-to-end with SlotPolicy's `:slot_ready` broadcast. Cover with a U7 integration scenario that uses real PubSub + a stub Slot.
- **Unchanged invariants:** Bridge token validity (token-only with generation counter from prior round) is preserved. Visible-sessions circle indicator (PubSub-driven `:slot_session_changed`) is preserved. Boot-time SessionGC (lifted from WarmServer) is preserved. The freeze fix (cached poll state in AgentList) is NOT touched.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| User opens many agents during boot (queue depth > slot_count) — opens past slot_count never drain | After slot_count :slot_ready events, the chain completes. Subsequent opens still drain — the chain doesn't broadcast again, but slots can rebuild on identifier_miss to free themselves. Document the timeout (60 s) as the upper bound. |
| `a` keybind chosen by user collides with terminal escape sequences | `a` is a plain printable byte. Already free in the existing dispatch table (verified). No collision. |
| `Slot.select` rebuild takes longer than the 60 s queue timeout under load | 60 s is generous (rebuild measured ~5 s in prior round). If it does time out, the AgentList sees the error and the user can retry. Not silent. |
| `state.last_attached_pane_id` becomes stale when the pane is killed externally (tmux kill-pane, opencode quit) | The existing `:pane_died` poll loop in Slot already broadcasts `{:slot_session_changed, _, nil}`. PaneManager subscribes; when it sees nil for the slot that owned `last_attached_pane_id`, it clears the pointer. Add this branch in U6's handle_info. |
| Coalescing duplicate-identifier opens in the queue is error-prone | Default to "refuse second open with `{:error, :already_queued}`" instead. Simpler. Document in U4's edge cases. |
| `materialize_slot` arg-change breaks any caller not enumerated | `grep -rn materialize_slot lib/ test/` to enumerate before changing. Currently only `Slot.handle_continue(:start_serve)` and `Slot.schedule_serve_rebuild` are callers (verified during prior round). |

---

## Documentation / Operational Notes

- After landing, update `elixir/docs/notes/2026-05-21-slot-bound-verification.md` to reflect the changed behavior (or write a new round-3 verification doc per U8). The "Known limitations" section is partially superseded.
- Run `/ce-code-review` at the end of the pipeline per the user's standing pattern. Focus areas: total LOC delta (expect significantly negative), dead-code removal (PaneSession + cold_attach + wait_for_active_identifiers + full-list seeding all gone), open-queue clarity (avoid GenServer reentrancy bugs).

---

## Sources & References

- **Origin document:** [elixir/docs/brainstorms/2026-05-21-pane-attach-queue-and-on-demand-models-requirements.md](elixir/docs/brainstorms/2026-05-21-pane-attach-queue-and-on-demand-models-requirements.md)
- Prior plan (the model this builds on): `elixir/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md`
- Prior round's verification: `elixir/docs/notes/2026-05-21-slot-bound-verification.md`
