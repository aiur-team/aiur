# Opencode pre-warm simplification — plan

**Branch**: `prewarm-simplification` (fork point: `e48c383` on `updated-opencode-logic`)
**Date**: 2026-05-23
**Owner**: claude / its-everdred
**Status**: PLAN — pending ce reviews + user sign-off on defaults applied for open questions.

This doc supersedes:
- `docs/brainstorms/2026-05-23-opencode-prewarm-spaghetti-audit.md`
- `docs/brainstorms/2026-05-23-current-architecture-summary.md`

## 1. Goal (one paragraph)

A user runs `aiur` (default, quiet) or `aiur --debug` (verbose). The agent list appears immediately with every initial-active ticket marked ⏳. Within 10 s, each pre-warmed slot is bound to a different active ticket as its leadoff → ⚪. Background "fill" attaches wire remaining agents into already-painted slots → 🔘 for shared ones. The user presses Enter on any ⚪ ticket and sees its opencode pane in <100 ms. They can open up to `max_vertical_panes × 2` chat panes; beyond that, the oldest pane is repurposed in place via kill+respawn against opencode-serve. Pausing an active agent frees a slot the user can manually consume by unpausing a queued ⚫ or another ⏸ — auto-poll respects the pause. Agents always work in the background, with or without a UI session attached.

## 2. Requirements (v2 — final unless user corrects)

### Logging
1. `--debug` controls system logging. Off: per-agent stdout files only. On: also write `aiur.log` (Elixir Logger + `aiur_perf` + tmux events + opencode HTTP traces + pipe-pane stderr capture).
2. `--debug` records UI-visible activity (opens, pauses, marker transitions) to a separate trace stream.
3. `--clear` requires `--debug`. `aiur --clear` alone errors.
4. Default `aiur` is quiet.

### Pre-warm configuration
5. WORKFLOW setting `pre_warmed_sessions` (positive int, default `3`, `0` is valid = no pre-warm).
6. Each pre-warmed serve binds to a *different* active ticket as leadoff (round-robin).
7. If `pre_warmed_sessions > active_ticket_count`: extra slots stay unspawned; they spawn when capacity grows.
8. If `pre_warmed_sessions < max_concurrent_agents`: some active agents share a slot.

### Markers
9. Bottom warmth-row (🔲 starting / ⬜ ready) is **DEBUG-ONLY**.
10. Per-ticket markers (always): ⚫ queued, ⏳ starting, 🔘 attached-shared, ⚪ attached-leadoff, 🟢 visible, ⏸ paused.
11. At boot, every initial-active ticket immediately shows ⏳ then flips up the ladder.

### Agent independence
12. Agents run regardless of opencode/UI state.
13. Closing a pane does not stop the agent. Slot returns to ready.

### Pre-warm fill
14. After a slot's leadoff is painted ⚪, the slot **continues attaching other active agents in the background, low priority**.
15. Background attaches MUST NOT block: user opens, other slots' leadoffs, marker updates.
16. Leadoff stays ⚪; shared-attached secondaries show 🔘.

### Layout
17. Setting: `max_vertical_panes` (existing, default `3`). Treat as **max chat columns**. **Rename not required this pass.**
18. Horizontal growth (example `max_vertical_panes = 3`):
    - Pane 0 = agent list (left column, full height).
    - 1st chat = right of agent list, 50/50.
    - 2nd chat = right of 1st chat → 3 columns × 1/3 width each.
    - 3rd chat = splits agent list column → agent list top half, 3rd chat bottom half.
    - 4th chat = splits middle column bottom half.
    - 5th chat = splits right column bottom half.
    - **6th chat onward = REPLACE the oldest visible chat pane** by kill+respawn opencode-attach in place against opencode-serve with the new identifier's session.
19. Vertical orientation toggle stays as today (existing feature).

### Pause / capacity
20. Pause: marks ⏸, pane stays if open, agent stops working.
21. Pause frees a slot from the capacity math (`available = max - active_count`; paused does NOT count).
22. **Auto-poll does NOT auto-claim a freed-by-pause slot.** Only manual user action consumes it.
23. Manual unpause of a ⚫ queued ticket: allowed iff `active_count < max_concurrent_agents`.
24. Resume of ⏸: allowed iff `active_count < max_concurrent_agents` (so if user already filled the freed slot with a ⚫, they must wait for another slot to free before resuming the ⏸).

### Performance targets
25. Boot → all leadoffs ⚪ with 6 agents: **<10 s**.
26. Enter on ⚪: **<100 ms**.
27. Enter on 🔘: **<500 ms**.
28. Enter on ⏳: placeholder immediate, real pane <10 s.
29. Layout-full replace: **<500 ms** (kill+respawn opencode-attach, no opencode-serve restart).

### UX guarantees
30. Re-Enter on 🟢 focuses existing pane.
31. Shift+Enter always opens a new pane (existing).
32. `Q` quits cleanly (existing).
33. Pane displaced by layout-full replace flips 🟢 → ⚪ (still pre-warmed, just no longer visible).

## 3. Architecture changes (the simplification)

