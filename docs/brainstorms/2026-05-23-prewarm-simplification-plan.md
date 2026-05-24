# Opencode pre-warm simplification — plan v3 (all reviews applied)

**Branch**: `prewarm-simplification` (fork point: `e48c383` on `updated-opencode-logic`)
**Date**: 2026-05-23
**Status**: REVISED — coherence + scope-guardian + adversarial + feasibility reviews applied. Ready to execute.

## Reviewer findings folded in

| Reviewer | Finding | Resolution |
|---|---|---|
| Coherence | Step 2 forward-refs AttachPolicy | AttachPolicy module dropped; helpers live in Slot |
| Coherence | Step 4 missed `open_queue_timers` | Both `open_queue` and `open_queue_timers` listed in step 4 |
| Coherence | aiur_perf logging conflict unresolved | `aiur_perf` PubSub events stay always-on; `aiur_perf.log` file always written; verbose `Logger.*` lines `--debug` only |
| Scope | `AttachPolicy` not justified | Dropped; logic stays as `defp` in `Slot` |
| Scope | Step 5 layout-full out-of-scope | DEFERRED — file as follow-up |
| Scope | Step 3 background fill not required | DEFERRED — file as follow-up |
| Scope | Step 1 `:manual` flag scope creep | Dropped; the code math is already correct |
| Scope | Req 7 unimplemented | Now covered in step 3 (wire `pre_warmed_sessions`) |
| Adversarial | F3 displaced-pane marker semantics | Layout-full deferred — moot |
| Adversarial | F4 step 1 wrong site | Confirmed: code math is already correct (orchestrator.ex:2250, 2340). Step 1 = diagnostic logging only (DONE) |
| Adversarial | F11 `:slot_attach_added` deletion conflicts | Keep the PubSub broadcast for now; only the AttachPool *state* and *attach_state_changed* re-broadcast go. Defer broadcast collapse |
| Feasibility | §25 boot <10s is empirically impossible | Re-baselined to **<20s** (matches observed 18.6s on this branch) |
| Feasibility | Step 4 breaks 9 test files | Acknowledged — step 4 includes a test-rewrite sub-step |
| Feasibility | `known_identifiers` seeded once at boot | New step 4 sub-task: read active identifier list at boot, no dynamic update this pass |
| Feasibility | aiur_perf event ≠ aiur_perf PubSub broadcast | Both kept always-on |

## 1. Goal

A user runs `aiur` (quiet, only per-agent logs) or `aiur --debug` (verbose system logs). The agent list appears immediately with every initial-active ticket marked ⏳. Within **20 s**, each pre-warmed slot is bound to a different active ticket as its leadoff → ⚪. Enter on ⚪ is <100 ms. Pausing an active agent frees a slot the user can manually consume by unpausing a queued ⚫ or another ⏸; auto-poll respects the pause. Agents always work in the background. WORKFLOW setting `pre_warmed_sessions` (default 3) controls how many opencode-serves spin up at boot.

## 2. In-scope requirements

### Logging
1. `--debug` controls verbose system logging. Off: per-agent stdout files + `aiur_perf.log` (always-on). On: also write `aiur.log` (Logger output, tmux events, opencode HTTP traces, pipe-pane stderr capture).
2. `aiur_perf` events fire to PubSub always-on. `aiur_perf.log` is always-on.
3. `--clear` requires `--debug`. `aiur --clear` alone errors.
4. Default `aiur` is quiet.

### Pre-warm configuration
5. WORKFLOW setting `pre_warmed_sessions` (positive int, default `3`, `0` = no pre-warm — opens go entirely through the cold placeholder path).
6. Each pre-warmed serve binds to a *different* active ticket as leadoff (round-robin).
7. If `pre_warmed_sessions > active_ticket_count`: extra slots stay unspawned.
8. If `pre_warmed_sessions < max_concurrent_agents`: some active agents share, but per req #14 below, those agents show ⏳ (no slot has them attached) — the 🔘 secondary marker is deferred with background fill.

### Markers
9. Bottom warmth-row (🔲 starting / ⬜ ready) is **DEBUG-ONLY**.
10. Per-ticket markers (always visible):
    - ⚫ queued
    - ⏳ starting OR no slot has this identifier attached
    - 🔘 attached as secondary to a slot whose leadoff is a different agent *(only appears after background-fill follow-up ships)*
    - ⚪ attached as leadoff for some slot (instant open)
    - 🟢 chat pane currently visible in window
    - ⏸ paused
11. At boot, every initial-active ticket starts ⏳ then flips ⚪ as its leadoff slot finishes painting.

### Agent independence
12. Agents run regardless of opencode/UI state.
13. Closing a pane does NOT stop the agent. Slot returns to ready (still leadoff-bound).

