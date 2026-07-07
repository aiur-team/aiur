# T-012: Characterization: renderer/app render-state & snapshots

**Phase:** 1
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:1` `complexity:3`

## Problem / context

The agent-list TUI passes state from `Aiur.AgentList.App` to
`Aiur.AgentList.Renderer` through a hand-curated `Map.take`/`Map.put` pipeline in
`src/lib/aiur/agent_list/app.ex` `render/1` (lines 1458–1489). Every field the
renderer needs must be explicitly threaded there; the renderer reads each key with
a permissive default (`%{}`, `MapSet.new()`, `false`, `nil`), so a new App state
field that is *consumed but not threaded* renders its silent default instead of the
real value. This exact seam is the repeat regression class #414/#473/#730 (named in
`docs/refactor/research-history-hotspots.md` and in project memory
"render_state takes explicit"). `docs/refactor/research-arch/giant-renderer.md` §4.1
and `docs/refactor/research-arch/giant-app.md` risk 10 both call for a
characterization test that diffs the App-threaded key set against the
renderer-consumed key set.

Phase 4 tickets T-042 (`app ▸ … RenderState`, per `giant-app.md`) and T-040/T-041
(`renderer ▸ …`, per `giant-renderer.md`) will move this code. Today the App→Renderer
threading has only a single indirect pin (`app_test.exs:529` "Map.take guard"), and
there are **no full-frame ANSI snapshots** of the agent list — `snapshot_support.exs`
serves only the status dashboard. This ticket adds ONE new characterization-test file
that pins three things before any decomposition: (1) render-state key threading,
(2) terminal-state rendering (flag/progress/pause — the #730 class), and (3) a
full-frame ANSI snapshot of the main board. No production code changes:
characterization only.

## Scope (exact)

Read first, in this order (no edits to any of them):

1. `docs/refactor/research-arch/giant-app.md` — §1 census row N (the `render/1` +
   render_state pipeline), §4 risks 1, 6, 10, 11.
2. `docs/refactor/research-arch/giant-renderer.md` — §1 group B (`render/1` layout
   fan-in), §4.1 (the threading seam), §4.2 (frame/terminal escape discipline).
3. Source you will parse/exercise (read, do not edit):
   `src/lib/aiur/agent_list/app.ex` `render/1` (1452–1493) and its header helpers
   (`project_label/0` 1495, `active_agent_count/1` 1521, `max_agents_from_state/1`
   1532, `terminal_geometry/0` 1559); `src/lib/aiur/agent_list/renderer.ex`
   `render/1` (139–242, note the 154–164 fan-in and `repo_identity/1` 2033).
4. Existing patterns you MUST copy:
   `src/test/aiur/agent_list/renderer_test.exs` (the `base_state/1` +
   `render/1` + `visible/1` + `row_for/2` helpers; the paused ⏸️ test ~251, the
   progress-bar tests ~846–920, the finished-agent 🏁/⏳ tests ~927), and
   `src/test/support/snapshot_support.exs` (`Aiur.TestSupport.Snapshot` —
   `assert_snapshot!/2`, `escape_ansi/1`; loaded by `test/test_helper.exs`).

Authoring constraints (binding for every test you write):

- The whole file is pure: it calls `Aiur.AgentList.Renderer.render/1` directly (a
  pure `state map → iodata` function) and parses source text. It starts **no
  processes**, spawns **no engine**, and touches **nothing** under
  `src/lib/aiur/events/`. Therefore:
  - The module is `use ExUnit.Case, async: true`.
  - There is **no** `assert_receive`/`refute_receive`, so no timeout rule applies.
  - There is **no** `Process.sleep` anywhere (synchronization is not needed — no
    concurrency).
  - Do **not** pin `AIUR_RELEASE_NODE` and do **not** add `:log_file` tmp-dir
    isolation — neither applies to a pure renderer test. Adding either is wrong.
  - No shared-singleton count assertions and no resource fan-out census — this test
    exercises no processes, so those rules are inapplicable.
- Every rendered fixture is deterministic: pass an explicit integer `:now_ms`
  (freezes the braille spinner), explicit `:columns`/`:rows`, `truecolor?: false`,
  and fixed `runtime_seconds`/progress samples. Never read the wall clock, env, or
  terminal geometry in a test.

Then:

1. Create `src/test/aiur/regression/render_state_test.exs` with module
   `Aiur.Regression.RenderStateTest`. Start the file with exactly this skeleton
   (moduledoc text may be reflowed but must cite #414/#473/#730):

   ```elixir
   defmodule Aiur.Regression.RenderStateTest do
     @moduledoc """
     Characterization of the App -> Renderer render-state contract (refactor T-012).
     Pins: (1) render-state key threading (a renderer-consumed state field that
     App.render/1 does not thread renders its silent default -- the #414/#473/#730
     class); (2) terminal-state rendering (flag/progress/pause -- #730); (3) a
     full-frame ANSI snapshot of the main board. Read-only for executor agents: if
     one of these tests fails, the production change is wrong.
     """

     use ExUnit.Case, async: true

     alias Aiur.AgentList.Renderer
     alias Aiur.TestSupport.Snapshot

     @app_source Path.expand("../../../lib/aiur/agent_list/app.ex", __DIR__)
     @renderer_source Path.expand("../../../lib/aiur/agent_list/renderer.ex", __DIR__)

     # Keys the renderer reads from its input map WITH a fallback default and that
     # App.render/1 deliberately does NOT thread: :now_ms defaults to the monotonic
     # clock, :repo_identity falls back to :project_label (renderer.ex:2033). Any
     # OTHER consumed-but-unthreaded key is the #414/#473/#730 bug.
     @intentionally_defaulted MapSet.new([:now_ms, :repo_identity])

     @ansi_green IO.ANSI.green()

     defp render(state), do: IO.iodata_to_binary(Renderer.render(state))

     defp visible(text), do: Regex.replace(~r/\e\[[?0-9;]*[A-Za-z]/, text, "")

     defp row_for(out, id) do
       out
       |> visible()
       |> String.split(["\r\n", "\n"])
       |> Enum.find(&String.contains?(&1, id))
     end

     defp base_state(overrides) do
       Map.merge(
         %{
           summaries: [],
           selection_index: 0,
           selection_focus: :agents,
           columns: 120,
           rows: 30,
           project_label: nil,
           dashboard_url: nil,
           agent_kind: nil,
           agent_count: nil,
           max_agents: nil,
           now_ms: 1_000_000,
           truecolor?: false
         },
         overrides
       )
     end

     # --- source-parse helpers for the key-threading census ---

     defp atoms_in(text) do
       ~r/:([a-z][a-z0-9_]*\??)/
       |> Regex.scan(text)
       |> Enum.map(fn [_, k] -> String.to_atom(k) end)
       |> MapSet.new()
     end

     defp app_threaded_keys do
       src = File.read!(@app_source)
       [_, rest] = String.split(src, "render_state =", parts: 2)
       [pipeline, _] = String.split(rest, "Renderer.render(render_state)", parts: 2)
       atoms_in(pipeline)
     end

     defp renderer_consumed_keys do
       src = File.read!(@renderer_source)
       get_keys = Regex.scan(~r/Map\.get\(state,\s*:([a-z][a-z0-9_]*\??)/, src)
       dot_keys = Regex.scan(~r/\bstate\.([a-z][a-z0-9_]*\??)/, src)

       (get_keys ++ dot_keys)
       |> Enum.map(fn [_, k] -> String.to_atom(k) end)
       |> MapSet.new()
     end
   ```

2. Write `describe "render_state key threading (#414/#473/#730)"` with exactly these
   2 tests:

   - test `"every render-state key the renderer consumes is threaded by App.render/1"`:
     ```elixir
     threaded = app_threaded_keys()
     consumed = renderer_consumed_keys()

     missing =
       consumed
       |> MapSet.difference(threaded)
       |> MapSet.difference(@intentionally_defaulted)

     assert MapSet.equal?(missing, MapSet.new()), """
     Renderer reads render-state key(s) that App.render/1 never threads: \
     #{inspect(MapSet.to_list(missing))}.
     A consumed-but-unthreaded key renders its silent default (the #414/#473/#730 class).
     Thread each key through the Map.take/Map.put pipeline in \
     src/lib/aiur/agent_list/app.ex render/1.
     """
     ```
   - test `"the intentionally-defaulted keys stay consumed-but-unthreaded (allowlist canary)"`
     (keeps `@intentionally_defaulted` from silently going stale):
     ```elixir
     threaded = app_threaded_keys()
     consumed = renderer_consumed_keys()

     for key <- MapSet.to_list(@intentionally_defaulted) do
       assert MapSet.member?(consumed, key),
              "#{inspect(key)} is no longer read by the renderer; drop it from @intentionally_defaulted."

       refute MapSet.member?(threaded, key),
              "#{inspect(key)} is now threaded by App.render/1; drop it from @intentionally_defaulted."
     end
     ```

3. Write `describe "terminal-state rendering (flag/progress/pause -- #730 class)"`
   with exactly these 5 tests (each builds a fixture via `base_state/1`, renders with
   `render/1`, and asserts on the target agent's row via `row_for/2`):

   - test `"a paused agent renders the pause glyph"`:
     `row = row_for(render(base_state(%{summaries: [%{identifier: "T-PAUSE", status: :running, alert_count: 0, work_state: :paused}], columns: 200})), "T-PAUSE")`;
     `assert row =~ "⏸️"`.
   - test `"a deactivated agent renders the finish flag, never the warming hourglass"`:
     `row = row_for(render(base_state(%{summaries: [%{identifier: "T-FLAG", status: :running, alert_count: 0, work_state: :deactivated}], columns: 200})), "T-FLAG")`;
     `assert row =~ "🏁"`; `refute row =~ "⏳"`.
   - test `"a mid-progress sample renders a partial bar without the green tint"`:
     `now = 1_000_000`;
     `out = render(base_state(%{summaries: [%{identifier: "T-PROG", status: :running, alert_count: 0}], columns: 200, now_ms: now, progress_by_id: %{"T-PROG" => [{50, now}]}}))`;
     `row = row_for(out, "T-PROG")`; `assert row =~ "█████░░░░░"`;
     `refute String.contains?(row, @ansi_green)`.
   - test `"a 100% sample tints the full bar green"` (selection sits on a second row
     so the reverse-highlight does not flatten the green — mirror `renderer_test.exs`):
     `now = 1_000_000`;
     `summaries = [%{identifier: "T-DONE", status: :running, alert_count: 0}, %{identifier: "T-SEL", status: :running, alert_count: 0}]`;
     `out = render(base_state(%{summaries: summaries, selection_index: 1, columns: 200, now_ms: now, progress_by_id: %{"T-DONE" => [{100, now}]}}))`;
     `row = row_for(out, "T-DONE")`; `assert row =~ "██████████"`;
     `assert String.contains?(row, @ansi_green)`.
   - test `"a row with no progress samples renders the dotted empty track, not a hatched bar"`:
     `out = render(base_state(%{summaries: [%{identifier: "T-IDLE", status: :running, alert_count: 0}], columns: 200, progress_by_id: %{}}))`;
     `row = row_for(out, "T-IDLE")`; `assert row =~ "··········"`; `refute row =~ "░"`.

4. Add these module-level fixtures (after the private helpers, before the snapshot
   describe) for the snapshot board:

   ```elixir
   @fixture_summaries [
     %{identifier: "701", status: :running, alert_count: 0, work_state: :working, runtime_seconds: 125, title: "add widget"},
     %{identifier: "702", status: :running, alert_count: 2, work_state: :paused, runtime_seconds: 640, title: "fix flake"},
     %{identifier: "703", status: :running, alert_count: 0, work_state: :deactivated, runtime_seconds: 3725, title: "shipped"},
     %{identifier: "704", status: :running, alert_count: 0, work_state: :queued, title: "queued work"}
   ]

   defp board_state(columns) do
     now = 1_000_000

     base_state(%{
       summaries: @fixture_summaries,
       selection_index: 0,
       columns: columns,
       rows: 30,
       project_label: "applekid/aiur",
       dashboard_url: "http://127.0.0.1:4000/",
       agent_kind: "claude",
       agent_count: 3,
       max_agents: 4,
       now_ms: now,
       progress_by_id: %{"701" => [{40, now}], "703" => [{100, now}]}
     })
   end
   ```

5. Write `describe "ANSI snapshot of the main board"` with exactly these 2 tests:

   - test `"wide board renders the full-width frame"`:
     `output = render(board_state(180))`;
     `Snapshot.assert_snapshot!("agent_list_snapshots/main_board_wide.snapshot.txt", Snapshot.escape_ansi(output))`.
   - test `"narrow board reflows the columns"`:
     `output = render(board_state(80))`;
     `Snapshot.assert_snapshot!("agent_list_snapshots/main_board_narrow.snapshot.txt", Snapshot.escape_ansi(output))`.

6. Generate the two snapshot fixtures once, then commit them: from `src/`, run
   `UPDATE_SNAPSHOTS=1 mix test test/aiur/regression/render_state_test.exs`. This
   writes `src/test/fixtures/agent_list_snapshots/main_board_wide.snapshot.txt` and
   `.../main_board_narrow.snapshot.txt` (the `@snapshot_root` is
   `test/fixtures`). `git add` both fixture files. Then re-run the same command
   WITHOUT `UPDATE_SNAPSHOTS` and confirm the snapshot tests now pass against the
   committed fixtures.

7. Run the Agent gate (below) from `src/`. All five commands must pass. The new file
   must report `9 tests, 0 failures` when run alone.

## Files

- Create: `src/test/aiur/regression/render_state_test.exs`
- Create: `src/test/fixtures/agent_list_snapshots/main_board_wide.snapshot.txt` (generated in step 6)
- Create: `src/test/fixtures/agent_list_snapshots/main_board_narrow.snapshot.txt` (generated in step 6)
- Modify: None
- Test: `src/test/aiur/regression/render_state_test.exs` (the deliverable IS the test)

## Out of scope

- ANY file under `src/lib/` — this ticket changes zero production code. If a test you
  wrote fails against current behavior, the test is wrong: re-read the source and fix
  the test, never the production code. In particular, do NOT "fix" the `:now_ms` /
  `:repo_identity` defaults by threading them in `app.ex` — they are intentionally
  defaulted and belong on `@intentionally_defaulted`.
- `src/test/support/snapshot_support.exs` — reuse `assert_snapshot!/2` and
  `escape_ansi/1` as-is; do not add a bespoke `assert_agent_list_snapshot` helper.
- The 19 existing files under `src/test/aiur/regression/` and every file under
  `src/test/aiur/agent_list/` (`app_test.exs`, `renderer_test.exs`,
  `debug_events_ticker_test.exs`, `prewarm_render_test.exs`,
  `app_progress_ratchet_test.exs`, `app_phase_tracking_test.exs`,
  `app_debug_events_persistence_test.exs`) — do not edit, extend, or delete any of
  them; this file complements their per-feature `String.contains?` pins with
  full-frame and key-census coverage they lack.
- Live `Aiur.AgentList.App` GenServer integration (starting the process, PubSub
  intake, `MockPaneManager`/`MockOrchestrator`) — App message-handling behavior is
  pinned by `app_test.exs`; this ticket exercises only the pure `Renderer.render/1`
  and the source-level threading contract.
- Events-block / event-line phrasing, MODEL-column color exactness, OSC-8 link
  targets, help-overlay body — pinned by `renderer_test.exs` /
  `debug_events_ticker_test.exs`; do not add fixtures for them here.
- `src/test/fixtures/status_dashboard_snapshots/` and `.github/workflows/` — no changes.

## Inventory-IDs

From `docs/refactor/feature-inventory/tui.md` (behaviors this file protects):

- **FI-TUI-051** — `render_state` `Map.take`/`Map.put` pipeline (renderer state
  contract). The key-threading census (describe 1) is the direct guard for this
  highest-value invariant in the slice.
- **FI-TUI-052** — `poll_state` cache keeps render non-blocking. The threaded
  `:max_agents` key (via `max_agents_from_state/1`) is part of the census.
- **FI-TUI-055** — terminal geometry + truecolor detection. `:columns`/`:rows`/
  `:truecolor?` threading is exercised by the census and the two-width snapshot.
- **FI-TUI-043** — warm-marker / state-emoji machine (⏸️ paused, 🏁 finished). Pinned
  by the pause + deactivated tests in describe 2.
- **FI-TUI-066** — progress bar + green completion tint (partial / 100% / dotted
  empty track). Pinned by the three progress tests in describe 2.
- **FI-TUI-068** — LATEST placeholder / warming ⏳ suppression on finished rows.
  Pinned by the `refute row =~ "⏳"` on the deactivated row.
- **FI-TUI-061** — flicker-free frame protocol (DEC-2026 sync + cursor escape
  discipline). The full-frame ANSI snapshot pins the exact escape-byte sequence.
- **FI-TUI-063** — box chrome (title, metadata rows, timeline-labelled borders).
  Pinned by the main-board snapshot.
- **FI-TUI-064** — responsive column-width algorithm. Pinned by rendering the same
  fixture at 180 and 80 columns (two snapshots).

## Characterization-tests

This ticket CREATES `src/test/aiur/regression/render_state_test.exs` (9 tests, 3
describes) plus its two committed ANSI snapshot fixtures under
`src/test/fixtures/agent_list_snapshots/`. Existing neighbors it complements
(unchanged): `src/test/aiur/agent_list/renderer_test.exs` (per-feature chrome /
marker / progress pins), `debug_events_ticker_test.exs` (events block),
`prewarm_render_test.exs` (prewarm line), `app_test.exs` (the App-side Map.take
guard at 529), and `src/test/aiur/regression/warm_marker_semantics_test.exs`
(source-pinned marker regex tests).

## Acceptance criteria

- `src/test/aiur/regression/render_state_test.exs` exists;
  `grep -q "defmodule Aiur.Regression.RenderStateTest" src/test/aiur/regression/render_state_test.exs` passes.
- `grep -q "async: true" src/test/aiur/regression/render_state_test.exs` passes.
- `grep -q "@intentionally_defaulted MapSet.new(\[:now_ms, :repo_identity\])" src/test/aiur/regression/render_state_test.exs` passes.
- All three describe strings match with `grep -F` against the file:
  - `describe "render_state key threading (#414/#473/#730)"`
  - `describe "terminal-state rendering (flag/progress/pause -- #730 class)"`
  - `describe "ANSI snapshot of the main board"`
- `grep -c "Process.sleep" src/test/aiur/regression/render_state_test.exs` outputs `0`.
- `grep -c "assert_receive" src/test/aiur/regression/render_state_test.exs` outputs `0`
  (this is a pure test — no message-passing synchronization).
- File length: `grep -c "" src/test/aiur/regression/render_state_test.exs` <= 200;
  every private helper is <= 20 logic lines.
- Both snapshot fixtures are committed and non-empty:
  `test -s src/test/fixtures/agent_list_snapshots/main_board_wide.snapshot.txt` and
  `test -s src/test/fixtures/agent_list_snapshots/main_board_narrow.snapshot.txt`.
- From `src/`: `mix test test/aiur/regression/render_state_test.exs` reports
  `9 tests, 0 failures`, and stays green with `--seed 0`, `--seed 7`, and `--seed 42`
  (the test is deterministic — a seed-sensitive failure is a real bug, not a retry).
- Re-running with `UPDATE_SNAPSHOTS=1` produces no `git diff` in the two fixture
  files (the render is reproducible byte-for-byte).
- `git diff --name-only origin/v2...HEAD` outputs exactly three lines and zero files
  under `src/lib/`:
  `src/test/aiur/regression/render_state_test.exs`,
  `src/test/fixtures/agent_list_snapshots/main_board_wide.snapshot.txt`,
  `src/test/fixtures/agent_list_snapshots/main_board_narrow.snapshot.txt`.

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
- Check: `git diff --name-only v2...<branch>` lists only the three files named in
  Acceptance criteria — reject the PR if any file under `src/lib/` appears (a
  characterization ticket that "fixed" production code inverted its purpose).
- Check: from `src/`, run
  `mix test test/aiur/regression/render_state_test.exs --seed 0 && mix test test/aiur/regression/render_state_test.exs --seed 7 && mix test test/aiur/regression/render_state_test.exs --seed 42`
  on the merge candidate — three green runs (flake screen per
  `regression-safety.md`; a seed-sensitive failure here is a blocker, not a retry).
- Check: `grep -c "Process.sleep" src/test/aiur/regression/render_state_test.exs`
  outputs `0`.
- Check: eyeball the two committed `agent_list_snapshots/*.snapshot.txt` fixtures —
  each is a plausible AIUR board frame (rounded `╭─ AIUR` title, the four fixture
  rows 701–704, the 🏁 flag on 703, the green 100% bar on 703, and DEC-2026 sync
  escapes `\e[?2026h` … `\e[?2026l` bracketing the frame). A garbled or empty
  fixture means the render was non-deterministic — block.
- TUI check: none required — test-only PR with no runtime surface.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
