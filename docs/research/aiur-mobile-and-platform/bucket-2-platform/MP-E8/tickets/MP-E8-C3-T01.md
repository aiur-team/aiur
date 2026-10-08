---
ticket_id: MP-E8-C3-T01
feature_id: MP-E8
chunk_id: MP-E8-C3
bucket: 2-platform
title: BuildLive, DataSource behaviour, fixture source, seam scan
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C1-T01, MP-E8-C2-T03, MP-E8-C1-T02]
complexity: 3
design_gate: DESIGN-E8
owns_edge_cases: [EC-01]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C3-T01 — `BuildLive`, the `DataSource` seam, the fixture source and the seam scan

> Cites code at `origin/main` `58854d4c8`. Paths marked PROPOSED do not exist
> yet. `J` = `design-source/assets/build.js`, `C` = `design-source/assets/build.css`,
> `H` = `design-source/Aiur Dashboard.html`.

## Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history), chunk C3 (home LiveView,
  data seam, payload protocol, URL state), ticket T01.
- **User value:** the new home page has one LiveView that owns authorization,
  data loading and (later) every write. The first paint is the design's loading
  skeleton, never an empty board. A hook-drawn page and an open ticket modal
  survive every server re-render.
- **Deliverable:**
  1. PROPOSED `AiurWeb.BuildLive` at a temporary route `/build` in
     `live_session :dashboard`. It renders `DashboardShell`, the design's
     `#build-root` with the loading skeleton in the dead render, and the
     `#tk-backdrop` modal containers. Hook-owned containers are
     `phx-update="ignore"`.
  2. PROPOSED `AiurWeb.Build.DataSource` behaviour (`subscribe/1`,
     `snapshot/1`, each taking a keyword `opts`, the arities C3-T02 builds on)
     with a default implementation that answers `{:error, :not_wired}` until
     C8-T04 replaces it.
  3. PROPOSED `Aiur.TestSupport.BuildHome.FixtureSource` that serves the C1-T01
     JSON with its fixed `meta.now`, plus a browser-harness endpoint
     `GET /build-fixture/:dataset` that picks the dataset and redirects to
     `/build`.
  4. A source-scan seam test (merged from the retired C3-T04).
- **Non-goals:** the payload schema, diffs, generations and `push_event`
  (C3-T02); URL parameters and `handle_params` (C3-T03); any drawing in the hook
  (C9-T01 and later); the real data source (C8-T04); nav entry and the `/`
  cutover (C12-T01); any write event.

## Dependencies and blockers

- **DESIGN-E8** (gate). No S-item blocks this ticket. Gaps are recorded under
  "Decisions made without the owner".
- **MP-E8-C1-T01:** the five fixture datasets (`live`, `dense`, `newrepo`,
  `noqueue`, `offline`) as JSON under PROPOSED `src/test/fixtures/build_home/`,
  each shaped `{meta: {dataset, now, tz, design_etag}, data, daemon}` with
  `meta.now` = `1791408000000` (2026-10-07 14:20 `America/Los_Angeles`, J:11;
  C1-T01 "dataset(k)" and its NOW-pin test). The same folder also holds
  `usage-sets.json` and `manifest.json`, which are **not** datasets. This ticket
  serves the raw export as-is; C3-T02 owns the mapping to schema v1.
- **MP-E8-C2-T03:** the `build-home/` loader and the `Hooks` map entry in
  `layouts.ex`. This ticket uses the hook name C2-T03 registers (PROPOSED
  `BuildHome`). It does not edit `layouts.ex` or `StaticAssets`. C2-T03's stub
  hook writes `data-build-home-hook` on `#build-root`; see "Hook-written
  `data-*` on `#build-root`" under Non-happy paths.
- **MP-E8-C1-T02:** the parity runner (B4 uses its element mode with
  `phase: 'loading'`) and `productUrl(dataset)`, which wraps this ticket's
  `GET /build-fixture/:dataset`.
- **Not a predecessor, on purpose:** C2-T04 (the `.bd-skel`, `.bd-loading` and
  `.tk-backdrop` rules). Waiting for it would put C3-T01 and C3-T02 behind the
  C2 style chain on the critical path. So the pixel cell is report-only here and
  C9-T01 enforces it (see Pixel parity).
- **Contract request:** CR-E8-6 (MP-R1 `component-map.md`) is already filed in
  [CONTRACT-REQUESTS.md](CONTRACT-REQUESTS.md). The seam test below is the
  enforcement until MP-R1-C1's dependency checker exists.
- **May run concurrently with:** C2-T01, C2-T04, all of C4–C7. C3-T02
  and C3-T03 start after this ticket merges (they edit `build_live.ex`).
- **Dependents:** C3-T02, C3-T03 (direct); C9-T01 (through C3-T02/T03); C8-T04
  (implements the behaviour); C11-T01 (fills `#tk-backdrop`); C12-T01 (moves the
  route to `/`).

## Verified starting point (`58854d4c8`)

- **Router.** `src/lib/aiur_web/router.ex:133–148`: scope with
  `pipe_through([:dashboard_auth, :browser])`, then
  `live_session :dashboard, on_mount: AiurWeb.FinancialDataAccess` holding `/`,
  `/chat/...`, `/commands`, `/build-orders`, `/build-orders/:root_number`,
  `/analytics`, `/streamdeck` (`:139–148`).
- **The pattern to copy:** `src/lib/aiur_web/live/build_order_live.ex`.
  - `:4` `use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}`.
  - `:41–67` `mount/3`: `NavState.assign_nav/1`, `AwaitingCommands.mount/2`,
    the source from `Application.get_env(:aiur, :build_order_data_source, DataSource)`
    (`:44`), connect-only work behind `connected?/1` (`:63`).
  - `:110–113` `AwaitingCommands.refresh/1` on `{:decision_changed, _, _}` and
    `AwaitingCommands.tick/1`; `:147` catch-all `handle_info`.
  - `:150–156` `handle_async` with `{:ok, …}` and `{:exit, _}` branches.
  - `:174–178` `toggle-nav` and `restore-nav` events (`NavState.toggle/1`,
    `NavState.restore/2`).
  - `:236–291` `render/1` wraps the page in `DashboardShell.dashboard_shell`.
- **Shell:** `src/lib/aiur_web/components/operator_control_center/dashboard_shell.ex`
  (334 lines). Required attrs `route` (map), `routes`, `tracker_kind`,
  `agent_kind` (`:8–14`); `nav_collapsed`, `nav_counts`, `globally_paused`,
  `writable` (`:15–23`). `route_item/1` picks `:patch` or `:navigate` from
  `RouteRegistry.navigation_mode/2` (`:225–260`). `nav_icon/1` has a fallback
  clause for unknown ids (`:325–327`).