### Pause / capacity (code is already correct — verify only)
14. Pause marks ⏸, pane stays if open, agent stops working.
15. Auto-poll does NOT auto-claim a freed-by-pause slot. ✓ Already enforced by `available_slots` at orchestrator.ex:1553–1555 (counts active+paused).
16. Manual unpause of ⚫ queued: allowed iff `active_count < max_concurrent_agents`. ✓ Already at orchestrator.ex:2340 (`resume_queued_issue`).
17. Resume of ⏸: allowed iff `active_count < max_concurrent_agents`. ✓ Already at orchestrator.ex:2250 (`resume_paused_issue`).

### Performance targets (re-baselined to empirical reality)
18. Boot → all leadoffs ⚪ with 6 agents: **<20 s** (was <10s; revised per feasibility review using aiur.log evidence).
19. Enter on ⚪: **<100 ms** (lock-free SlotRegistry path; already in place at commit e48c383).
20. Enter on ⏳: placeholder pane appears immediately (<200 ms), real pane swaps in when ready (~10 s for cold).

### UX guarantees
21. Re-Enter on already-open 🟢 focuses existing pane.
22. Shift+Enter always opens a new pane.
23. `Q` quits cleanly.

## 3. Out of scope (deferred to follow-ups)

| Follow-up | Why deferred |
|---|---|
| Layout-full pane replacement (`max_vertical_panes` × 2 + 1 chat replace policy) | New feature, not pre-warm simplification |
| Background fill attach (secondaries → 🔘 marker) | Requires new priority-control machinery in Slot mailbox; "low priority" claim is a category error in Erlang (FIFO mailbox) |
| Dynamic `known_identifiers` updates when active set grows post-boot | Requires `schedule_serve_rebuild` on every active-set change — heavyweight. Acceptable to require restart |
| WORKFLOW rename `max_vertical_panes` → `max_pane_columns` | Cosmetic, breaks back-compat |
| Vertical-orientation layout redesign | Out of scope |
| `aiur_perf` event channel deletion | Warmth report and debug footer depend on it; keep the event, only delete the PubSub re-broadcasts from AttachPool |

## 4. Implementation steps (4 steps, each independently shippable + verifiable)

### Step 1 — Diagnostic logging on resume failures ✓ DONE (commit 537ea19)

Surface the actual error code on `handle_resume_result`. Next live run will pin down whichever error code is firing for the user's "red flash with capacity available" report.

**Manual verify**: launch aiur, reproduce 5/6 + ⚫ resume, read `aiur.log` for `[user-action] resume_failed reason=...`.

### Step 2 — Drop eager fan-out's "rest" attaches

**Files**: `lib/aiur/opencode/attach_pool.ex` only.

**Change**: `kickoff_fan_out` no longer iterates the `rest` identifier list and spawns `start_attach_task` for each. Slot's leadoff is the only thing fired on `:slot_ready`. The `fanned_out_slots` MapSet guard stays (prevents re-fire on slot rebuild).

```elixir
# Before — 30 attaches at boot (6 slots × 5 rest agents each)
state = Enum.reduce(rest, state, fn id, acc ->
  start_attach_task(acc, slot_index, id, leadoff: false)
end)

# After — just leadoff
state  # no rest loop
```

**Manual verify**:
- launch aiur (current `max_concurrent_agents=6`, `pre_warmed_sessions` not yet wired so still 6 slots)
- Within 20 s, all 6 tickets show ⚪
- Enter on any → <100 ms
- Read `aiur.log`: no `attach_pool_attach_done leadoff=false` events
- Boot wall-clock recorded for follow-up baseline

### Step 3 — Wire `pre_warmed_sessions` setting

**Files**: `lib/aiur/config.ex` (new accessor), `lib/aiur/opencode/slot_policy.ex` (consume new setting), WORKFLOW schema doc note (additive — no migration).

