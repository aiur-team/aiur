# Decomposition: src/lib/aiur/pane_manager.ex (1,839 LOC)

Behavior-preserving split of `Aiur.PaneManager` into the existing `Aiur.PaneManager.*` namespace
(`src/lib/aiur/pane_manager/`, where `layout.ex` already lives). House style followed: the GenServer
shell stays the single owner of process/mailbox semantics; extracted modules are either pure
policy/state transforms (`State`, `OpenQueue`) or handler-body modules taking `(state, args)` and
returning updated state / `{:reply|:noreply, ...}` tuples; dependency direction is strictly
shell → path modules → pure modules → external collaborators (Tmux, Slot, AttachPool, SlotRegistry,
SlotSupervisor, AgentPubSub). No new GenServers, no new ETS, no message shapes change — this is a
code-location refactor, not a redesign. The lock-free ETS-first warm-open shape from the prewarm
simplification is preserved verbatim and becomes the named responsibility of one module
(`OpencodeOpen`).

---

## 1. Function / responsibility census

Line ranges from the current file (branch `refactor-planning-prompt`).

### A. Public API surface (114–198, ~85 lines)
| Function | Lines | Notes |
|---|---|---|
| `start_link/1` | 116–119 | |
| `open_conversation/4` | 121–130 | 65 s call timeout (must exceed 60 s queue timeout) |
| `hide_by_pane_id/2` | 132–151 | catches `:noproc`/`:timeout` exits |
| `close_conversation/2` | 153–156 | |
| `attach_conversation/4` | 158–176 | 65 s timeout, same reason |
| `list_open_panes/1`, `orientation/1`, `toggle_orientation/1` | 178–198 | |

