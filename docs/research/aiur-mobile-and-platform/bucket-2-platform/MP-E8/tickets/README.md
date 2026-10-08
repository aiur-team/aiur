# MP-E8 tickets — work-order for the per-ticket writers

Researched 2026-10-07 at aiur `origin/main` `58854d4c8`. Design source:
[`../design-source/`](../design-source/) (etag 1791431544512943). Plan:
[../plan.md](../plan.md). Chunks: [../chunks.md](../chunks.md). Owner gate:
[DESIGN-E8](../../../owner-design-tasks/DESIGN-E8.md). Owner questions:
[../questions.md](../questions.md). Contract requests:
[CONTRACT-REQUESTS.md](CONTRACT-REQUESTS.md).

**Status.** No ticket docs exist yet. Each row below is the brief for one writer
agent. The writer researches the row with the pack and the live code, then
writes `MP-E8-Cx-Tyy.md` in the shape of `../../MP-E1/tickets/MP-E1-C3-T01.md`
(frontmatter, then the nine sections of brief §9).

**Rules every writer applies.**
- **Every ticket is `blocked` on DESIGN-E8.** Add the extra `blocked_by` tickets listed in the row.
- **An `OQ-E8-n` or `S-n` in a row is not a blocker.** The ticket follows that
  question's written default ([../questions.md](../questions.md) §10,
  [DESIGN-E8](../../../owner-design-tasks/DESIGN-E8.md) sign-off items) and says so in
  its doc. Kevin's answer may reopen the ticket. The one exception is C13-T03,
  which waits on S-8 because the design has nothing to default to.
- **The design is the specification** ([../claude-design-source-of-truth.md](../claude-design-source-of-truth.md)).
  A visual ticket names the design elements it reproduces and has a C1-T02
  screenshot check. A difference from the design is a failing test unless Kevin
  approved it in writing. Do not restyle, re-space or simplify.
- **Port, don't redraw.** Reuse the design's CSS values, keyframes, DOM, class
  names and constants (`LH=46`, `SEC=36`, `SPANS`, `CH`, timings). Remove mock code
  only.
- **Unknown is never zero** (AGENTS.md). A ticket that renders an unknown,
  stale or unavailable value needs the mutation test described there.