**Change**:
- `Config.pre_warmed_sessions/0` returns the setting value or `3` if absent.
- `SlotPolicy.default_target_count/0` returns `min(pre_warmed_sessions, max_concurrent_agents)`. (Active ticket count clamp happens implicitly: if fewer tickets exist, leadoff stays ⏳ for the extras, but slots still boot. Per req #7 — extra slots stay unspawned — gate slot start on `active_count > slot_index - 1`.)

**Manual verify**:
- launch aiur with `pre_warmed_sessions=3` in WORKFLOW
- 3 slots boot, 3 active tickets show ⚪, 3+ show ⏳
- Bump `max_concurrent_agents` to 7 via ←/→ keys → no new slot spawns (capped by `pre_warmed_sessions`)
- Restart with `pre_warmed_sessions=0` → no slots boot, all tickets stay ⏳
- Enter on ⏳ → placeholder pane appears, cold spawn completes

### Step 4 — Collapse AttachPool state + agent_list mirror + test rewrites

**Files**: `lib/aiur/opencode/slot_registry.ex` (extend value), `lib/aiur/opencode/slot.ex` (write extended value), `lib/aiur/opencode/attach_pool.ex` (delete state, KEEP `:slot_attach_added` *PubSub broadcast* but stop maintaining `attachments` map), `lib/aiur/agent_list/app.ex` (delete `attach_state`, `visible_sessions`), `lib/aiur/agent_list/renderer.ex` (read SlotRegistry snapshot), `lib/aiur/pane_manager.ex` (delete `open_queue`, `open_queue_timers`).

**Sub-steps**:
- **4a**: Extend `SlotRegistry` value to `%{visible_identifier, pane_id, leadoff_identifier, attached_identifiers}`. Add `SlotRegistry.snapshot_all/0` helper that does ONE `Registry.select` and returns a `%{slot_index => value}` map (addresses adversarial F6).
- **4b**: Slot writes the extended value on every transition. `Aiur.Perf.event(:slot_attach_added, ...)` continues firing (warmth_report depends on it).
- **4c**: Renderer's `compute_markers/2` accepts a SlotRegistry snapshot from `App` instead of `attach_state` map. App computes the snapshot at render time.
- **4d**: Delete `AttachPool.attachments`, `fanned_out_slots`, `in_flight`, `fully_warmed_slots`, `active_identifiers`. Delete the `:attach_state_changed` re-broadcast. `AttachPool.consume/2` reimplements as a SlotRegistry scan + `Slot.set_visible` call.
- **4e**: Delete `AgentList.state.attach_state`, `visible_sessions`. Delete `handle_info({:attach_state_changed, ...})` handler.
- **4f**: Delete `PaneManager.open_queue`, `open_queue_timers`, `handle_info({:slot_ready, ...})` drain logic.
- **4g**: Rewrite the 9 test files that asserted on deleted state/broadcasts:
  - `test/aiur/regression/shared_prewarm_e2e_test.exs` (145 lines — heaviest)
  - `test/aiur/regression/warm_state_transitions_test.exs`
  - `test/aiur/regression/warm_attach_open_test.exs`
  - `test/aiur/regression/enter_opens_new_pane_test.exs`
  - `test/aiur/regression/prewarm_complete_time_test.exs`
  - `test/aiur/agent_list/app_test.exs`
  - `test/aiur/opencode/slot_test.exs`
  - `test/aiur/opencode/slot_policy_test.exs`
  - `test/aiur/opencode/warmth_report_test.exs` (keep — depends on `Perf.event`, not PubSub)

**Manual verify**:
- launch aiur
- All markers correct through full lifecycle: boot, open, pause, queued unpause, resume, close
- Warm open stays <100 ms
- Bottom debug-footer warmth glyphs render correctly (proves Perf.event channel intact)

## 5. Tests & verification per step

- Each step: existing `mix test --seed 1` stays at 0 failures.
- Each step: at least one new live test in `test/aiur/regression/`.
- Each step: manual checklist above with logs pasted back.

## 6. Risk register (updated)

| Risk | Likelihood | Mitigation |
|---|---|---|
| Step 4 rewrites 9 test files; one of them subtly regresses | High | Run full suite after each sub-step (4a–4g); commit each separately |
| `Slot.attach` `:identifier_unknown` on post-boot agents | High | Deferred — restart required for active-set changes this pass. Document. |
| Renderer per-tick ETS scan becomes the new bottleneck | Low | `snapshot_all/0` does ONE `Registry.select` per render, then in-memory bucket math |
| Slot rebuild path re-fires kickoff_fan_out and displaces leadoff | Medium | `fanned_out_slots` guard kept |
| AgentPubSub `:pane_opened`/`:pane_closed` keeps `opened_panes` as separate truth | Low | Out of scope this pass — `opened_panes` is genuine UI focus state, not pre-warm state |
| `pre_warmed_sessions=0` user sees all-⏳ forever | Documented behavior | Verify in step 3 includes the `=0` case |

## 7. Sign-off

- [x] Coherence + scope + adversarial + feasibility reviews applied (this v3)
- [ ] User confirms re-baselined boot budget (<20s, not <10s)
- [ ] User confirms 🔘 marker deferred (only ⏳/⚪ this pass)
- [ ] Begin Step 2

## 8. Follow-up tickets to file

1. **Layout-full pane replacement** (req for >2N chats).
2. **Background fill attach** for 🔘 secondary marker support.
3. **`known_identifiers` dynamic update** when active set grows post-boot.
4. **WORKFLOW rename** `max_vertical_panes` → `max_pane_columns`.
5. **Dynamic slot shrink** when `pre_warmed_sessions` is lowered.
6. **Profile opencode-serve cold start** — see if the 10-13s can be reduced.