- **Route registry:** `src/lib/aiur_web/operator_control_center/route_registry.ex`.
  `current_route/1` falls back to `hd(@routes)` (Units) for an unknown action
  (`:75–78`), so passing `:build` there would highlight Units. `navigation_mode/2`
  returns `:patch` only for the same `owner` (`:92–98`).
- **Nav state:** `src/lib/aiur_web/operator_control_center/nav_state.ex:19–42`.
- **Command counts:** `src/lib/aiur_web/operator_control_center/awaiting_commands.ex:35–74`
  (`mount/2`, `tick/1`, `refresh/1`, `nav_counts/1`; unreadable store → `nil`,
  never `0`).
- **Existing seam to model on:** `src/lib/aiur_web/build_order/data_source.ex:1–138`
  (callbacks `:21–36`; public functions take `opts \\ []` and resolve each
  dependency with `dependency(opts, name, default)`, `:128–129`). The source is
  swapped with `Application.get_env` as a module or a `{module, context}` tuple,
  as `AiurWeb.BuildOrder.Runtime.source_call/3` does
  (`src/lib/aiur_web/build_order/runtime.ex:42–43`). This ticket keeps the
  swap and passes the tuple's second element as the callbacks' `opts`, because
  C3-T02 ("Dependencies and blockers") builds on `snapshot(opts)` and
  `subscribe(opts)`.
- **Hook registration:** `src/lib/aiur_web/components/layouts.ex:38–45` loader
  scripts, `:54–270` `Hooks` map (each entry guarded by `if (window.X)`), `:272–286`
  `LiveSocket` with `hooks: Hooks`. C2-T03 adds the home entry.
- **LiveView 1.1.33** (`src/mix.lock`). In
  `src/deps/phoenix_live_view/priv/static/phoenix_live_view.js`:
  `mergeAttrs` with `isIgnored` updates **only `data-*` attributes** on a
  `phx-update="ignore"` element (`:790–822`), the patch calls it for ignored
  elements and does not touch their children (`:2522–2530`), and a hook's
  `updated` fires on an ignored element only when its dataset changes
  (`:4621–4628`). So the server can signal state through `data-*` on
  `#build-root`, and a `class="… show"` set by the hook on `#tk-backdrop` is kept.
  **The same function also removes every `data-*` attribute that the server
  did not render** (`:812–820`, the check at `:816`: `name.startsWith("data-") &&
  !source.hasAttribute(name)`, except `PHX_PENDING_ATTRS`). A `data-*` that the
  hook writes on `#build-root` is therefore deleted by the next server patch.
  Non-`data-` attributes and classes written by the hook are kept.
- **Browser harness:** `src/test/browser/fixture_server.exs` (2,640 lines).
  `FixtureRouter` `:2224–2301`; unmatched paths `forward("/", AiurWeb.Router)`
  (`:2291`), so `/build` is served by the production router. `FixtureServer.run/0`
  sets `:build_order_data_source` to a harness module (`:2360`). The
  `FixtureStreamdeckControl` controller (`:1571–1599`) is the precedent for a
  per-server control endpoint. `src/browser/playwright.config.mjs:14–19` runs
  `fullyParallel: false, workers: 1`, and every `run-browser-tests.mjs` call gets
  its own fixture server (the `FixtureStreamdeckControl` moduledoc says so), so
  a server-global dataset switch is safe.
  `src/browser/scripts/start-fixture.mjs:10` runs `mix run --no-start test/browser/fixture_server.exs`.
- **Browser auth for forwarded routes:** `configure_forwarded_dashboard/0`
  (`fixture_server.exs:2574–2581`) sets `dashboard_auth_required: true`, and
  `run/0` exports `AIUR_DASHBOARD_USERNAME`/`PASSWORD` (`:2357–2358`). Specs for
  production routes authenticate with HTTP Basic credentials, not the fixture
  session: `src/browser/tests/build-order-route.browser.spec.mjs:4,36`
  (`setHTTPCredentials(dashboardCredentials)`), with the credentials in
  `src/browser/tests/support/layout-worker.mjs:8–11`. `/auth/:mode` only opens
  the fixture-only LiveViews (`:fixture_access`, `fixture_server.exs:2267–2279`, pipe at `:2268`).
- **Test support is required, not compiled:** `src/test/test_helper.exs:64–67`
  uses `Code.require_file`; `fixture_server.exs:1` requires
  `../support/browser_harness/fixtures.ex` the same way.
- **LiveView test pattern:** `src/test/aiur_web/live/build_order_live_test.exs:1–40`
  (`use Aiur.TestSupport`, `Phoenix.LiveViewTest`, a GenServer fake source) and
  `:158–180` (swap `:build_order_data_source`, `dashboard_auth_required: false`,
  `Aiur.TestSupport.start_owned_endpoint!/0`, restore in `on_exit`).
- **Source-scan precedent:** `src/test/aiur/orchestrator/resume_decline_reason_test.exs:39–51`
  (`File.read!` + `Regex.scan`, with `assert MapSet.size(literals) > 0` so it
  cannot pass empty). MP-E1-C1-T07 is the planned twin for `build_queue/`.
- **Absent at base:** `src/lib/aiur_web/build/`, `src/lib/aiur_web/live/build_live.ex`,
  `src/lib/aiur/build_queue/`, `src/test/fixtures/build_home/`.

### Design elements this ticket reproduces

