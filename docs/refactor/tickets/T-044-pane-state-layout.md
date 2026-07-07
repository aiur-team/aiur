# T-044: pane_manager wave 1: State, OpenQueue, Anchor, ScreenGrab, Layout

**Phase:** 4
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:4` `complexity:3`

## Problem / context

`src/lib/aiur/pane_manager.ex` is a 1,839-line GenServer that owns the identifier↔pane↔slot maps, the pending-open queue, anchor-pane resolution, the AIUR_SCREEN_GRAB diagnostics loop, and layout application — all in one module. `docs/refactor/research-arch/giant-pane_manager.md` defines the binding name map for its decomposition into the existing `Aiur.PaneManager.*` namespace (`src/lib/aiur/pane_manager/`, where `layout.ex` already lives). This ticket is wave 1 of 2 (T-045 is wave 2): extract the low-risk pure/side seams — `State`, `OpenQueue`, `Anchor`, `ScreenGrab`, and `Layout.apply` — corresponding to the research doc's extraction waves 1 and 2.

This is a code-location refactor, not a redesign. tmux timing races are the historical risk here (hotspot map rows 5 and 13 in `docs/refactor/research-history-hotspots.md`: warm-attach races, the #34→#51→#61→#77 slot-cycling chain, stale layout state). Every sequencing, retry, timeout, and broadcast is preserved verbatim. The GenServer shell (`Aiur.PaneManager`) remains the registered process, keeps all `handle_call`/`handle_info` heads, all timers, all `GenServer.reply` calls, and all PubSub subscriptions; extracted modules are pure transforms (`State`, `OpenQueue`) or thin side-effect seams called from the shell (`Anchor`, `ScreenGrab`, `Layout.apply`). Callers (`src/lib/aiur.ex:82` supervision, `src/lib/aiur/agent_list/app.ex`, `src/lib/aiur_web/controllers/observability_api_controller.ex`, all tests) see zero public-API change.

## Scope (exact)

Line numbers refer to `src/lib/aiur/pane_manager.ex` at the current tip of `v2` (1,839 lines). Move code verbatim — cut/paste including the attached comments; do not rewrite bodies, rename variables, reword log strings, or change any timeout/interval literal. Do the work as two commits in this order, with a green `mix compile --warnings-as-errors && mix test` (from `src/`) after each: commit 1 = steps 1–3 (State + OpenQueue), commit 2 = steps 4–7 (Anchor + ScreenGrab + Layout.apply).

1. **Create `src/lib/aiur/pane_manager/state.ex` — module `Aiur.PaneManager.State`.**
   - Move the entire `defstruct` block (lines 60–94, all fields and their comments, verbatim) from `Aiur.PaneManager` into `State`. Add `@type t :: %__MODULE__{}` plus `@type agent_id :: Aiur.AgentEvents.agent_identifier()` and `@type pane_id :: String.t()` (mirrors of the shell's types; the shell keeps its own).
   - Move these functions verbatim, changing each `defp` to `def`, and every `%__MODULE__{}` pattern inside them stays `%__MODULE__{}` (it now means `%State{}`):
     - `remember_title/3` (1597–1605), `pane_title_text/2` (1617–1622), `scrub_title/1` (1624–1631, keep `defp` — private helper of `pane_title_text`),
     - `forget_identifier_for_pane/2` (1633–1645), `forget_pane_by_identifier/2` (1647–1673), `forget_dead_slot/2` (1675–1680),
     - `drop_placeholder/2` (1137–1140), `drop_placeholder_by_pane/2` (1774–1781),
     - `advance_cycle/1` (1446–1448),
     - `slot_panes_list/1` (1532–1546 incl. comment), `visible_panes_packed/1` (1548–1560 incl. comment), `first_available_visual_slot/1` (1562–1570), `slot_count/1` (1572), `empty_slot_panes/1` (1574–1576).
   - Split the two record functions exactly as the research doc directs (its "Design notes" bullet 1): `State` gets the PURE map transform, the shell keeps the tmux title side effect so title-set ordering at every call site is unchanged.
     - `State.record_slot_pane/4` = lines 1580–1591 MINUS the `set_pane_title(new_state, pane_id, identifier)` call: the four `Map.put` updates, returning `new_state`.
     - `State.record_placeholder/4` = lines 1123–1135 MINUS the `set_pane_title(new_state, placeholder_pane_id, identifier)` call.
   - Public signatures (write these `@spec`s exactly; every public `def` gets one):
     ```elixir
     @spec record_slot_pane(t(), pos_integer(), pane_id(), agent_id()) :: t()
     @spec record_placeholder(t(), agent_id(), pane_id(), pos_integer()) :: t()
     @spec drop_placeholder(t(), agent_id()) :: t()
     @spec drop_placeholder_by_pane(t(), pane_id()) :: t()
     @spec remember_title(t(), agent_id(), keyword()) :: t()
     @spec pane_title_text(t(), agent_id()) :: String.t()
     @spec forget_identifier_for_pane(t(), pane_id()) :: t()
     @spec forget_pane_by_identifier(t(), pane_id()) :: t()
     @spec forget_dead_slot(t(), pos_integer()) :: t()
     @spec advance_cycle(t()) :: t()
     @spec slot_panes_list(t()) :: [pane_id() | nil]
     @spec visible_panes_packed(t()) :: [pane_id() | nil]
     @spec first_available_visual_slot(t()) :: pos_integer() | nil
     @spec slot_count(pos_integer()) :: pos_integer()
     @spec empty_slot_panes(pos_integer()) :: %{optional(pos_integer()) => nil}
     ```
   - `State` imports/aliases nothing except what the moved code needs (it is pure: no `Tmux`, no `Logger`, no PubSub).

2. **Create `src/lib/aiur/pane_manager/open_queue.ex` — module `Aiur.PaneManager.OpenQueue`.** Pure queue/timer-map data ops only. Timer creation (`Process.send_after`), timer cancellation, `GenServer.reply`, and all `Logger` lines stay in the shell.
   - Move `@open_queue_timeout_ms 60_000` with its comment (lines 98–103) into `OpenQueue`; expose it as `def timeout_ms, do: @open_queue_timeout_ms`. Do NOT change the value — the timeout lattice (caller call timeout 65 s > queue timeout 60 s) is load-bearing (research doc risk 4).
   - Write exactly these four functions:
     ```elixir
     @spec timeout_ms() :: pos_integer()
     def timeout_ms

     @spec queued?(%{optional(String.t()) => reference()}, String.t()) :: boolean()
     def queued?(timers, identifier)          # Map.has_key?(timers, identifier)

     @spec enqueue(:queue.queue(), map(), String.t(), GenServer.from(), reference()) ::
             {:queue.queue(), map()}
     def enqueue(queue, timers, identifier, from, timer_ref)
     # {:queue.in({identifier, from, timer_ref}, queue), Map.put(timers, identifier, timer_ref)}

     @spec pop(:queue.queue()) :: :empty | {tuple(), :queue.queue()}
     def pop(queue)
     # case :queue.out(queue) do {:empty, _} -> :empty; {{:value, entry}, rest} -> {entry, rest} end

     @spec pluck(:queue.queue(), map(), String.t()) ::
             :not_queued | {GenServer.from(), :queue.queue(), map()}
     def pluck(queue, timers, identifier)
     ```
   - `pluck/3` body: move the logic of the `:open_queue_timeout` handler (472–503) verbatim minus logging/reply/state-update: if `Map.fetch(timers, identifier)` is `:error`, return `:not_queued` (timer fired after drain — legal race, no-op; keep the comment). Otherwise run the exact `Enum.reduce` queue walk from lines 481–487; if `dropped_from` is `nil` return `:not_queued` (do NOT delete the timer entry in this branch — current behavior); else return `{from, :queue.from_list(Enum.reverse(entries)), Map.delete(timers, identifier)}`.

3. **Rewire the shell (`src/lib/aiur/pane_manager.ex`) for State + OpenQueue.**
   - Change the alias line 55 to `alias Aiur.PaneManager.{Anchor, Layout, OpenQueue, ScreenGrab, State}` (Anchor/ScreenGrab are created in steps 4–5; if committing step 3 first, add them in that commit's alias anyway only if the compiler allows — otherwise extend the alias in commit 2).
   - Delete the moved `defstruct` and functions from the shell. In `init/1`, `%__MODULE__{...}` (line 253) becomes `%State{...}`; `slot_count(max_vertical_panes)` (214) becomes `State.slot_count(max_vertical_panes)`; `empty_slot_panes(slot_count)` (259) becomes `State.empty_slot_panes(slot_count)`.
   - Keep these three compositions in the shell (side-effect ordering unchanged — the title set fires immediately after the map update, exactly as today):
     ```elixir
     defp record_slot_pane(state, slot, pane_id, identifier) do
       new_state = State.record_slot_pane(state, slot, pane_id, identifier)
       set_pane_title(new_state, pane_id, identifier)
       new_state
     end

     defp record_placeholder(state, identifier, placeholder_pane_id, slot) do
       new_state = State.record_placeholder(state, identifier, placeholder_pane_id, slot)
       set_pane_title(new_state, placeholder_pane_id, identifier)
       new_state
     end

     defp set_pane_title(state, pane_id, identifier) do
       _ = Tmux.set_pane_title(state.tmux, pane_id, State.pane_title_text(state, identifier))
       :ok
     end
     ```
     Every existing call site of `record_slot_pane`/`record_placeholder`/`set_pane_title` in the shell then needs NO edit (533, 957, 995, 1046, 1318, 1357, 1471, 1488, 1133, 1589).
   - Prefix every remaining shell call to a moved State function with `State.` — the sites are: 301, 318, 327 (`remember_title`, `forget_pane_by_identifier`), 417, 779, 812, 838, 1407, 1470, 1478, 1686, 1696–1697, 1761, 1770, 1778 (`forget_*`, `drop_placeholder*`), 535, 573, 589 (`drop_placeholder`), 866 (`advance_cycle`), 1030 (`first_available_visual_slot`), 1506 (`visible_panes_packed` — moves into Layout in step 6), 1564 (internal to State already). Use the compiler: after deleting, `mix compile --warnings-as-errors` reports every missed site as undefined function — fix all, add none.
   - Rewrite exactly three queue sites in the shell:
     - `enqueue_open/3` (1424–1444) becomes: `if OpenQueue.queued?(state.open_queue_timers, identifier)` → keep the duplicate-refusal branch and comment returning `{:reply, {:error, :already_queued}, state}`; else `timer_ref = Process.send_after(self(), {:open_queue_timeout, identifier}, OpenQueue.timeout_ms())`, then `{new_queue, new_timers} = OpenQueue.enqueue(state.open_queue, state.open_queue_timers, identifier, from, timer_ref)`, then the existing struct update, `Logger.info` line (unchanged text, still `:queue.len(new_queue)`), and `{:noreply, new_state}`.
     - `drain_open_queue/1` (701–706) becomes a `case OpenQueue.pop(state.open_queue)` with branches `:empty -> state` and `{entry, rest} -> drain_open_entry(state, entry, rest)`. Keep its comment ("v1: drains 1 entry per broadcast" — research doc risk 5; never drain more).
     - `handle_info({:open_queue_timeout, identifier}, state)` (472–503) becomes a `case OpenQueue.pluck(state.open_queue, state.open_queue_timers, identifier)`: `:not_queued -> {:noreply, state}`; `{from, new_queue, new_timers} ->` the existing `Logger.warning` (replace `#{@open_queue_timeout_ms}` with `#{OpenQueue.timeout_ms()}`), then `GenServer.reply(from, {:error, :no_ready_slot})`, then `{:noreply, %{state | open_queue: new_queue, open_queue_timers: new_timers}}`.
   - `drain_open_entry/3` (708–727) stays in the shell verbatim, including `Process.cancel_timer`, the `Map.delete` on timers, and the `{:error, :no_ready_slot} -> state` leave-it-queued race branch (research doc risk 4).