### Source-of-truth collapse
- `SlotRegistry` ETS becomes the **single readable view** of per-slot state: `%{visible_identifier, pane_id, attached_identifiers, status}`.
- Slot writes its state to the registry on every transition.
- Anyone (PaneManager, AgentList renderer, AttachPool's residual policy) reads ETS directly — no GenServer hops.

### State deletions
- `AttachPool.attachments`, `fanned_out_slots`, `in_flight`, `fully_warmed_slots`, `active_identifiers` — all derivable from SlotRegistry + Orchestrator. **Delete.**
- `AgentList.attach_state`, `visible_sessions` — replaced by direct SlotRegistry reads on each render tick. **Delete.**
- `PaneManager.open_queue`, `open_queue_timers` — with eager fan-out gone, no one waits on `:slot_ready` for opens. **Delete.**
- `Slot.active_identifier`, `active_session_id` — dups of `visible_identifier` / `visible_session_id`. **Delete.**
- Most `Slot.attach` call sites — replaced by the "background fill" task that runs only after leadoff is painted.

### Broadcast collapse
- Drop: `:slot_attach_added`, `:slot_attach_removed`, `:attach_state_changed`, `:attach_consumed`.
- Keep: `:slot_state_changed` (single event, payload `slot_index`; subscribers re-read ETS) + `:slot_ready` (boot signal) + `:pane_opened` / `:pane_closed` (UI bookkeeping).

### AttachPool's new shape
- No GenServer state. Becomes `Aiur.Opencode.AttachPolicy`: pure functions that take the active-identifier list + a SlotRegistry snapshot and answer:
  - "Which slot should paint identifier X next?" → returns slot index or `:none`.
  - "Which identifier should slot Y paint next?" → returns identifier or `:none`.
- Called by `Slot` (when it reaches `:ready`) and by `AgentList.App` (when the active list changes — e.g., a paused agent unpauses).

### Fan-out replaced by per-slot leadoff
- Slot boots → reaches `:ready` → calls `AttachPolicy.leadoff_for(slot_index)` → paints exactly one identifier.
- A background `Task` then iterates other active identifiers, calling `Slot.attach` for each, low priority. Cancellable if a higher-priority `set_visible` arrives.

### PaneManager warm-open path
- Already lock-free via `SlotRegistry.find_visible` (commit `e48c383`). Keep.
- Layout grid (`PaneManager.apply_layout`) gets a new "REPLACE oldest" branch for the `>2N` chat case.

## 4. Implementation order (5 steps, each independently shippable + manually verified)

Each step ends with: build release → launch aiur → drive feature in real tmux → paste log evidence here → commit + push → next step.

### Step 1 — Pause frees capacity (for manual action only)
**Files**: `lib/aiur/orchestrator.ex` (one function: `available_slots`), `lib/aiur/agent_list/app.ex` (resume-paused precondition).

**Change**:
```elixir
# orchestrator.ex
defp available_slots(%State{} = state) do
  used = active_running_count(state.running)  # was: + paused_running_count
  max(max_concurrent_agent_limit(state) - used, 0)
end
```
Plus: a `:manual` flag on the dispatch path so auto-poll continues to subtract paused from its OWN math, while manual user actions use the new lighter rule.

**Manual verify**: 6 active. Pause #4 → 5 active 1 paused. Unpause ⚫ #7 → 6 active 1 paused, no red flash. Try to resume #4 → red flash "no capacity". Pause #7 → resume #4 → success.

### Step 2 — Drop eager fan-out; leadoff-only at boot
**Files**: `lib/aiur/opencode/attach_pool.ex` (gut `kickoff_fan_out`'s rest loop), `lib/aiur/opencode/slot.ex` (boot leadoff hook).

**Change**: each slot on `:ready` calls `AttachPolicy.leadoff_for(slot_index, active_identifiers)` and paints exactly that one identifier. No `rest` attaches at boot.

**Manual verify**: launch aiur. Within 10 s, all 6 tickets show ⚪. No 🔘 yet (no background fill in this step). Enter on any → <100 ms open. Boot wall-clock: <10 s.

### Step 3 — Background fill attach (low priority)
**Files**: `lib/aiur/opencode/slot.ex` (post-leadoff task), `lib/aiur/opencode/attach_policy.ex` (new).

**Change**: after slot's leadoff is painted, spawn a `Task` that walks all other active identifiers and calls `Slot.attach` for each. Task is cancellable if a higher-priority `set_visible` arrives. Slot's mailbox prioritizes calls over fill tasks via explicit ordering in `handle_call`.

**Manual verify**: launch aiur. All leadoffs ⚪ within 10 s. Then secondaries flip to 🔘 over the next ~30 s. Throughout, Enter on any agent stays <500 ms (proves fill doesn't block opens).

### Step 4 — Collapse AttachPool + state-store dedup
**Files**: `lib/aiur/opencode/attach_pool.ex` (delete most state + most broadcasts), `lib/aiur/opencode/attach_policy.ex` (grows), `lib/aiur/agent_list/app.ex` (drop `attach_state`/`visible_sessions`, read ETS in renderer), `lib/aiur/agent_list/renderer.ex` (read SlotRegistry directly), `lib/aiur/pane_manager.ex` (drop `open_queue`).

**Change**: convert `AttachPool` from stateful GenServer to thin policy module + a lightweight subscriber that re-broadcasts `:slot_state_changed` consolidated events. Delete state listed in §3 above.

**Manual verify**: launch aiur. All markers correct through every lifecycle event: boot, open, close, pause, resume, queue advance. No mailbox-induced latency anywhere (warm open stays <100 ms even during fan-out).

### Step 5 — Layout growth + switch-session replace
**Files**: `lib/aiur/pane_manager.ex` (`apply_layout`, `open_opencode_pane` when grid full), `lib/aiur/opencode/slot.ex` (re-set_visible into already-visible pane via kill+respawn).

**Change**: implement the §17–18 grid growth rules. When `>2N` chats are needed, identify the oldest visible chat (FIFO by open time), kill its opencode-attach pane, respawn with the new identifier's `--session`, update `SlotRegistry` so the displaced agent flips 🟢 → ⚪.

**Manual verify**: launch aiur, max_vertical_panes=3. Open 5 chats → 2-row grid as spec'd. Open 6th → oldest pane (top-middle) repurposes via kill+respawn in <500 ms, displaced agent shows ⚪.

### Logging gate (rolled into above steps)
- Step 4 also gates `Aiur.Perf.event`/`aiur_perf` log lines on `AIUR_DEBUG=1` (currently always-on per the user's prior memory `feedback_perf_logging`).
- Wait — that memory says **"always-on aiur_perf log lines; never gate on --debug"**. CONFLICT with req #1.

## 5. Conflict: aiur_perf logging gate

User memory `feedback_perf_logging` says: *"always-on aiur_perf log lines for pane/opencode lifecycle; never gate on --debug"*. Req #1 says system logs are debug-only.

**Resolution proposal**: keep `aiur_perf` always-on (it's already minimal, structured, machine-parseable for the 3-row debug footer), but gate the verbose Elixir `Logger.info`/`Logger.debug` lines on `--debug`. Per-agent log files stay always-on. `aiur.log` exists only in debug mode and contains the Logger output + pipe-pane capture.

**User: confirm this resolution OR override the old memory.**

## 6. Tests & manual verification per step

- Each step has a code-grep regression test (small, fast) for the architectural rules it enforces.
- Each step has at least one new live test in `test/aiur/regression/`.
- Each step has a manual checklist (above), with logs pasted back here as proof.
- All steps: existing `mix test` suite stays at 0 failures.

## 7. Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| Background fill task blocks `set_visible` despite priority math | Medium | Run fill via `Task.Supervisor` with `:transient` restart; call cancellation hook in slot's `handle_call({:set_visible, ...})`. |
| Switch-session via kill+respawn flickers | Medium | Use tmux `respawn-pane -k` (in-place) instead of kill+split — same pane id, no layout disruption. |
| Pause→capacity change breaks orchestrator polling invariants | Low-Medium | Add explicit test: auto-poll cycle with 5 active 1 paused 1 queued ⚫ — assert auto-poll does NOT claim. |
| Markers go stale because subscribers no longer get fine-grained events | Low | `:slot_state_changed` fires on every transition. Renderer re-reads ETS on every tick (250ms geometry tick already exists). |
| Existing tests rely on broadcast tuples we're deleting | High | Audit test/ for `:slot_attach_added`, `:attach_state_changed`, etc. Rewrite to subscribe to `:slot_state_changed` and assert via SlotRegistry. |

## 8. What we explicitly do NOT do this pass

- Vertical layout redesign (existing toggle stays).
- New keybinds (existing input map preserved).
- WORKFLOW schema migration (additive `pre_warmed_sessions` field only).
- Renaming `max_vertical_panes` (open question Q-F deferred — assumed NO this pass).
- Persisting open-pane state across `aiur` restarts.

## 9. Open questions resolved with defaults (correct in chat if wrong)

- Q-F: `max_vertical_panes` keeps its name.
- Q-G: Switch-session via tmux `respawn-pane -k` (kill+respawn opencode-attach in place).
- Q-H: Agent list column splits first when chat columns are full; generalizes beyond max=3.
- Q-I: Plain Enter focuses if open, Shift+Enter always new pane (no change from today).
- Q-J: Displaced agent goes 🟢 → ⚪.

## 10. Reviewers to spawn

- `ce-adversarial-document-reviewer` — high stakes, multiple architectural changes, new abstraction (AttachPolicy).
- `ce-feasibility-reviewer` — verify the boot-time + open-latency budgets are real.
- `ce-scope-guardian-reviewer` — guard against accidental scope creep.
- `ce-coherence-reviewer` — sanity-check internal consistency of this doc.
- `ce-design-lens-reviewer` — check missing interaction states (e.g., what does the user see during layout-full replace?).

## 11. Sign-off checklist

- [ ] User confirms requirements list v2 with no further corrections
- [ ] User confirms 5 default-resolved open questions
- [ ] User confirms aiur_perf logging conflict resolution (§5)
- [ ] All 4 ce reviewers report no blockers
- [ ] Plan revised based on reviewer findings
- [ ] Begin Step 1