| Element | Source | What must match exactly |
| --- | --- | --- |
| Home panel root | H:1910 `<div id="build-root" class="bd-root">` | id and class; `.bd-root { container: bd / inline-size; display: flex; flex-direction: column; gap: .9rem; min-width: 0; }` (C:83) |
| Hosts the hook fills | J:545–550 `shell()` | Child order and ids: `#bd-usage`, `#bd-offline`, `#bd-fh`, `.bd-toolbar` › `#bd-tools-l.bd-bar-l`, `#bd-filters.bd-filters`, `#bd-tools.bd-bar-r`; `.bd-vpw` › `#bd-vp.bd-vp`, `#bd-sb.bd-sb` › `<i>`, `#bd-tree.bd-tree[hidden]`; `#bd-status.bd-status` |
| Loading skeleton | J:1249–1253 `renderLoading()` | Inside `#bd-vp`: `.bd-lanes` › `.bd-skel-lanes` › `<i class="bd-skel-i">` + 3 `<i>`, each with inline `background: var(--surface-3)` (J:1252); `.bd-skel` with 16 `<i>`; `.bd-loading` › `.bd-spin` + text `Loading build timeline…` (U+2026) |
| Skeleton styles | C:317–324, C:223, H:720 | `.bd-skel` padding `60px 90px 30px`, 4 columns, gap 16px; cells 92px high, radius 12px, `--surface-3`, `bdPulse 1.4s ease-in-out infinite`, delays `.2s` (3n) and `.4s` (4n+1); `.bd-skel-lanes` absolute `left 90px right 16px top 8px`, cells 30px, radius 9px; `.bd-loading` centred pill, `.55rem 1rem`, radius 999px, `--bg-2`, 1px `--line-strong`, `600 .74rem "JetBrains Mono"`, `--muted`; `.bd-spin` 16px, 2px `--line-strong`, top `--accent`, `khSpin .8s linear infinite` (keyframe H:720); reduced motion C:298 (pulse off) and C:324 (spin 3s) under `.bd-root.rm` |
| Ticket modal frame | H:2058–2064 | `div.tk-backdrop#tk-backdrop` › `div.tk-modal#tk-modal[role=dialog][aria-modal=true][aria-label="Ticket context"]` › `header.tk-head#tk-head`, `div.tk-body#tk-body`; styles H:1596–1598 (`position: fixed; inset: 0; z-index: 80; display: none`, `.show` → `display: grid`). In the design it is a body-level sibling of the app, not inside it |
| Usage popover | J:1052–1054 | `.ax-pop` is created by script and appended to `document.body` (C:809 `position: fixed; z-index: 95`). It is outside the LiveView container, so no server container is rendered for it |

The 600 ms (J:1565–1572) and 650 ms (J:1261–1263) loading timers are mock
behaviour. In the product, loading ends when the first payload arrives
(C3-T02/C9-T01), not on a timer.

## Chosen design

**Layering.** `BuildLive` owns the socket, auth context (from the
`live_session` on_mount), the source call and the load state. The hook owns all
children of `#build-root` and `#tk-backdrop`. The server never re-renders those
children after the first paint; it signals the hook only through `data-*`
attributes on `#build-root`, which LiveView 1.1.33 still merges on ignored
elements.

**Load state machine** (assign `:build_state`):

```text
dead render ──► :loading ──(connected mount: start_async :build_snapshot)
:loading ──{:ok, {:ok, data}}──────────► :ready         (assign :build_snapshot = data)
:loading ──{:ok, {:error, reason}}─────► {:unavailable, reason_tag(reason)}
:loading ──{:exit, _}──────────────────► {:unavailable, "crashed"}
:loading ──:build_snapshot_timeout─────► {:unavailable, "timeout"}  (cancel_async)
any other state + any of the above ────► unchanged (stale or late message)
```

Rendered as `data-build-state="loading|ready|unavailable"` and
`data-build-reason` (absent unless unavailable). `reason_tag/1` maps
`:not_wired` → `"not_wired"`, `:timeout` → `"timeout"`, everything else →
`"unknown"` (AGENTS.md "a collapsed cause names the collapse": never a specific
cause for an unknown term, and never `inspect/1` of a raw term into the DOM).

**DataSource behaviour** (PROPOSED `src/lib/aiur_web/build/data_source.ex`):

```elixir
defmodule AiurWeb.Build.DataSource do
  @moduledoc "Read seam for the home page. C8-T04 replaces the default bodies with the ticket index."
  # `opts` carries every injectable dependency (the BuildOrder.DataSource rule).
  # After `subscribe/1` succeeds, the source may send messages to the caller
  # process; C3-T02 defines them.
  @callback subscribe(keyword()) :: :ok | {:error, term()}
  @callback snapshot(keyword()) :: {:ok, map()} | {:error, term()}

  @spec source() :: module() | {module(), keyword()}
  def source, do: Application.get_env(:aiur, :build_data_source, __MODULE__)

  # The tuple's keyword list is appended as the last argument (`opts`).
  @spec call(module() | {module(), keyword()}, atom(), [term()]) :: term()
  def call({module, opts}, fun, args) when is_atom(module) and is_list(opts),
    do: apply(module, fun, args ++ [opts])

  def call(module, fun, args) when is_atom(module), do: apply(module, fun, args ++ [[]])

  # Default implementation until C8-T04.
  @behaviour __MODULE__
  @impl true
  def subscribe(_opts), do: :ok
  @impl true
  def snapshot(_opts), do: {:error, :not_wired}
end
```

The `now` a page draws with travels inside the snapshot (C3-T02 lists `now` in
the initial snapshot), so the behaviour has no clock callback. The final
callbacks are the C3-T02 forms: `snapshot/1`, `subscribe/1`, `earlier/3`
(C3-T02), plus `ticket/2` (C11-T01) and `unit_row/2` (C11-T07, added in its
PR); all keep the trailing `opts`.

**Fixture source** (PROPOSED `src/test/support/build_home/fixture_source.ex`,
module `Aiur.TestSupport.BuildHome.FixtureSource`, loaded with
`Code.require_file` so it never ships in a release):

- `@datasets ~w(live dense newrepo noqueue offline)` (files) plus the two
  control names `unavailable` and `hold`: seven names in all, returned by
  `datasets/0`. The list is fixed in code. A request value is never put into a path, so `manifest`,
  `usage-sets` or `../x` cannot be loaded. Later tickets add datasets in their
  own PRs (R-G1): `unknowns` (C9-T05, reused by C9-T06 and C12-T05), `now0`/`now24`
  (C9-T08), odd-edges (C4-T05).
- `snapshot(opts)` takes the dataset from `Keyword.get(opts, :dataset,
  Application.get_env(:aiur, :build_fixture_dataset, "live"))` and the folder
  from `Keyword.get(opts, :dir, Path.expand("../../fixtures/build_home",
  __DIR__))`. For a file dataset it reads `<dir>/<dataset>.json`, decodes it
  with `Jason.decode/1`, and returns `{:ok, json}` **unchanged**. The fixed
  `now` is already in `json["meta"]["now"]` (`1791408000000`); nothing is
  added, because the raw `data` object already has a `now` key (the design's
  list of active tickets) and a second meaning would be a trap.