4. **Create `src/lib/aiur/pane_manager/anchor.ex` — module `Aiur.PaneManager.Anchor`.**
   - Move verbatim: `resolve_agent_list_pane/2` (731–742), `env_pane/0` (744–749, stays `defp`), `resolve_window_target/3` (751–756), `publish_control_url/1` (273–289 incl. the best-effort comment and the `rescue`), `control_url_host/0` (291–296, stays `defp`). Public defs: `resolve_agent_list_pane/2`, `resolve_window_target/3`, `publish_control_url/1`, changed `defp`→`def`, with specs:
     ```elixir
     @spec resolve_agent_list_pane(keyword(), GenServer.server()) :: {:ok, String.t()} | {:error, term()}
     @spec resolve_window_target(keyword(), GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, term()}
     @spec publish_control_url(GenServer.server()) :: :ok
     ```
   - Module needs `require Logger` and `alias Aiur.Tmux`. The resolution precedence (opts → `$TMUX_PANE` → `Tmux.resolve_self_pane`) and the fail-closed contract must not change: `init/1` in the shell keeps its `with` and still returns `{:stop, :no_agent_list_pane}` on failure (research doc risk 10, issue #34 root cause) — only the two `with` clauses gain the `Anchor.` prefix, and `publish_control_url(tmux)` (241) becomes `Anchor.publish_control_url(tmux)`.

5. **Create `src/lib/aiur/pane_manager/screen_grab.ex` — module `Aiur.PaneManager.ScreenGrab`.**
   - Move verbatim: `@screen_grab_interval_ms 2_000` and `@screen_grab_max_lines 8` with their comment block (105–112), `log_screen_grab/1` (614–622), both `log_pane_grab/3` clauses (624–647 incl. the dead-server demotion comment, stay `defp`), `dead_tmux?/1` (649–655 incl. comment), `collect_tracked_panes/1` (657–673), `screen_grab?/0` (685–696 incl. comment). Public defs with specs:
     ```elixir
     @spec interval_ms() :: pos_integer()   # def interval_ms, do: @screen_grab_interval_ms
     @spec screen_grab?() :: boolean()
     @spec log_screen_grab(Aiur.PaneManager.State.t()) :: :ok
     @spec collect_tracked_panes(Aiur.PaneManager.State.t()) :: %{optional(String.t()) => String.t()}
     @spec dead_tmux?(term()) :: boolean()
     ```
   - Module needs `require Logger` and `alias Aiur.{Boot, Tmux}`. Gating stays on `AIUR_SCREEN_GRAB` and must remain independent of `AIUR_DEBUG` (research doc risk 15, `:emfile` fan-out class #409/#457) — the moved comments say exactly this; keep them.
   - Shell rewires: `init/1` line 248–250 becomes `if ScreenGrab.screen_grab?() do Process.send_after(self(), :screen_grab_tick, ScreenGrab.interval_ms()) end`; `handle_info(:screen_grab_tick, state)` (602–610) stays in the shell, delegating to `ScreenGrab.log_screen_grab(state)` / `ScreenGrab.screen_grab?()` / `ScreenGrab.interval_ms()`.
   - `debug_mode?/0` (675–683) STAYS in the shell (used by the `:tmux_event` catch-all at 594–600) — the name map keeps it there. Do not move it into ScreenGrab.

6. **Extend `src/lib/aiur/pane_manager/layout.ex` (existing module `Aiur.PaneManager.Layout`).**
   - Add `def apply(state)` = the body of `apply_layout/1` (1498–1517) verbatim, with `visible_panes_packed(state)` → `State.visible_panes_packed(state)` and `log_layout_apply(...)` now a local `defp`. Spec: `@spec apply(Aiur.PaneManager.State.t()) :: :ok | {:error, term()}`. (`apply/1` does not clash with `Kernel.apply/2,3` — different arity.)
   - Add `defp log_layout_apply/4` = lines 1519–1530 verbatim, plus a private copy of `debug_mode?/0` (verbatim body of 675–683) for its gate — per-module private `AIUR_DEBUG` readers are the existing house pattern (`slot.ex:491`, `agent_list/app.ex:1150`); do NOT import it from the shell (that would invert the dependency direction).
   - `Layout.build/6` and everything else in `layout.ex` is untouched.
   - Module needs `require Logger`, `alias Aiur.Tmux`, `alias Aiur.PaneManager.State` added to `layout.ex` as required by the moved code.
   - Shell: delete `apply_layout/1` and `log_layout_apply/4`; replace every `apply_layout(` call with `Layout.apply(` — sites: 384, 429, 537, 590, 780, 813, 839, 865, 960, plus the ones inside 1024–1092, 1293–1422, 1682–1702 regions (again: let `mix compile --warnings-as-errors` enumerate them; the call must stay at the exact same point in each sequence — layout re-application after every mutation is half of the #34-chain fix, research doc risk 10).

7. **Tests.** Create one test file per extracted module (new modules are NOT coverage-exempt; do not add any module to `ignore_modules` in `src/mix.exs`):
   - `src/test/aiur/pane_manager/state_test.exs` (`async: true`, pure): `record_slot_pane` populates all four maps; `forget_pane_by_identifier` clears both directions + title + nils the slot; `forget_identifier_for_pane` deletes only `identifier_to_pane` + title (pin the asymmetry: `pane_to_identifier` keeps the entry); `forget_dead_slot` no-ops on an empty slot; `remember_title` stores only non-blank binaries; `pane_title_text` returns `"<id> <title>"` with control chars (CR/LF/tab) collapsed to spaces, bare id when no title; `record_placeholder`/`drop_placeholder`/`drop_placeholder_by_pane` round-trip; `advance_cycle` wraps at `slot_count`; `slot_panes_list` overlays placeholders on slot indexes; `visible_panes_packed` packs left-to-right and pads with nils (the "chat opens under the agent list" fix); `first_available_visual_slot` returns the first nil index + 1 and nil when full; `slot_count(3) == 5`; `empty_slot_panes(5)` has keys 1..5 all nil.
   - `src/test/aiur/pane_manager/open_queue_test.exs` (`async: true`, pure): `queued?` true/false; `enqueue` appends FIFO and records the timer; `pop` on empty → `:empty`, otherwise first-in entry + rest; `pluck` with identifier absent from timers → `:not_queued`; `pluck` with identifier in timers but not in the queue → `:not_queued` (timers map NOT mutated); `pluck` middle entry → returns its `from`, remaining entries keep order, timer entry deleted; `timeout_ms() == 60_000`.
   - `src/test/aiur/pane_manager/anchor_test.exs` (`async: false` — it touches `TMUX_PANE`; save/restore the env var in `setup` with `on_exit`): opts `:agent_list_pane` wins even when `TMUX_PANE` is set; `TMUX_PANE` used when opts absent; empty-string `TMUX_PANE` falls through; `resolve_window_target` returns opts `:window_target` when non-empty binary; `publish_control_url/1` returns `:ok` in the test env (dashboard unbound — the best-effort rescue path).
   - `src/test/aiur/pane_manager/screen_grab_test.exs` (`async: false` — touches `AIUR_SCREEN_GRAB`; save/restore in `setup`): `screen_grab?()` true for `"1"`/`"true"`/`" YES "`, false for `"0"`/unset; `dead_tmux?` true only for binaries containing `"no server running"`; `collect_tracked_panes` labels the anchor `"agent_list"`, slot panes `"slot<N>:<identifier>"` (unknown identifier → `"?"`), skips nil slots; `interval_ms() == 2_000`.
   - Extend `src/test/aiur/pane_manager/layout_test.exs` with a new `describe "apply/1"` block (2 tests) using the mock transport seam exactly as `src/test/aiur/pane_manager_test.exs` does (start `{Aiur.Tmux, [transport: {:mock, self()}, name: ..., session: "test"]}`, reply with `%begin/%end`-framed chunks): (a) happy path — respond to the window-size query, then assert the next `{:tmux_mock_out, cmd}` is a `select-layout` against the state's `window_target` whose layout string equals `Layout.build/6` for the same inputs, and `Layout.apply/1` returns `:ok`; (b) window-size query answered with a `%error` frame → returns `{:error, _}`. Build the `%State{}` fixtures directly. Read `Aiur.Tmux.window_size/2` first to craft the mock reply shape. Every `Layout.build/6` test already present stays byte-identical.

8. **Run the full Agent gate** (below). Then confirm the wave-1 no-touch pins: all six strings in the Acceptance criteria "pins" bullet still appear in `src/lib/aiur/pane_manager.ex` — they belong to functions that move in T-045, not here.

## Files

- Create: `src/lib/aiur/pane_manager/state.ex`, `src/lib/aiur/pane_manager/open_queue.ex`, `src/lib/aiur/pane_manager/anchor.ex`, `src/lib/aiur/pane_manager/screen_grab.ex`, `src/test/aiur/pane_manager/state_test.exs`, `src/test/aiur/pane_manager/open_queue_test.exs`, `src/test/aiur/pane_manager/anchor_test.exs`, `src/test/aiur/pane_manager/screen_grab_test.exs`
- Modify: `src/lib/aiur/pane_manager.ex`, `src/lib/aiur/pane_manager/layout.ex`, `src/test/aiur/pane_manager/layout_test.exs`
- Test: `src/test/aiur/pane_manager/state_test.exs`, `src/test/aiur/pane_manager/open_queue_test.exs`, `src/test/aiur/pane_manager/anchor_test.exs`, `src/test/aiur/pane_manager/screen_grab_test.exs`, `src/test/aiur/pane_manager/layout_test.exs`, `src/test/aiur/pane_manager_test.exs` (must pass unchanged), `src/test/aiur/pane_manager_live_test.exs` (`:live_tmux`, unchanged)

## Out of scope

- The wave-2 extractions (T-045): `GenericOpen`, `Close`, `Reconcile`, `SlotAttach`, `ConvoPaint`, `Placeholder`, `OpencodeOpen`. `open_opencode_pane`, `move_warm_pane_visible`, `open_with_placeholder`, `drive_real_attach`, `attach_identifier_to_slot`, `close_opencode_or_generic`, `hide_slot_pane`, `reconcile_visible_panes`, `handle_pane_closed`, `refocus_agent_list_if_focused`, `wrap_with_unique_node`, `detect_convo_first_paint` and friends all STAY in `pane_manager.ex` — only prefix their calls into State/OpenQueue/Layout.
- Unifying the five near-duplicate "pane became visible" epilogues — they differ deliberately in `apply_layout` and perf events; MOVE nothing, UNIFY nothing (research doc design note 3, risk 9).
- Any change to timers, `GenServer.reply` placement, queue drain rate (1 per `:slot_ready`), the 60 s/65 s timeout lattice, PubSub message shapes, tmux command strings, perf event names, or `aiur_pane_manager phase=…` log line formats (grepped by `src/test/aiur/regression/chat_open_perf_test.exs` and operator tooling).
- `src/lib/aiur/tmux.ex`, `src/lib/aiur/opencode/*` (Slot, AttachPool, SlotRegistry, SlotPolicy, SlotSupervisor, HiddenWindow), `src/lib/aiur/agent_list/*`.
- `src/test/aiur/pane_manager_test.exs` and `src/test/aiur/pane_manager_live_test.exs` — read-only; they pin the public API and must pass byte-identical.
- `src/test/aiur/regression/` — read-only, always.
- `Layout.build/6` and every existing test for it.
- The coverage `ignore_modules` list in `src/mix.exs` — do not add entries (it only ever shrinks).

## Inventory-IDs

From `docs/refactor/feature-inventory/tui.md`:

- FI-TUI-014 — anchor-pane resolution + `{:stop, :no_agent_list_pane}` fail-closed init (moves to `Anchor`; contract unchanged)
- FI-TUI-015 — `@aiur_control_url` tmux global option publication (moves to `Anchor`)
- FI-TUI-016 — deterministic slot grid via explicit `select-layout`, left-to-right packing, `slot_count` formula (`Layout.apply` + `State.visible_panes_packed`/`slot_count`)
- FI-TUI-017 — orientation toggle re-applies layout (call site now `Layout.apply/1`)
- FI-TUI-018 — open idempotence path (its `forget_pane_by_identifier` call moves to `State`)
- FI-TUI-021 — placeholder lifecycle bookkeeping (struct field + `record_placeholder`/`drop_placeholder` pure parts move to `State`; spawn/swap logic untouched)
- FI-TUI-022 — open queue, 60 s timeout, duplicate refusal, one-drain-per-`:slot_ready` (`OpenQueue`)
- FI-TUI-028 — pane border titles "<id> <title>" + control-char scrubbing (`State.remember_title`/`pane_title_text`; title side effect stays in shell)
- FI-TUI-031 — generic-pane slot round-robin (`State.advance_cycle`; node wrapping untouched)
- FI-TUI-033 — AIUR_SCREEN_GRAB tick, own flag NOT AIUR_DEBUG (`ScreenGrab`)
- FI-TUI-034 — AIUR_DEBUG layout logging + always-on `aiur_pane_manager phase=` perf lines (`log_layout_apply` moves to `Layout`; shell keeps `debug_mode?/0` and all phase log lines)
- FI-TUI-003 — mock tmux transport seam (test dependency only; `tmux.ex` untouched)

## Characterization-tests

- `src/test/aiur/regression/time_to_paint_test.exs` — pins `spawn_placeholder_pane(state, identifier)`, `Task.start(fn -> drive_real_attach`, `def handle_info({:placeholder_swap,`, and the `swap-pane -s … -t …` string against `src/lib/aiur/pane_manager.ex`. All four targets stay in the shell this wave — the test must pass UNCHANGED.
- `src/test/aiur/regression/enter_opens_new_pane_test.exs` — pins `defp open_opencode_pane(state, identifier, _opts, from) do` / `defp move_warm_pane_visible` and `SlotRegistry.find_visible`-before-`AttachPool.consume` ordering in the shell source. Untouched this wave; must pass unchanged.
- `src/test/aiur/regression/done_agent_detach_test.exs` — pins the AttachPool-topic subscribe in `init/1`, `handle_info({:agent_inactive,`, and the `close_opencode_or_generic(state, identifier, pane_id)` call substring. All stay in the shell; must pass unchanged.
- `src/test/aiur/regression/chat_open_perf_test.exs` — greps `aiur_pane_manager phase=…` log lines; all such lines keep their exact format.
- (`src/test/aiur/regression/warm_attach_open_test.exs` is `@describetag :skip` — retired by issue #85; do not resurrect its patterns.)
- Behavioral nets outside `regression/`: `src/test/aiur/pane_manager_test.exs` (513 lines, mock tmux — the strongest pin; drives the public API only) and `src/test/aiur/pane_manager_live_test.exs` (`:live_tmux`).

## Acceptance criteria

- New module files exist and declare the exact names: `grep -l "defmodule Aiur.PaneManager.State do" src/lib/aiur/pane_manager/state.ex`, `grep -l "defmodule Aiur.PaneManager.OpenQueue do" src/lib/aiur/pane_manager/open_queue.ex`, `grep -l "defmodule Aiur.PaneManager.Anchor do" src/lib/aiur/pane_manager/anchor.ex`, `grep -l "defmodule Aiur.PaneManager.ScreenGrab do" src/lib/aiur/pane_manager/screen_grab.ex` each print the path.
- `grep -c "defstruct" src/lib/aiur/pane_manager.ex` prints `0`; `grep -c "defstruct" src/lib/aiur/pane_manager/state.ex` prints `1`.
- The shell no longer defines the moved functions: `grep -cE "defp (remember_title|pane_title_text|scrub_title|forget_identifier_for_pane|forget_pane_by_identifier|forget_dead_slot|drop_placeholder|drop_placeholder_by_pane|advance_cycle|slot_panes_list|visible_panes_packed|first_available_visual_slot|empty_slot_panes|apply_layout|log_layout_apply|resolve_agent_list_pane|env_pane|resolve_window_target|publish_control_url|control_url_host|log_screen_grab|log_pane_grab|dead_tmux|collect_tracked_panes|screen_grab)" src/lib/aiur/pane_manager.ex` prints `0`, and `grep -c "@open_queue_timeout_ms\|@screen_grab_interval_ms\|@screen_grab_max_lines" src/lib/aiur/pane_manager.ex` prints `0`.
- The shell keeps its retained seams: `grep -c "defp debug_mode?" src/lib/aiur/pane_manager.ex` prints `1`; `grep -cE "defp (record_slot_pane|record_placeholder|set_pane_title|drain_open_queue|drain_open_entry|enqueue_open)\(" src/lib/aiur/pane_manager.ex` prints `6`.
- Wave-1 no-touch pins all still present in the shell — each of these greps against `src/lib/aiur/pane_manager.ex` matches at least once: `spawn_placeholder_pane(state, identifier)`, `Task.start(fn -> drive_real_attach`, `def handle_info({:placeholder_swap,`, `defp open_opencode_pane(state, identifier, _opts, from) do`, `defp move_warm_pane_visible`, `close_opencode_or_generic(state, identifier, pane_id)`.
- Public API unchanged: `grep -cE "def (open_conversation|close_conversation|hide_by_pane_id|attach_conversation|list_open_panes|orientation|toggle_orientation|start_link)" src/lib/aiur/pane_manager.ex` prints `8`.
- `Layout.apply/1` exists (`grep -c "def apply(" src/lib/aiur/pane_manager/layout.ex` prints `1`) and `Layout.build/6` is untouched (`git diff origin/v2 -- src/lib/aiur/pane_manager/layout.ex` shows no hunks inside `build/6` or its helpers — additions only).
- Timing literals preserved: `grep -c "60_000" src/lib/aiur/pane_manager/open_queue.ex` ≥ 1, `grep -c "2_000" src/lib/aiur/pane_manager/screen_grab.ex` ≥ 1, `grep -c "65_000" src/lib/aiur/pane_manager.ex` prints `2`.
- Size norms: `wc -l` ≤ 200 for `open_queue.ex`, `anchor.ex`, `screen_grab.ex`; ≤ 260 for `state.ex` (the struct's field comments move with it; 200 is not reachable verbatim — do not trim comments to chase it); `wc -l src/lib/aiur/pane_manager.ex` ≤ 1500 (down from 1839). Every function in the new files ≤ 20 logic lines (moved bodies already comply).
- Docs/specs: each new module file has ≥ 1 `@moduledoc` and a `@spec` for every public `def` (`mix dialyzer` passes; `grep -c "@spec" src/lib/aiur/pane_manager/state.ex` ≥ 15, `open_queue.ex` ≥ 5, `anchor.ex` ≥ 3, `screen_grab.ex` ≥ 5).
- Tests exist for every extracted module: the four new `_test.exs` files listed in Files exist and `mix test test/aiur/pane_manager/ test/aiur/pane_manager_test.exs` is green; `layout_test.exs` gains a `describe "apply/1"` block with ≥ 2 tests.
- Coverage exemptions unchanged: `git diff origin/v2 -- src/mix.exs` is empty (no new `ignore_modules` entries).
- `git diff --name-only origin/v2...HEAD` lists exactly the 11 files in the Files section — nothing under `src/test/aiur/regression/`, nothing else.
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

- Diff review: confirm the diff is move-only for the extracted bodies (every deleted block in `pane_manager.ex` reappears byte-similar in the new module; only `defp`→`def`, module prefixes, and the two documented record-function splits differ). Confirm no hunk touches `src/test/aiur/regression/` or `src/mix.exs`.
- Run the Acceptance-criteria greps verbatim; all must match.
- Run from `src/`: `mix test test/aiur/pane_manager_test.exs test/aiur/pane_manager/ test/aiur/regression/ --seed 0` and again with `--seed 1` — both green.
- If a live tmux is available: `mix test test/aiur/pane_manager_live_test.exs --include live_tmux` — green (grid geometry, round-robin reuse, orientation round-trip unchanged).
- Check: FI-TUI-015 — in a live session run `tmux -L "$AIUR_TMUX_SOCKET" show-options -gv @aiur_control_url` and confirm it prints the dashboard base URL.
- Check: FI-TUI-016/017 — open two chat panes, close one, press `v`: the grid re-packs left-to-right and the orientation flip re-applies immediately (no stray pane under the agent list).
- Check: FI-TUI-019 (adjacent, must not regress) — press Enter on a warm (⚪) agent row: chat pane appears sub-second with no placeholder loading screen (perf logs show the warm move, not `placeholder_spawn`) — proves no synchronous call crept into the open path.
- Check: FI-TUI-022 — perf log lines `aiur_pane_manager phase=open_queued` / `phase=open_queue_drained` / `phase=open_queue_timeout` retain their exact field layout (compare against a pre-merge log).

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