- **A computed age is rendered** (AGENTS.md).
- **Edge cases** are cited by `EC-nn` from [../plan.md §8](../plan.md#8-edge-case-catalog).
  A ticket owns the edge cases listed in its row: it implements them and tests them.
- Complexity is 1 (an hour) to 5 (several days, high risk).
- Cite code at `58854d4c8`. Mark proposed paths as PROPOSED.

Abbreviations: `J` = `design-source/assets/build.js`, `C` = `design-source/assets/build.css`,
`H` = `design-source/Aiur Dashboard.html`.

## Summary table

| ID | Title | Cx | Extra blocked_by |
| --- | --- | --- | --- |
| MP-E8-C1-T01 | Design fixture exporter | 2 | — |
| MP-E8-C1-T02 | Side-by-side screenshot parity runner | 4 | C1-T01 |
| MP-E8-C1-T03 | Motion and interaction parity scripts | 4 | C1-T02 |
| MP-E8-C2-T01 | Tokens, Gruvbox palette, body wash, self-hosted fonts | 3 | C1-T02, OQ-E8-1 |
| MP-E8-C2-T02 | App shell restyle (top bar, cog menu, sidenav) | 4 | C2-T01, OQ-E8-1, OQ-E8-2 |
| MP-E8-C2-T03 | Static assets and the four-place hook registration | 1 | — |
| MP-E8-C2-T04 | Consolidated home stylesheet from build.css | 4 | C2-T01, C1-T02 |
| MP-E8-C3-T01 | BuildLive, DataSource behaviour, fixture source, seam scan | 3 | C1-T01, C2-T03 |
| MP-E8-C3-T02 | Payload schema v1, diff and resync protocol | 4 | C3-T01 |
| MP-E8-C3-T03 | Server-owned URL state and legacy URL presets | 2 | C3-T01 |
| MP-E8-C4-T01 | `Aiur.BuildOrder.History` store | 3 | — |
| MP-E8-C4-T02 | One-time history backfill (about 30–45 GraphQL points) | 4 | C4-T01 |
| MP-E8-C4-T03 | Steady-state history feed and boot catch-up | 4 | C4-T01 |
| MP-E8-C4-T04 | Start and end times for Gantt | 3 | C4-T02, C4-T03 |
| MP-E8-C4-T05 | Historic edges, children index, order violations | 2 | C4-T02 |
| MP-E8-C5-T01 | Epics config section and docs | 2 | — |
| MP-E8-C5-T02 | Epic resolver | 2 | C5-T01 |
| MP-E8-C5-T03 | Epic override registry and batch CLI | 3 | C5-T02 |
| MP-E8-C5-T04 | Skill and prompt guidance for categories and estimates | 2 | C5-T03, C6-T04, C7-T03 |
| MP-E8-C6-T01 | Feature registry and membership journal | 3 | C5-T02 |
| MP-E8-C6-T02 | `feature:` label projection and reconciliation | 3 | C6-T01 |
| MP-E8-C6-T03 | Build Order roots imported as features | 2 | C6-T01 |
| MP-E8-C6-T04 | `aiur feature` CLI | 3 | C6-T01, C6-T02 |
| MP-E8-C6-T05 | Feature statistics | 2 | C6-T01, C4-T01 |
| MP-E8-C7-T01 | Planned rows, waves and cues from the build queue | 3 | C4-T01, MP-E1-C6-T01, MP-E1-C7-T02, MP-E1-C5-T02 |
| MP-E8-C7-T02 | Unfiled planning-pack items as planned rows | 2 | C7-T01 |
| MP-E8-C7-T03 | Estimates, overrides, CLI and ETA | 3 | C7-T01, OQ-E8-7 |
| MP-E8-C7-T04 | Not-queued rows | 1 | C4-T01, MP-E1-C6-T01 |
| MP-E8-C8-T01 | Now-band rows and agent-state mapping | 3 | C3-T02 |
| MP-E8-C8-T02 | Usage strip data | 3 | C3-T02 |
| MP-E8-C8-T03 | Daemon, freshness and offline signals | 2 | C3-T02 |
| MP-E8-C8-T04 | Ticket index assembler, live diffs, history by day | 4 | C3-T02, C4-T03, C5-T02, C6-T05, C7-T01, C7-T04, C8-T01 |
| MP-E8-C9-T01 | Hook shell, scrollbar, payload intake, URL bridge | 4 | C3-T02, C3-T03, C2-T04 |
| MP-E8-C9-T02 | Timeline layout and density tiers | 3 | C9-T01 |
| MP-E8-C9-T03 | Virtualised rendering and history paging | 3 | C9-T02 |
| MP-E8-C9-T04 | Dynamic epic columns | 3 | C9-T03 |
| MP-E8-C9-T05 | Ticket cards in four tiers | 4 | C9-T03 |
| MP-E8-C9-T06 | Agent indicators (logo, glow, stuck, idle) | 2 | C9-T05 |
| MP-E8-C9-T07 | Dependency edges | 3 | C9-T05 |
| MP-E8-C9-T08 | Now band, live snap and jump to live | 4 | C9-T05, C9-T07 |
| MP-E8-C9-T09 | Gantt mode | 4 | C9-T05, C9-T07, C4-T04 |
| MP-E8-C9-T10 | Span, zoom and calendar controls | 2 | C9-T02 |
| MP-E8-C9-T11 | Dependency chains, lock tab, whole-tree view | 3 | C9-T07 |
| MP-E8-C9-T12 | List view | 2 | C9-T01 |
| MP-E8-C9-T13 | Loading, empty and stale board states | 2 | C9-T03, C8-T03 |
| MP-E8-C10-T01 | Toolbar and status line | 2 | C9-T01 |
| MP-E8-C10-T02 | Filters, popovers and the `not_planned` default | 4 | C10-T01, C9-T05, C8-T04 |
| MP-E8-C10-T03 | Feature header, focus and compact modes | 4 | C10-T02, C6-T05, C9-T09 |
| MP-E8-C10-T04 | Usage strip | 3 | C10-T01, C8-T02 |
| MP-E8-C11-T01 | Modal frame, `?ticket=` deep link, navigation | 3 | C3-T03, C9-T05, OQ-E8-5 |
| MP-E8-C11-T02 | Issue view for tickets without an agent | 3 | C11-T01, C7-T01, MP-E1-C6-T02 |
| MP-E8-C11-T03 | Conversation read seam and wave-0b adapter | 4 | C11-T01 |
| MP-E8-C11-T04 | Event rows in the conversation | 3 | C11-T03 |
| MP-E8-C11-T05 | Minimap preview sidebar, live tail, typing | 3 | C11-T03, C11-T04 |
| MP-E8-C11-T06 | Composer: send to the agent | 4 | C11-T03 |
| MP-E8-C11-T07 | Pause, resume and "Open in Conversations" | 2 | C11-T01 |
| MP-E8-C11-T08 | Command answer card | 3 | C11-T03 |
| MP-E8-C11-T09 | Dictation button | 2 | C11-T06 |
| MP-E8-C11-T10 | Units fields in the modal (only if OQ-E8-5 says yes) | 2 | C11-T01, OQ-E8-5 |
| MP-E8-C12-T01 | Cutover: `/` is home, Units retired, rollback route | 3 | C9-*, C10-*, C11-T01..T08, C11-T10, C8-T04, OQ-E8-3 |
| MP-E8-C12-T02 | Build Order routes retire to feature focus | 2 | C12-T01, C6-T03 |
| MP-E8-C12-T03 | Dead-code deletion | 2 | C12-T01 |
| MP-E8-C12-T04 | Phone width and WebView | 3 | C12-T01 |
| MP-E8-C12-T05 | Accessibility pass | 3 | C12-T01 |
| MP-E8-C12-T06 | Performance budget and measurement | 3 | C12-T01 |
| MP-E8-C12-T07 | Documentation | 2 | C12-T01, C5-T03, C6-T04, C7-T03 |
| MP-E8-C12-T08 | DESIGN-E8 sign-off package | 2 | C12-T01..T06, C1-T03 |
| MP-E8-C13-T01 | `aiur history export` for classification | 2 | C12-T01 |
| MP-E8-C13-T00 | Measure the backfill cost (instrumentation) | 2 | C13-T01 |
| MP-E8-C13-T04 | Backfill runbook and the agent run | 2 | C13-T00, C5-T03, C6-T04 |
| MP-E8-C13-T02 | Optional paced label writes for classifications | 3 | C13-T04 |
| MP-E8-C13-T03 | Unconfirmed classification display and confirm | 2 | C13-T04, S-8 (a real wait) |
| MP-E8-C14-T01 | Conversation reads from the MP-E4 journal | 3 | MP-E4-C2-T01, MP-E4-C3-T02, MP-E4-C4-T01, C11-T04 |
| MP-E8-C14-T02 | Delivery receipts in the composer | 2 | MP-E4-C6-T01, MP-E7-C3-T03, MP-E7-C3-T04, C11-T06 |
| MP-E8-C14-T03 | "Open in Conversations" to the full view | 1 | MP-E4-C5-T01, C11-T07 |
| MP-E8-C14-T04 | Command answers through the MP-E2 contract | 2 | MP-E2-C1-T01, MP-E2-C3-T01, C11-T08 |

Counts: C1 3 · C2 4 · C3 3 · C4 5 · C5 4 · C6 5 · C7 4 · C8 4 · C9 13 · C10 4 ·
C11 10 · C12 8 · C13 5 · C14 4 = **76 tickets**. Complexity sum 210.
67 tickets ship in wave 0b, C13's five after cutover, C14's four in waves 2–3.
C11-T10 is conditional: it is dropped if Kevin answers OQ-E8-5 "no".
C3-T04 was merged into C3-T01 by the review pass; its id is retired.

## Dependency order (critical path)

```text
C1-T01 ─► C1-T02 ─► C2-T01 ─► C2-T04 ─┐
C2-T03 ─► C3-T01 ─► C3-T02 ───────────┴─► C9-T01 ─► C9-T02 ─► C9-T03 ─► C9-T05 ─► C9-T07 ─► C9-T08 ─┐
C4-T01 ─► C4-T03 ─┐                                                                                 │
C5-T01 ─► C5-T02 ─┼─► C6-T01 ─► C6-T05 ─┐                                                           │
MP-E1-C6-T01 ─► C7-T01 ─────────────────┼─► C8-T04 ─────────────────────────────────────────────────┴─► C12-T01 ─► C12-T05/T06 ─► C12-T08
C3-T02 ─► C8-T01 ───────────────────────┘
C9-T05 ─► C11-T01 ─► C11-T03 ─► C11-T04 ─► C11-T05 ─► C12-T01
```

Critical path (15 merges): C1-T01 → C1-T02 → C2-T01 → C2-T04 → C9-T01 → C9-T02 →
C9-T03 → C9-T05 → C11-T01 → C11-T03 → C11-T04 → C11-T05 → C12-T01 → C12-T05 →
C12-T08. Server data (C4–C8) runs alongside it and joins at C8-T04 → C12-T01.

## What may run concurrently

- **After DESIGN-E8 (level 0):** C1-T01, C2-T03, C4-T01, C5-T01. All touch different files.
- **Server and client tracks mostly run apart and join fully at C8-T04.** The
  client builds against the fixture DataSource (C3-T01). Before the join, these
  client tickets wait on server tickets: C9-T09 ← C4-T04, C9-T13 ← C8-T03,
  C10-T02 ← C8-T04, C10-T03 ← C6-T05, C10-T04 ← C8-T02, C11-T02 ← C7-T01 and
  MP-E1-C6-T02.
- **Inside C9, after C9-T05:** T06, T07 and T12 can run in parallel. T08 and T09 wait for T07.
- **Inside C11, after C11-T03:** T04, T06 and T08 can run in parallel. T07 needs only T01.
- **File conflicts:** C9 tickets all edit the one hook file (PROPOSED
  `src/priv/static/build-home-hook.js`). Writers split it into modules by
  subsystem (C9-T01 decides the module layout) so parallel tickets do not collide.
  C2-T04 and every visual ticket edit the one stylesheet. Merge in the order listed.

---

## Ticket briefs

### C1 — Parity harness and design fixtures

#### MP-E8-C1-T01 — Design fixture exporter
- **Scope.** A test-support script runs the unmodified `build.js` in a Node `vm`
  context with stub `window`/`document`. It patches a copy of the source text in
  memory (never the file) to expose `dataFor`. It writes the five datasets
  (`live`, `dense`, `newrepo`, `noqueue`, `offline`) as JSON in the payload schema
  that C3-T02 defines, with `NOW` = 2026-10-07 14:20 (J:11).
  - `build.js` builds every date with local-time constructors, so the exporter
    runs with `TZ=America/Los_Angeles` (the same as C1-T02), records the zone in
    the fixture metadata, and fails under any other zone.
  - `offline` is not a `dataFor` dataset (it falls back to `live`). It is the
    render flag `S.demo === "offline"` (J:665, 1066, 1139). Export it as the
    `live` data plus a daemon block (offline, heartbeat 6 min ago, last 14:14).
  - The feasibility review ran this export on 2026-10-07: `build.js` touches no
    DOM at load, and stubs for `window`, `document`, `location` and `history` are
    enough.
  It also records the
  sha256 of `build.js`, `build.css` and the HTML, and fails if they change without
  a re-export (IMPORTED.md rule).
  - Ordering: the schema is C3-T02's. Ship the raw export first, with a mapping
    function that C3-T02 then owns.
  - Fixtures go under PROPOSED `src/test/fixtures/build_home/`.
- **Design elements.** `build`, `dataFor`, `NOW`, `GENERAL`, `POOL`, `FPOOL`,
  `ACTIVE`, `PLAN`, `MODELS`, `AST` (J:11–297).
- **Predecessors.** DESIGN-E8.
- **Cx.** 2.
- **Owns.** EC-20 (frozen clock and time zone in fixtures).

#### MP-E8-C1-T02 — Side-by-side screenshot parity runner
- **Scope.** Add a Playwright spec to `src/browser/` (pattern:
  `support/visual.mjs`, `tests/visual-shell`) that loads:
  - the design HTML as static files with `?example=<dataset>`, after
    `switchTab("build")`;
  - the product at the fixture route with the same dataset.
  It runs both at 1440, 1024 and 390 px, in dark and light, and with the Gruvbox
  and default palettes. Before each run it freezes `Date`, sets
  `TZ=America/Los_Angeles`, uses local fonts and waits for the 600 ms boot timer
  (J:1565).
  - It compares the two by pixel diff. Because the 0.002 threshold of the existing
    `playwright.config.mjs` would hide small drift, it uses its own threshold set
    to the anti-aliasing floor. The writer measures that floor on two design-vs-design
    runs and records it.
  - It also exposes an element-level mode, so a ticket can compare one region
    (for example `.bd-now`).
  - Approved differences are listed in a checked-in allowlist. Each entry cites
    Kevin's approval.
  - The design loads Google Fonts and d3 from CDNs. The runner serves local
    copies.
- **Design elements.** The whole page. H:1910 `#build-root`, H:2059 `#tk-backdrop`.
- **Predecessors.** C1-T01.
- **Cx.** 4.
- **Owns.** EC-28 (theme and palette in the matrix), EC-20.

#### MP-E8-C1-T03 — Motion and interaction parity scripts
- **Scope.** Scripted interaction sequences that run on both the design and the
  product and compare DOM state (classes, inline `top`/`left`/`width`) and frame
  sequences:
  - live snap after scroll (`liveGuard`/`snapLive`, 420 ms ease-out cubic);
  - modal open (`tkin` .24s) and close;
  - column enter and leave (300 ms, 220 ms debounce);
  - view switches, span changes, filter dims, feature focus and compact;
  - minimap drag and jump flash;
  - the whole-tree overlay fade (`bdTreeIn`, C:675–677);
  - the grain overlay, which is static.
  For frames, use Playwright's video or `requestAnimationFrame` sampling with a
  frozen clock. Reduced-motion variants are included.
- **Design elements.** J:575–602, 1234–1241; C:170, 179, 227, 511–513; H:1599.
- **Predecessors.** C1-T02.
- **Cx.** 4.
- **Owns.** EC-19 (reduced-motion parity).

### C2 — Shell, tokens, palette, fonts, assets, CSS

#### MP-E8-C2-T01 — Tokens, Gruvbox palette, body wash, self-hosted fonts
- **Scope.** Bring the design's tokens into `src/priv/static/dashboard.css`:
  - `:root` dark tokens H:22–74, light tokens H:76–124, body background H:128–139;
  - `html[data-palette="gruvbox"]` C:1027–1076, 1141–1154, set as the default (H:1820);
  - aliases for the names the design uses that the dashboard lacks or names
    differently (`--block*` vs `--blocking*`, `--attn*` vs `--attention*`, `--board-bg`).
  Palette persistence follows the theme pattern (`ThemeToggle` hook in
  `layouts.ex`, localStorage `aiur-palette`). The first paint must not flash.
  Self-host Space Grotesk and JetBrains Mono as woff2, next to `bungee.woff2`, in
  `StaticAssets` `long_lived_static_paths`. `dashboard.css` is read at compile
  time (`static_assets.ex`), so a recompile is part of verification.
- **Design elements.** H:12–139; C:1027–1076, 1141–1158.
- **Predecessors.** C1-T02; OQ-E8-1 (tokens change every page).
- **Cx.** 3.
- **Owns.** EC-28.

#### MP-E8-C2-T02 — App shell restyle (top bar, cog menu, sidenav)
- **Scope.** Restyle `AiurWeb.OperatorControlCenter.DashboardShell`
  (`dashboard_shell.ex`, 334 lines) to the design shell:
  - `header.ax-top` with `.ax-brand`, a cog `#ax-set`/`#ax-menu` holding pause
    all, theme and palette, `#ax-title`, and the `#ax-paused` chip;
  - `aside.sidenav` with `.snav` items, `.snav-c` counts (`.attn` red dot),
    `#ax-collapse`, and the `#ax-drag` width handle (`--navw` 60–188 px,
    `html.nav-drag`);
  - `#decisions-banner` and `#page-head` per C:899–928, 991–1016. Note that
    the design **hides** `#decisions-banner` (C:900), `.page-head` (C:901) and
    `.page-head-run` (C:27) on every page, so Commands attention shows only as
    the `.snav-c.attn` count. This is part of S-1.
  Constraints:
  - Keep the server-owned collapse state (#1306) and the writable-gated global
    pause (`global_pause_button`).
  - The nav items come from `route_registry.ex`. The design's items are Build,
    Commands, Analytics, Khala and Streamdeck.
  - The Khala item waits on OQ-E8-2. Default: no Khala item.
  - The mobile pill nav below 960 px must still work.
- **Design elements.** H:1823–1899; C:5–47, 899–928, 991–1016, 1077.
- **Predecessors.** C2-T01; OQ-E8-1, OQ-E8-2.
- **Cx.** 4.
- **Owns.** EC-12 (pause all is writable-gated), EC-18 (shell under 960 px),
  EC-19 (menu keyboard access).

#### MP-E8-C2-T03 — Static assets and the four-place hook registration
- **Scope.** Add the design assets and two empty entry points for the home
  hook and stylesheet.
  - **Assets.** `kimi-logo.png` (12 KB) and `deepseek-logo.png` (413 KB) are
    missing. The token SVGs exist but differ in bytes from the design's
    (`claude-token.svg`, `codex-token.svg`), so the home page uses the design's
    files under their own names and other pages keep theirs. The 413 KB PNG is
    re-encoded at 2× its largest display size; C1-T02 proves no visible change.
  - **Loading without a bundler.** Follow the `aiur-dom-svg-layout` precedent:
    one `build-home/` directory entry in `StaticAssets` `@revalidated_static_paths`,
    one loader `<script defer>` in `layouts.ex`, and one `Hooks` map entry. Later
    C9–C11 tickets add module files under `build-home/` without touching
    `layouts.ex` or `StaticAssets`.
  - Unknown model fallback asset: the design's `.ax-mono` letter circle (J:1018).
- **Design elements.** `design-source/assets/*`.
- **Predecessors.** DESIGN-E8.
- **Cx.** 1.
- **Owns.** —

#### MP-E8-C2-T04 — Consolidated home stylesheet from build.css
- **Scope.** Turn `build.css` (1193 lines, about ten override passes) into one
  ordered stylesheet section with the same computed style for every element the
  product renders.
  - Delete the dead rules the inventory lists: `.bd-now-g`, `.bd-mock`, `.bd-prop`,
    `.bd-tg`, `.bd-m-*`, `.bd-now-strip`, `.bd-more`, `.bd-gl`, `.bd-fa`,
    `.bd-fd` (the design hides it: "feature diamond removed from cards", C:1182–1183),
    `.bd-card.compact`, `.bd-root.narrow`, `.lay-tiles`, `.lay-stack`,
    `.bd-feats`, `.bd-fp`.
  - Keep the class names (`bd-*`, `cv-*`, `bm-*`, `ax-*`, `lr-*`, `mm-*`, `lst`).
  - Proof: a computed-style snapshot test. Playwright reads
    `getComputedStyle` for every element in each fixture, on the design and on the
    product. It must be equal, except for properties on the C1-T02 allowlist.
  - Decide whether the section lives in `dashboard.css` or in a second file. A
    second file must be registered in `StaticAssets`.
- **Design elements.** All of C.
- **Predecessors.** C2-T01, C1-T02.
- **Cx.** 4.
- **Owns.** EC-28.

### C3 — Home LiveView, data seam, payload protocol, URL state

#### MP-E8-C3-T01 — BuildLive, DataSource behaviour, fixture source
- **Scope.** PROPOSED `AiurWeb.BuildLive` mounted at a temporary route (`/build`)
  inside `live_session :dashboard` (`router.ex`; `on_mount` FinancialDataAccess).
  It renders `DashboardShell` and `<div id="build-root" class="bd-root" phx-hook=…
  phx-update="ignore">`, plus the `#tk-backdrop` modal containers.
  - **Every container the hook writes into** (`#tk-backdrop` and its children,
    and the `.ax-pop` popover host) also has a stable id and
    `phx-update="ignore"`. Otherwise a LiveView patch (nav counts, URL patch)
    resets the open modal. Test: a server re-render while the modal is open keeps
    it open.
  - **Seam scan** (merged from the retired C3-T04). A source-scan test keeps
    `aiur_web/build/` and the history and feature modules on their seam. Allowed:
    the DataSource, `Aiur.BuildOrder.*`, the per-ticket Units row, AgentChat,
    DecisionCommands and BuildQueue public APIs (pattern: MP-E1-C1-T07). File the
    component-map request (CR-E8-6).
  - PROPOSED `AiurWeb.Build.DataSource` behaviour, modelled on
    `AiurWeb.BuildOrder.DataSource` (swappable through `Application.get_env`,
    every dependency injectable).
  - A fixture implementation that serves the C1-T01 JSON, with a fixed `now`.
  - The browser harness `fixture_server.exs` gets a route for it.
- **Design elements.** H:1910, 2059–2064.
- **Predecessors.** C1-T01, C2-T03.
- **Cx.** 3.
- **Owns.** EC-01 (loading before the first payload), EC-10 (modal survives patches).

#### MP-E8-C3-T02 — Payload schema v1, diff and resync protocol
- **Scope.** Define the JSON the hook consumes, as a versioned schema with an
  ExUnit contract test.
  - **Initial snapshot:** epics, features, order, counts, tickets in four
    sections, usage, daemon, `now`, `generation`.
  - **Ticket row:** id, num, title, type, epic, feature, also, cx, pts, sec,
    start, end, status, pct, agent {model, state, effort}, est, override, added,
    deps, wave, qpos, cue {held, promoted, wait, waitAny, failed, blockedChain},
    created, url facts.
  - **Diffs** through `push_event`, keyed by ticket id, with a monotonic
    `generation`.
  - **Rejoin or gap:** the hook detects a generation gap and requests a full
    snapshot.
  - **Duplicate or old diffs** are ignored.
  - **Client→server events:** `load_earlier` (day), `open_ticket`,
    `conversation_page`, `send`, `pause`, `resume`, `answer`, `queue_add`.
  - **Size budget:** measured against the initial window C8-T04 sends (all
    planned, now and not-queued rows plus the last two active days of history),
    not the whole index. Baseline: the design's dense rows alone measure about
    451 KB uncompressed for 1,384 tickets (about 326 B each; feasibility review,
    2026-10-07), and `/live` has no websocket compression today. The writer sets
    the window budget from a measurement; C12-T06 measures the whole index and
    decides on compression.
  - **Escaping:** every string is data; the hook escapes on render (the design's
    `esc`, J:9).
- **Design elements.** The data shape `build()` returns (J:294).
- **Predecessors.** C3-T01.
- **Cx.** 4.
- **Owns.** EC-11, EC-30 (escape), EC-09 (payload size).

#### MP-E8-C3-T03 — Server-owned URL state and legacy URL presets
- **Scope.** `handle_params` parses and validates every design parameter:
  - `view` (graph|gantt|list), `span` ∈ `SPANS`, `feature`, `fmode`;
  - the comma lists `epic`, `model`, `tstate`, `astate`;
  - `live=min`, `trees=1`, `ticket`.
  Unknown values are dropped. The hook calls `pushEvent` → `push_patch(replace:
  true)` instead of a bare `history.replaceState` (J:327), so LiveView and the
  address bar agree. `example` and `models` are demo parameters and are not
  supported. Legacy Units URLs (`?v=1&scope=…&conditions=…`, `units_url.ex`) map
  to `astate`/`tstate` presets. Back and forward navigation restore state.
- **Design elements.** `readURL`/`writeURL` J:304–328.
- **Predecessors.** C3-T01.
- **Cx.** 2.
- **Owns.** EC-26, EC-17 (ticket param validation).

#### MP-E8-C3-T04 — retired
Merged into C3-T01 by the review pass on 2026-10-07. Do not write a doc for it.

### C4 — Durable history store

#### MP-E8-C4-T01 — `Aiur.BuildOrder.History` store
- **Scope.** PROPOSED `src/lib/aiur/build_order/history.ex`. An event-sourced
  index of every issue: number, title, state, stateReason, createdAt, closedAt,
  merged_at, PR number, type labels, the epic and feature inputs, parent,
  blocked_by, start, end, observed_at.
  - Persisted with `Aiur.JsonStore.write!` (atomic rename and fsync) under a
    `Config.Paths` key in `decision_state_dir`.
  - A versioned file. A corrupt file fails closed: the store reports
    unavailable, never empty.
  - A PubSub change signal.
  - Memory for 1.4k issues is about 0.4 MB; the writer checks 10k.
- **Design elements.** —
- **Predecessors.** DESIGN-E8.
- **Cx.** 3.
- **Owns.** EC-07, EC-31.

#### MP-E8-C4-T02 — One-time history backfill (about 30–45 GraphQL points)
- **Scope.** A daemon-owned job, because the agent `gh` wrapper refuses GraphQL
  (`apis/github.md`). It runs the census query measured on 2026-10-06 (state,
  stateReason, createdAt, closedAt, labels(30), parent, blockedBy(first:100),
  timelineItems filtered to LABELED/UNLABELED/CONNECTED/CLOSED).
  - Pages of 100, resumable from a checkpoint.
  - Paced, and held on a GitHub budget hold.
  - Runs once per repository.
  - The PR states the measured points per AGENTS.md "A claimed saving must be
    measured". This is a cost, not a saving: state the number. The baseline's
    about 30 points came from two separate 1-point-per-page queries; one combined
    query with `blockedBy` nested costs about 3 points per page (about 42–45 in
    total).
  - The store is rewritten whole by `JsonStore.write!`, so writes are coalesced
    (the writer sets the interval from the measured event rate).
  - **Read `website/docs-app/apis/github.md` first.**
- **Design elements.** —
- **Predecessors.** C4-T01.
- **Cx.** 4.
- **Owns.** EC-32, EC-31 (resume after restart).

#### MP-E8-C4-T03 — Steady-state history feed and boot catch-up
- **Scope.** Update History from existing feeds, with no new polling: ResourceStore
  `:issue` and `:issue_dependency` deposits, the open-issue poll, webhook
  deliveries, `RecentMergeStore`, and run telemetry dispatch events.
  - At boot, one "closed since the checkpoint" GraphQL page.
  - Updates are idempotent.
  - The store rows carry `observed_at`.
  - A reopened issue moves back to open.
- **Design elements.** —
- **Predecessors.** C4-T01.
- **Cx.** 4.
- **Owns.** EC-10 (source side), EC-31, EC-32.

#### MP-E8-C4-T04 — Start and end times for Gantt
- **Scope.** Define start and end and journal them.
  - **End:** PR merged_at, else closedAt.
  - **Start:** the first `agent:in-progress` labeled event, else the first
    telemetry dispatch, else `unknown`. Never createdAt.
  - Paused time and rework stay inside the bar, as the design draws one bar per
    ticket (J:442).
  - New starts are journaled at the write, not read back from the bus (MP-E1 F2).
  - A reopened ticket keeps its latest end.
  - Zero or negative durations are clamped to the design's minimum height.
  - The "start unknown" card treatment is sign-off item S-5. Default: an
    end-anchored minimum-height card with a "start unknown" title tooltip.
- **Design elements.** `ganttHist` inputs (J:424–470).
- **Predecessors.** C4-T02, C4-T03.
- **Cx.** 3.
- **Owns.** EC-22.

#### MP-E8-C4-T05 — Historic edges, children index, order violations
- **Scope.** Edges from `blocked_by` (73 native edges today) plus the children
  index (J:288). An edge whose blocked ticket closed before its blocker reuses
  `EdgeState :terminal_unsatisfied`. An edge to a ticket that is not in the index
  is kept as data with `missing: true`; the hook drops it, as the design does
  (J:903). Cycles are allowed in data. Every traversal (`chainOf`, the tree depth
  in `openTree`) guards against them.
- **Design elements.** `D.children`, `deps`.
- **Predecessors.** C4-T02.
- **Cx.** 2.
- **Owns.** EC-21.

### C5 — Epics

#### MP-E8-C5-T01 — Epics config section and docs
- **Scope.** PROPOSED `Aiur.Config.Schema.BuildHistory` with a per-repository
  list of general epics. Each epic has a key, label, label matchers, hue and icon.
  - Defaults: Bugs (hue 38, matcher `bug`), Design (312), Infra (200, `refactor`,
    `chore`), Docs (100, `documentation`).
  - The writer confirms the matchers against the label census (baseline §5).
  - Validation rejects any `epic:` matcher, because `IssueSync` parks `epic:*`
    (options §1.2).
  - Docs go in `reference/configuration.md`, and `scripts/check-config-docs.py`
    must pass.
  - Templates: `.aiur/examples/config.example` and `src/examples/workflows/*`.
- **Design elements.** `GENERAL` (J:96), the epic icons `I.bug/pen/server/docs`.
- **Predecessors.** DESIGN-E8.
- **Cx.** 2.
- **Owns.** EC-21.

#### MP-E8-C5-T02 — Epic resolver
- **Scope.** A pure function in `Aiur.BuildOrder` that returns exactly one epic:
  feature epic (from the owning feature), then override, then the first general
  matcher in config order, then `unsorted`. Each answer comes with its source
  (`feature`, `override:<actor>`, `label:<name>`, `default`). Property tests:
  always exactly one; deterministic.
- **Design elements.** `colKey` (J:332), `epics.unsorted` (J:116).
- **Predecessors.** C5-T01.
- **Cx.** 2.
- **Owns.** EC-21.

#### MP-E8-C5-T03 — Epic override registry and batch CLI
- **Scope.** A durable override store: ticket → epic, with actor, at, source
  (`cli:<who>`, `agent:<ticket>`, `backfill-agent`) and `confirmed`.
  - CLI `aiur epic set <epic> <ids…>`, with `--source` and `--json`, through the
    shared launcher engine.
  - Callable from agent workspaces: E8-D9 asks for "a single CLI or tool call".
    The writer checks the agent-workspace guard rules.
  - Concurrency: last write wins, and each write is journaled.
  - An unknown epic is rejected.
  - The CLI is documented in `reference/cli.md`.
- **Design elements.** —
- **Predecessors.** C5-T02.
- **Cx.** 3.
- **Owns.** EC-13.

#### MP-E8-C5-T04 — Skill and prompt guidance for categories
- **Scope.** Edit `.claude/skills/aiur-build`, `aiur-run`, `aiur-agent` and the
  planner prompts (`src/prompts/`) so planning agents give every ticket an epic,
  use feature epics where a feature needs them, and run the batch CLI. They also
  learn `aiur ticket estimate` and its rule: override an estimate only with a
  strong reason, which is recorded (E8-D7).
  `website/docs-app/skills.md` is updated too.
- **Design elements.** —
- **Predecessors.** C5-T03, C6-T04, C7-T03.
- **Cx.** 2.
- **Owns.** —

### C6 — Features

#### MP-E8-C6-T01 — Feature registry and membership journal
- **Scope.** PROPOSED `Aiur.BuildOrder.Features`, a durable store with:
  - feature: slug, label, hue, feature epics (key, label), from/to times,
    baseline (a membership snapshot and time), optional `public_ref` (E8-R1);
  - membership: one owning feature per ticket (E8-D11), plus "also affects"
    links;
  - a journal of `member.added`/`removed` events with source and actor.
  A ticket is in at most one owning feature: adding it to a second one is an
  error unless `--move` is given. **Hue** (OQ-E8-6 default): a stable hash of the
  slug into the design's hue range that the general epics leave free,
  overridable with `--hue`. With no baseline, all members count as original
  and the header says so.
- **Design elements.** `features`, `addF` (J:117–121).
- **Predecessors.** C5-T02.
- **Cx.** 3.
- **Owns.** EC-24, EC-13.

#### MP-E8-C6-T02 — `feature:` label projection and reconciliation
- **Scope.** The registry is the system of record, and labels are a projection
  (options F-C).
  - A `feature:<slug>` label without a registry entry becomes a join with source
    `label:<login>`.
  - A registry join without the label writes the label, paced like MP-E1
    (`max_writes_per_minute`).
  - Register `feature:` in the label families aiur-build's reconciliation test
    accepts (MP-E1 F10).
  - Label rename or removal: removal leaves the feature and journals the leave.
- **Design elements.** —
- **Predecessors.** C6-T01.
- **Cx.** 3.
- **Owns.** EC-13, EC-32.

#### MP-E8-C6-T03 — Build Order roots imported as features
- **Scope.** Every `build-order` root becomes a feature. Its members come from
  its sub-issues, and join times from `SubIssueAddedEvent.createdAt` (backfill).
  There are no label writes for history. A root's `build-lane:` slugs become
  feature epics. The import is idempotent.
- **Design elements.** —
- **Predecessors.** C6-T01.
- **Cx.** 2.
- **Owns.** EC-24.

#### MP-E8-C6-T04 — `aiur feature` CLI
- **Scope.** `aiur feature create|add|remove|also|baseline|show`, with `--json`,
  `--hue` on create,
  batch ids, and the actor recorded. Agents can call it. Documented in
  `reference/cli.md`.
- **Design elements.** —
- **Predecessors.** C6-T01, C6-T02.
- **Cx.** 3.
- **Owns.** EC-13.

#### MP-E8-C6-T05 — Feature statistics
- **Scope.** Port `featStats` (J:343–352) to the server:
  - done/total;
  - weighted % (Σpts×fraction / Σpts, E8-R1 "weighted");
  - original → now and added;
  - the daily scope series for the sparkline;
  - the also-affects count, which never counts toward progress (E8-D11).
  Unknown inputs give `unknown`, not 0.
- **Design elements.** `featStats`; `.bd-fh` figures.
- **Predecessors.** C6-T01, C4-T01.
- **Cx.** 2.
- **Owns.** EC-24, EC-08.

### C7 — Planned, not-queued and estimates

#### MP-E8-C7-T01 — Planned rows, waves and cues from the build queue
- **Scope.** Map `Aiur.BuildQueue.show/1` (MP-E1-C6-T01, contract §3) to planned
  rows:
  - `qpos`;
  - `wave` = the prerequisite level inside the queue rank (no 100-node cap);
  - `cue.promoted` (age);
  - `cue.held` (actor and reason; if the read model lacks them, raise a contract
    request);
  - `cue.wait`, `waitAny`;
  - `cue.failed` {by, blocks[]}, `blockedChain` (MP-E1-C5-T02 attentions).
  States:
  - "queue disabled" and "store unavailable" are explicit states. They are never
    shown as "Nothing planned".
  - A queued item whose issue closed leaves the section.
  This ticket replaces MP-E1-C8-T01.
- **Design elements.** `PLAN` cues, `tstate` (J:333), `.bd-q`, `.bd-alert`, the W
  labels.
- **Predecessors.** C4-T01, MP-E1-C6-T01, MP-E1-C7-T02, MP-E1-C5-T02.
- **Cx.** 3.
- **Owns.** EC-03, EC-23.

#### MP-E8-C7-T02 — Unfiled planning-pack items as planned rows
- **Scope.** Planning-pack items that are not filed on GitHub yet. They show
  as "Planned · not filed", with the source line "<pack path> · wave N · not
  filed yet" in the modal. The path comes from the pack, not a hard-coded
  `docs/build-plan.md`.
  - **Reading packs.** `AiurWeb.BuildOrder.PlanningSource` today replaces the
    live Build Order source (selected by `config :aiur, :build_order_data_source`;
    its moduledoc calls it demo and planning tooling). It is not an extra feed.
    This ticket calls its pack loader (`load_packs` and the pack-path helpers)
    as an extra read, with its own configured pack path and an explicit "no pack
    configured" state.
  - **Order.** The design puts them after the filed planned items (waves ≥ 5,
    J:1378). They have no queue position, so they sort by pack wave, then pack
    order.
  - They use provisional ids. When an item is filed, its row moves to the real
    ticket id without a duplicate.
- **Design elements.** `fromDoc` (J:1378, 1394, 1429).
- **Predecessors.** C7-T01.
- **Cx.** 2.
- **Owns.** EC-23.

#### MP-E8-C7-T03 — Estimates, overrides, CLI and ETA
- **Scope.**
  - **Default estimate (hours):** from complexity, `EST = [1,2,4,7,11]` (J:94),
    unless OQ-E8-7 picks the historical median.
  - **Overrides** (E8-D7): hours, reason, actor and time, in a durable store.
  - **CLI:** `aiur ticket estimate <id> <hours> --reason`.
  - **ETA:** in the band header, Σest ÷ the agent cap. The design divides by a
    hard-coded 4 (J:667); the product uses `agent.max_concurrent_agents`.
  - Unknown complexity gives no estimate ("—").
- **Design elements.** `.bd-q.ovr`, `.bd-now-eta`, `override`.
- **Predecessors.** C7-T01; OQ-E8-7.
- **Cx.** 3.
- **Owns.** EC-08, EC-13.

#### MP-E8-C7-T04 — Not-queued rows
- **Scope.** Not queued = open, not a queue item, and no active agent state.
  `agent:todo` outside a queue counts as planned (options §3.3). Status line:
  "Open · not queued · N pts". Sorted by created date, newest first, as the
  design's order shows. Hundreds of rows must work.
- **Design elements.** The `nq` section (J:266–275, 862).
- **Predecessors.** C4-T01, MP-E1-C6-T01.
- **Cx.** 1.
- **Owns.** EC-04.

### C8 — Live state, usage, daemon status, ticket index

#### MP-E8-C8-T01 — Now-band rows and agent-state mapping
- **Scope.** Build now rows from `UnitsRow.snapshot`/`UnitsPresenter`, made
  per ticket.
  - **Model or harness → logo key:** claude, codex, deepseek, kimi, muse,
    openrouter; anything else is the mono-letter fallback.
  - **State → `AST`:**
    - running → active;
    - error → error;
    - retry exhausted → retries;
    - blocked on a human Command → command;
    - paused → paused;
    - parked (account limit or capacity, #2742) → parked.
    The writer maps every `UnitsPolicy` condition and records the table.
  - **Other fields:** pct, start, est. An unknown pct sets neither `--pct` nor
    `--ph` (the progress hue, J:1386). The CSS fallback `var(--ph, 60)` would
    otherwise paint an amber "early progress" tone for an unknown value. Mutation
    test: the test fails if the 60-hue fallback renders.
  - **Logos for models the design lacks** (muse, openrouter, unknown) use the S-13
    default: the `.ax-mono` letter circle sized to each logo slot.
- **Design elements.** `AST`, `MODELS` (J:82–91).
- **Predecessors.** C3-T02.
- **Cx.** 3.
- **Owns.** EC-05, EC-08.

#### MP-E8-C8-T02 — Usage strip data
- **Scope.** Map the existing provider meters (`ProviderMeterRefresh`, the
  `ProviderMetersLive` fixture) and the GitHub budget (core, GraphQL) to the
  design rows:
  - per provider: session and weekly windows per account, reset times, credits,
    and "not observed";
  - the "Search" row only if a search provider meter exists; otherwise omitted.
  Usage is financial data: follow `FinancialDataAccess` (`financial_data_capability`).
- **Design elements.** `PSETS`, `renderUsage` data (J:991–1036).
- **Predecessors.** C3-T02.
- **Cx.** 3.
- **Owns.** EC-25, EC-12.

#### MP-E8-C8-T03 — Daemon, freshness and offline signals
- **Scope.** Server side:
  - daemon live/stale from the Orchestrator snapshot age;
  - per-source `observed_at`.
  Client side:
  - socket disconnect (`phx:disconnected`) → stale mode with "cached HH:MM" and
    the offline banner;
  - "Reconnect" calls `liveSocket.connect()`.
  Copy: "last heartbeat N min ago (HH:MM)" uses the real age.
- **Design elements.** `renderOffline`, `.bd-root.stale`, `.bd-daemon.off`
  (J:1065–1068, 1139).
- **Predecessors.** C3-T02.
- **Cx.** 2.
- **Owns.** EC-06, EC-07.

#### MP-E8-C8-T04 — Ticket index assembler, live diffs, history by day
- **Scope.** The real DataSource.
  - **Joins:** History, epic resolver, features, planned, not-queued, now rows,
    usage, daemon.
  - **Subscribes** to the existing topics: TicketActivity, `AgentPubSub` running,
    the queue change signal, History, Features, and the provider meters.
  - **Diffs:** changes are coalesced (≤ 500 ms) into per-ticket diffs.
  - **Section moves** (plan → now → hist) are one diff.
  - **History by day:** the initial window is the last two active days (dense:
    one, J:746); `load_earlier` returns the previous day.
  - **Errors:** a source failure degrades that section to unavailable and does
    not crash the page.
- **Design elements.** `D` shape, `histDays`, `loadEarlier`.
- **Predecessors.** C3-T02, C4-T03, C5-T02, C6-T05, C7-T01, C7-T04, C8-T01.
- **Cx.** 4.
- **Owns.** EC-09, EC-10, EC-11.

### C9 — Client timeline engine (port of build.js)

#### MP-E8-C9-T01 — Hook shell, scrollbar, payload intake, URL bridge
- **Scope.** The LiveView hook (PROPOSED `src/priv/static/build-home-hook.js`,
  split into modules) that:
  - ports `shell()` (J:543–573): toolbar hosts, `.bd-vpw`, `#bd-vp`, the overlay
    scrollbar `#bd-sb` with drag and track click and its `.act` (700 ms reveal),
    `.drag` and `.off` states (J:554–559), the Escape and outside-click handlers,
    the resize handler;
  - replaces the design's `NOW` constant with the payload's `now` everywhere it
    is read (band time, `jumpNow`, Gantt), not only in `build()`;
  - replaces `build()`/`dataFor` with the payload from C3-T02;
  - applies diffs;
  - bridges URL state to C3-T03.
  The writer fixes the module layout that the other C9 tickets fill in. The hook
  survives LiveView patches (`phx-update="ignore"` on `#build-root`) and cleans up
  intervals on `destroyed`.
- **Design elements.** J:536–573, 1265–1269, 1549–1576.
- **Predecessors.** C3-T02, C3-T03, C2-T04.
- **Cx.** 4.
- **Owns.** EC-11 (client side).

#### MP-E8-C9-T02 — Timeline layout and density tiers
- **Scope.** Port `computeLayout` rows and labels (J:356–422, 497–533) without
  Gantt:
  - row packing per epic, the day labels and lines;
  - density tiers from span (bar, mini, line, full);
  - flow mode when columns are under 62 px (J:648);
  - the planned waves.
  Keep the constants `LH`, `SEC`, `CH` and `gap`.
- **Design elements.** `computeLayout`, `rows`, `.bd-lbl`, `.bd-dl`, `.bd-mk.wave`.
- **Predecessors.** C9-T01.
- **Cx.** 3.
- **Owns.** EC-18 (flow mode is the narrow layout).

#### MP-E8-C9-T03 — Virtualised rendering and history paging
- **Scope.** Port `update()`, `place()`, `relayout()` and the ±700 px render
  window (J:638–675, 695–767). `loadEarlier` (J:747) becomes a server request
  that keeps the scroll anchor. Cards are recycled by uid. A live diff that moves
  a card keeps scroll position. The section headers ("History since … · N of M
  loaded").
- **Design elements.** J:638–767; `.bd-sec`, `.bd-sech`, `.bd-layer`.
- **Predecessors.** C9-T02.
- **Cx.** 3.
- **Owns.** EC-09, EC-10.

#### MP-E8-C9-T04 — Dynamic epic columns
- **Scope.** Port:
  - `visibleCols`: whole visible days, the fixed forward set, the feature lock,
    and the epic-filter fallback;
  - `applyCols` and `syncKeyed`: enter and leave, the 300 ms removal, the 220 ms
    debounce;
  - lane headers: icon, label, count or lock; `temp`, `unsorted`, `lock`, `first`;
  - the guides (J:677–693, 769–804);
  - the lane container query at 132 px (C:32).
  Kevin accepted that general columns move as you scroll (E8-D13).
- **Design elements.** `.bd-lanes`, `.bd-lane`, `.bd-guide`, `.bd-lane-g`.
- **Predecessors.** C9-T03.
- **Cx.** 3.
- **Owns.** EC-21 (Unsorted column).

#### MP-E8-C9-T05 — Ticket cards in four tiers
- **Scope.** Port `cardDetail`, `makeCard` and `decorate` (J:807–877):
  - the four tiers;
  - per-section content (hist Merged/Failed with date; now state and %; plan
    Qn, cues, ≈h · pts; nq);
  - the type icon and the complexity glyph with its points hue. **No feature
    dot:** the design hides `.bd-fd` (C:1183); feature membership shows through
    `feat-on` (C10-T03) and the modal's ◆ meta;
  - the progress hue `--ph` (J:824; C:456–457) on now cards, with the C8-T01
    unknown rule;
  - the card container-query tiers at 150 and 96 px (C:350–372).
  All text is escaped, and titles may contain any characters. Clicking a card
  opens the modal (C11-T01). The `noanim` first-paint rule is kept.
- **Design elements.** `.bd-card`, `.bd-in`, `.bd-top`, `.bd-cx`, `.bd-status`,
  `.bd-bar`, `.bd-cues`, `.bd-q`, `.bd-alert`, `.bd-ic`, `.bd-id`, `.bd-title`.
- **Predecessors.** C9-T03.
- **Cx.** 4.
- **Owns.** EC-30, EC-08.

#### MP-E8-C9-T06 — Agent indicators (logo, glow, stuck, idle)
- **Scope.**
  - **Logo:** `span.bd-ag` (`.fill` variant).
  - **Glow:** `span.bd-glow` with `bdRot` (9 s conic, `@property --bd-a`);
    `bdStuck` (3.2 s); `ag-idle` static.
  - **Reduced motion:** the static equivalents (`.bd-root.rm`).
  - **Accessibility:** the design's state glyph is empty (`glyph = ""`, J:827),
    so the state appears only in a `title`. Add an `aria-label` / visually-hidden
    text with the `AST` label, which does not change pixels. Whether a visible
    glyph is wanted is S-4.
- **Design elements.** J:818–828; C:225–301 (`.bd-ag`, `.bd-glow`), C:1110–1124.
- **Predecessors.** C9-T05.
- **Cx.** 2.
- **Owns.** EC-19.

#### MP-E8-C9-T07 — Dependency edges
- **Scope.** Port `drawEdgesSoon`, `drawEdges` and the signature cache
  (J:879–932):
  - vertical and horizontal beziers and arrowheads;
  - edge classes `ok`/`bl`/`bad`/`gh` with `hl`/`fade`;
  - the `.bd-eh` hit paths (click → lock);
  - the blurred band edge layer `.bd-now-e`.
  Edges are drawn only between rendered cards, and edges to tickets that are not
  loaded are dropped, as in the design. rAF loops must stop when the hook is
  destroyed.
- **Design elements.** `svg.bd-edges`, `.bd-e`, `.bd-ea`, `.bd-eh`, `.bd-now-e`.
- **Predecessors.** C9-T05.
- **Cx.** 3.
- **Owns.** EC-21, EC-09.

#### MP-E8-C9-T08 — Now band, live snap and jump to live
- **Scope.**
  - **Band layout:** BK stacks of ≤ 380 px (J:487–496).
  - **Header:** the Live pulse, time or "cached", the running/stuck/paused
    buttons as `astate` filters, ETA, minimise and the `.bd-now-sum` bar.
  - **States:** the `.bd-now-empty` state; `?live=min`.
  - **Sticky:** sticky at the top and bottom.
  - **The top-to-bottom transition:** `liveGuard`, `snapLive`, `scrollVP` with
    420 ms ease-out cubic, the T=36 thresholds and the 460–480 ms lock, with no
    snapping during scrollbar drag, paging, loading or list view.
  - **Jump to live:** `#bd-nowbtn` with the `.at` state (J:738).
  - **Band appearance:** the `::before` accent line and the dark-only `::after`
    grain (C:1125–1131).
  - **Overflow:** many agents (20+) make a tall band, and the snap then gives up
    (J:588). Keep that.
- **Also:** `markScrolling` (J:575–578): `.bd-content.scrolling` turns off card
  pointer events and transitions, hides the unlocked `.bd-lt` tab, clears hover,
  and runs `snapLive` 200 ms after scrolling stops (C:353–354, 670).
- **Design elements.** J:487–496, 575–602, 662–671, 1234–1248; C:214–223,
  378–403, 1080–1131, 1187–1193.
- **Predecessors.** C9-T05, C9-T07.
- **Cx.** 4.
- **Owns.** EC-05, EC-19 (instant scroll under reduced motion).

#### MP-E8-C9-T09 — Gantt mode
- **Scope.**
  - Port `ganttHist`: interval merge, idle gaps over 3 h compressed to `BRK`,
    "Idle · … · Nh" labels when ≥ 20 h, hour ticks, `assignLanes` (J:424–485).
  - Planned Gantt cards: est or override height, `gplan` styling, the "≈ +Nh"
    cumulative labels (J:509–523).
  - Band Gantt heights.
  - Card time and badges (J:845–848).
  - The "Planned estimate" legend.
  - "Start unknown" uses the C4-T04 treatment (S-5).
  - Dependency arrows between Gantt cards (E8-D4) use the C9-T07 edges on Gantt
    geometry (variable heights, compressed idle gaps), with a C1-T02 check in
    Gantt view.
- **Design elements.** `.bd-mk.brk`, `.bd-card.gplan`, `.bd-time`, `.bd-badges`,
  `.bd-leg-h`.
- **Predecessors.** C9-T05, C9-T07, C4-T04.
- **Cx.** 4.
- **Owns.** EC-22, EC-20.

#### MP-E8-C9-T10 — Span, zoom and calendar controls
- **Scope.** `SPANS`, `setSpan`, `calNear`, the Day/Week/Month buttons with
  `CALI` icons, zoom −/+ with the `%` label and its disabled ends, `jumpNow`
  after a span change, and the dot-grid `--dot` (J:654, 1222–1248). `fitTree` uses
  these (C9-T11).
- **Design elements.** `.bd-cal`, `.bd-zoom`, `.bd-zv`, `.bd-vp` dot grid
  (C:1095–1099).
- **Predecessors.** C9-T02.
- **Cx.** 2.
- **Owns.** —

#### MP-E8-C9-T11 — Dependency chains, lock tab, whole-tree view
- **Scope.**
  - Port `chainOf` (cycle-safe), `onHover`, `setHover`, `lockTree`, `unlock`,
    `fitTree`, the `.bd-lt` lock/fit/eye tab, and `openTree`/`closeTree`
    (J:933–985, 1183–1221).
  - Hover is on only with `?trees=1`, as in the design (S-3).
  - Touch devices have no hover. Tapping a card opens the modal, as the design
    does.
  - The tree layout's `dep()` must not recurse forever on a cycle.
  - The 200 ms hover clear on content `mouseleave` (J:619) and the tree overlay
    fade with backdrop blur (`bdTreeIn`, C:675–677).
- **Design elements.** `.bd-lt`, `.bd-tree`, `.bd-tree-h`, `.bd-tn`, `.hl`,
  `.hdim`, `.bd-content.hovering`.
- **Predecessors.** C9-T07.
- **Cx.** 3.
- **Owns.** EC-21, EC-18.

#### MP-E8-C9-T12 — List view
- **Scope.** Port `renderList` (J:1151–1181):
  - the table roles;
  - sections Live, Planned, Not queued, History (newest first);
  - the state chips `lst st-*`;
  - the agent column;
  - progress with `--ph` (C:761–763), deps ↑↓;
  - "Load earlier day".
  The list view is also the screen-reader-friendly view. Rows are focusable, and
  Enter opens the modal.
- **Design elements.** `.bd-list`, `.lr`, `.lr-h`, `.lh`, `.c-*`, `.lr-*`, `.lst`.
- **Predecessors.** C9-T01.
- **Cx.** 2.
- **Owns.** EC-19, EC-04.

#### MP-E8-C9-T13 — Loading, empty and stale board states
- **Scope.**
  - `renderLoading`: lane skeleton, 16 skeleton rows, the spinner "Loading build
    timeline…".
  - Empty markers: "No history yet …", "Nothing planned … N open tickets are not
    queued …" (J:419, 499).
  - `.bd-root.stale` styling.
  - Distinct copy for "queue unavailable" and "history unavailable" is S-9. They
    must never show as empty.
- **Design elements.** `.bd-skel*`, `.bd-loading`, `.bd-spin`, `.bd-mk.empty`.
- **Predecessors.** C9-T03, C8-T03.
- **Cx.** 2.
- **Owns.** EC-01, EC-02, EC-03, EC-06, EC-07.

### C10 — Toolbar, filters, feature header, usage strip

#### MP-E8-C10-T01 — Toolbar and status line
- **Scope.** Port `renderTools` (J:1128–1150): the view segment
  (Timeline/Gantt/List), the right tools, and the status line (`.bd-daemon`,
  legend).
  - **Remove the "Demo data" select** (`#bd-exl`). It is mock-only, and the
    fixtures replace it.
  - Final toolbar order and the breakpoints at 1180 and 720 px (C:613–644,
    1018–1024).
- **Design elements.** `.bd-toolbar`, `.bd-bar-l/-r`, `.bd-seg.vw`, `.bd-live`,
  `#bd-status`, `.bd-key`, `.bd-leg`.
- **Predecessors.** C9-T01.
- **Cx.** 2.
- **Owns.** EC-18.

#### MP-E8-C10-T02 — Filters, popovers and the `not_planned` default
- **Scope.** Port `FOPTS`, `renderFilters`, `match`, `filtersChanged` and `syncAst`
  (J:1097–1127, 335–342) with real option lists:
  - every model the product has a logo for, as the design lists all `MODELS`
    (J:1098);
  - the last 6 features;
  - epics with counts;
  - ticket and agent states.
  Semantics: OR within a group, AND across groups.
  - **Epic** removes tickets and relays out (`epicOk`). The other groups dim.
    Keep that difference.
  - Clear; outside click closes the popover.
  - Filters write the URL (C3-T03).
  - **`not_planned` default (E8-R1).** C8-T04 maps `stateReason = not_planned` to
    a ticket state `closed · not planned`. It is collapsed by a default filter
    that appears in the URL and in the Ticket group, so it can be shown. The
    design has no such state; its look is S-17 (default: the `failed` swatch
    family in the muted tone, label "Not planned").
  - **Ticket type.** There is no type filter (OQ-E8-4 default). If Kevin wants
    one, it adds a sixth group to `FOPTS` with options from the type labels and a
    `type` URL key (about +1 complexity).
- **Design elements.** `.bd-filters`, `.bd-fg`, `.bd-fclear`, `.bd-pop`, `.bd-opt`,
  `.lst`.
- **Predecessors.** C10-T01, C9-T05.
- **Cx.** 3.
- **Owns.** EC-26, EC-24 (>6 features).

#### MP-E8-C10-T03 — Feature header, focus and compact modes
- **Scope.** Port:
  - `renderFeatures`: name, Done, Weighted, the Scope sparkline, the
    Focus/Compact segment, clear, the epic chips with lock, "+N also affect";
  - `setFeature`;
  - the compact `entries` with ghosts and gap markers in the timeline, Gantt and
    waves (J:366–380, 450, 506, 1070–1096);
  - also-affects outlined (`also`) and feature members `feat-on`.
  - A focused feature with no tickets in the loaded window loads its oldest day
    first.
- **Design elements.** `.bd-fh`, `.bd-kv`, `svg.sp`, `.bd-seg`, `.bd-x`, `.bd-chip`,
  `.bd-mk.gap`, `.bd-card.ghost`, `.also`, `.feat-on`.
- **Predecessors.** C10-T02, C6-T05, C9-T09.
- **Cx.** 4.
- **Owns.** EC-24.

#### MP-E8-C10-T04 — Usage strip
- **Scope.** Port `renderUsage`, `fitResets`, `wireUsagePop` and the `ax-*`
  helpers (J:987–1064):
  - the n2/n4/n7 layouts with rows and columns;
  - `hi` at ≥80 %, `max` at ≥95 %;
  - credits, "not observed", the multi-account ×N, the popover.
  The models counter is not a demo cycle button in the product (OQ-E8-8). The
  dark-only grain on `.ax-uc` is kept.
- **Design elements.** `.ax-usage`, `.ax-uc`, `.ax-r2`, `.ax-who`, `.ax-ln`,
  `.ax-bar`, `.ax-seg`, `.ax-pc`, `.ax-rs`, `.ax-usd`, `.ax-no`, `.ax-pop`, `.ax-cnt`.
- **Predecessors.** C10-T01, C8-T02.
- **Cx.** 3.
- **Owns.** EC-25.

### C11 — Ticket modal and agent chat (read and write)

#### MP-E8-C11-T01 — Modal frame, `?ticket=` deep link, navigation
- **Scope.**
  - The `#tk-backdrop`/`#tk-modal.bdm` frame (H:1595–1636, C:473–611) with the
    `tkin` open animation.
  - **Header:** epic icon, `#N` + title, state tone + % (live), epic, ◆ feature,
    pts.
  - **Links:** the GitHub issue (the repo URL from config, not the design's
    hard-coded `aiur-labs/aiur`), the PR chip `open|merged|closed`, and copy link
    with `.ok`.
  - **Close:** close button, Escape, backdrop.
  - **Focus:** focus trap and return; reuse `TicketContextDialog` hook patterns.
  - **Deep link:** `?ticket=` opens on load. A ticket outside the loaded window
    is fetched by id. An unknown id shows a not-found state (S-10).
  - **Navigation:** `data-goto` between tickets.
  - **Ticket ids:** the real id is `#N` from `TrackerIdentity`. The design's
    `AIUR-N` is mock.
  - **Page state while open:** `body` overflow hidden (J:1454), and closing
    clears `?ticket=` (the backdrop MutationObserver, J:1557).
  - **Progress hue** `--ph` on `.bm-st b` (J:1387; C:489).
- **Design elements.** `openModal` header (J:1370–1400), `closeModal`, `.bm-h`,
  `.bm-ep`, `.bm-tt`, `.bm-meta`, `.bm-st`, `.bm-act`, `.bm-links`, `.bm-pr`, `.bm-x`.
- **Predecessors.** C3-T03, C9-T05; OQ-E8-5 (the Units fields the design header
  does not show: runtime, turns, tokens/context, priority, resume reason, Remote
  Control link). Default: follow the design and add none.
- **Cx.** 3.
- **Owns.** EC-17, EC-19, EC-29.

#### MP-E8-C11-T02 — Issue view for tickets without an agent
- **Scope.** The `.bm-doc` variant:
  - `.bm-src` (opened by @login · date, or the pack source);
  - the issue body rendered as sanitised Markdown inside `.bm-art`. The
    design's "Scope / Done when" lists are mock (`descOf`); a real body renders
    what it has with the same type styles;
  - the cues `.bm-cue`;
  - the facts Queue/Wave/Estimate/Complexity;
  - the "Depends on" / "Unblocks" buttons.
  **Add to queue** (not-queued tickets) calls MP-E1's queue add API. It is only
  shown when writable and the queue is enabled, and it is disabled with a reason
  otherwise. Its pending, failed and success states follow S-14 (the design's
  button is inert, J:1438). Today the body comes from `TicketContextPresenter`/`TicketDetailCoordinator`.
- **Design elements.** J:1417–1440; `.bm-doc`, `.bm-art`, `.bm-src`, `.bm-sum`,
  `.bm-cue`, `.bm-side`, `.bm-facts`, `.bm-dg`, `.bm-dep`.
- **Predecessors.** C11-T01, C7-T01, MP-E1-C6-T02.
- **Cx.** 3.
- **Owns.** EC-30 (Markdown sanitising), EC-12, EC-23.

#### MP-E8-C11-T03 — Conversation read seam and wave-0b adapter
- **Scope.** PROPOSED `AiurWeb.Build.ConversationSource` behaviour (page, tail,
  subscribe), with a wave-0b implementation over today's sources:
  `Aiur.LiveConversation` (resolve/subscribe, in memory) for live agents, and
  `Aiur.AgentLog.read_workspace` (`agent.ndjson`) for the rest, as the drawer
  does (`dashboard_live.ex` `open_conversation`).
  - **Entry mapping** to the design kinds: `say` (agent prose with the model
    logo), `op` (operator, "You · HH:MM"), `sys` (pick-up line with effort),
    `tool` (name, arg, result, bad), `diff` (file, +/−, lines).
  - **Paging:** older pages on scroll to the top, with the S-15 loading row.
    The DOM keeps at most 500 entries. `read_workspace` reads and parses the
    whole file every time, so the adapter adds a tail-first paged reader over
    `agent.ndjson`.
  - **Past tickets:** `read_workspace` returns a placeholder message for a
    missing file, and the drawer only finds the workspace of running entries.
    So for a non-running ticket the adapter resolves
    `<workspace.root>/<repo>/<issue-id>/` itself and checks that the directory
    exists. Missing → `:not_retained` ("conversation not retained", S-6). The
    missing-file branch means known-empty only for a live agent. Never an empty
    "no messages".
  - **Other states:** the drawer's vocabulary (`:live`, `:ended`, `:known_empty`,
    `:stale`, `:unavailable`, `:restart_unknown`) maps to the footer `.cv-end` and
    the typing indicator.
  - **Security:** transcripts may hold secrets; show the same data the drawer
    shows today, no more.
- **Design elements.** `.cv`, `.cv-main`, `#cv-log`, `.cv-say`, `.cv-op`, `.cv-sys`,
  `.cv-tool`, `.cv-diff`, `.cv-end`; `itemEl` (J:1342–1354).
- **Predecessors.** C11-T01.
- **Cx.** 4.
- **Owns.** EC-16, EC-30.

#### MP-E8-C11-T04 — Event rows in the conversation
- **Scope.** `.cv-ev` rows with `--eh` hue and icon by kind (`EVK`, J:1284):
  dep, commit, prog, pr, review, comment, merge, fail, cmd, you.
  - In wave 0b, each kind comes only from a source that exists: TicketActivity
    progress, PR open/merge (RecentMergeStore, issue facts), pause/resume, error
    and retries, open Commands (DecisionStore), dependency state.
  - A kind with no source is not shown. Never invent one.
  - **CI.** The CI-failure `fail` row ("CI failed 3/14 · PR #N closed", J:1332)
    comes from the PR check state in issue facts when that is present, and does
    not appear otherwise. CI has no header field (OQ-E8-5).
  - Timestamps are daemon `observed_at` in local time.
  - "Open" on a dep row navigates the modal.
  - MP-E4 anchors replace this in C14-T01.
- **Design elements.** `.cv-ev`, `.cv-evi`, `.cv-evs`, `.cv-go`, `time`.
- **Predecessors.** C11-T03.
- **Cx.** 3.
- **Owns.** EC-08, EC-20.

#### MP-E8-C11-T05 — Minimap preview sidebar, live tail, typing
- **Scope.** Port:
  - `buildMap` and `syncView`: blocks per kind with the design widths, event ticks
    `.mm-e`, the viewport window `.mm-vw`, the tooltip `.mm-tip`;
  - pointer drag to scroll, click to jump + `.flash`;
  - rebuild on resize (J:1527–1541, 1466–1484);
  - live append that sticks to the bottom within 60 px, else "New activity"
    (`#cv-new`);
  - `cvIn` on new items;
  - the typing indicator: shown only for an active agent on a live socket.
  The design's `startLive` mock stream is removed. Live entries come from the
  C11-T03 subscription.
  - Very long transcripts: the minimap covers the loaded entries only.
- **Design elements.** `#cv-map`, `.mm`, `.mm-b.k-*`, `.mm-e`, `.mm-vw`, `.mm-tip`,
  `#cv-new`, `#cv-typing`; C:511–550.
- **Predecessors.** C11-T03, C11-T04.
- **Cx.** 3.
- **Owns.** EC-16, EC-10, EC-19.

#### MP-E8-C11-T06 — Composer: send to the agent
- **Scope.** `form#cv-in`.
  - **Input:** the textarea grows to 140 px; Enter sends, Shift+Enter adds a
    newline.
  - **Placeholder:** "Message {model}…", or the paused copy.
  - **Send path:** today's drawer send path, through the server. A
    `send-operator-message`-style event calls the shared helper from
    `dashboard_live.ex` `send_operator_message`/`message_id_for_send`/`send_agent_message`
    (`AgentChat.send/3`, honouring `:agent_chat_send_fun`).
  - **Shared helper:** move it into a module that both LiveViews use, keeping the
    #2717 rule: one `message_id` per user action, and on `outcome_unknown` keep
    the draft and the id. Today `send_operator_message/4` discards the
    `request_id` and returns a socket with DashboardLive-only assigns. The
    extracted helper returns `{result, request_id, message_id}`, and each
    LiveView applies it. BuildLive replies to the hook with `push_event`.
  - **Delivery polling is new code.** No dashboard code calls
    `AgentChat.delivery_status/2` today; its only caller is `agent_control_cli.ex`
    (`message_delivery_status`). Add a bounded poll keyed by `request_id`,
    modelled on that caller.
  - **Operator row:** the `cv-op` row appears when the send is accepted, not
    before (the design appends it optimistically, J:1495).
  - **Paused and parked agents:** sending resumes any paused agent if a slot is
    free (`operator_messages.ex` `message_resumes_pause?`; "Chatting with a
    paused agent auto-resumes it"). That includes an agent parked on its account
    limit (`paused_reason :usage_limit_exhausted`, #2742): main resumes it too. If
    no slot is free, the cap error shows and the agent stays paused. The composer
    does not change this behaviour (OQ-E8-10 asks whether parked agents should
    stay parked).
  - **Gates:** the composer is hidden on past tickets and on read-only dashboards
    (server re-check in `handle_writable_event`). Empty text and oversized text
    (the writer finds the limit) are rejected.
  - **Delivery states:** pending, delivered or unknown from `delivery_status/2`.
    Never a false "delivered". The visual for failed and unknown sends is S-7.
  - **MP-E7 routing:** comes through `AgentChat.send/3` (RC-36) with no change here.
  - **Manual test** (AGENTS.md "Manual testing"): drive `scripts/aiurdev --test`
    in the wrapper tmux. Send a message from the modal and confirm it in the
    agent's TUI chat pane, and the reverse.
- **Design elements.** `.cv-in`, `textarea`, `.cv-send`; J:1485–1500; C:550–563.
- **Predecessors.** C11-T03.
- **Cx.** 4.
- **Owns.** EC-14, EC-12, EC-13 (two tabs), EC-30.

#### MP-E8-C11-T07 — Pause, resume and "Open in Conversations"
- **Scope.**
  - **Pause/resume:** the `.bm-agent` button calls the existing control path
    (`UnitsControlPolicy.affordance`/`recheck`, `AgentChat.pause/resume`), with
    the server re-check. The new state comes back as a diff. A "Paused/Resumed by
    you" event row is added only from the real event (C11-T04).
    - Conflicts: if the TUI changed the state first, the settled state wins.
  - **"Open in Conversations"** (expand icon) goes to the drawer route
    `/chat/:owner/:repository/:identifier` until C14-T03.
- **Design elements.** `.bm-agent`, `.bm-ib[data-a=pause|chat]`; J:1389–1392,
  1447–1451.
- **Predecessors.** C11-T01.
- **Cx.** 2.
- **Owns.** EC-13, EC-12.

#### MP-E8-C11-T08 — Command answer card
- **Scope.** When the ticket's agent waits on a Command (`command` state), show
  `.cv-cmd` with the question, the option buttons, and the "recommended" badge.
  - **Answer path:** the same one as `/commands`
    (`AiurWeb.OperatorControlCenter.DecisionCommands.record_answer/4` →
    `DecisionStore.answer/5` with the actor). `record_answer/4` finds the
    decision only through `socket.assigns.selected_decision` or
    `decision_page.decisions`, and keeps idempotency keys in `decision_actions`.
    So BuildLive loads the ticket's open decision from DecisionStore, assigns it
    as `selected_decision` with `decision_actions` initialised, and submits the
    design's option button as `%{"choice" => "option:<id>"}`. The version check
    and the idempotency key are then reused, not rewritten.
  - **Success:** the card is removed and an "Answered: <option>" `cv-op` row is
    appended, as in the design (J:1501–1506). The agent state and typing
    indicator change only from the server diff, never optimistically.
  - **Races:** the decision is answered elsewhere first, expired, or superseded →
    the card shows the settled answer and disables the buttons.
  - **Failure:** an answer error keeps the card and shows the reason.
  - Writable-gated.
  - **Resume:** an answer recorded through `DecisionStore.answer` is delivered
    as a correlated message. On main that resumes a worker self-paused on the
    Command (#2738, `self_pause_ends_on_input?`), under the normal slot gates.
    The card never resumes the agent itself.
- **Design elements.** `#bd-cmd.cv-cmd`, `.row`, `.btn[data-ans]`, `.rec`;
  J:1406, 1501–1506.
- **Predecessors.** C11-T03.
- **Cx.** 3.
- **Owns.** EC-15, EC-12.

#### MP-E8-C11-T09 — Dictation button
- **Scope.** `#cv-mic` uses the existing dictation:
  `conversation-voice-controller.js` and `voice-capture-worklet.js`, the
  `data-voice-composer` pattern of the drawer. `.rec` while recording, `cvRec`.
  When voice is not configured, the button is disabled with a reason (S-11).
  Microphone permission denied → the button returns to idle with a message.
- **Design elements.** `.cv-mic`, `.cv-mic.rec`; C:563.
- **Predecessors.** C11-T06.
- **Cx.** 2.
- **Owns.** EC-12, EC-19.

#### MP-E8-C11-T10 — Units fields in the modal (only if OQ-E8-5 says yes)
- **Scope.** E8-D5 and E8-D8 move the Units columns into the modal. The design
  header shows only the model logo, name and effort. If Kevin answers OQ-E8-5
  "yes", add the Units-only fields: model version, runtime, turns,
  tokens/context, priority, resume reason, CI state, and the Remote Control link.
  The data comes from the per-ticket `UnitsRow`, and the placement is his. If he
  answers "no", this ticket is dropped and C12-T01 loses the edge.
  It is sized now so the total is honest either way.
- **Design elements.** None in the design; placement comes from Kevin's answer.
- **Predecessors.** C11-T01; OQ-E8-5.
- **Cx.** 2.
- **Owns.** EC-08 (unknown runtime and tokens are never 0), EC-12 (Remote Control link writable-gated).

### C12 — Cutover, retirement, mobile, accessibility, performance, docs, sign-off

#### MP-E8-C12-T01 — Cutover: `/` is home, Units retired, rollback route
- **Scope.**
  - **`/` routes to `BuildLive`.** `DashboardLive` keeps `/chat/...` and
    `/commands`.
  - **Rollback:** the old Units page stays reachable at a hidden `/units` route
    for one release, outside the nav (OQ-E8-3).
  - **`/chat/...` today is `DashboardLive, :index`,** the Units board with the
    drawer on top. Give it its own action that renders the drawer without the
    Units board, or redirect it to `/?ticket=<id>`. Route test: `/chat/...` does
    not render the Units table.
  - **Nav:** `route_registry.ex` gets one "Build" item at `/`. Units is removed
    (E8-D8), and Build Order is removed because the design's nav has no such item
    (H:1846–1875). Its routes stay reachable until OQ-E8-9 is answered (C12-T02).
  - **Nav badge:** the count of active agents (`nav_counts`).
  - **Legacy URLs:** `?scope=`/`?conditions=` redirect (C3-T03).
  - **Unchanged:** the Stream Deck and MP-N3 counts (E8-D8).
  - **Tests:** update `route_registry_test.exs`, `dashboard_live_test.exs` and
    the browser `units.browser.spec.mjs`.
  - **Manual test** (AGENTS.md "Manual testing"): drive `scripts/aiurdev --test`
    in the wrapper tmux, open `/` and a running agent's modal, send a message, and
    confirm it in the agent's TUI chat pane.
- **Design elements.** H:1846–1875 nav.
- **Predecessors.** every C9 ticket, every C10 ticket, C11-T01..T08, C8-T04;
  OQ-E8-3.
- **Cx.** 3.
- **Owns.** EC-26.

#### MP-E8-C12-T02 — Build Order routes retire to feature focus
- **Scope.** `/build-orders` → `/`. `/build-orders/:root_number` →
  `/?feature=<root slug>`.
  - The Breakdown, Analytics and Usage panes of the selected root are not in the
    design. They go away only after Kevin confirms (OQ-E8-9); until then the old
    routes stay reachable without nav.
  - The selected-root refresh RPC used by the Executor (memory: Build Order
    publish recipe) must keep working.
- **Design elements.** —
- **Predecessors.** C12-T01, C6-T03.
- **Cx.** 2.
- **Owns.** EC-26.

#### MP-E8-C12-T03 — Dead-code deletion
- **Scope.** Delete `FleetTable`, `FleetFilters`, `Overview.fleet_overview`, the
  no-op `toggle-fleet-filter`, and (after the rollback release) `UnitsTable`,
  `UnitsFilters` and the Units card. Keep `UnitsPresenter`/`UnitsRow` (per-ticket
  use) and `AgentLogModal.build` while the drawer uses it. Fix the drawer
  presenter's stale "Read-only mirror" text.
- **Design elements.** —
- **Predecessors.** C12-T01.
- **Cx.** 2.
- **Owns.** —

#### MP-E8-C12-T04 — Phone width and WebView
- **Scope.** Prove the page at 390 and 430 px (MP-N1 DV-P6) in flow mode:
  - gutter 46 px;
  - the modal at ≤ 720 px (C:604);
  - no horizontal page scroll;
  - the sticky band in an iOS/Android WebView;
  - touch: no hover, tap opens.
  The design defines this behaviour. Gaps found here become S-items, not
  improvisation.
- **Design elements.** C `@media` 560/720/960/1180 and container queries.
- **Predecessors.** C12-T01.
- **Cx.** 3.
- **Owns.** EC-18, EC-27.

#### MP-E8-C12-T05 — Accessibility pass
- **Scope.**
  - **Keyboard:** cards focusable with Enter opening the modal, toolbar and
    popovers operable, Escape closes, the modal traps focus.
  - **Screen reader:** a per-card summary (title, state, progress, complexity,
    blockers count, blocks count; feature-constraints doc).
  - **Live regions:** status changes are polite.
  - **forced-colors:** the design has none; add a fallback for `dim`/`hdim`
    (dashed outline), the glows and the edges, without touching the normal
    rendering. Pattern: `dashboard.css` forced-colors blocks and
    `aiur-dom-svg-layout`.
  - **Focus rings:** focus-visible rings appear only on keyboard focus and are
    S-12.
  - **Checks:** axe on every fixture.
- **Design elements.** —
- **Predecessors.** C12-T01.
- **Cx.** 3.
- **Owns.** EC-19.

#### MP-E8-C12-T06 — Performance budget and measurement
- **Scope.**
  - **Measure** with the dense fixture (1,300) and a synthetic 10,000-ticket
    fixture:
    - initial payload bytes;
    - server assembly time;
    - first board paint;
    - scroll frame time;
    - `drawEdges` time;
    - JS heap;
    - the modal with a 5,000-entry transcript.
    Measure on desktop and in a phone WebView.
  - **Budgets:** the writer proposes them, the PR records the measured numbers,
    and a regression test asserts the payload size.
  - Decide whether to turn on `/live` websocket compression; today the endpoint
    has none.
  - This is instrumentation; it claims no saving.
- **Design elements.** —
- **Predecessors.** C12-T01.
- **Cx.** 3.
- **Owns.** EC-09, EC-27.

#### MP-E8-C12-T07 — Documentation
- **Scope.**
  - **`guide/gui.md`:** the home page replaces the Units and Build Order rows,
    the writable-controls table changes, and one screenshot.
    `website/tests/gui-docs.spec.ts` must pass.
  - **`concepts/`:** a page for build history, epics and features, which
    replaces or merges `concepts/units.md` and `build-orders.md`; the sidebar in
    `.vitepress/config.ts` is updated.
  - **`reference/cli.md`:** epic, feature and estimate commands.
  - **`reference/configuration.md`:** the build history section.
  - **`skills.md`.**
- **Design elements.** —
- **Predecessors.** C12-T01, C5-T03, C6-T04, C7-T03.
- **Cx.** 2.
- **Owns.** —

#### MP-E8-C12-T08 — DESIGN-E8 sign-off package
- **Scope.** Run the full C1 matrix on the final build: every fixture, viewport,
  theme and palette; every motion script; every interaction script. Then publish
  the side-by-side evidence and the allowlist for Kevin. The open S-items get
  their answers recorded. This is DESIGN-E8's acceptance gate.
- **Design elements.** All.
- **Predecessors.** C12-T01..T06, C1-T03.
- **Cx.** 2.
- **Owns.** —

### C13 — History classification backfill (E8-D10)

#### MP-E8-C13-T01 — `aiur history export` for classification
- **Scope.** `aiur history export --unsorted --json` gives title, labels, body
  excerpt and PR files per ticket from the History store. It makes no new GitHub
  reads beyond what History holds. Documented in `reference/cli.md`.
- **Predecessors.** C12-T01.
- **Cx.** 2.
- **Owns.** EC-30 (bodies are data).

#### MP-E8-C13-T00 — Measure the backfill cost (instrumentation)
- **Scope.** Using the C13-T01 export, measure the GitHub points (expected near
  zero) and the model tokens for classifying 100 real tickets, then project the
  total. If label writes are wanted (C13-T02), give the write count and hours at
  the ceiling. The PR states the numbers (E8-D10: "ships the measured cost
  before it runs"). This ticket claims no saving.
- **Predecessors.** C13-T01.
- **Cx.** 2.
- **Owns.** EC-32.

#### MP-E8-C13-T04 — Backfill runbook and the agent run
- **Scope.**
  - **No new job runner.** An Executor-dispatched agent ticket does the work.
  - **Runbook:** the agent proposes an epic and feature per ticket from the
    export and applies them with the C5-T03 and C6-T04 batch CLIs, with
    `--source backfill-agent` and `confirmed: false`.
  - **Budget:** a cap per run from C13-T00. Pause and resume work through the
    ticket's label state.
  - **GitHub:** no GitHub writes.
- **Predecessors.** C13-T00, C5-T03, C6-T04.
- **Cx.** 2.
- **Owns.** EC-13.

#### MP-E8-C13-T02 — Optional paced label writes for classifications
- **Scope.**
  - **Opt-in** command that writes `feature:` (and, if configured, epic matcher)
    labels for confirmed classifications.
  - **Pacing:** an explicit hourly ceiling well below the agent core budget;
    paused on a budget hold; pause and resume; resumable checkpoint.
  - **Measurement:** the measured cost is stated before it runs (E8-D10).
- **Predecessors.** C13-T04.
- **Cx.** 3.
- **Owns.** EC-32, EC-13.

#### MP-E8-C13-T03 — Unconfirmed classification display and confirm
- **Scope.** How a `backfill-agent` unconfirmed epic looks, and a confirm action
  (CLI `aiur epic confirm`, and in the modal if S-8 asks for it). DESIGN-E8
  item 10 asks for exactly this, but the design has no treatment, so this
  ticket really waits on S-8.
- **Predecessors.** C13-T04; S-8.
- **Cx.** 2.
- **Owns.** EC-21.

### C14 — Later-wave upgrades

#### MP-E8-C14-T01 — Conversation reads from the MP-E4 journal
- **Scope.** Add a ConversationSource implementation over `Aiur.Conversation.History`
  (MP-E4-C2-T01): durable, with past tickets retained from then on. Event rows
  come from MP-E4 anchors and the jump-point catalogue (MP-E4-C3-T02, C4-T01) at
  journal positions. The minimap jump goes to the anchor. The wave-0b adapter is
  deleted. The UI does not change.
- **Predecessors.** MP-E4-C2-T01, MP-E4-C3-T02, MP-E4-C4-T01, C11-T04.
- **Cx.** 3.
- **Owns.** EC-16.

#### MP-E8-C14-T02 — Delivery receipts in the composer
- **Scope.** Use `AiurWeb.Conversation.DeliveryOverlay` (MP-E4-C6-T01) and
  `Aiur.Listener.receipt/2` (MP-E7-C3-T04) for the composer's states:
  accepted, queued, in context, failed, unknown. Send still goes through
  `AgentChat.send/3`, which delegates to `Aiur.Listener.send/3` (RC-36). The
  design has no mode chip, so none is added.
- **Predecessors.** MP-E4-C6-T01, MP-E7-C3-T03, MP-E7-C3-T04, C11-T06.
- **Cx.** 2.
- **Owns.** EC-14.

#### MP-E8-C14-T03 — "Open in Conversations" to the full view
- **Scope.** The expand button goes to `/conversations/:conversation_id` at the
  latest anchor (MP-E4-C5-T01).
- **Predecessors.** MP-E4-C5-T01, C11-T07.
- **Cx.** 1.
- **Owns.** —

#### MP-E8-C14-T04 — Command answers through the MP-E2 contract
- **Scope.** When MP-E2 changes the Command answer path, the card calls it:
  supervisor or human authority, supersede until delivered (D11). The card's
  look stays.
- **Predecessors.** MP-E2-C1-T01, MP-E2-C3-T01, C11-T08.
- **Cx.** 2.
- **Owns.** EC-15.