- `"unavailable"` returns `{:error, :fixture_unavailable}`. `"hold"` blocks in
  `receive` with no timeout. The `start_async` task that called it is killed
  when the LiveView exits or when the 15 s timeout calls `cancel_async`. So a
  `hold` page stays in `loading` for 15 s and then turns `unavailable`/`timeout`.
  A capture of the loading frame must happen inside that window and must assert
  `[data-build-state=loading]` at capture time.
- An unknown dataset → `{:error, :unknown_dataset}`. A missing or unparsable
  file → `{:error, {:fixture_missing, path}}`. Never `{:ok, %{}}`.
- `subscribe(_opts)` → `:ok`. C3-T02 extends both callbacks (day windows,
  `earlier/3`).

**Browser control endpoint** (in `fixture_server.exs`, modelled on
`FixtureStreamdeckControl`, controller PROPOSED
`Aiur.BrowserHarness.FixtureBuildDataset`): `GET /build-fixture/:dataset`
checks the name against the same fixed list (`FixtureSource.datasets/0`), sets
`:build_fixture_dataset` for that fixture server, and answers **302 to
`/build`**, keeping the query string (`/build-fixture/live?ticket=12` →
`/build?ticket=12`). So one URL per dataset opens the page, which is what
C1-T02's `productUrl(dataset)` and C9-T01's `/build-fixture/hold` expect.
Unknown names answer 404 with a plain-text body. `FixtureServer.run/0` sets
`Application.put_env(:aiur, :build_data_source, Aiur.TestSupport.BuildHome.FixtureSource)`
next to `:2360`. The product page stays at `/build` (forwarded to
`AiurWeb.Router`, Basic auth as above). There is no `?example=` or `?fixture=`
parameter, because C3-T03 drops `example` and a production LiveView must not
know test datasets.

**Shell route map.** `BuildLive` passes a local route map to `DashboardShell`:
`%{id: :build, label: "Build", icon: "", description: "", path: "/build",
type: :live, owner: :build, availability: :available, active_actions: [:build]}`.
It is not added to `RouteRegistry` (`/build` is a hidden temporary route; C12-T01
adds the nav item). Owner `:build` makes every nav link a `navigate`, which is
correct across LiveView modules.

**Seam scan** (PROPOSED `src/test/aiur_web/build/seam_test.exs`). Two rules:

1. **Web side:** files `lib/aiur_web/live/build_live.ex` and
   `lib/aiur_web/build/**/*.ex` may reference only these `Aiur*` modules:
   `AiurWeb.Build.*`, `AiurWeb.BuildLive`, `Aiur.BuildOrder.*`,
   `Aiur.BuildQueue` (public API), `Aiur.AgentChat`,
   `AiurWeb.OperatorControlCenter.{UnitsRow, UnitsRow.*, UnitsControlPolicy, DecisionCommands, DashboardShell, NavState, AwaitingCommands, RouteRegistry}`,
   `AiurWeb.Layouts`, `AiurWeb.FinancialDataAccess`, `AiurWeb.Presenter`,
   `AiurWeb.BuildOrder.Runtime`. Any other `Aiur.` or
   `AiurWeb.` reference fails, with its file and line.
2. **Store side:** `lib/aiur/build_order/history{.ex,/**/*.ex}` and
   `lib/aiur/build_order/features{.ex,/**/*.ex}` must not reference `AiurWeb`
   (stores sit below the web layer; MP-R1 moves them into `build-orders`, CR-E8-6).

The scanner drops whole-line comments only (`~r/^\s*#.*$/m`). It does not try
to find trailing comments, because a `#` inside a string or a `#{}` interpolation
would confuse it; a trailing comment is scanned, which fails closed. Text in
`@moduledoc`/`@doc` is scanned too: a doc that names an off-seam module is an
offender, on purpose. The scanner expands grouped aliases
(`alias AiurWeb.{Build, DashboardLive}`), and matches `Module.concat`/string forms
(`"Elixir.AiurWeb.DashboardLive"`). Rule 1 asserts it scanned at least one file.
Rule 2 may scan zero files until C4-T01 and C6 add theirs (`# ponytail:` comment
names this).

## Implementation steps

1. **Behaviour.** Add PROPOSED `src/lib/aiur_web/build/data_source.ex` (above).
2. **LiveView.** Add PROPOSED `src/lib/aiur_web/live/build_live.ex`:
   - `mount/3`: `NavState.assign_nav/1`, `AwaitingCommands.mount(socket, connected?)`,
     assign `:build_state = :loading`, `:route` (the local route map), and
     `:tracker_kind`/`:agent_kind` from `AiurWeb.BuildOrder.Runtime.tracker_kind/0`
     and `agent_kind/0` (`runtime.ex:36–40`, the existing failure-aware config
     read; it is on the rule 1 allowlist by name).
     When connected: `source = DataSource.source()`; call
     `DataSource.call(source, :subscribe, [])` (log a warning on `{:error, _}`;
     the page still loads the snapshot); `start_async(:build_snapshot, fn ->
     DataSource.call(source, :snapshot, []) end)`;
     `Process.send_after(self(), :build_snapshot_timeout, @snapshot_timeout_ms)`
     with `@snapshot_timeout_ms 15_000`.
   - `handle_async(:build_snapshot, …)` and `handle_info(:build_snapshot_timeout, …)`
     per the state machine. Each branch matches `%{assigns: %{build_state: :loading}}`
     first; other states return the socket unchanged. Log a warning on every
     unavailable transition, with the tag only.
   - `handle_info` for `{:decision_changed, _, _}` and `:awaiting_commands_tick`
     (copy `build_order_live.ex:110–113`); catch-all last.
   - `handle_event` for `toggle-nav` and `restore-nav` (copy `:174–178`); catch-all
     returns `{:noreply, socket}`.
   - `render/1`:

     ```heex
     <DashboardShell.dashboard_shell route={@route} routes={RouteRegistry.routes(@analytics)}
       tracker_kind={@tracker_kind} agent_kind={@agent_kind}
       nav_collapsed={@nav_collapsed} nav_counts={@nav_counts}>
       <div id="build-root" class="bd-root" phx-hook="BuildHome" phx-update="ignore"
            data-build-state={state_name(@build_state)} data-build-reason={reason(@build_state)}>
         <div id="bd-usage"></div><div id="bd-offline"></div><div id="bd-fh"></div>
         <div class="bd-toolbar"><div class="bd-bar-l" id="bd-tools-l"></div><div class="bd-filters" id="bd-filters"></div><div class="bd-bar-r" id="bd-tools"></div></div>
         <div class="bd-vpw"><div class="bd-vp" id="bd-vp">
           <div class="bd-lanes"><div class="bd-skel-lanes"><i class="bd-skel-i" style="background: var(--surface-3)"></i><i style="background: var(--surface-3)"></i><i style="background: var(--surface-3)"></i><i style="background: var(--surface-3)"></i></div></div>
           <div class="bd-skel"><i :for={_ <- 1..16}></i></div>
           <div class="bd-loading"><span class="bd-spin"></span>Loading build timeline…</div>
         </div><div class="bd-sb" id="bd-sb"><i></i></div><div class="bd-tree" id="bd-tree" hidden></div></div>
         <div class="bd-status" id="bd-status"></div>
       </div>
     </DashboardShell.dashboard_shell>
     <div class="tk-backdrop" id="tk-backdrop" phx-update="ignore">
       <div class="tk-modal" id="tk-modal" role="dialog" aria-modal="true" aria-label="Ticket context">
         <header class="tk-head" id="tk-head"></header>
         <div class="tk-body" id="tk-body"></div>
       </div>
     </div>
     ```

     The snapshot is kept in `:build_snapshot` but **not referenced** in the
     template, so it adds nothing to the diff. C3-T02 decides retention and
     how the snapshot reaches the hook (its design answers a `build-resync`
     event with a reply). `state_name/1` maps `:loading`/`:ready`/
     `{:unavailable, _}` to the three names; `reason/1` returns the tag for
     `{:unavailable, tag}` and `nil` otherwise, so HEEx omits the attribute. `@analytics` comes from
     `AiurWeb.Presenter.analytics_navigation/0` as in `build_order_live.ex:61`
     (add `AiurWeb.Presenter` to the allowlist), and the `phx-hook` name is the
     one C2-T03 registers.
