# T-045: pane_manager wave 2: opens, close, reconcile; slim

**Phase:** 4
**Depends-on:** T-044
**Labels:** `agent:todo` `refactor` `phase:4` `complexity:3` `model:claude`

## Problem / context

`src/lib/aiur/pane_manager.ex` is the GenServer that owns every chat-pane
open/close/hide/reconcile path. T-044 (wave 1, merged before this ticket) already
extracted the low-risk seams into the `Aiur.PaneManager.*` namespace
(`src/lib/aiur/pane_manager/`): `State` (the `%State{}` struct + pure bookkeeping),
`OpenQueue` (pure queue data ops), `Anchor`, `ScreenGrab`, and `Layout.apply/1`.
This ticket is wave 2 — the FINAL pane_manager decomposition wave — and it extracts the
seven remaining behaviour clusters named in the binding name map of
`docs/refactor/research-arch/giant-pane_manager.md` §2: `GenericOpen`, `Close`,
`Reconcile`, `SlotAttach`, `ConvoPaint`, `Placeholder`, `OpencodeOpen`. After this
wave the `Aiur.PaneManager` shell is a thin GenServer of public API + `init/1` +
delegating `handle_call`/`handle_info` heads (**target ~280 lines; hard ceiling ≤ 320**).

This is a code-location refactor, not a redesign. The opencode open hot path and the
tmux timing/swap races this file fronts are top-quartile hotspots
(`docs/refactor/research-history-hotspots.md` rows 5 and 13: warm-attach races, the
#34→#51→#61→#77 slot-cycling chain, `:emfile` fan-out). Every sequencing, timeout,
reply-ordering, and broadcast listed in the research doc §4 "Risks" is preserved
**verbatim**. The shell stays the registered GenServer (supervised from
`src/lib/aiur.ex:82`); callers (`src/lib/aiur/agent_list/app.ex`,
`src/lib/aiur_web/controllers/observability_api_controller.ex`, `application_test.exs`,
the Mock PaneManagers in `agent_list/app_test.exs`) see **zero public-API change**.

## Scope (exact)

### Ground rules (read before touching anything)

- **Line numbers are pre-T-044 references.** All line numbers in this ticket and in the
  research-doc census (`giant-pane_manager.md` §1) are from the original 1,839-line file.
  T-044 already deleted ~340 lines and renumbered the shell, so **locate every function
  by name with `grep -n`, not by the cited line number.** The line ranges are a map of
  *which* code, not *where* it now sits.
- **What T-044 already changed in the shell** (you will see these; do not undo them):
  the `%State{}` struct lives in `pane_manager/state.ex`; call sites already read
  `State.`, `OpenQueue.`, `Layout.apply(`, `Anchor.`, `ScreenGrab.`. `enqueue_open/3`,
  `drain_open_queue/1`, `drain_open_entry/3`, `record_slot_pane/4`, `record_placeholder/4`,
  `set_pane_title/3`, `debug_mode?/0` are currently retained shell privates.
- **Move verbatim.** Cut/paste each function body including its comments. The only
  permitted edits to a moved body are: (a) `defp` → `def` when the name map makes it a
  module entry point, (b) prefixing calls to already-extracted helpers with their module
  (`State.`, `Layout.`, `OpenQueue.`, and the new modules below), (c) the record-helper
  homing in the next rule. Do **not** rewrite logic, rename variables/arguments, reword a
  log/perf string, or change any timeout/interval/percent literal.
- **The `record_slot_pane` / `set_pane_title` / `record_placeholder` composition** (the
  pure `State.record_slot_pane` map update + the `Tmux.set_pane_title` side effect) is used
  by functions that land in **both** dependency chains. There is no single downward home
  that both chains reach and that may touch tmux (`State` is pure by T-044's contract).
  Resolve it exactly like this, no other way:
  - `SlotAttach` gets **public** `record_slot_pane/4` and `set_pane_title/3` (verbatim
    copies of the current shell privates, `defp`→`def`). Chain-1 modules `OpencodeOpen`
    and `Placeholder` call `SlotAttach.record_slot_pane/4` (they already depend on
    `SlotAttach`).
  - `GenericOpen` (chain 2, which must NOT depend on `SlotAttach`) gets its **own private**
    `record_slot_pane/4` and `set_pane_title/3` — verbatim copies. This one intentional
    duplicate is the cost of keeping the dependency graph acyclic; unifying the two copies
    is an explicit follow-up (out of scope), consistent with the research doc's deferral of
    epilogue unification until characterization exists.
  - `record_placeholder/4` is used only by `Placeholder` → make it a **private** function
    of `Placeholder` (it calls `SlotAttach.set_pane_title/3`).
- **Dependency direction (one way, acyclic — enforce it):**
  `shell → OpencodeOpen → {Placeholder, SlotAttach, ConvoPaint, GenericOpen}`;
  `Placeholder → {SlotAttach, ConvoPaint, OpenQueue}`; `SlotAttach → {State, Layout}`;
  `shell → {Close, Reconcile, GenericOpen} → {State, Layout}`; `Close → Reconcile`
  (for `refocus_agent_list_if_focused/2`); `ConvoPaint` is a leaf. `State`, `Layout`,
  `OpenQueue` are the sinks. **No extracted module may call back into `Aiur.PaneManager`**
  (that would be a cycle) — the two functions that tempt it (`enqueue_open`,
  `refocus_agent_list_if_focused`) move out of the shell in the steps below.

Do the work as **four commits**, in this order (research-doc waves 3→6), each ending with a
green `mix compile --warnings-as-errors && mix test` from `src/`. Wave order is mandatory:
`SlotAttach` must exist before `Placeholder`, which must exist before `OpencodeOpen`
(one-way arrows); `GenericOpen` must exist before `OpencodeOpen` (`do_open` routes to it).

### Commit 1 — GenericOpen + Close + Reconcile (research wave 3)

1. **Create `src/lib/aiur/pane_manager/generic_open.ex` — module `Aiur.PaneManager.GenericOpen`.**
   Move verbatim (`defp`→`def` only where the shell calls it): `open_generic_pane/4`
   (858–873), `open_in_slot/4` (1450–1463), `replace_in_slot/5` (1465–1480),
   `create_pane_for_slot/4` (1482–1494), `wrap_with_unique_node/2` (1785–1809),
   `read_erlang_cookie/0` (1823–1838). Add the **private** `record_slot_pane/4` +
   `set_pane_title/3` copies per the record-helper rule; inside them call `State.`. The
   ERL_AFLAGS string in `wrap_with_unique_node` is load-bearing (research doc risk 14) —
   copy it byte-for-byte. Public entry point called from the shell: `open_generic_pane/4`.
   `open_in_slot`/`replace_in_slot`/`create_pane_for_slot`/`wrap_with_unique_node`/
   `read_erlang_cookie` may stay `defp` (module-internal). Module needs `require Logger`,
   `alias Aiur.Tmux`, `alias Aiur.PaneManager.State`, and the PubSub alias the moved
   `broadcast_status_change` call uses (`alias Aiur.AgentEvents.PubSub, as: AgentPubSub` —
   copy the exact alias form from the shell). Prefix `advance_cycle` in `open_generic_pane`
   with `State.` (already moved in T-044), and `apply_layout(` with `Layout.apply(`,
   `forget_identifier_for_pane`/`forget_dead_slot` with `State.`.
   Specs:
   ```elixir
   @spec open_generic_pane(State.t(), State.agent_id(), String.t(), GenServer.from()) ::
           {:reply, {:ok, String.t()} | {:error, term()}, State.t()}
   @spec wrap_with_unique_node(String.t(), State.agent_id()) :: String.t()
   ```

2. **Create `src/lib/aiur/pane_manager/reconcile.ex` — module `Aiur.PaneManager.Reconcile`.**
   Move verbatim: `handle_pane_closed/2` (1682–1702), `refocus_agent_list_if_focused/2`
   (1704–1717), `reconcile_visible_panes/1` (1719–1736), `drop_stale_tracked_panes/2`
   (1738–1743), `release_stale_visible_pane/2` (1745–1763), `drop_stale_placeholders/2`
   (1765–1772). Public entry points (called from the shell / `Close`): `handle_pane_closed/2`,
   `reconcile_visible_panes/1`, `refocus_agent_list_if_focused/2` — `defp`→`def`. The rest
   stay `defp`. Prefix `forget_pane_by_identifier`, `drop_placeholder`, `drop_placeholder_by_pane`
   with `State.` (moved in T-044) and `apply_layout(` with `Layout.apply(`. Change the
   `reconcile_visible_panes(%__MODULE__{} = state)` head to `%State{} = state`. Module needs
   `require Logger`, `alias Aiur.Tmux`, the `Slot`/`SlotRegistry` aliases the moved code uses
   (`alias Aiur.Opencode.{Slot, SlotRegistry}` — copy exact forms from the shell),
   `AgentPubSub`, and `alias Aiur.PaneManager.{Layout, State}`. **Focus rule verbatim**
   (research doc risk 8): `refocus_agent_list_if_focused` re-selects the anchor ONLY when
   `closed_pane_id == state.last_attached_pane_id`; its return value is discarded at the
   `hide_slot_pane`/`handle_pane_closed` call sites today — keep that (do not capture it).
   **Reconcile-placement verbatim** (risk 12): the early-return-when-nothing-tracked guard
   and the fact that the shell runs `reconcile_visible_panes` at the TOP of the `{:open}`
   handler before the idempotence probe must not change.
   Specs:
   ```elixir
   @spec handle_pane_closed(State.t(), State.pane_id()) :: State.t()
   @spec reconcile_visible_panes(State.t()) :: State.t()
   @spec refocus_agent_list_if_focused(State.t(), State.pane_id()) :: State.t()
   ```

3. **Create `src/lib/aiur/pane_manager/close.ex` — module `Aiur.PaneManager.Close`.**
   Move verbatim: `hide_slot_pane/3` (772–799), `close_opencode_or_generic/3` (801–842),
   `slot_for_pane/2` (846–854). Public entry points (called from shell handlers):
   `hide_slot_pane/3`, `close_opencode_or_generic/3` — `defp`→`def`. `slot_for_pane/2` stays
   `defp`. Prefix `forget_pane_by_identifier` with `State.`, `apply_layout(` with
   `Layout.apply(`, and `refocus_agent_list_if_focused(new_state, pane_id)` (in
   `hide_slot_pane`) with `Reconcile.` (its return still discarded). **CRITICAL — keep the
   call-substring `close_opencode_or_generic(state, identifier, pane_id)` reachable with those
   exact argument names**: the shell handlers keep calling
   `Close.close_opencode_or_generic(state, identifier, pane_id)`, so the substring
   `close_opencode_or_generic(state, identifier, pane_id)` still appears in the shell source —
   `regression/done_agent_detach_test.exs` greps for it and must pass **unchanged**. Preserve
   the **hide ≠ close** asymmetry verbatim (risk 6): `hide_slot_pane` moves the pane hidden
   and keeps the slot's identifier binding (no `Slot.deselect`); `close_opencode_or_generic`
   additionally `Slot.deselect`s. Preserve broadcast parity (risk 7): every close path
   broadcasts `:pane_closed`. Module needs `require Logger`, `alias Aiur.{Boot, Tmux}`,
   `alias Aiur.Opencode.{HiddenWindow, Slot, SlotRegistry}` (copy exact forms), `AgentPubSub`,
   `Aiur.Perf`, and `alias Aiur.PaneManager.{Layout, Reconcile, State}`.
   Specs:
   ```elixir
   @spec hide_slot_pane(State.t(), State.agent_id(), State.pane_id()) ::
           {:reply, :ok | {:error, term()}, State.t()}
   @spec close_opencode_or_generic(State.t(), State.agent_id(), State.pane_id()) ::
           {:reply, :ok, State.t()}
   ```

4. **Rewire the shell for commit 1.** In the `handle_call({:open, ...})` head, replace
   `reconcile_visible_panes(state)` with `Reconcile.reconcile_visible_panes(state)` (keep it
   at the same line, before the `Map.fetch` idempotence probe). In `handle_info({:tmux_event,
   {:notification, :pane_died, ...}})`, replace `handle_pane_closed(state, pane_id)` with
   `Reconcile.handle_pane_closed(...)`. In `handle_call({:close, ...})` and
   `handle_info({:agent_inactive, ...})`, replace `close_opencode_or_generic(...)` with
   `Close.close_opencode_or_generic(...)` (arg names unchanged). In
   `handle_call({:hide_by_pane_id, ...})`, replace `hide_slot_pane(...)` with
   `Close.hide_slot_pane(...)`. Delete the moved functions from the shell. Add
   `alias Aiur.PaneManager.{Close, GenericOpen, Reconcile}` to the shell's existing
   `alias Aiur.PaneManager.{...}` line. Let `mix compile --warnings-as-errors` enumerate any
   missed call site; fix each with a module prefix, add nothing.

### Commit 2 — SlotAttach + ConvoPaint (research wave 4)

5. **Create `src/lib/aiur/pane_manager/convo_paint.ex` — module `Aiur.PaneManager.ConvoPaint`.**
   Move verbatim: `@convo_paint_poll_interval_ms 100` and `@convo_paint_budget_ms 30_000`
   with their comment block (1142–1153), `detect_convo_first_paint/5` (1155–1160),
   `do_detect_convo_paint/7` (1162–1201), `wait_and_retry_convo_paint/7` (1203–1218). Public
   entry point (called from `OpencodeOpen` and `Placeholder`): `detect_convo_first_paint/5`
   — `defp`→`def`; the other two stay `defp`. **Fire-and-forget parity verbatim** (risk 13):
   marker string `"Build · issue-"`, 100 ms poll, 30 s budget, and the single `:convo_first_paint`
   info message back to the GenServer must not change. Module needs `alias Aiur.Tmux` and
   `Aiur.Perf`.
   Specs:
   ```elixir
   @spec detect_convo_first_paint(pid(), GenServer.server(), State.agent_id(), pos_integer(), State.pane_id()) :: :ok
   ```
   (add `alias Aiur.PaneManager.State` for the type; the function runs in a spawned Task and
   returns whatever its recursion returns — `:ok` on emit/timeout.)

6. **Create `src/lib/aiur/pane_manager/slot_attach.ex` — module `Aiur.PaneManager.SlotAttach`.**
   Move verbatim: `attach_identifier_to_slot/5` (1297–1347), `handle_pane_move_error/7`
   (1349–1369), `pane_already_visible_reason?/1` (1371–1380), `attach_to_focused_pane/3`
   (1389–1415), `reply_or_noreply/3` (1417–1422 — both clauses), `bump_next_slot/0`
   (1815–1821). Add the **public** `record_slot_pane/4` + `set_pane_title/3` copies (verbatim
   shell privates, `defp`→`def`) per the record-helper rule. Public defs (called from shell
   or `OpencodeOpen`): `attach_identifier_to_slot/5`, `attach_to_focused_pane/3`,
   `pane_already_visible_reason?/1`, `reply_or_noreply/3`, `bump_next_slot/0`,
   `record_slot_pane/4`, `set_pane_title/3`. `handle_pane_move_error/7` stays `defp`. Prefix
   `apply_layout(` → `Layout.apply(`, `forget_identifier_for_pane` → `State.` (in
   `attach_to_focused_pane`), and `detect_convo_first_paint(` → `ConvoPaint.` (there is no
   such call in SlotAttach — that lives in OpencodeOpen; ignore if absent). **Preserve verbatim**:
   the already-visible asymmetry (risk 9 — `pane_already_visible_reason?` treats "source and
   target panes must be different" as success), the `reply_or_noreply` nil-`from` queue-drain
   convention, the `bump_next_slot` rescue/catch armor (risk 11), and the
   `aiur_pane_manager phase=open_visible … open_ms=…` log line (unchanged text — it is grepped
   from `log/aiur.log` by `regression/chat_open_perf_test.exs`). Module needs `require Logger`,
   `alias Aiur.{Boot, Tmux}`, `alias Aiur.Opencode.{Slot, SlotRegistry, SlotPolicy}`,
   `AgentPubSub`, `Aiur.Perf`, `alias Aiur.PaneManager.{Layout, State}`.
   Specs:
   ```elixir
   @spec attach_identifier_to_slot(State.t(), State.agent_id(), pos_integer(), pid(), GenServer.from() | nil) ::
           {:reply, {:ok, String.t()} | {:error, term()}, State.t()} | {:noreply, State.t()}
   @spec attach_to_focused_pane(State.t(), State.agent_id(), GenServer.from()) ::
           {:reply, {:ok, String.t()} | {:error, term()}, State.t()} | {:noreply, State.t()}
   @spec pane_already_visible_reason?(term()) :: boolean()
   @spec reply_or_noreply(term(), GenServer.from() | nil, State.t()) ::
           {:reply, term(), State.t()} | {:noreply, State.t()}
   @spec bump_next_slot() :: :ok
   @spec record_slot_pane(State.t(), pos_integer(), State.pane_id(), State.agent_id()) :: State.t()
   @spec set_pane_title(State.t(), State.pane_id(), State.agent_id()) :: :ok
   ```

7. **Rewire the shell for commit 2.** In `handle_call({:attach, ...})`, replace
   `attach_to_focused_pane(...)` with `SlotAttach.attach_to_focused_pane(...)`. In
   `drain_open_entry/3` (which stays in the shell), replace `attach_identifier_to_slot(...)`
   with `SlotAttach.attach_identifier_to_slot(...)`. Delete the moved functions
   (`attach_identifier_to_slot`, `handle_pane_move_error`, `pane_already_visible_reason?`,
   `attach_to_focused_pane`, `reply_or_noreply`, `bump_next_slot`, and the shell copies of
   `record_slot_pane`/`set_pane_title` — they now live in SlotAttach) plus the ConvoPaint
   functions from the shell. Extend the shell alias to include `ConvoPaint, SlotAttach`. Fix
   compiler-reported call sites with prefixes only.

### Commit 3 — Placeholder (research wave 5)

8. **Create `src/lib/aiur/pane_manager/placeholder.ex` — module `Aiur.PaneManager.Placeholder`.**
   Move verbatim: `open_with_placeholder/3` (1024–1092), `spawn_placeholder_pane/2`
   (1097–1117), `horizontal_orientation/1` (1119–1121, three clauses), `drive_real_attach/3`
   (1222–1237), `wait_then_select_for_placeholder/4` (1239–1248), `perform_select_for_placeholder/6`
   (1250–1271), `wait_for_slot/1` + `do_wait_for_slot/1` (1273–1291), the **bodies** of
   `handle_info({:placeholder_swap, ...})` (509–575) and `handle_info({:placeholder_failed, ...})`
   (583–592) as new functions `handle_swap/5` and `handle_failed/4`, and `enqueue_open/3`
   (1424–1444 — moved here because `open_with_placeholder` is its sole caller; keeping it in
   the shell would create a `Placeholder → shell` cycle). Add the **private** `record_placeholder/4`
   (verbatim, calling `SlotAttach.set_pane_title/3`). Public entry points: `open_with_placeholder/3`
   (called by `OpencodeOpen`), `handle_swap/5`, `handle_failed/4` (called by the shell heads).
   Prefix in the moved code: `record_slot_pane(` (in the swap body) → `SlotAttach.record_slot_pane(`;
   `drop_placeholder`/`first_available_visual_slot` → `State.`; `apply_layout(` → `Layout.apply(`;
   `attach_identifier_to_slot(` (in the `open_with_placeholder` sync fallback) →
   `SlotAttach.attach_identifier_to_slot(`; `detect_convo_first_paint(` (in the swap body) →
   `ConvoPaint.detect_convo_first_paint(`; `enqueue_open(` stays a local call now that it lives
   here. `handle_swap/5` and `handle_failed/4` each return `{:noreply, new_state}` exactly as
   the current handler bodies do — take arguments matching the message tuple's fields
   (`state, identifier, placeholder_pane_id, slot_index, real_pane_id` for swap;
   `state, identifier, placeholder_pane_id, reason` for failed). **Preserve verbatim** the three
   pinned races: reply-before-async on `open_with_placeholder` (risk 2 — `GenServer.reply(from,
   {:ok, placeholder})` fires BEFORE `Task.start(drive_real_attach)`); atomic swap ordering
   (risk 3 — `swap-pane` then kill-placeholder then select-real); the `wait_for_slot` 150 ms
   poll / 60 s budget (risk 4). Module needs `require Logger`, `alias Aiur.{Boot, Tmux}`,
   `alias Aiur.Opencode.{SlotSupervisor}` (and any others the moved code references — copy
   exact aliases the current shell uses for these functions), `AgentPubSub`, `Aiur.Perf`,
   `alias Aiur.PaneManager.{ConvoPaint, Layout, OpenQueue, SlotAttach, State}`.
   Specs:
   ```elixir
   @spec open_with_placeholder(State.t(), State.agent_id(), GenServer.from()) ::
           {:noreply, State.t()} | {:reply, {:ok, String.t()} | {:error, term()}, State.t()}
   @spec handle_swap(State.t(), State.agent_id(), State.pane_id(), pos_integer(), State.pane_id()) ::
           {:noreply, State.t()}
   @spec handle_failed(State.t(), State.agent_id(), State.pane_id(), term()) :: {:noreply, State.t()}
   @spec enqueue_open(State.t(), State.agent_id(), GenServer.from()) ::
           {:noreply, State.t()} | {:reply, {:error, :already_queued}, State.t()}
   ```

9. **Rewire the shell for commit 3.** Keep the `handle_info({:placeholder_swap, ...}, state)`
   and `handle_info({:placeholder_failed, ...}, state)` **heads** in the shell (the
   `def handle_info({:placeholder_swap,` line is grepped and must stay in `pane_manager.ex`);
   replace each body with a one-line delegation:
   ```elixir
   def handle_info({:placeholder_swap, identifier, placeholder_pane_id, slot_index, real_pane_id}, state) do
     Placeholder.handle_swap(state, identifier, placeholder_pane_id, slot_index, real_pane_id)
   end

   def handle_info({:placeholder_failed, identifier, placeholder_pane_id, reason}, state) do
     Placeholder.handle_failed(state, identifier, placeholder_pane_id, reason)
   end
   ```
   Delete the moved functions and the shell's `enqueue_open/3` and `record_placeholder/4`.
   Extend the shell alias to include `Placeholder`. `drain_open_queue/1` and `drain_open_entry/3`
   stay in the shell (they call `OpenQueue.pop` and `SlotAttach.attach_identifier_to_slot`).
10. **Repoint the one wave-5 source-pin guard (authorized regression edit).**
    `src/test/aiur/regression/time_to_paint_test.exs` greps `@pane_manager_source` for four
    strings; three now live in `placeholder.ex`. Edit ONLY the source-path targeting, never the
    assertion messages: add `@placeholder_source Path.expand("../../../lib/aiur/pane_manager/placeholder.ex", __DIR__)`;
    in the test `"open_opencode_pane spawns a placeholder pane before driving the slot"` read
    `@placeholder_source` for both `spawn_placeholder_pane(state, identifier)` and
    `Task.start(fn -> drive_real_attach` assertions; in the test
    `"PaneManager handles :placeholder_swap with swap-pane"` read `@pane_manager_source` for the
    `def handle_info({:placeholder_swap,` assertion (unchanged — head stays in the shell) and
    `@placeholder_source` for the `swap-pane -s #{real_pane_id} -t #{placeholder_pane_id}`
    assertion. The `@describetag :perf_regression` log-assertion test is untouched. This is the
    only edit permitted in any `regression/` file this commit.

### Commit 4 — OpencodeOpen; final slim (research wave 6)

11. **Create `src/lib/aiur/pane_manager/opencode_open.ex` — module `Aiur.PaneManager.OpencodeOpen`.**
    Move verbatim: `do_open/5` (760–765), `open_opencode_pane/4` (881–943),
    `move_warm_pane_visible/5` (948–1022). Public entry points: `do_open/5` (called by the
    shell `{:open}` handler), `open_opencode_pane/4`, `move_warm_pane_visible/5` — **all become
    `def`** (the wave-6 regression guard splits the source on `def open_opencode_pane` /
    `def move_warm_pane_visible`). In `do_open`, the non-opencode branch calls
    `GenericOpen.open_generic_pane(...)` and the opencode branch calls `open_opencode_pane(...)`
    (local). Prefix in the moved code: `move_warm_pane_visible(` (local, unprefixed);
    `open_with_placeholder(` → `Placeholder.open_with_placeholder(`; `record_slot_pane(` →
    `SlotAttach.record_slot_pane(`; `bump_next_slot()` → `SlotAttach.bump_next_slot()`;
    `reply_or_noreply(` → `SlotAttach.reply_or_noreply(`; `pane_already_visible_reason?(` →
    `SlotAttach.pane_already_visible_reason?(`; `detect_convo_first_paint(` →
    `ConvoPaint.detect_convo_first_paint(`; `apply_layout(` → `Layout.apply(`. **Preserve the
    lock-free ordering verbatim** (risk 1, the #1 hotspot seam): `SlotRegistry.find_visible/1`
    (ETS read) runs FIRST, `AttachPool.mark_visible` is an async mirror (never a gate),
    `AttachPool.consume(identifier, exclude_slots: visible_in_window_0)` is the fallback, and the
    `visible_in_window_0` computation (filter `slot_panes` to non-nil pane ids) is unchanged.
    The already-visible-warm branch deliberately does NOT `Layout.apply` while the success branch
    does (risk 9) — do not "fix" this. Module needs `require Logger`, `alias Aiur.Tmux`,
    `alias Aiur.Opencode.{AttachPool, SlotRegistry, SlotSupervisor}` (copy exact aliases the moved
    code uses), `AgentPubSub`, `Aiur.Perf`,
    `alias Aiur.PaneManager.{ConvoPaint, GenericOpen, Layout, Placeholder, SlotAttach, State}`.
    Specs:
    ```elixir
    @spec do_open(State.t(), State.agent_id(), String.t(), keyword(), GenServer.from()) ::
            {:reply, term(), State.t()} | {:noreply, State.t()}
    @spec open_opencode_pane(State.t(), State.agent_id(), keyword(), GenServer.from()) ::
            {:reply, term(), State.t()} | {:noreply, State.t()}
    @spec move_warm_pane_visible(State.t(), State.agent_id(), pos_integer(), State.pane_id(), GenServer.from()) ::
            {:reply, term(), State.t()} | {:noreply, State.t()}
    ```
12. **Rewire the shell for commit 4.** In `handle_call({:open, ...})`, replace both
    `do_open(...)` call sites with `OpencodeOpen.do_open(...)` (the one in the idempotence-miss
    branch takes `State.forget_pane_by_identifier(state, existing_pane)` — keep that arg exactly).
    Delete `do_open/5`, `open_opencode_pane/4`, `move_warm_pane_visible/5` from the shell. Extend
    the shell alias to include `OpencodeOpen`. This is the last extraction — after it the shell
    defines only: public API, `init/1`, `start_link/1`, every `handle_call`/`handle_info` head,
    `drain_open_queue/1`, `drain_open_entry/3`, `debug_mode?/0`, module attrs/aliases/moduledoc.
13. **Repoint the one wave-6 source-pin guard (authorized regression edit).**
    `src/test/aiur/regression/enter_opens_new_pane_test.exs`, describe
    `"PaneManager warm-open hot path is lock-free"` only. Edit ONLY the source targeting and the
    two `defp`→`def` split markers, never the ordering-assertion logic or messages: add
    `@opencode_open_source Path.expand("../../../lib/aiur/pane_manager/opencode_open.ex", __DIR__)`;
    in that one test, `File.read!(@opencode_open_source)` instead of `@pane_manager_source`, and
    change the two split regexes `~r/defp open_opencode_pane\(state, identifier, _opts, from\) do/`
    → `~r/def open_opencode_pane\(state, identifier, _opts, from\) do/` and
    `~r/defp move_warm_pane_visible/` → `~r/def move_warm_pane_visible/`. The `find_visible`-before-
    `consume` position assertions stay byte-identical. All other describes in this file
    (`@app_source`, `@slot_source`, `@registry_source`, `aiur.ex`) are untouched. This is the only
    edit permitted in any `regression/` file this commit.

### Tests (spread across the four commits, one file per new module)

New modules are NOT coverage-exempt; do not add any module to `ignore_modules` in `src/mix.exs`.
Each new file gets a test file exercising its testable-in-isolation public surface. Deep
end-to-end behaviour stays pinned by the untouched `pane_manager_test.exs` (public API, 513
lines) and `pane_manager_live_test.exs`. Use the mock-Tmux transport seam exactly as
`src/test/aiur/pane_manager_test.exs` sets it up (start `{Aiur.Tmux, [transport: {:mock, self()},
name: ..., session: "test"]}`; reply to outbound `{:tmux_mock_out, cmd}` with `%begin`/`%end`-framed
chunks). Build `%Aiur.PaneManager.State{}` fixtures directly.

14. `src/test/aiur/pane_manager/generic_open_test.exs` (`async: true` for the pure parts):
    `wrap_with_unique_node/2` produces `env ERL_AFLAGS="-name pane-<safe>-<b36>@127.0.0.1 …
    -proto_dist inet_tcp -kernel inet_dist_use_interface {127,0,0,1}" <command>`; a non-`[A-Za-z0-9_-]`
    identifier is sanitized to `-`; with `AIUR_ERLANG_COOKIE` set the string contains
    `-setcookie <cookie>` and without it does not (that one test `async: false`, save/restore the
    env var in `setup`/`on_exit`); `read_erlang_cookie/0` returns the env cookie when set.
15. `src/test/aiur/pane_manager/reconcile_test.exs` (mock Tmux): `refocus_agent_list_if_focused/2`
    emits a `select-pane -t <anchor>` and nils `last_attached_pane_id` when `closed_pane_id ==
    last_attached_pane_id`, and is a no-op (no `{:tmux_mock_out, _}`, state unchanged) otherwise;
    `reconcile_visible_panes/1` returns the state unchanged and issues NO tmux command when
    `pane_to_identifier` and `placeholder_panes` are both empty (risk 12 early return).
16. `src/test/aiur/pane_manager/close_test.exs` (mock Tmux, empty `SlotRegistry`):
    `close_opencode_or_generic/3` on a pane no slot owns kills it (`kill-pane -t <pane>` on the
    mock), forgets the mapping, and replies `{:reply, :ok, _}`; `hide_slot_pane/3` on a pane no
    slot owns replies `{:reply, {:error, :not_slot_pane}, state}` with state unchanged.
17. `src/test/aiur/pane_manager/convo_paint_test.exs` (mock Tmux): `detect_convo_first_paint/5`
    emits an `:convo_first_paint` `Aiur.Perf` event (subscribe to the Perf topic) when the mock
    `capture-pane` reply contains `"Build · issue-"`; assert `@convo_paint_poll_interval_ms == 100`
    and `@convo_paint_budget_ms == 30_000` via a public accessor or by reading the module source
    (the 30 s timeout branch is not unit-tested — it is impractically slow and the interval/budget
    constants are pinned instead).
18. `src/test/aiur/pane_manager/slot_attach_test.exs` (`async: true` for pure parts):
    `pane_already_visible_reason?/1` is `true` for `"source and target panes must be different"`
    and for `{1, "…source and target panes must be different…"}`, `false` otherwise;
    `reply_or_noreply/3` returns `{:reply, result, state}` for `nil` from and `{:noreply, state}`
    (delivering `result` to the caller pid) for a real `from`; `bump_next_slot/0` returns `:ok`
    when `SlotPolicy` is not started (the rescue/catch armor, risk 11); `record_slot_pane/4` +
    `set_pane_title/3` populate the four state maps and emit a `select-pane -T` on the mock Tmux.
19. `src/test/aiur/pane_manager/placeholder_test.exs` (mock Tmux): `horizontal_orientation/1`
    returns `:horizontal`/`:vertical`/`:horizontal` for the three inputs; `spawn_placeholder_pane/2`
    strips single quotes from the identifier in the split command and returns `{:ok, pane_id}` from
    the mock; `record_placeholder/4` stores `%{pane_id: …, slot: …}` under the identifier and emits
    a title `select-pane -T`.
20. `src/test/aiur/pane_manager/opencode_open_test.exs` (mock Tmux + the same slot infra
    `pane_manager_test.exs` starts): `do_open/5` with a non-sentinel command routes to the generic
    path (a `split-window` on the mock, no placeholder); `do_open/5` with `"__aiur_opencode__ <id>"`
    and an empty `SlotRegistry` + `AttachPool` returning `:miss` routes into the placeholder cold
    path (a placeholder `split-window` appears). If starting `AttachPool`/`SlotRegistry` is
    required, mirror `pane_manager_test.exs`'s `setup` verbatim.

## Files

- Create: `src/lib/aiur/pane_manager/generic_open.ex`, `src/lib/aiur/pane_manager/close.ex`,
  `src/lib/aiur/pane_manager/reconcile.ex`, `src/lib/aiur/pane_manager/slot_attach.ex`,
  `src/lib/aiur/pane_manager/convo_paint.ex`, `src/lib/aiur/pane_manager/placeholder.ex`,
  `src/lib/aiur/pane_manager/opencode_open.ex`,
  `src/test/aiur/pane_manager/generic_open_test.exs`, `src/test/aiur/pane_manager/close_test.exs`,
  `src/test/aiur/pane_manager/reconcile_test.exs`, `src/test/aiur/pane_manager/slot_attach_test.exs`,
  `src/test/aiur/pane_manager/convo_paint_test.exs`, `src/test/aiur/pane_manager/placeholder_test.exs`,
  `src/test/aiur/pane_manager/opencode_open_test.exs`
- Modify: `src/lib/aiur/pane_manager.ex`,
  `src/test/aiur/regression/time_to_paint_test.exs` (source-path repoint only, step 10),
  `src/test/aiur/regression/enter_opens_new_pane_test.exs` (source-path + `defp`→`def` split-marker
  repoint only, step 13)
- Test: the seven new `_test.exs` files above; `src/test/aiur/pane_manager_test.exs` and
  `src/test/aiur/pane_manager_live_test.exs` (`:live_tmux`) must pass **unchanged**;
  `src/test/aiur/regression/done_agent_detach_test.exs` and
  `src/test/aiur/regression/chat_open_perf_test.exs` must pass **unchanged**

## Out of scope

- Any behaviour change. This is a location refactor: no new features, no API changes, no
  "cleanups" of the five near-duplicate "pane became visible" epilogues (they differ deliberately
  in `Layout.apply` and perf events — MOVE them, UNIFY nothing; research doc design note 3, risk 9).
- The two intentional record-helper duplicates (`GenericOpen`'s private copies vs `SlotAttach`'s
  public ones) — do NOT try to unify them into a shared module this ticket (it would break the
  one-way dependency graph or force `State` impure). Unification is a follow-up.
- Changing any timeout/interval/percent literal, `GenServer.reply` placement, queue drain rate
  (1 per `:slot_ready`), the 60 s/65 s/30 s/150 ms lattice, PubSub message shapes, tmux command
  strings, perf event names, or `aiur_pane_manager phase=…` log-line formats.
- The already-extracted T-044 modules (`State`, `OpenQueue`, `Anchor`, `ScreenGrab`, `Layout`) —
  you call them and add `Layout`/`State`/`OpenQueue`/`SlotAttach` aliases, but you do not edit
  `state.ex`, `open_queue.ex`, `anchor.ex`, `screen_grab.ex`, or `layout.ex`, and you do not touch
  `Layout.build/6` or `Layout.apply/1`.
- `debug_mode?/0` stays in the shell (used by the `:tmux_event` catch-all) — do not move it.
- `src/lib/aiur/tmux.ex`, `src/lib/aiur/opencode/*` (Slot, AttachPool, SlotRegistry, SlotPolicy,
  SlotSupervisor, HiddenWindow), `src/lib/aiur/agent_list/*`, `src/lib/aiur.ex`.
- `src/test/aiur/pane_manager_test.exs`, `src/test/aiur/pane_manager_live_test.exs` — read-only;
  they pin the public API and must pass byte-identical.
- Every `regression/` file EXCEPT the two named source-path repoints in steps 10 and 13; and even
  in those two, only the `@*_source` path constants, the `defp`→`def` split markers, and which
  `File.read!` each assertion targets may change — never an assertion body or its failure message.
- The coverage `ignore_modules` list in `src/mix.exs` — do not add entries (it only ever shrinks).

## Inventory-IDs

From `docs/refactor/feature-inventory/tui.md` (the FI IDs these Files implement):

- FI-TUI-018 — open idempotence path (`{:open}` head stays in shell; delegates to `OpencodeOpen.do_open`)
- FI-TUI-019 — warm-open lock-free fast path via `SlotRegistry` ETS (`open_opencode_pane`,
  `move_warm_pane_visible` → `OpencodeOpen`; risk 1)
- FI-TUI-020 — `AttachPool.consume` slow path with window-0 exclusion (`open_opencode_pane` → `OpencodeOpen`)
- FI-TUI-021 — instant placeholder pane + async real-attach swap (`open_with_placeholder`,
  `spawn_placeholder_pane`, `:placeholder_swap`/`:placeholder_failed` bodies → `Placeholder`)
- FI-TUI-022 — open queue 60 s timeout + duplicate refusal (`enqueue_open` → `Placeholder`;
  `drain_open_queue`/`drain_open_entry` stay in shell)
- FI-TUI-023 — close vs hide semantics for slot panes (`hide_slot_pane`, `close_opencode_or_generic`,
  `slot_for_pane` → `Close`; risk 6)
- FI-TUI-024 — `agent_inactive` auto-closes the pane (shell head stays; delegates to
  `Close.close_opencode_or_generic`)
- FI-TUI-025 — `%pane-died` handling with focus restoration (`handle_pane_closed`,
  `refocus_agent_list_if_focused` → `Reconcile`; risk 8)
- FI-TUI-026 — visible-pane reconciliation before opens (`reconcile_visible_panes` and helpers →
  `Reconcile`; risk 12)
- FI-TUI-027 — `attach_conversation` rebinds the focused pane's slot (`attach_to_focused_pane`,
  `attach_identifier_to_slot` → `SlotAttach`)
- FI-TUI-029 — `pane_opened`/`pane_closed` broadcast contract (parity across `Close`, `Reconcile`,
  `SlotAttach`, `OpencodeOpen`, `Placeholder`; risk 7)
- FI-TUI-030 — `convo_first_paint` detection (`detect_convo_first_paint` and helpers → `ConvoPaint`;
  risk 13)
- FI-TUI-031 — generic-pane distribution wrapping (unique BEAM node) (`open_generic_pane`,
  `wrap_with_unique_node`, `open_in_slot`, `replace_in_slot`, `create_pane_for_slot`,
  `read_erlang_cookie` → `GenericOpen`; risk 14)
- FI-TUI-032 — lazy slot expansion bump (`bump_next_slot` → `SlotAttach`; risk 11)
- FI-TUI-003 — mock tmux transport seam (test dependency only; `tmux.ex` untouched)

## Characterization-tests

Under `src/test/aiur/regression/`:

- `time_to_paint_test.exs` — source-pin wiring guard. Its three moved-string assertions repoint to
  `pane_manager/placeholder.ex` in step 10 (path constant only; messages byte-identical); the
  `def handle_info({:placeholder_swap,` assertion keeps hitting `pane_manager.ex`. Pins risks 2 & 3.
- `enter_opens_new_pane_test.exs` — source-pin wiring guard. Its `find_visible`-before-`consume`
  ordering test repoints to `pane_manager/opencode_open.ex` and flips two `defp`→`def` split markers
  in step 13 (targeting only; ordering assertion byte-identical). Pins risk 1.
- `done_agent_detach_test.exs` — pins the `AttachPool`-topic subscribe in `init/1` (stays in shell),
  `handle_info({:agent_inactive,` (stays in shell), and the `close_opencode_or_generic(state,
  identifier, pane_id)` call substring (still present because the shell calls
  `Close.close_opencode_or_generic(state, identifier, pane_id)`). Must pass **unchanged**.
- `chat_open_perf_test.exs` — reads `log/aiur.log` for `aiur_pane_manager phase=open_visible …
  open_ms=…`; that line moves into `SlotAttach` verbatim and is still logged identically. Must pass
  **unchanged**.
- `warm_attach_open_test.exs` is `@describetag :skip` (retired by issue #85) — do not resurrect its
  patterns.

Behavioral nets outside `regression/`: `src/test/aiur/pane_manager_test.exs` (513 lines, mock tmux —
the strongest pin; drives the public API only) and `src/test/aiur/pane_manager_live_test.exs`
(`:live_tmux`). Both must pass byte-identical.

## Acceptance criteria

- All seven new module files exist with exact names:
  `grep -l "defmodule Aiur.PaneManager.GenericOpen do" src/lib/aiur/pane_manager/generic_open.ex`,
  and likewise `Close`→`close.ex`, `Reconcile`→`reconcile.ex`, `SlotAttach`→`slot_attach.ex`,
  `ConvoPaint`→`convo_paint.ex`, `Placeholder`→`placeholder.ex`, `OpencodeOpen`→`opencode_open.ex`
  each print their path.
- The shell no longer defines the moved functions:
  `grep -cE "defp (open_generic_pane|open_in_slot|replace_in_slot|create_pane_for_slot|wrap_with_unique_node|read_erlang_cookie|hide_slot_pane|close_opencode_or_generic|slot_for_pane|handle_pane_closed|refocus_agent_list_if_focused|reconcile_visible_panes|drop_stale_tracked_panes|release_stale_visible_pane|drop_stale_placeholders|attach_identifier_to_slot|handle_pane_move_error|pane_already_visible_reason\?|attach_to_focused_pane|reply_or_noreply|bump_next_slot|record_slot_pane|record_placeholder|set_pane_title|detect_convo_first_paint|do_detect_convo_paint|wait_and_retry_convo_paint|open_with_placeholder|spawn_placeholder_pane|horizontal_orientation|drive_real_attach|wait_then_select_for_placeholder|perform_select_for_placeholder|wait_for_slot|do_wait_for_slot|enqueue_open|do_open|open_opencode_pane|move_warm_pane_visible)\(" src/lib/aiur/pane_manager.ex`
  prints `0`, and `grep -cE "@convo_paint_poll_interval_ms|@convo_paint_budget_ms" src/lib/aiur/pane_manager.ex` prints `0`.
- The shell keeps exactly its retained seams:
  `grep -cE "defp (drain_open_queue|drain_open_entry|debug_mode\?)\(?" src/lib/aiur/pane_manager.ex` prints `3`.
- The two grepped strings that must stay in the shell each match at least once against
  `src/lib/aiur/pane_manager.ex`: `def handle_info({:placeholder_swap,` and the substring
  `close_opencode_or_generic(state, identifier, pane_id)`.
- The two moved-out source markers now live in the new files:
  `grep -c "def open_opencode_pane(state, identifier, _opts, from) do" src/lib/aiur/pane_manager/opencode_open.ex` prints `1`;
  `grep -c "def move_warm_pane_visible" src/lib/aiur/pane_manager/opencode_open.ex` prints `1`;
  `grep -c "spawn_placeholder_pane(state, identifier)" src/lib/aiur/pane_manager/placeholder.ex` ≥ 1;
  `grep -c "swap-pane -s #{real_pane_id} -t #{placeholder_pane_id}" src/lib/aiur/pane_manager/placeholder.ex` ≥ 1.
- Public API unchanged:
  `grep -cE "def (open_conversation|close_conversation|hide_by_pane_id|attach_conversation|list_open_panes|orientation|toggle_orientation|start_link)" src/lib/aiur/pane_manager.ex` prints `8`.
- Lock-free ordering preserved: in `src/lib/aiur/pane_manager/opencode_open.ex`, the first byte
  offset of `SlotRegistry.find_visible` is less than that of `AttachPool.consume` (the
  `enter_opens_new_pane_test.exs` ordering assertion, repointed, encodes this and passes).
- Load-bearing strings preserved verbatim:
  `grep -c "proto_dist inet_tcp" src/lib/aiur/pane_manager/generic_open.ex` ≥ 1;
  `grep -c "Build · issue-" src/lib/aiur/pane_manager/convo_paint.ex` ≥ 1;
  `grep -c "source and target panes must be different" src/lib/aiur/pane_manager/slot_attach.ex` ≥ 1;
  `grep -c "aiur_pane_manager phase=open_visible" src/lib/aiur/pane_manager/slot_attach.ex` ≥ 1.
- Timing literals preserved: `grep -c "30_000" src/lib/aiur/pane_manager/convo_paint.ex` ≥ 1;
  `grep -c "65_000" src/lib/aiur/pane_manager.ex` prints `2` (the two public-API call timeouts).
- Size norms: `wc -l` ≤ 200 for `generic_open.ex`, `close.ex`, `reconcile.ex`, `convo_paint.ex`;
  ≤ 210 for `slot_attach.ex`; ≤ 230 for `opencode_open.ex`; ≤ 260 for `placeholder.ex` (the last two
  carry moved comment blocks + `@moduledoc` + `@spec`s that make 200 unreachable verbatim — do not
  trim comments to chase it). `wc -l src/lib/aiur/pane_manager.ex` **≤ 320** (target ~280). New
  helper functions you add (the record-helper copies) are ≤ 20 logic lines; the verbatim-moved
  bodies are NOT resized — several (`open_opencode_pane`, `move_warm_pane_visible`,
  `close_opencode_or_generic`, `handle_swap`, `open_with_placeholder`) legitimately exceed 20
  logic lines and MUST be moved intact (splitting them is a behavior-risk and is out of scope;
  the 20-line norm is waived for verbatim moves, same as the file-size exceptions above).
- Docs/specs: each new module has ≥ 1 `@moduledoc` and a `@spec` for every public `def`
  (`mix dialyzer` passes). `grep -c "@spec" …` ≥: generic_open 2, reconcile 3, close 2, convo_paint 1,
  slot_attach 7, placeholder 4, opencode_open 3.
- Tests exist for every extracted module: the seven new `_test.exs` files exist and
  `mix test test/aiur/pane_manager/` is green.
- Coverage exemptions unchanged: `git diff origin/v2 -- src/mix.exs` is empty.
- Regression edits are surgical: `git diff origin/v2 -- src/test/aiur/regression/time_to_paint_test.exs
  src/test/aiur/regression/enter_opens_new_pane_test.exs` shows ONLY added `@*_source` path constants,
  changed `File.read!` targets, and the two `defp`→`def` split-marker regex edits — no assertion body
  or message changed. No other file under `src/test/aiur/regression/` appears in
  `git diff --name-only origin/v2...HEAD`.
- `git diff --name-only origin/v2...HEAD` lists exactly the 16 files in the Files section — nothing else.
- Full suite green: `mix test` from `src/` passes with 0 failures (regression suite included).

## Verification

### Agent gate (run all, from src/)

```
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
```

### At-merge (reviewer)

- Diff review: confirm the diff is move-only for the extracted bodies (each deleted block in
  `pane_manager.ex` reappears byte-similar in its new module; only `defp`→`def`, module prefixes,
  and the documented record-helper duplication differ). Confirm the two `regression/` edits touch
  only path constants + split markers, and no other `regression/` file or `src/mix.exs` is in the diff.
- Run every Acceptance-criteria grep verbatim; all must match.
- From `src/`: `mix test test/aiur/pane_manager_test.exs test/aiur/pane_manager/ test/aiur/regression/ --seed 0`
  and again `--seed 1` — both green.
- If a live tmux is available: `mix test test/aiur/pane_manager_live_test.exs --include live_tmux` —
  green (grid geometry, round-robin reuse, orientation round-trip unchanged).
- Check: FI-TUI-019 (risk 1) — press Enter on a warm (⚪) agent row: the chat pane appears sub-second
  with no placeholder loading screen (perf logs show `warm_open_registry_hit` + the warm move, not
  `placeholder_spawn`). Proves the lock-free ordering survived the move.
- Check: FI-TUI-021 (risks 2 & 3) — press Enter on a cold (⏳) agent row: a loading placeholder
  appears in < ~500 ms, then the real opencode pane swaps into the same grid slot (no flash, no
  selection jump).
- Check: FI-TUI-023 (risk 6) — Ctrl+Q hides a chat pane and reopening from the list is instant (no
  respawn); `close` (from the list) frees the slot for the next agent.
- Check: FI-TUI-025 (risk 8) — kill the focused chat pane (Ctrl+C→close): focus returns to the agent
  list (j/k work); kill a background chat pane: focus does NOT jump.
- Check: FI-TUI-029/030 — `aiur_pane_manager phase=…` and `aiur_perf … convo_first_paint` lines retain
  their exact field layout (compare against a pre-merge log); the 🟢 marker tracks open/close on every
  path.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