### B. Init, anchor/window resolution, control URL (202–296 + 729–756, ~125 lines)
| Function | Lines | Notes |
|---|---|---|
| `init/1` | 202–271 | slot_count = max(grid, max_concurrent_agents); subscribes tmux events, Slot topic, AttachPool topic; `:net_kernel.monitor_nodes`; **refuses to start without anchor pane** (`{:stop, :no_agent_list_pane}` — issue #34 guard) |
| `publish_control_url/1`, `control_url_host/0` | 273–296 | best-effort tmux global option for Ctrl+C binding |
| `resolve_agent_list_pane/2`, `env_pane/0`, `resolve_window_target/3` | 729–756 | opts → `$TMUX_PANE` → `Tmux.resolve_self_pane` |

### C. handle_call clauses (298–386, ~90 lines)
`{:open,...}` 299–324 (reconcile → idempotence probe → `do_open`); `{:attach,...}` 326–345;
`{:close,...}` 347–357; `{:hide_by_pane_id,...}` 359–369; `:list` 371; `:orientation` 373;
`:toggle_orientation` 375–386.

### D. handle_info clauses (388–612, ~225 lines)
`:pane_died` 389–402; `:slot_ready` → drain 404–406; `:slot_session_changed` nil 408–431 (forget +
clear `last_attached_pane_id` + re-layout); 8 no-op slot/attach event clauses 433–470;
`{:agent_inactive, id}` 447–458 (routes through `close_opencode_or_generic`);
`:open_queue_timeout` 472–503 (queue pluck + reply `:no_ready_slot`); node up/down no-ops 505–507;
`:placeholder_swap` 509–575 (atomic `swap-pane`, kill placeholder, record, layout, broadcast, spawn
paint detector); `:convo_first_paint` 577–581 (no-op sink); `:placeholder_failed` 583–592;
`:tmux_event` catchall 594–600; `:screen_grab_tick` 602–610; final catchall 612.

### E. Screen-grab diagnostics + env flags (614–696, ~85 lines)
`log_screen_grab/1` 614–622, `log_pane_grab/3` ×2 624–647, `dead_tmux?/1` 649–655,
`collect_tracked_panes/1` 657–673, `debug_mode?/0` 675–683, `screen_grab?/0` 686–696.
Gated on `AIUR_SCREEN_GRAB`, deliberately NOT `AIUR_DEBUG` (FD pressure).

### F. Open queue (698–727 + handler 472–503 + 1424–1444, ~85 lines)
`drain_open_queue/1` 698–706, `drain_open_entry/3` 708–727 (1 entry per `:slot_ready`; `:no_ready_slot`
race leaves entry queued), `enqueue_open/3` 1424–1444 (duplicate → `:already_queued`; 60 s timer),
plus the `:open_queue_timeout` pluck in D.

### G. Close / hide semantics (758–854, ~95 lines)
`do_open/5` 760–765 (opencode-vs-generic route); `hide_slot_pane/3` 767–799 (hide WITHOUT deselect —
slot keeps identifier binding for fast reopen); `close_opencode_or_generic/3` 801–842 (hide +
`Slot.deselect`, or plain kill for generic panes; deselect-on-move-failure fallback);
`slot_for_pane/2` 844–854 (SlotRegistry scan + `Slot.snapshot`).

### H. Generic (non-opencode) opens + distribution wrapping (856–873, 1446–1494, 1783–1838, ~120 lines)
`open_generic_pane/4` 856–873; `advance_cycle/1` 1446–1448; `open_in_slot/4` 1450–1463;
`replace_in_slot/5` 1465–1480 (respawn-pane, stale-pane fallback); `create_pane_for_slot/4` 1482–1494;
`wrap_with_unique_node/2` 1785–1809 (ERL_AFLAGS long-name @127.0.0.1 + cookie — string format is
load-bearing); `read_erlang_cookie/0` 1823–1838; `bump_next_slot/0` 1811–1821 (SlotPolicy.bump wrapped
in rescue/catch).

### I. Opencode open decision path (875–1141, ~265 lines) — the hot path
`open_opencode_pane/4` 875–943: **lock-free fast path** — `SlotRegistry.find_visible` (ETS) FIRST,
then async `AttachPool.mark_visible` mirror, then `AttachPool.consume(identifier, exclude_slots:
visible-in-window-0)`, then placeholder fallback. `move_warm_pane_visible/5` 945–1022 (move-visible +
record + broadcast + `bump_next_slot` + paint detector; "already visible" error treated as success —
note: that branch does NOT `apply_layout`, the success branch does). `open_with_placeholder/3`
1024–1092 (spawn placeholder, `GenServer.reply` BEFORE `Task.start(drive_real_attach)`; on spawn
failure falls back to synchronous acquire/attach or enqueue). `spawn_placeholder_pane/2` 1094–1117;
`horizontal_orientation/1` 1119–1121; `record_placeholder/4` 1123–1135; `drop_placeholder/2` 1137–1140.

### J. Convo first-paint detector (1142–1218, ~75 lines)
`detect_convo_first_paint/5` 1155–1160, `do_detect_convo_paint/7` 1162–1201, `wait_and_retry_convo_paint/7`
1203–1218. Fire-and-forget Task; polls `capture-pane` for `"Build · issue-"` every 100 ms, 30 s budget;
runs on BOTH warm and swap paths for metric parity.

### K. Async attach driver for placeholders (1220–1291, ~70 lines)
`drive_real_attach/3` 1222–1237, `wait_then_select_for_placeholder/4` 1239–1248,
`perform_select_for_placeholder/6` 1250–1271, `wait_for_slot/1` + `do_wait_for_slot/1` 1273–1291
(150 ms poll, 60 s budget). Runs OUTSIDE the GenServer; communicates back via
`:placeholder_swap` / `:placeholder_failed` messages.

### L. Slot attach + focused-pane rebind (1293–1422, ~125 lines)
`attach_identifier_to_slot/5` 1293–1347 (Slot.select → move-visible → record → broadcast → bump;
deselect on move failure); `handle_pane_move_error/7` 1349–1369; `pane_already_visible_reason?/1`
1371–1380 ("source and target panes must be different" → success); `attach_to_focused_pane/3`
1382–1415 (rebind `last_attached_pane_id`'s slot to a new identifier); `reply_or_noreply/3` 1417–1422
(nil-from = queue-drain caller convention).

### M. Layout application (1496–1576, ~80 lines)
`apply_layout/1` 1498–1517 (window_size → `Layout.build` → `select_layout`); `log_layout_apply/4`
1519–1530; `slot_panes_list/1` 1532–1546 (slot-indexed occupancy incl. placeholders);
`visible_panes_packed/1` 1548–1560 (pack left-to-right — the "chat opens under the agent list" fix);
`first_available_visual_slot/1` 1562–1570; `slot_count/1` 1572; `empty_slot_panes/1` 1574–1576.

### N. State bookkeeping (60–94 struct + 1578–1781, ~240 lines)
Struct/defstruct 60–94 (4 pane maps + cycle_index + queue + placeholders + titles);
`record_slot_pane/4` 1580–1591 (map updates + title side effect); `remember_title/3` 1593–1605;
`set_pane_title/3` 1607–1615; `pane_title_text/2` 1617–1622; `scrub_title/1` 1624–1631;
`forget_identifier_for_pane/2` 1633–1645; `forget_pane_by_identifier/2` 1647–1673;
`forget_dead_slot/2` 1675–1680; `handle_pane_closed/2` 1682–1702; `refocus_agent_list_if_focused/2`
1704–1717 (only refocus if the DEAD pane was the focused one); `reconcile_visible_panes/1` 1719–1736;
`drop_stale_tracked_panes/2` 1738–1743; `release_stale_visible_pane/2` 1745–1763 (Slot.deselect +
broadcast `:pane_closed`); `drop_stale_placeholders/2` 1765–1772; `drop_placeholder_by_pane/2` 1774–1781.

---

## 2. Proposed module split (NAME MAP — the contract)

All new files under `src/lib/aiur/pane_manager/`. `Aiur.PaneManager` remains the registered GenServer
(supervised from `src/lib/aiur.ex:82`; callers `agent_list/app.ex`, `observability_api_controller.ex`,
and all tests keep calling it — zero public-API change).

| # | Module | File | Responsibility (one sentence) | ~LOC | Key functions that move |
|---|---|---|---|---:|---|
| 1 | `Aiur.PaneManager` (retained shell) | `src/lib/aiur/pane_manager.ex` | GenServer shell: public API, init/subscriptions, and thin `handle_call`/`handle_info` clauses that delegate to the modules below. | ~280 | public API (§A), `init/1`, all handler heads, `debug_mode?/0`, catch-alls |
| 2 | `Aiur.PaneManager.State` | `src/lib/aiur/pane_manager/state.ex` | The `%State{}` struct and every pure transform/view over the identifier↔pane↔slot maps, placeholders, titles, and cycle index — the single source of truth for pane bookkeeping. | ~200 | defstruct (§N), `record_slot_pane` (pure part), `forget_identifier_for_pane`, `forget_pane_by_identifier`, `forget_dead_slot`, `record_placeholder` (pure part), `drop_placeholder`, `drop_placeholder_by_pane`, `remember_title`, `pane_title_text`, `scrub_title`, `advance_cycle`, `slot_panes_list`, `visible_panes_packed`, `first_available_visual_slot`, `empty_slot_panes`, `slot_count/1` |
| 3 | `Aiur.PaneManager.OpenQueue` | `src/lib/aiur/pane_manager/open_queue.ex` | Pure FIFO pending-open queue: enqueue with duplicate refusal, single-entry pop, and timeout pluck; timers and `GenServer.reply` stay in the shell. | ~90 | queue/timers data ops from `enqueue_open`, `drain_open_queue` pop, the `:open_queue_timeout` reduce (§F), `@open_queue_timeout_ms` |
| 4 | `Aiur.PaneManager.Anchor` | `src/lib/aiur/pane_manager/anchor.ex` | Init-time resolution of the agent-list anchor pane and window target, plus control-URL publication into tmux. | ~80 | `resolve_agent_list_pane/2`, `env_pane/0`, `resolve_window_target/3`, `publish_control_url/1`, `control_url_host/0` (§B) |
| 5 | `Aiur.PaneManager.ScreenGrab` | `src/lib/aiur/pane_manager/screen_grab.ex` | AIUR_SCREEN_GRAB-gated periodic capture of every tracked pane's content into the log for post-mortem replay. | ~110 | `log_screen_grab/1`, `log_pane_grab/3`, `dead_tmux?/1`, `collect_tracked_panes/1`, `screen_grab?/0`, tick constants (§E) |
| 6 | `Aiur.PaneManager.Layout` (existing, extended) | `src/lib/aiur/pane_manager/layout.ex` | Owns the layout fact end-to-end: builds the explicit layout string (existing) and now also applies it to the tmux window from state occupancy. | ~250 | gains `apply/1` (= `apply_layout/1`) + `log_layout_apply/4` (§M); `build/6` unchanged |
| 7 | `Aiur.PaneManager.GenericOpen` | `src/lib/aiur/pane_manager/generic_open.ex` | Legacy non-opencode pane opens: slot cycling, respawn-or-split, and unique-BEAM-node command wrapping. | ~130 | `open_generic_pane/4`, `open_in_slot/4`, `replace_in_slot/5`, `create_pane_for_slot/4`, `wrap_with_unique_node/2`, `read_erlang_cookie/0` (§H) |
| 8 | `Aiur.PaneManager.Close` | `src/lib/aiur/pane_manager/close.ex` | Close/hide semantics: hide-keeping-slot-binding, close-with-deselect, generic kill, and slot-ownership lookup for a pane. | ~130 | `hide_slot_pane/3`, `close_opencode_or_generic/3`, `slot_for_pane/2` (§G) |
| 9 | `Aiur.PaneManager.Reconcile` | `src/lib/aiur/pane_manager/reconcile.ex` | Reconciles tracked state against live tmux panes: stale-pane/placeholder drops, pane-death handling, and focus return to the anchor. | ~140 | `reconcile_visible_panes/1`, `drop_stale_tracked_panes/2`, `release_stale_visible_pane/2`, `drop_stale_placeholders/2`, `handle_pane_closed/2`, `refocus_agent_list_if_focused/2` (§N) |
| 10 | `Aiur.PaneManager.SlotAttach` | `src/lib/aiur/pane_manager/slot_attach.ex` | Drives a ready slot through select → move-visible → record/broadcast (with the already-visible success quirk), including focused-pane rebind and the reply convention. | ~150 | `attach_identifier_to_slot/5`, `handle_pane_move_error/7`, `pane_already_visible_reason?/1`, `attach_to_focused_pane/3`, `reply_or_noreply/3`, `bump_next_slot/0` (§L, §H) |
| 11 | `Aiur.PaneManager.ConvoPaint` | `src/lib/aiur/pane_manager/convo_paint.ex` | Fire-and-forget detector that polls a pane for opencode's `Build · issue-` render marker and emits first-paint perf events. | ~90 | `detect_convo_first_paint/5`, `do_detect_convo_paint/7`, `wait_and_retry_convo_paint/7`, poll/budget constants (§J) |
| 12 | `Aiur.PaneManager.Placeholder` | `src/lib/aiur/pane_manager/placeholder.ex` | Instant-placeholder lifecycle: spawn the loading pane, reply immediately, drive the real attach asynchronously, and handle the atomic swap-in or failure. | ~230 | `open_with_placeholder/3`, `spawn_placeholder_pane/2`, `horizontal_orientation/1`, `drive_real_attach/3`, `wait_then_select_for_placeholder/4`, `perform_select_for_placeholder/6`, `wait_for_slot/1`, `do_wait_for_slot/1`, handler bodies for `:placeholder_swap` / `:placeholder_failed` (§I, §K, §D) |
| 13 | `Aiur.PaneManager.OpencodeOpen` | `src/lib/aiur/pane_manager/opencode_open.ex` | The opencode open decision tree: lock-free SlotRegistry hit → AttachPool consume → placeholder fallback, plus the warm move-visible path. | ~200 | `open_opencode_pane/4`, `move_warm_pane_visible/5`, `do_open/5` route (§I) |

Dependency direction (one way, no cycles):
`PaneManager` (shell) → `OpencodeOpen` → `Placeholder` → `SlotAttach` → `State`/`Layout`;
shell → `Close`/`Reconcile`/`GenericOpen`/`OpenQueue`/`ScreenGrab`/`Anchor` → `State`/`Layout`;
`ConvoPaint` is a leaf used by `OpencodeOpen` and `Placeholder`. External collaborators
(Tmux, Slot, AttachPool, SlotRegistry, SlotSupervisor, SlotPolicy, HiddenWindow, AgentPubSub,
Aiur.Perf) are only ever called downward from path modules.

Design notes (behavior-preserving constraints):
- `record_slot_pane`/`record_placeholder` currently mix pure map updates with the `set_pane_title`
  tmux side effect. Split: `State` gets the pure transform; the shell keeps a 3-line
  `record_slot_pane/4` composition (State update + `Tmux.set_pane_title(..., State.pane_title_text(...))`)
  so the title-set ordering at every call site is unchanged and the side effect is not fanned out.
- All extracted handler-body functions keep their exact names and argument names
  (`state, identifier, pane_id`, `state, identifier, _opts, from`) — several regression tests grep for
  these exact call shapes (see §4).
- The five near-duplicate "pane became visible" epilogues (warm success, warm already-visible, attach
  success, attach already-visible, placeholder swap) are MOVED, not unified: they differ in whether
  `apply_layout` runs and which perf event fires. Unification is a follow-up candidate AFTER
  characterization coverage exists, not part of this decomposition.
- `%Aiur.PaneManager{}` struct becomes `%Aiur.PaneManager.State{}`. No code outside pane_manager.ex
  constructs or matches the struct (verified by grep; tests drive the server via its API only).

---

## 3. Extraction sequencing (waves; strictly serialized on this file; repo compiles + tests green after each; ≤400 moved lines per wave)

- **Wave 0 — characterization backfill (no code moves).** Add the missing behavioral tests from §4
  (open-queue enqueue/duplicate/timeout/drain; `:slot_session_changed` nil handling;
  `:agent_inactive` close; hide/close slot paths and `:placeholder_swap`/`:placeholder_failed`
  handling behind stub SlotRegistry/Slot seams where feasible with the existing mock Tmux).
  This is the cheapest insurance for waves 3–6.
- **Wave 1 — `State` + `OpenQueue` (~300 moved lines).** Move the struct and all pure bookkeeping/
  occupancy/queue transforms; every remaining private in pane_manager.ex switches to `State.*` /
  `OpenQueue.*` calls. Timer creation/cancel and `GenServer.reply` stay in the shell. No test changes
  expected (all pinned behavior is via the server API).
- **Wave 2 — `Anchor` + `ScreenGrab` + `Layout.apply` (~230 moved lines).** Low-risk side seams:
  init-time resolution, diagnostics loop, and the apply_layout/log pair into `Layout`. `layout_test.exs`
  unchanged (`build/6` untouched).
- **Wave 3 — `GenericOpen` + `Close` + `Reconcile` (~340 moved lines).** The `{:close}`/`{:hide_by_pane_id}`
  /`{:agent_inactive}`/`:pane_died` handler clauses stay in the shell and delegate. Keep call shape
  `Close.close_opencode_or_generic(state, identifier, pane_id)` — the `done_agent_detach_test.exs`
  source regex matches on the substring and needs NO change if argument names are preserved.
- **Wave 4 — `SlotAttach` + `ConvoPaint` (~230 moved lines).** `{:attach}` clause and
  `drain_open_entry/3` delegate to `SlotAttach.attach_identifier_to_slot/5`. Must land BEFORE
  `Placeholder`/`OpencodeOpen`, which call into it (keeps the dependency arrow one-way).
- **Wave 5 — `Placeholder` (~250 moved lines + test-pin updates).** `open_with_placeholder`, the async
  driver, and the `:placeholder_swap`/`:placeholder_failed` bodies move; the `handle_info` heads stay
  in the shell. **Same-wave test edit:** `regression/time_to_paint_test.exs` pins
  `spawn_placeholder_pane(state, identifier)`, `Task.start(fn -> drive_real_attach`, and the
  `swap-pane -s #{real_pane_id} -t #{placeholder_pane_id}` string against
  `@pane_manager_source` — repoint those assertions at `pane_manager/placeholder.ex`
  (the `def handle_info({:placeholder_swap,` pin still hits pane_manager.ex and stays).
- **Wave 6 — `OpencodeOpen` (~210 moved lines + test-pin updates).** The hot path moves last, after
  everything under it is settled. **Same-wave test edit:** `regression/enter_opens_new_pane_test.exs`
  splits `@pane_manager_source` on `defp open_opencode_pane(state, identifier, _opts, from) do` and
  `defp move_warm_pane_visible` to assert `SlotRegistry.find_visible` is checked BEFORE
  `AttachPool.consume` — repoint the path at `pane_manager/opencode_open.ex` and change `defp` → `def`
  in the split regexes (the functions become the module's public entry points). The ordering assertion
  itself must keep passing untouched.

Each wave is one reviewable ticket; wave N+1 must not start until wave N is merged (single-file
serialization). After wave 6 the shell is ~280 lines of API + delegating clauses.

---

## 4. Risks

### Concurrency / state / timing semantics that must be preserved verbatim

1. **Lock-free warm-open ordering** (`open_opencode_pane`, 875–943): `SlotRegistry.find_visible`
   (ETS read) MUST run before any GenServer call (`AttachPool.consume`, `Slot.*`); on a hit,
   `AttachPool.mark_visible` is an async mirror, never a gate. A busy fan-out wedges Slot/AttachPool
   mailboxes >5 s and would time the open into the cold path. Pinned by
   `regression/enter_opens_new_pane_test.exs`. Hotspot map row 5 (opencode integration, ~17 incidents:
   "warm-marker/attach races under multi-agent load") is exactly this seam.
2. **Reply-before-async on the placeholder path** (1024–1061): `GenServer.reply(from, {:ok, placeholder})`
   fires before `Task.start(drive_real_attach)`; a synchronous `Slot.select` inside the handler defeats
   the <500 ms placeholder guarantee. Pinned by `regression/time_to_paint_test.exs`.
3. **Atomic swap ordering** (509–575): `swap-pane` (one atomic tmux op) → kill placeholder → select
   real pane. kill+spawn instead of swap flashes the layout and loses selection state. Pinned by
   `time_to_paint_test.exs`.
4. **Timeout lattice**: caller call timeout 65 s > `@open_queue_timeout_ms` 60 s > `wait_for_slot` 60 s
   budget; shrinking any of these crashes parked callers mid-cold-prewarm. The `:open_queue_timeout`
   handler must keep its timers-map guard (timer firing after drain is a legal race → no-op) and the
   drain must keep the "another open stole the slot → leave entry queued" branch (722–726).
5. **Queue drain rate**: exactly 1 entry per `:slot_ready` broadcast (documented v1 decision, 71–74).
   "Optimizing" this during the move is a behavior change.
6. **Hide ≠ close**: `hide_slot_pane` keeps the slot's identifier binding (fast reopen via
   `Slot.set_visible`); `close_opencode_or_generic` additionally `Slot.deselect`s. Conflating them
   regresses the Ctrl+Q/Ctrl+C-close semantic (see memory: Ctrl+C kill race history).
7. **Broadcast parity on all three close paths** (`:pane_died`, reconcile drop, user hide/close): each
   broadcasts `:pane_closed` so the agent-list renderer stays in sync — hotspot theme 9
   (renderer/backend desync, #414/#425/#473 class).
8. **Focus rules**: refocus the agent-list anchor ONLY when the dead/dropped pane equals
   `last_attached_pane_id` (background deaths must not steal focus) — both directions are pinned by
   `pane_manager_test.exs` ("focused pane dying…", "background pane dying…", reconcile variant, the #16
   lockup).
9. **`pane_already_visible_reason?` asymmetry**: "source and target panes must be different" is treated
   as success, and the warm already-visible branch deliberately does NOT `apply_layout` while the
   normal success branch does. Preserve verbatim; do not "fix" during the move.
10. **Init fail-closed**: no anchor pane → `{:stop, :no_agent_list_pane}` (the silent-fallback root
    cause of the #34→#51→#61→#77 chain — hotspot map row 13, "slot-cycling fixed 3× before root
    cause"). Layout re-application after every mutation is the other half of that chain's fix
    ("stale layout state").
11. **`bump_next_slot` armor**: `SlotPolicy.bump()` wrapped in rescue/catch — SlotPolicy may be down;
    an open must never crash on it.
12. **Reconcile placement**: `reconcile_visible_panes` runs synchronously at the top of `{:open,...}`
    (before the idempotence probe), and skips entirely when nothing is tracked. Moving it later lets a
    stale cached pane short-circuit an open.
13. **`ConvoPaint` parity**: the detector Task fires on BOTH warm and swap paths so the debug footer's
    "opencode render" number stays comparable; it is fire-and-forget (100 ms poll / 30 s budget) and
    must never block or message-couple back into the open path beyond the single info message.
14. **Generic-pane node wrapping string** (1785–1809): the exact ERL_AFLAGS quoting
    (long name `@127.0.0.1`, `-proto_dist inet_tcp`, `{127,0,0,1}` interface, cookie flag) is
    load-bearing for BEAM distribution through `/bin/sh -c` double parsing.
15. **Screen-grab gating**: `AIUR_SCREEN_GRAB` stays independent of `AIUR_DEBUG` (per-pane
    `capture-pane` forks scale with ticket count — hotspot theme 7, `:emfile` fan-out #409/#457).

### Tests that pin this file today

- `src/test/aiur/pane_manager_test.exs` (513 lines, mock-tmux behavioral): open/split/respawn cycling,
  titles + scrubbing, close/kill, idempotent reopen, placeholder reconcile + left-packing, focus
  return rules, orientation toggle. Strongest safety net; runs against the public API so waves 1–4
  should not touch it.
- `src/test/aiur/pane_manager_live_test.exs` (359 lines, real tmux, `:live_tmux`): grid geometry,
  round-robin pane-id reuse, orientation round-trip, close/external-close reconcile geometry.
- `src/test/aiur/pane_manager/layout_test.exs`: pins `Layout.build/6` (untouched by this split).
- Source-grep wiring guards (ACTIVE — must be repointed in the same wave that moves their target):
  - `regression/time_to_paint_test.exs` → placeholder spawn call, `Task.start(fn -> drive_real_attach`,
    `handle_info({:placeholder_swap,` clause, `swap-pane -s … -t …` string (wave 5).
  - `regression/enter_opens_new_pane_test.exs` → `defp open_opencode_pane(...)` /
    `defp move_warm_pane_visible` split markers + find_visible-before-consume ordering (wave 6).
  - `regression/done_agent_detach_test.exs` → AttachPool-topic subscribe (stays in shell),
    `handle_info({:agent_inactive,` (stays in shell), `close_opencode_or_generic(state, identifier,
    pane_id)` call substring (still matches after wave 3 if argument names are kept).
  - `regression/warm_attach_open_test.exs` source block is `@describetag :skip` (retired by issue #85)
    — no action, but do not resurrect its stale patterns.
- `application_test.exs` asserts `Aiur.PaneManager` presence/absence in the supervision tree
  (module name must not change). `agent_list/app_test.exs`, `regression/agent_list_sort_test.exs`,
  `regression/warm_marker_semantics_test.exs` use Mock PaneManagers — they pin the public call
  contract (`open_conversation/4` etc.), not internals.

### Characterization coverage missing (recommend adding in wave 0)

1. **Open queue**: enqueue on `:no_ready_slot`, duplicate open → `:already_queued`, timeout →
   `{:error, :no_ready_slot}` reply + queue pluck, drain-on-`:slot_ready`, drain race re-queue.
   Zero behavioral coverage today.
2. **Slot-owned close/hide happy paths**: `hide_by_pane_id` success (move to hidden window, binding
   kept), `close` → `Slot.deselect` + hidden move; only the `:not_slot_pane` fallback and the generic
   kill path are tested.
3. **`:agent_inactive`** → pane close (source-grep only today).
4. **`:slot_session_changed` nil** → forget pane + clear `last_attached_pane_id` + re-layout (untested).
5. **`:placeholder_swap` / `:placeholder_failed` handler behavior** with mock tmux (swap success
   records + drops placeholder; swap failure kills placeholder; failure applies layout) — currently
   source-grep + packing tests only.
6. **Warm-open registry-hit and consume-hit paths** (`move_warm_pane_visible`, incl. the
   already-visible-success quirk and cold-fallback on move failure) — currently pinned only by source
   greps and live perf logs; needs a stubbed SlotRegistry/AttachPool seam to test at the PaneManager
   boundary.
7. **`attach_to_focused_pane`** stale-pointer clears (`last_attached_pane_id` → untracked pane, slot
   gone from registry).

The hotspot map (docs/refactor/research-history-hotspots.md) rates `pane_manager.ex` itself moderate
(row 13, ~6 incidents) but the seams it fronts — `src/lib/aiur/opencode/` slots/attach pool (row 5,
~17 incidents) and timing/submission races (cross-cutting theme 1) — are top-quartile. The decomposition
deliberately does NOT touch Slot/AttachPool/SlotRegistry message shapes, tmux command strings, perf
event names, or log line formats (`aiur_pane_manager phase=…` lines are grepped by
`regression/chat_open_perf_test.exs` and operator tooling).
