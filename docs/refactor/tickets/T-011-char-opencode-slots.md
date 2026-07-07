# T-011: Characterization: opencode slots, attach & FD budget

**Phase:** 1
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:1` `complexity:3` `model:claude`

## Problem / context

`src/lib/aiur/opencode/` is hotspot #5 in `docs/refactor/research-history-hotspots.md`
(~17 incidents): warm-marker/attach races under multi-agent load (PR #65→#74→#83→#96),
the `:emfile` FD fan-out (#409 / PR #457, census in
`docs/measurements/2026-06-23-emfile-structural-fix-census.md`), the slot-display
TOCTOU/churn chain (#372 → PR #607 → #608), and operator messages lost in panes
(#332, recurred after 3 fixes). Phase 4 tickets T-046 (slot.ex decomposition per
`docs/refactor/research-arch/giant-slot.md`) and T-045 (PaneManager SlotAttach) will
move this code; today only `src/test/aiur/opencode/slot_test.exs` (API-edge, no live
slot) and `src/test/aiur/regression/attach_fanout_cap_test.exs` pin fragments of it.

This ticket adds ONE new characterization-test file pinning four behavior families
before any decomposition: (a) warm-marker lifecycle (paint is gated on `:slot_ready`
— the warm gate that makes Enter instant), (b) attach/reclaim under churn (the #608
TOCTOU class: surplus-slot reclamation, visible-slot preference, exclude-slot
protection), (c) FD/attach fan-out CENSUS invariants (the `:emfile` class: counts of
attaches/sessions stay within the ≈M budget, never M×N), and (d) operator-message
preservation through the slot lifecycle (the #332 class: SessionWriters survive
detach, rebuild reaps only the old generation in the documented order, the
same-identifier fast path never respawns a pane out from under a typing user).
No production code changes: characterization only.

## Scope (exact)

Read first, in this order (no edits to any of them):

1. `docs/refactor/research-arch/giant-slot.md` — section 1 (function census with line
   ranges), section 4 (risk invariants 1–11).
2. `src/lib/aiur/opencode/slot.ex` (1392 lines), `src/lib/aiur/opencode/attach_pool.ex`
   (913 lines), `src/lib/aiur/opencode/slot_policy.ex` (305 lines).
3. Existing patterns you MUST copy: `src/test/aiur/regression/attach_fanout_cap_test.exs`
   (RecordingSlot mock + census counting), `src/test/aiur/regression/warm_marker_semantics_test.exs`
   (source-pinning regex tests with explanatory failure messages),
   `src/test/aiur/opencode/slot_policy_test.exs` (private-PubSub SlotPolicy startup).

Authoring constraints (binding for every test you write):

- Never assert exact counts on shared singletons (the app's `Aiur.PubSub`,
  `SlotRegistry`, or any globally-named process). Count only calls to processes this
  test file starts itself (RecordingSlot mocks, uniquely-named AttachPool/SlotPolicy
  instances).
- Every `assert_receive` passes an explicit timeout of exactly `2000` (ms).
  `refute_receive` uses `1000`.
- NO `Process.sleep` anywhere in the file. Synchronize with `:sys.get_state/1`
  (mailbox barrier), `assert_receive`, or monitors only.
- The module is `async: false` (it registers mock slots in the global
  `SlotRegistry` and broadcasts on the global `Aiur.PubSub`).
- (Rules about `AIUR_RELEASE_NODE` pinning and `:log_file` tmp-dir isolation do not
  apply here: this file spawns no engine and starts nothing under
  `src/lib/aiur/events/`. Do not add either.)

Then:

1. Create `src/test/aiur/regression/opencode_slots_test.exs` with module
   `Aiur.Regression.OpencodeSlotsTest`. Start the file with exactly this skeleton
   (moduledoc text may be reflowed but must cite #409, #372/#607/#608, #332, and
   `docs/measurements/2026-06-23-emfile-structural-fix-census.md`):

   ```elixir
   defmodule Aiur.Regression.OpencodeSlotsTest do
     @moduledoc """
     Characterization of the opencode slot/attach layer (refactor T-011).
     Pins: warm gate before paint (:slot_ready), attach/reclaim under
     churn (#372/#607/#608 TOCTOU class), FD/attach fan-out census
     (#409 :emfile class — docs/measurements/2026-06-23-emfile-structural-fix-census.md),
     and operator-message preservation through the slot lifecycle (#332 class).
     Read-only for executor agents: if one of these tests fails, the
     production change is wrong.
     """

     use ExUnit.Case, async: false

     alias Aiur.Opencode.{AttachPool, Slot, SlotPolicy, SlotRegistry}

     @slot_source Path.expand("../../../lib/aiur/opencode/slot.ex", __DIR__)

     defmodule RecordingSlot do
       use GenServer

       def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

       @impl true
       def init(opts) do
         index = Keyword.fetch!(opts, :index)
         test = Keyword.fetch!(opts, :test)
         :ok = SlotRegistry.register_self(index)
         {:ok, %{index: index, test: test, visible: nil}}
       end

       @impl true
       def handle_call({:set_visible, identifier}, _from, state) do
         send(state.test, {:slot_call, :set_visible, state.index, identifier})
         {:reply, {:ok, "%#{state.index}"}, %{state | visible: identifier}}
       end

       def handle_call({:attach, identifier}, _from, state) do
         send(state.test, {:slot_call, :attach, state.index, identifier})
         {:reply, {:ok, :attached}, state}
       end

       def handle_call({:detach, identifier}, _from, state) do
         send(state.test, {:slot_call, :detach, state.index, identifier})
         visible = if state.visible == identifier, do: nil, else: state.visible
         {:reply, :ok, %{state | visible: visible}}
       end

       def handle_call(:snapshot, _from, state) do
         {:reply, %{visible_identifier: state.visible}, state}
       end
     end

     setup do
       {:ok, pool} =
         AttachPool.start_link(name: :"AttachPool_#{System.unique_integer([:positive])}")

       {:ok, pool: pool}
     end

     defp start_slots(test, m) do
       for index <- 1..m do
         {:ok, _} =
           start_supervised({RecordingSlot, [index: index, test: test]}, id: {:slot, index})
       end
     end

     defp announce_ready(indexes) do
       for index <- indexes do
         Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_ready, index})
       end
     end

     defp sync(pid), do: :sys.get_state(pid)

     defp pos!(block, needle) do
       {pos, _len} = :binary.match(block, needle)
       pos
     end

     defp extract!(source, regex) do
       case Regex.run(regex, source) do
         [block | _] -> block
         _ -> raise "could not extract block for #{inspect(regex)}"
       end
     end
   ```

2. Write `describe "warm gate: no paint before :slot_ready"` with exactly these
   2 tests (pins `attach_pool.ex` `kickoff_fan_out/2` lines 412–442 and the
   `fanned_out_slots` guard, struct comment lines 52–59):

   - test `"seeded identifiers are not painted until the slot broadcasts :slot_ready"`:
     seed the pool with `AttachPool.seed(pool, ["issue-1", "issue-2"])` while NO
     slots are registered; `sync(pool)`; then `start_slots(self(), 1)`;
     `refute_receive {:slot_call, _, _, _}, 1000` (registration alone must not
     paint — the warm gate is the `:slot_ready` broadcast); then
     `announce_ready([1])` and `assert_receive {:slot_call, :set_visible, 1, "issue-1"}, 2000`
     (slot 1's rotational leadoff is `active[0]`).
   - test `"a repeated :slot_ready (rebuild re-ready) never re-fires the rotational leadoff"`:
     same setup through the first `assert_receive ... set_visible`; then
     `announce_ready([1])` a second time; `sync(pool)`;
     `refute_receive {:slot_call, :set_visible, 1, _}, 1000`. Failure message must
     explain: a slot re-broadcasts `:slot_ready` after `schedule_serve_rebuild`, and
     re-firing the rotation races in-flight `set_visible` from `do_seed`, displacing
     the assignment the user just triggered.

3. Write `describe "warmth lifecycle events (4-state marker inputs)"` with exactly
   these 2 tests (pins `attach_pool.ex` `maybe_update_fully_warmed/2` lines 587–611
   and `do_mark_visible/3`/`do_clear_visible/2`; events per FI-EVT-111). In both,
   first `Phoenix.PubSub.subscribe(Aiur.PubSub, AttachPool.topic())`:

   - test `"first attach flips :slot_fully_warmed exactly once; losing the last attach drops warmth"`:
     broadcast on `Slot.slots_topic()` the tuple `{:slot_attach_added, 1, "issue-1"}`;
     `assert_receive {:slot_fully_warmed, 1}, 2000`; broadcast
     `{:slot_attach_added, 1, "issue-2"}`; `refute_receive {:slot_fully_warmed, 1}, 1000`
     (leadoff-only model: warmth == "slot has paint", threshold is `>= 1`, it must
     not re-announce); broadcast `{:slot_attach_removed, 1, "issue-1"}`;
     `refute_receive {:slot_warmth_dropped, 1}, 1000`; broadcast
     `{:slot_attach_removed, 1, "issue-2"}`;
     `assert_receive {:slot_warmth_dropped, 1}, 2000`.
   - test `"attach_state_changed carries attach_count and visible_in through mark/clear cycles"`,
     taking `%{pool: pool}`: broadcast `{:slot_attach_added, 1, "issue-1"}`;
     `assert_receive {:attach_state_changed, "issue-1", 1, nil}, 2000`;
     `assert AttachPool.attach_count(pool, "issue-1") == 1`;
     `AttachPool.mark_visible(pool, "issue-1", 1)`;
     `assert_receive {:attach_state_changed, "issue-1", 1, 1}, 2000`;
     `assert AttachPool.visible_count(pool) == 1`;
     `AttachPool.clear_visible(pool, "issue-1")`;
     `assert_receive {:attach_state_changed, "issue-1", 1, nil}, 2000`;
     `assert AttachPool.visible_count(pool) == 0`.

4. Write `describe "attach/reclaim under churn (#372/#607/#608 TOCTOU class)"` with
   exactly these 4 tests:

   - test `"free_slots_for/2 reclaim decision table"` (pure function,
     `attach_pool.ex:684-701`; the #372 reclamation contract), asserting all four rows:
     - `AttachPool.free_slots_for([{1, "issue-1"}, {2, "issue-1"}, {3, nil}], ["issue-1", "issue-2"]) == [2, 3]`
       (lowest index claims; surplus duplicate and idle slot are free)
     - `AttachPool.free_slots_for([{1, "stale"}, {2, "issue-1"}], ["issue-1"]) == [1]`
       (a slot showing a now-inactive identifier is free)
     - `AttachPool.free_slots_for([], ["issue-1"]) == []`
     - `AttachPool.free_slots_for([{1, nil}, {2, nil}], []) == [1, 2]`
   - test `"find_slot_for prefers the identifier's own visible slot (instant-open fast path)"`,
     taking `%{pool: pool}`: broadcast on `Slot.slots_topic()` in order
     `{:slot_attach_added, 1, "issue-1"}`, `{:slot_attach_added, 2, "issue-1"}`,
     `{:slot_visible_changed, 2, "issue-1"}`; `sync(pool)`;
     `assert AttachPool.find_slot_for(pool, "issue-1") == {:ok, 2}` (own visible slot
     wins over `Enum.min` — returning any other slot forces a 5–7 s respawn); then
     broadcast `{:slot_visible_changed, 2, nil}`; `sync(pool)`;
     `assert AttachPool.find_slot_for(pool, "issue-1") == {:ok, 1}` (falls back to min).
   - test `"find_slot_for honors :prefer and :exclude_slots"`, taking `%{pool: pool}`:
     same three broadcasts + `sync(pool)` as above, then assert
     `AttachPool.find_slot_for(pool, "issue-1", prefer: 1) == {:ok, 1}`,
     `AttachPool.find_slot_for(pool, "issue-1", exclude_slots: [1, 2]) == :miss`
     (a slot the user is looking at in window 0 must never be rebound), and
     `AttachPool.find_slot_for(pool, "issue-1", exclude_slots: [2]) == {:ok, 1}`.
   - test `"post-boot churn: removed identifier detaches, newcomer claims the freed slot, unpaired newcomer attaches nowhere"`,
     taking `%{pool: pool}` (pins `do_seed/3` lines 313–410: detach-removed-FIRST,
     surplus reclamation, leadoff-only fill; the #608 churn scenario):
     `Phoenix.PubSub.subscribe(Aiur.PubSub, AttachPool.topic())`;
     `start_slots(self(), 2)`; `AttachPool.seed(pool, ["issue-a", "issue-b"])`;
     `assert_receive {:slot_call, :set_visible, 1, "issue-a"}, 2000` and
     `assert_receive {:slot_call, :set_visible, 2, "issue-b"}, 2000`; simulate the
     real-Slot echo by broadcasting `{:slot_attach_added, 1, "issue-a"}` and
     `{:slot_attach_added, 2, "issue-b"}` on `Slot.slots_topic()`; `sync(pool)`;
     `AttachPool.seed(pool, ["issue-b", "issue-c", "issue-d"])`;
     `assert_receive {:slot_call, :detach, 1, "issue-a"}, 2000`;
     `assert_receive {:agent_inactive, "issue-a"}, 2000`;
     `assert_receive {:slot_call, :set_visible, 1, "issue-c"}, 2000` (the reclaimed
     slot); `refute_receive {:slot_call, :set_visible, _, "issue-d"}, 1000`;
     `refute_receive {:slot_call, :attach, _, _}, 1000`;
     `assert AttachPool.find_slot_for(pool, "issue-d") == :miss` (unpaired newcomer
     opens via the cold path, never a background attach).

5. Write `describe "FD/attach fan-out census (#409 :emfile class)"` with exactly
   these 2 tests (census contract per
   `docs/measurements/2026-06-23-emfile-structural-fix-census.md`: boot-burst handles
   scale with M slots, never M×N):

   - test `"boot census: N=6 agents x M=3 slots => exactly M set_visible, zero attach"`,
     taking `%{pool: pool}`: seed `["issue-1", ..., "issue-6"]` (N=6) BEFORE any slot
     registers; `sync(pool)`; `start_slots(self(), 3)`; `announce_ready([1, 2, 3])`;
     `assert_receive {:slot_call, :set_visible, 1, "issue-1"}, 2000`,
     `assert_receive {:slot_call, :set_visible, 2, "issue-2"}, 2000`,
     `assert_receive {:slot_call, :set_visible, 3, "issue-3"}, 2000` (rotation:
     slot i's leadoff is `active[i-1]`); then
     `refute_receive {:slot_call, :attach, _, _}, 1000` (the M×(N−1) background fill
     is the `:emfile` blow-up: 240→0 attaches at N=M=16) and
     `refute_receive {:slot_call, :set_visible, _, _}, 1000` (no extra paints); then
     for each of `"issue-4"`, `"issue-5"`, `"issue-6"`:
     `assert AttachPool.find_slot_for(pool, id) == :miss` and
     `assert AttachPool.attach_count(pool, id) == 0` (session/writer count tracks
     ≈M painted agents, not M×N).
   - test `"slot pool budget: target_count 0 boots zero slots and grow_slot refuses at max_slots"`:
     start a private PubSub via
     `start_supervised!({Phoenix.PubSub, name: pubsub_name}, id: {Phoenix.PubSub, pubsub_name})`
     with a unique `pubsub_name`, then
     `{:ok, policy} = SlotPolicy.start_link(name: unique_name, target_count: 0, max_slots: 0, pubsub: pubsub_name)`;
     assert `SlotPolicy.target_count(policy) == 0`,
     `SlotPolicy.highest_started(policy) == 0`, and
     `SlotPolicy.grow_slot(policy) == {:error, :at_capacity}` (the pool's hard cap is
     the M that bounds every FD family in the census — serves, ports, tmux polls).

6. Write `describe "operator-message preservation through slot lifecycle (#332 class)"`
   with exactly these 3 source-pinned tests reading `File.read!(@slot_source)` (live
   slots need tmux + opencode-serve; per `giant-slot.md` §4 these seams are pinned at
   source level until T-046 makes them unit-testable). Each assertion gets a
   multi-line failure message explaining the incident it guards, in the style of
   `warm_marker_semantics_test.exs`:

   - test `"detach never reaps the identifier's SessionWriter"`: extract with
     `extract!(source, ~r/def handle_call\(\{:detach, identifier\}, _from, state\) do.*?\n  end\n/s)`
     (clause at `slot.ex:600-633`); `refute block =~ "SessionWriterRegistry"` and
     `refute block =~ "reap_session_writer"`; `assert block =~ "broadcast_attach_removed"`.
     Message: the detached agent's SessionWriter must stay alive so re-attach (and any
     queued operator message in its session) survives — reaping here recreates the
     #332 lost-message class.
   - test `"set_visible same-identifier fast path returns the existing pane without respawn"`:
     `assert source =~ ~r/state\.visible_identifier == identifier and is_binary\(state\.pane_id\)/`
     (clause at `slot.ex:566-573`). Message: PaneManager's instant open depends on the
     no-op; a respawn here kills the pane a user may be typing an operator message
     into, and the `/tui/select-session` HTTP path must never be reintroduced
     (opencode kills the attach seconds after returning 200).
   - test `"deferred select reply vs fire-and-forget attach retry stay distinct contracts"`:
     extract `~r/defp drain_pending_select\(%\{pending_select: \{from, identifier\}\} = state\) do.*?\n  end\n/s`
     (`slot.ex:1180-1197`) and `assert` it contains `"GenServer.reply(from,"`; extract
     `~r/defp retry_pending_attach\(id, acc\) do.*?\n  end\n/s` (`slot.ex:1213-1234`)
     and `refute` it contains `"GenServer.reply"`. Message: `pending_select` holds a
     caller mid-`GenServer.call` across a serve rebuild (reply after `:ready` or the
     caller's open hangs); `pending_attaches` callers were already answered
     `{:error, :identifier_unknown}` — unifying the two either double-replies or
     drops the deferred reply (per `giant-slot.md` risk 5).

7. Write `describe "rebuild/watchdog invariants (source-pinned)"` with exactly these
   3 tests, same `File.read!(@slot_source)` + failure-message style:

   - test `"serve rebuild teardown order: reap writers -> stop serve -> kill pane -> delete token -> rebuild_now"`:
     extract `~r/defp do_schedule_serve_rebuild\(state, pending, next_known\) do.*?\n  end\n/s`
     (`slot.ex:1253-1298`), then assert strictly increasing `pos!/2` positions of, in
     order: `"reap_writers_for_base_url"`, `"GenServer.stop(state.server_pid"`,
     `"kill-pane -t "`, `"TokenRegistry.delete"`, `"send(self(), :rebuild_now)"`.
     Message: reap first so `DELETE /session` reaches a still-live serve (#372);
     kill the pane before clearing `pane_id` or every identifier-miss leaks a pane
     until the hidden window hits `no space for new pane`; token delete before the
     self-message keeps the `{slot_index, generation}` overlap window intact.
   - test `"pane-death watchdog: threshold 3, reset on success, cancel-before-reschedule"`:
     `assert source =~ ~r/@poll_death_threshold 3/`;
     `assert source =~ ~r/\{:ok, \[\^pane_id \| _\]\} ->\s+\{:noreply, schedule_poll\(%\{state \| poll_death_count: 0\}\)\}/`
     (success resets the debounce, `slot.ex:685-687`); extract
     `~r/defp schedule_poll\(%\{status: :active\} = state\) do.*?\n  end\n/s`
     (`slot.ex:1340-1350`) and assert `pos!(block, "cancel_poll(state.poll_ref)")` is
     less than `pos!(block, "Process.send_after")`. Message: tmux `display-message`
     returns empty under transient load; one bad reading must not tear the slot down,
     and stacked timers fire together, defeating the consecutive-failures debounce
     and false-killing a live pane.
   - test `"attach_many stays sequential (PR #83 SQLite contention)"`: extract
     `~r/def attach_many\(server, identifiers, timeout[^\n]*\) when is_list\(identifiers\) do.*?\n  end\n/s`
     (`slot.ex:221-223`); `assert block =~ "Enum.map"`; `refute block =~ ~r/Task\.(async|start|Supervisor)/`.
     Message: parallel attaches against one serve hit SQLite write-lock contention
     even after PR #83's transaction batching; replay timeouts wedge slots at ⏳.

8. Run the Agent gate (below) from `src/`. All five commands must pass. The new file
   must report `16 tests, 0 failures` when run alone.

## Files

- Create: `src/test/aiur/regression/opencode_slots_test.exs`
- Modify: None
- Test: `src/test/aiur/regression/opencode_slots_test.exs` (the deliverable IS the test)

## Out of scope

- ANY file under `src/lib/` — this ticket changes zero production code. If a test you
  wrote fails against current behavior, the test is wrong: re-read the source and fix
  the test, never the production code.
- The 19 existing files under `src/test/aiur/regression/` and
  `src/test/aiur/opencode/*_test.exs` — do not edit, extend, or delete any of them
  (in particular do not touch `attach_fanout_cap_test.exs` or `slot_test.exs`, whose
  pins this file deliberately complements, not duplicates).
- Live-slot integration (starting a real `Aiur.Opencode.Slot` worker) — it requires
  tmux + opencode-serve + HiddenWindow; the tmux-injection seam is a T-046 concern.
- The `/tui/select-session` prohibition test — already pinned in
  `src/test/aiur/regression/chat_pane_loads_session_test.exs`.
- The `#506` SlotPolicy test flake — T-003 owns it; do not modify
  `src/test/aiur/opencode/slot_policy_test.exs`.
- `chat_completions.ex` / `normalize_operator_text` (the bridge half of #332) —
  pinned by `src/test/aiur/opencode/chat_completions_test.exs`; T-047 owns that area.
- `src/test/support/` and `.github/workflows/` — no changes.

## Inventory-IDs

From `docs/refactor/feature-inventory/oc.md` (behaviors of `slot.ex` /
`attach_pool.ex` / `slot_policy.ex` this file protects):

- **FI-OC-006** — TokenRegistry generation-overlap restart window (teardown-order test pins the token-delete position in the rebuild sequence).
- **FI-OC-031** — per-(identifier, base_url) SessionWriter ensure (detach-never-reaps test keeps writers alive across slot churn).
- **FI-OC-033** — history replay / `await_replay` barrier (sequential `attach_many` pin protects replay from SQLite contention).
- **FI-OC-049** — `/tui/select-session` prohibition (the set_visible fast-path pin is its complement: same-identifier opens must not respawn either).
- **FI-OC-051** — boot-time session GC trigger lives in `slot.ex:513-518`; adjacent, unmodified.
- **FI-OC-058** — slot workspace materialization + token registration (rebuild ordering keeps its generation contract).

Cross-section entries for the same files:

- **FI-EVT-110** (`opencode:slots` topic tuples), **FI-EVT-111** (`attach_pool` topic
  tuples) — every PubSub shape this file asserts.
- **FI-ART-024** — slot workspace artifacts + token/generation binding.
- **FI-TUI-019** (warm-open fast path), **FI-TUI-020** (`consume`/`find_slot_for`
  exclude-slots contract), **FI-TUI-032** (SlotPolicy bump/growth).

## Characterization-tests

This ticket CREATES `src/test/aiur/regression/opencode_slots_test.exs` (16 tests, 6
describes). Existing neighbors it complements (unchanged):
`attach_fanout_cap_test.exs` (#409 leadoff-only cap),
`warm_marker_semantics_test.exs` (#339 sleep marker; older warm-marker pins),
`warm_state_transitions_test.exs` (await_replay MatchError, replay transaction),
`chat_pane_loads_session_test.exs` (select-session prohibition),
`src/test/aiur/opencode/slot_test.exs` (dead-pid API mapping,
`terminate_pane_command/1`, `writers_for_base_url/2`).

## Acceptance criteria

- `src/test/aiur/regression/opencode_slots_test.exs` exists;
  `grep -q "defmodule Aiur.Regression.OpencodeSlotsTest" src/test/aiur/regression/opencode_slots_test.exs` passes.
- File length: `grep -c "" src/test/aiur/regression/opencode_slots_test.exs` <= 650.
  (Deviation from the 200-line new-file norm is intentional for characterization
  suites — precedent: `warm_marker_semantics_test.exs` at 286 lines; private helper
  functions stay <= 20 logic lines each.)
- All six describe strings match with `grep -F` against the file:
  - `describe "warm gate: no paint before :slot_ready"`
  - `describe "warmth lifecycle events (4-state marker inputs)"`
  - `describe "attach/reclaim under churn (#372/#607/#608 TOCTOU class)"`
  - `describe "FD/attach fan-out census (#409 :emfile class)"`
  - `describe "operator-message preservation through slot lifecycle (#332 class)"`
  - `describe "rebuild/watchdog invariants (source-pinned)"`
- `grep -c "Process.sleep" src/test/aiur/regression/opencode_slots_test.exs` outputs `0`.
- `grep -n "assert_receive" src/test/aiur/regression/opencode_slots_test.exs | grep -v ", 2000"`
  outputs nothing (every assert_receive window is 2000 ms).
- `grep -q "2026-06-23-emfile-structural-fix-census" src/test/aiur/regression/opencode_slots_test.exs` passes.
- `grep -q "async: false" src/test/aiur/regression/opencode_slots_test.exs` passes.
- From `src/`: `mix test test/aiur/regression/opencode_slots_test.exs` reports
  `16 tests, 0 failures`, and stays green with `--seed 0`, `--seed 7`, and `--seed 42`.
- `git diff --name-only origin/v2...HEAD` outputs exactly one line:
  `src/test/aiur/regression/opencode_slots_test.exs` (zero production files changed).

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

- NOTE: this PR touches the guarded regression path BY DESIGN (it adds a file under
  `src/test/aiur/regression/`), so the T-005 `regression-guard / guard` check will
  fail until the merging agent applies the `regression-suite-change` override label
  to the PR. Apply it, confirm the `labeled` event re-runs the guard, and
  `gh pr checks <pr-number>` shows `guard` passing before merge.
- Check: `git diff --name-only v2...<branch>` lists only
  `src/test/aiur/regression/opencode_slots_test.exs` — reject the PR if any file
  under `src/lib/` appears (a characterization ticket that "fixed" production code
  inverted its purpose).
- Check: from `src/`, run
  `mix test test/aiur/regression/opencode_slots_test.exs --seed 0 && mix test test/aiur/regression/opencode_slots_test.exs --seed 7 && mix test test/aiur/regression/opencode_slots_test.exs --seed 42`
  on the merge candidate — three green runs (flake screen per
  `regression-safety.md` flake rules; a seed-sensitive failure here is a blocker,
  not a retry).
- Check: `grep -c "Process.sleep" src/test/aiur/regression/opencode_slots_test.exs`
  outputs `0` and
  `grep -rn "assert_receive" src/test/aiur/regression/opencode_slots_test.exs | grep -v ", 2000"`
  outputs nothing.
- TUI check: none required — test-only PR with no runtime surface.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