3. **Route.** In `router.ex` inside `live_session :dashboard` (`:139–148`), add
   `live("/build", BuildLive, :build)` after the `/build-orders` lines.
4. **Fixture source** and its `Code.require_file` lines in `test_helper.exs`
   (next to `:67`) and at the top of `fixture_server.exs` (next to `:1`).
5. **Fixture server:** the `:build_data_source` env line in `FixtureServer.run/0`;
   a `FixtureBuildDataset` controller and
   `get("/build-fixture/:dataset", …)` in the `pipe_through(:browser)` scope
   (`:2260–2265`, next to `/streamdeck-control/:mode` at `:2264`). That scope
   has no auth, like the Stream Deck control; it exists only in the loopback
   fixture server. The redirect target `/build` is then authenticated by the
   forwarded production router.
6. **Tests** (Verification).
7. **Browser script:** `"test:build-home": "node scripts/run-browser-tests.mjs tests/build-home-shell.browser.spec.mjs"`
   in `src/browser/package.json`, and append `npm run test:build-home` to `test`.

## Non-happy paths

- **First paint before data (EC-01).** The dead render already contains the
  skeleton, so there is no empty frame between HTML arrival, LiveView join and the
  first payload. The dead render does not call the source (no double load).
- **Source error, crash or hang.** Each one ends in `unavailable` with a fixed
  tag. A hang ends after 15 s; `cancel_async/2` then makes `handle_async` receive
  `{:exit, {:shutdown, :cancel}}`, which the `:loading` guard ignores, so the tag
  stays `timeout`. A late `{:ok, …}` after the timeout is ignored for the same
  reason. Unavailable is **never** shown as `ready` or as an empty board.
- **Unavailable before C9-T01.** Ignored children cannot be re-rendered by the
  server, so until C9-T01 reads `data-build-state` the pill still says
  "Loading build timeline…" when the state is `unavailable`. `/build` is unlinked
  and C12-T01 depends on every C9 ticket, so no operator reaches this page in that
  state. C9-T01 must render it (see handoff).
- **Subscribe fails.** Logged; the snapshot still loads. Live diffs are C3-T02's.
- **Modal open during a server patch** (README row "modal survives patches";
  see decision 12 on the EC id). `#tk-backdrop` is
  `phx-update="ignore"`, so its `show` class and children survive nav-count,
  nav-toggle and URL patches. `#build-root` likewise keeps every hook-drawn node.
  Only `data-*` reaches it, which fires the hook's `updated` callback (LV
  `:4621–4628`), the channel for later state.
- **Hook-written `data-*` on `#build-root`.** LiveView removes every `data-*`
  on an ignored element that the server did not render (LV `:816`), on every
  patch. Three neighbour tickets plan hook-written `data-*` there:
  `data-build-home-hook` (C2-T03), `data-build-epoch` (C3-T02, read by its
  reconnect test) and `data-build-socket`/`data-build-epoch` (C9-T01). Each is
  deleted by the next nav-count, nav-toggle or URL patch. The rule this ticket
  sets: **the server owns `data-build-*` names it renders (`data-build-state`,
  `data-build-reason`, and C3-T03's `data-url-state`); any other `data-*` the
  hook writes on `#build-root` must be written again in the hook's `updated()`
  callback**, which LiveView calls in the same patch because the dataset then
  differs (LV `:4621–4628`). Classes and non-`data-` attributes (`.rm`, J:560)
  need nothing. B6 proves the removal so the rule cannot be forgotten.
- **Hook missing** (C2-T03 entry empty or script failed). LiveView logs `unknown
  hook found for "BuildHome"` (LV `:4926`) and the skeleton stays: the page reads
  as loading, not as data.
- **Disconnect or reconnect.** A rejoin re-runs `mount/3` and reloads the snapshot.
  Generation and gap handling are C3-T02's (EC-11).
- **Auth and privacy.** `/build` is in the `:dashboard_auth` scope and the
  `:dashboard` live_session, so it has the same Basic auth and
  `FinancialDataAccess` capability as `/build-orders`. The DOM carries only state
  names and fixed tags, never a raw error term, path or secret.
- **Read-only dashboard.** This ticket adds no write. The shell's global pause
  keeps its default `writable={false}`, exactly as `build_order_live.ex:238–248`.
- **Concurrency.** One LiveView process per tab; each tab loads its own snapshot.
  The fixture dataset switch is server-global, which is safe only because the
  harness runs one worker per fixture server (`playwright.config.mjs:14–18`).

## Compatibility and rollout

- New hidden route `/build`; no nav item, no operator config key, no CLI flag,
  no environment variable. `:build_data_source` and `:build_fixture_dataset` are
  internal Application env keys, like `:build_order_data_source`.
- No migration. Nothing is persisted.
- **Docs:** none required (AGENTS.md "Docs ship with the change": no config key,
  CLI flag, operator env var or reachable new surface). C12-T01 documents the home
  page when it becomes `/`.
- **Rollback:** revert the commit. No other page changes.
- **Route lifetime:** C12-T01 points `/` at `BuildLive`. It decides whether
  `/build` is removed or redirects to `/`.

## Pixel parity

- **Elements:** `#build-root` and its shell hosts (J:545–550), the loading
  skeleton inside `#bd-vp` (J:1251–1252, C:166–169, 317–324, H:720), the
  `#tk-backdrop` frame (H:2058–2064, 1596–1598).
- **Check:** C1-T02's element-level mode compares `#bd-vp` in the loading state.
  - Design side: the design HTML with Playwright's clock installed before load
    and never advanced past 599 ms, after `switchTab("build")`, so
    `S.loading === true` (J:1565).
  - Product side: `GET /build-fixture/hold` (302 to `/build`), captured while
    `[data-build-state=loading]` holds (under 15 s, see the fixture source).
  - Matrix: 1440 and 390 px, dark and light, Gruvbox and default palettes.
    Threshold and allowlist are C1-T02's. This ticket adds no allowlist entry.
  - **Gate:** the pixels depend on C2-T01 tokens and C2-T04 rules
    (`.bd-skel`, `.bd-loading`, `khSpin`). Neither is a predecessor of this
    ticket. So at this merge the cell runs in C1-T02's
    report mode (B4) and is not a pass/fail gate. **C9-T01 enforces it**: it
    waits for C2-T04 and, through C3-T02, for this ticket (handoff below).
- **Structure check (the merge gate here):** the ExUnit DOM assertion U1, that the dead
  render's `#build-root` subtree has the same element order, tags, ids, classes
  and inline styles as `shell()` + `renderLoading()`. This catches drift before
  pixels do.
- **Reduced motion:** the `.rm` class is added by the hook at mount (J:560;
  C9-T01). The dead render has no `.rm`, so pulse and spin run for the few
  milliseconds before the hook mounts. C1-T03's reduced-motion script covers it
  after C9-T01.
- **Not comparable here:** the design fills the toolbar, usage strip and feature
  header during loading because its data is local (J:1265–1267). The product has
  no data before the first payload, so those hosts are empty in the loading frame.
  See decision 4 (S-23).

## Verification

ExUnit (PROPOSED files; isolated HOME per the memory note "mix test clobbers
agent-token"):

| # | Test | Expected | Fails without |
| --- | --- | --- | --- |
| U1 | `build_live_test.exs` "dead render is the design skeleton" — `get(conn, "/build")` | `#build-root.bd-root[phx-update=ignore][phx-hook=BuildHome][data-build-state=loading]`; children in `shell()` order; `#bd-vp .bd-skel > i` count 16; `.bd-skel-lanes > i` count 4, first has class `bd-skel-i`, each `style="background: var(--surface-3)"`; `.bd-loading` text `Loading build timeline…` with one `.bd-spin` | the skeleton markup (an empty `#build-root` fails every count) |
| U2 | "dead render does not call the source" — fake `{Spy, test_pid: self()}` source (the `opts` tuple form) | no `:snapshot` message after the HTTP GET; one after `live/2` | the `connected?` guard |
| U3 | "connected mount loads the snapshot" — spy returns `{:ok, %{"meta" => %{"now" => 1791408000000}}}` | `data-build-state="ready"`, no `data-build-reason` | the `start_async`/`handle_async` ready branch |
| U4 | "source error renders unavailable, never ready" — `{:error, :boom}`, then `{:error, :not_wired}` | `unavailable` with reason `unknown`, then `unavailable` with `not_wired` | the error branch (mutate it to `:ready` → fails); the `_ -> "unknown"` clause (mutate it to `"not_wired"` → first case fails) |
| U5 | "source crash renders unavailable" — snapshot raises | `unavailable`, reason `crashed` | the `{:exit, _}` clause |
| U6 | "timeout renders unavailable; late results are ignored" — spy blocks in `receive`; test sends `:build_snapshot_timeout` to `view.pid`; then `render(view)` again after the cancel exit is delivered | `unavailable`/`timeout`, and still `timeout` on the second render | the timeout handler; the `:loading` guard (without it the cancel exit rewrites the tag to `crashed`) |
| U7 | "a timeout after ready is ignored" | stays `ready` | the `:loading` guard |
| U8 | "default source is not wired" — no env override | `unavailable`/`not_wired` | `snapshot/1` returning `{:ok, %{}}` (a plausible empty board) |
| U9 | "modal frame markup" | `#tk-backdrop.tk-backdrop[phx-update=ignore]` › `#tk-modal[role=dialog][aria-modal=true][aria-label="Ticket context"]` › `header#tk-head`, `#tk-body`; `#tk-backdrop` is **not** inside `.dashboard-shell` | the containers (behaviour proof is B2) |
| U10 | "/build requires dashboard auth" — pattern of `test/aiur_web/router_auth_test.exs:47–52` (credentials put in `conn.private` with `dashboard_conn/3`, `:290–293`): no `authorization` header, then the right one | 401, then 200 | the route in the `:dashboard_auth` scope (a route outside it answers 200 without the header) |
| F1 | `build/fixture_source_test.exs` "every dataset loads its own file with the frozen now" — `snapshot(dataset: name)` for each of the five, and once with only `Application.put_env(:aiur, :build_fixture_dataset, "dense")` (restored in `on_exit`) | `{:ok, map}` with `map["meta"]["dataset"] == name` and `map["meta"]["now"] == 1791408000000`; the env case gives `"dense"` | a source that ignores the name (always `live`) or the env key |
| F2 | "unknown, non-dataset or missing fixture is an error" | `"nope"`, `"manifest"` and `"../live"` → `{:error, :unknown_dataset}`; `snapshot(dataset: "live", dir: tmp)` with an empty temp dir → `{:error, {:fixture_missing, _}}`; `"unavailable"` → `{:error, :fixture_unavailable}` | the fixed list (`manifest.json` exists, so a path built from the name would load it); returning `{:ok, %{}}` for a missing file (mutate → fails) |
| S1 | `build/seam_test.exs` "web side references only the seam" | no offenders; ≥ 1 file scanned | (the rule; guards future changes) |
| S2 | "stores do not reference AiurWeb" | no offenders | (same) |
| S3 | "scanner flags a grouped alias and a string module, and skips comment lines" — fixture strings `alias AiurWeb.{Build, DashboardLive}`, `"Elixir.Aiur.Orchestrator"` and a line `  # see AiurWeb.DashboardLive` | the first two reported (`AiurWeb.DashboardLive`, `Aiur.Orchestrator`); the comment line not reported | the alias expansion and string match (positive control); the comment rule (negative control) |

Browser (PROPOSED `src/browser/tests/build-home-shell.browser.spec.mjs`, auth via
`page.context().setHTTPCredentials(dashboardCredentials)` as in
`build-order-route.browser.spec.mjs:36`, because `/build` is served by the
forwarded production router; 1440 px so `#nav-toggle` is visible):

| # | Test | Expected | Fails without |
| --- | --- | --- | --- |
| B1 | "hook-owned DOM survives a server patch" — `goto('/build-fixture/live')` (lands on `/build`); page script appends `<b id="probe">` to `#build-root`; click `#nav-toggle` and wait for `aria-pressed` to flip | `#probe` still present | `phx-update="ignore"` on `#build-root` |
| B2 | "an open modal survives a server patch" — add class `show` to `#tk-backdrop` and `<b id="mprobe">` to `#tk-body`; click `#nav-toggle` and wait for `aria-pressed` to flip | `#tk-backdrop` class list still contains `show`; `#mprobe` present. (No computed-style check: the `.tk-backdrop.show` rule arrives with C2-T04, not a predecessor) | `phx-update="ignore"` on `#tk-backdrop` (LiveView resets `class` and drops the child) |
| B3 | "server state reaches the ignored root" — dataset `live` | `[data-build-state=ready]` appears; dataset `unavailable` → `[data-build-state=unavailable][data-build-reason=unknown]` | the `data-*` attributes (proves the LV 1.1.33 merge rule this design relies on) |
| B4 | "loading skeleton matches the design" (EC-01) — dataset `hold`; C1-T02 element mode on `#bd-vp` | **report mode at this merge** (see Pixel parity "Gate"); the cell is registered and produces its side-by-side image. C9-T01 turns it into a pass/fail check | (not counted as coverage here) |
| B5 | "fixture endpoint picks only known datasets" — `request.get` with `maxRedirects: 0` | `/build-fixture/live?ticket=12` → 302, `location` `/build?ticket=12`; `/build-fixture/manifest`, `/build-fixture/nope`, `/build-fixture/..%2Flive` → 404 | the fixed list in the controller; the query-string carry |
| B6 | "a hook-written `data-*` on the root does not survive a patch" (guard for the rule under Non-happy paths; it passes on LiveView 1.1.33 as is and is **not** counted as coverage of this ticket's code) — page script sets `data-probe="1"` and class `probe` on `#build-root`; click `#nav-toggle` | `data-probe` absent; class `probe` present; `data-build-state` still present | a LiveView upgrade that changes the merge rule (then the rule and its neighbours' handoffs must be revisited) |

Mutation check (AGENTS.md): in a worktree with a clean `git status --porcelain`,
remove `phx-update="ignore"` from `#tk-backdrop` → B2 fails; restore → passes.
Same for `#build-root` → B1 fails. Replace the error branch with `:ready` → U4
fails. Replace `_ -> "unknown"` with `_ -> "not_wired"` → U4 fails. Remove the
`:loading` guard → U6 and U7 fail. Make `FixtureSource` return `{:ok, %{}}` for a
missing file → F2 fails. Build the path from the raw name instead of the list →
F2 (`manifest`) and B5 fail. Always read `live.json` → F1 fails. Move `/build`
out of the `:dashboard_auth` scope → U10 fails. Record each command in the PR
body.

Commands:

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur_web/live/build_live_test.exs test/aiur_web/build/
env -C src/browser npm run test:build-home
```

Manual: none in this ticket. The page has no user-visible content beyond the
skeleton; the AGENTS.md manual TUI test runs in C11-T06 and C12-T01.

## Completion and handoff

- [ ] `/build` mounts in `live_session :dashboard`; dead render is the skeleton;
      U1–U10, F1–F2, S1–S3, B1–B3, B5–B6 pass, B4 produces its report-mode
      image, and each listed mutation fails.
- [ ] `AiurWeb.Build.DataSource` default answers `{:error, :not_wired}`.
- [ ] Fixture source and `/build-fixture/:dataset` work for all seven names.
- [ ] `test:build-home` is in the browser `test` chain.
- **For C3-T02:** the callbacks are already `subscribe(opts)` and
  `snapshot(opts)`; add `earlier/3` with the same trailing `opts`. Read the
  snapshot from `:build_snapshot` (or replace it) and deliver it as your design
  says. Settled 2026-10-08: fixture pages open with `GET /build-fixture/<dataset>`
  (C1-T02 `productUrl`), including your reconnect test. `data-build-epoch` written by
  the hook is removed by every server patch (Non-happy paths); either re-write
  it in `updated()` or render it from the server assign `:build_epoch`.
- **For C9-T01 (required, not in its row today):** read `data-build-state` and
  `data-build-reason` in `mounted`/`updated`; render `unavailable` in the
  `.bd-loading` pill with the S-9 default copy pattern and no spinner; keep the
  server skeleton until the first payload instead of the 600 ms timer. Re-write
  `data-build-home-hook`, `data-build-socket` and `data-build-epoch` in
  `updated()` (they are removed by each patch). Turn B4 (the loading-frame
  parity cell) into a pass/fail check once C2-T04 has merged.
- **For C2-T03:** `data-build-home-hook` on `#build-root` is removed by the first
  server patch after the hook writes it. Its B-tests run in the harness without
  a server patch, so they will not see this. The C9-T01 hook re-writes it in
  `updated()`; the stub needs the same one-line `updated` if anything reads the
  attribute after a patch.
- **For C8-T04:** implement `subscribe/1`, `snapshot/1` and `earlier/3`
  (`ticket/2` and `unit_row/2` come with C11-T01 and C11-T07) and set
  `:build_data_source`, or replace the default bodies.
- **For C1-T02:** Settled 2026-10-08: `productUrl(dataset)` wraps
  `GET /build-fixture/:dataset`; one `goto` lands on `/build` through the 302.
  Product requests need `httpCredentials: dashboardCredentials`.
- **For C2-T04:** carry `@keyframes khSpin` (H:720). `.bd-spin` (C:323) needs it,
  and it is in the HTML, not in `build.css`.
- **For C12-T01:** move the route to `/`; add the registry item; decide `/build`.
- Docs: none.
- Sources: plan §5, §8 (EC-01), §10 item 28; chunks.md C3; tickets/README.md
  C3-T01 row; brief §9; DESIGN-E8 S-9; neighbour tickets C1-T01, C1-T02,
  C2-T03, C3-T02, C9-T01 (read 2026-10-08).

## Decisions made without the owner

1. **The dataset is chosen with a fixture control endpoint** (`/build-fixture/:dataset`,
   302 to `/build`), not `?example=`. C3-T03 drops `example`, and a production
   LiveView should not know test datasets. The redirect makes it one URL per
   dataset, which C1-T02 and C9-T01 both assume.
2. **`.ax-pop` keeps the design's placement** on `document.body` (J:1054). It is
   outside the LiveView container, so patches never touch it and no server host
   is needed. The row asked for a server host with an id. The hook that creates
   it (C10-T04) must remove it in `destroyed`.
3. **`#tk-backdrop` is a sibling of the shell**, not inside it, as in the design
   (H:2058). A future shell ancestor with `transform`, `filter` or `contain` would
   otherwise break its `position: fixed`.
4. **Loading frame:** the server renders the `#bd-vp` skeleton; the toolbar,
   usage and feature hosts are empty until the first payload. The design fills
   them during its mock loading because its data is local. This design gap is
   sign-off item S-23.
5. **Snapshot timeout 15 s**, then `unavailable`/`timeout`. A hang must not show
   "Loading…" forever.
6. **Unavailable reasons are a fixed vocabulary** (`not_wired`, `timeout`,
   `crashed`, `unknown`); anything else collapses to `unknown`.
7. **No `RouteRegistry` change:** a local route map with owner `:build`.
8. **No clock callback** on the behaviour; `now` is in the snapshot.
9. **The fixture source lives in `test/support/`** and is loaded with
   `Code.require_file`, so it never ships.
10. **The seam allowlist includes the shell modules** (`DashboardShell`, `NavState`,
    `AwaitingCommands`, `RouteRegistry`, `Layouts`, `FinancialDataAccess`,
    `Presenter`, `BuildOrder.Runtime`). Without them the LiveView cannot render
    the shell.
11. **The dead render does not load data**, as `build_order_live.ex:63` does.
12. **EC id.** The README row says this ticket owns "EC-10 (modal survives
    patches)", but plan §8 defines EC-10 as "a ticket changes section while the
    user scrolls" (owned by C3-T02, C4-T03, C11-T05). This ticket owns the
    modal-survival behaviour from the row text (B2) and lists only EC-01 in
    `owns_edge_cases`. The modal-survival case is not EC-10 (EC-10 is the scroll
    anchor).
13. **Callbacks take `opts`** (`subscribe/1`, `snapshot/1`), to match C3-T02 and
    the "every dependency injectable" rule of the row, instead of `/0` and a
    later rename.
14. **The fixture JSON is served unchanged;** the frozen `now` is
    `meta.now` (epoch ms). No top-level ISO `now` is added.
15. **Hook-written `data-*` on `#build-root` is re-written in `updated()`**
    rather than renamed, so the names C2-T03, C3-T02 and C9-T01 already use
    stay valid.
16. **The pixel cell is report-only at this merge** and enforced by C9-T01,
    so this ticket does not wait for C2-T04.

## Review log

Adversarial review, 2026-10-08 (feasibility, coherence, design, scope), checked
against `58854d4c8`, design-source and the neighbour tickets.

1. `owns_edge_cases` → `[EC-01]`. Plan §8 EC-10 is the scroll-anchor case, not
   modal survival; the behaviour stays owned (decision 12).
2. DataSource callbacks changed from `/0` to `subscribe(opts)`/`snapshot(opts)`
   with `{module, opts}` config, to match C3-T02 and the row's "every dependency
   injectable" (decision 13).
3. Fixture source: serves the C1-T01 file unchanged and reads `meta.now`
   (`1791408000000`); the invented ISO top-level `now` (which would sit next to
   the design's `data.now` row list) is gone. Fixed dataset list via `datasets/0`;
   folder injectable for F2; `hold` vs the 15 s timeout made explicit.
4. `/build-fixture/:dataset` now answers 302 to `/build` with the query kept, so
   one URL opens a dataset (C9-T01 N1 and C1-T02 `productUrl` assume this).
   Unauthenticated-scope note replaces a garbled sentence. B5 added.
5. Browser auth corrected: forwarded `/build` needs HTTP Basic credentials
   (`dashboardCredentials`), not the `/auth/read_only` fixture session.
6. New finding: LiveView 1.1.33 `mergeAttrs` removes hook-written `data-*` on an
   ignored element at each patch (`phoenix_live_view.js:816`). This breaks
   `data-build-home-hook` (C2-T03), `data-build-epoch` (C3-T02) and
   `data-build-socket` (C9-T01). Rule, guard test B6 and handoffs added.
7. B4 pixel cell made report-only (C2-T04 and C1-T02 are not predecessors);
   C9-T01 enforces it. B2 no longer asserts `display: grid` for the same reason.
8. Tests sharpened: F1 asserts the dataset name and env key (fails on an
   always-`live` source), F2 covers `manifest` and `../live`, S3 adds a
   comment-line negative control, U10 follows `router_auth_test.exs`, U6 no
   longer "releases" a task that `cancel_async` already killed. More mutations
   listed.
9. Seam scan comment rule made concrete (whole-line only; docs are scanned).
10. Line fixes: `playwright.config.mjs:14–19`, LV `:4926`; harness auth lines
    added. Handoffs to C1-T02, C2-T03, C3-T02, C8-T04, C9-T01 updated.

Residual risks: C3-T02 still names `/build?fixture=live` and C1-T02 still names
`/fixture-build/`; both must take the handoff. The README "EC-10" label needs a
coordinator fix. The `updated()` re-write rule depends on LiveView keeping its
1.1.33 merge behaviour (B6 catches a change).
- Reconciliation 2026-10-08 (coordinator): DataSource callbacks are the C3-T02 forms plus `ticket/2` (C11-T01) and `unit_row/2` (C11-T07), C1-T02 is a predecessor (dependencies, concurrency, Pixel parity gate, Decision 16, matching front matter), fixture dataset list grows by ticket (`unknowns`, `agents-odd`, `now0`/`now24`, odd-edges), loading-frame empty chrome = S-23, modal survival is not EC-10, C1-T02/C3-T02 handoffs settled (`productUrl` over `GET /build-fixture/:dataset`).
