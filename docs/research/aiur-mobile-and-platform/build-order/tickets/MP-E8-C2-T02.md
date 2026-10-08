---
ticket_id: MP-E8-C2-T02
feature_id: MP-E8
chunk_id: MP-E8-C2
bucket: 2-platform
title: App shell restyle (top bar, cog menu, sidenav)
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C2-T01]
follows_defaults: [OQ-E8-1, OQ-E8-2, S-1, S-2]
complexity: 4
design_gate: DESIGN-E8
owns_edge_cases: [EC-12, EC-18, EC-19]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C2-T02 — App shell restyle (top bar, cog menu, sidenav)

> Design source: `../design-source/` (etag 1791431544512943). `H` = `Aiur Dashboard.html`,
> `C` = `assets/build.css`. Product paths are at `58854d4c8` under
> `/home/everdred/github/everdred/aiur-worktrees/runtime/src`. PROPOSED marks a path or
> symbol that does not exist yet.

## Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history), chunk C2 (shell, tokens,
  palette, fonts, assets, CSS).
- **User value.** Every dashboard page gets the design's chrome: a sticky top bar with
  the brand, a settings cog (pause all agents, theme, Gruvbox palette), the page title
  and an "All agents paused" chip; a sidenav whose width you drag between icons and
  icons-plus-labels; Commands attention as a red dot. The home page (C3 and later)
  cannot match the design inside today's shell.
- **Deliverable.**
  1. `AiurWeb.OperatorControlCenter.DashboardShell` renders the design DOM
     (H:1823–1877): `header.ax-top` > `.ax-brand` (logo, `.wm`, `#ax-set` with
     `#ax-cog` and `#ax-menu`), `#ax-title`, `#ax-paused`; then `.app-layout` >
     `aside.sidenav` (`#ax-drag`, `nav.sidenav-nav` of `.snav` links) and
     `section.dashboard-shell` (banner slot, then page content).
  2. The design's shell CSS ported into `src/priv/static/dashboard.css`, and the old
     `.app-shell`, `.dashboard-shell`, `.topbar`, `.shell-*`, `.route-context`,
     `.shell-nav-mobile` rules deleted.
  3. Inline hooks in `layouts.ex`: `NavToggle` (extended: mirror, drag, keyboard),
     `AxMenu` (PROPOSED: menu open/close and keyboard; patch survival through
     `JS.ignore_attributes`), `ThemeToggle` (one line removed), `PaletteToggle`
     (from C2-T01; it writes `aria-checked` instead of `aria-pressed`). One
     early-paint line for the collapse state. The same changes in the browser
     fixture layout's hook copies (`test/browser/fixture_server.exs` L43–79).
  4. The tri-state pause input (`true | false | nil` = unknown) and the read-only gate.
- **Non-goals.**
  - The nav item set. Build replacing Units and Build Order is C12-T01. This ticket
    renders whatever `RouteRegistry.routes/1` returns.
  - Tokens, palette values, palette persistence and fonts: C2-T01.
  - Home-page CSS (`bd-*`, `cv-*`, …): C2-T04.
  - Focus rings and forced colours: S-12, C12-T05.
  - No Khala item (OQ-E8-2 default, S-2).

## Dependencies and blockers

- **Blocked by DESIGN-E8** (Kevin's go) and **MP-E8-C2-T01** (the tokens this CSS
  reads: `--attn*`/`--block*` aliases, `--surface-3`, `--line-strong`, `--faint`, the
  Gruvbox palette and the `PaletteToggle` hook; the self-hosted Space Grotesk and
  JetBrains Mono the menu and chip use). C2-T01 itself waits on C1-T02, so the
  parity runner exists when this ticket starts.
- **Follows defaults, not blocked:** OQ-E8-1 / S-1 (the shell, and hiding the
  decisions banner and page head, apply to every page), OQ-E8-2 / S-2 (no Khala
  item). If Kevin reverses S-1, the hide rules are two CSS lines (see Rollout).
- **Shared contract:** none. MP-E8 owns no shared contract (CONTRACT-REQUESTS.md).
- **Runs concurrently with:** C2-T03 (assets, different files), C2-T04 (same
  stylesheet: merge in README order, C2-T02 first; see Interface notes), C3-T01.
- **Successors that read this ticket's interface:** C3-T01 (BuildLive renders the
  shell), C9-T01 (listens for the `resize` event the drag fires), C12-T01 (adds the
  `:build` route; full sidenav parity), C12-T04 (phone), C12-T05 (a11y, focus rings).

## Verified starting point (`58854d4c8`)

- **Shell component.** `lib/aiur_web/components/operator_control_center/dashboard_shell.ex`
  (334 lines). The path in the row (`operator_control_center/dashboard_shell.ex`) is
  short for this one.
  - Root `<section class="dashboard-shell" data-nav-collapsed=…>` (L32), `header.topbar`
    with brand row and an "Offline" badge (L33–40), pause + theme in `.topbar-controls`
    (L46–53), `aside.shell-sidebar` with `#nav-toggle` (`phx-hook="NavToggle"`,
    `phx-click="toggle-nav"`, L58–92), `.route-context` with `h1#route-title`, the
    optional back link and the route description (L102–114), the `:banner` slot
    (L118), and a second nav `nav.shell-nav-mobile` with `#global-pause-toggle-mobile`
    (L124–140).
  - Attributes: `nav_collapsed` server-owned (#1306, L16–19); `globally_paused` and
    `writable` default `false` (L22–23).
  - `global_pause_button/1` (L153–176): `phx-click="toggle-global-pause"`,
    `disabled={not @writable}`. `theme_button/1` (L180–200). `route_item/1`
    (L230–277): `.link patch|navigate|href`, or a "Coming soon" span.
  - `nav_count/1` (L282–290) renders only `is_integer(count) and count > 0`;
    `:commands` gets `is-attention`. `nav_icon/1` (L294–327): `:units` is the same
    four-square as the design's Build icon (H:1853); `:streamdeck` is a bezel with
    four keys, which differs from the design's six-dot icon (H:1871).
- **Collapse state.** `lib/aiur_web/operator_control_center/nav_state.ex` (43 lines):
  `assign_nav/1`, `toggle/1`, `restore/2` (boolean only, L35–38). Every shell
  LiveView handles both events: `dashboard_live.ex` L370/373, `analytics_live.ex`
  L63/66, `streamdeck_live.ex` L142/144, `build_order_live.ex` L174/177.
- **Hooks.** `lib/aiur_web/components/layouts.ex`: early theme script (L25–33);
  `Hooks.NavToggle` (L107–127) replays `localStorage["aiur-nav-collapsed"]`
  (`"true"`/`"false"`) through `restore-nav` and writes it back in `updated()`;
  `Hooks.ThemeToggle` (L159–176) flips `html[data-theme]`, writes `aiur-theme`, and
  sets `aria-label` (L166). The root layout's `<html>` is static (L17), so LiveView
  never patches it. Today's `NavToggle` reads `aria-pressed` on `#nav-toggle`
  (L113, L123), not `data-nav-collapsed`.
- **App layout.** `Layouts.app/1` wraps every LiveView in `<main class="app-shell">`
  (layouts.ex L300–305). That element plays the design's `div.app-shell` (H:1844):
  C:6 sets it to `max-width: none; padding: 0`, so the header is full-bleed.
- **LiveView client API** (`deps/phoenix_live_view` 1.1.33). `pushEvent/2` without a
  reply callback returns a promise that rejects while the socket is down
  (`phoenix_live_view.js` L4092–4101, L5421–5430). `JS.ignore_attributes/1`
  (`js.ex` L967) keeps client-set attributes across server patches.
- **Browser fixture harness** (`test/browser/fixture_server.exs`). Its own layout
  `Aiur.BrowserHarness.FixtureLayout` (L3–113) has no early script and carries
  *copies* of `NavToggle` (L43–63, reads `aria-pressed`) and `ThemeToggle`
  (L65–79). The harness owns `/`, `/commands`, `/commands/:id`
  (`RouteShellLive`, L2276–2278). Every other path is forwarded to
  `AiurWeb.Router` (L2289–2291), whose `:browser` pipeline puts the production
  root layout (`router.ex` L32). So `/analytics` and `/build-orders` in the harness
  run the production hooks and early script; `/` does not. C2-T01 adds a probe
  route that renders `DashboardShell` under the production root layout
  (C2-T01 step 10).
- **Pause.** Only `DashboardLive` passes `globally_paused={global_paused?(@payload)}`
  and `writable` (L914–923) and handles `toggle-global-pause` through
  `handle_writable_event` (L712–714). `toggle_global_pause/1` (L730–750) writes
  `@global_pause_error`, which the `:banner` slot shows (L924–930).
  `global_paused?/1` (L752–756) returns `false` when the fleet payload has an `error`
  (no snapshot, orchestrator down): an unknown state shown as "not paused".
  `AiurWeb.Presenter` sets `globally_paused` only on a published snapshot (L37–55).
  Analytics, Streamdeck and Build Order pass neither attribute, so their pause button
  is disabled today.
- **Counts.** `DashboardLive.nav_counts/2` (L1176–1186) and
  `AwaitingCommands.nav_counts/1` (`awaiting_commands.ex` L70–74) emit only
  positive integers. When the Decision store is unreadable, `Overview.decisions_banner/1`
  (`overview.ex` L36–90) renders the `.decisions-banner` link only when
  `open > 0`, plus a separate `.readonly-banner` "Command counts unavailable" (L79–85)
  or "Partial Command counts" (L86–89). The link has no id.
- **Routes.** `route_registry.ex` L4–60: Units `/`, Commands, Build Order, Analytics,
  "Streamdeck+" (also used as the page title).
- **CSS** (`priv/static/dashboard.css`, 10,417 lines): `.app-shell` L227–235,
  `.dashboard-shell` L237–241, `.shell-body`/`.shell-sidebar`/`.shell-nav*`
  L243–395, `.route-context`/`.route-title-*` L396–465, `.topbar` L1865, brand rules
  L1893–1936, `.shell-nav-toggle` L1942–1962, `.global-pause-toggle[disabled]`
  (opacity .5, `not-allowed`) L1971–1974, collapsed rules L2053–2066 and L6075–6100,
  `.shell-nav-mobile` L6143–6230, `.decisions-banner` L2167+.
- **Logo.** `priv/static/aiur-logo.png` is byte-identical to the design's
  `assets/aiur-logo.png` (same SHA-256).
- **Tests that pin today's shell** (each must be updated, not deleted):
  - `test/aiur_web/live/dashboard_live_test.exs` L619–676 (`#global-pause-toggle`),
    L680–712 (topbar/mobile pill placement), L728–740 (mobile toggle),
    L910 and L921 (`h1#route-title`).
  - `test/aiur_web/live/build_order_live_test.exs` L192, L586, L643, L1756, L1801.
  - `test/aiur/extensions_test.exs` L1078–1081 (CSS strings), L1270 (`id="nav-toggle"`).
  - `browser/tests/visual-shell.browser.spec.mjs` (selectors at L29–39, L72,
    L92–97, and 141 PNG baselines in `visual-shell.browser.spec.mjs-snapshots/`),
    `browser/tests/route-shell.browser.spec.mjs` (L73, L98, L119–135, L148,
    L165–166, L261–279), `browser/tests/shell-content-width.browser.spec.mjs`
    (L85–104, L145–152: `.shell-main`, `.shell-content`, `--shell-measure`), and
    `browser/support/visual.mjs` `openVisualRoute` (L28–51; L50 asserts
    `.dashboard-shell[data-nav-collapsed]`).
  - The fixture layout's `NavToggle` copy (`fixture_server.exs` L43–63) reads
    `aria-pressed`; with the new DOM it would push a wrong `restore-nav` on every
    mount and write `"false"` on every patch.
  - CSS selectors elsewhere in `dashboard.css` that read the old root:
    `.dashboard-shell[data-nav-collapsed="true"]` at L1957, L2053, L2060, L6087;
    `.app-shell` responsive rules at L6095–6098, L6135–6137, L6258–6260,
    L6375–6377; `.shell-main`/`.shell-content`/`.shell-sidebar` L6108–6131;
    `.topbar` media rules L6252, L6262. `.toolbar` (L2065, L6269) has no user
    outside `dashboard_shell.ex` (`build_order_graph.ex` L90 uses `.bo-grid-toolbar`).
    No current rule uses `.sidenav`, `.snav`, `.ax-*`, `.app-layout`, `.page-head`
    or `html.nav-collapsed`, so the port collides with nothing.

### Design elements this ticket reproduces

| Element | Markup | CSS | Behaviour |
| --- | --- | --- | --- |
| Top bar | H:1823–1843 | C:7–16, 903, 921–923, 1077; Gruvbox light C:1147 (this ticket: C2-T01 non-goals and C2-T04 §4.2 both assign it here) | sticky, 56 px, `color-mix(var(--bg) 70%)` + `blur(8px)` |
| Brand column | H:1824–1826 | C:8–9, 904–906, 996, 928 | width `var(--navw)`, `.26s cubic-bezier(.22,1,.36,1)` |
| Cog + menu | H:1827–1840 | C:11–13, 907–920; light C:983 (the `.ax-menu` selector only; `.ax-pop` is C2-T04's) | H:5079–5082: click toggles `.open`, outside click and Escape close; `.12s` opacity, `.14s` `translateY(-4px)` |
| Pause item, chip | H:1830, H:1842 | C:15–16, 918–920, 923 | H:5105: switch `translateX(11px)`, chip `.show` |
| Theme item | H:1831–1836 | C:915–916; H:237–241 | H:5061 |
| Palette item | H:1837 | C:918–920 | H:5076–5078 (hook from C2-T01) |
| Title | H:1841 | C:921–922 | H:3972 sets it per tab |
| Sidenav | H:1848–1875 | H:163–183; C:18–24, 34–38, 902, 925–927, 992–1008 | |
| Drag handle | H:1849 | C:1005–1008, 997–998 | H:5086–5103: MIN 60, MAX 188, clamp 50–204, threshold 124, click = toggle, `resize` 260 ms later |
| Phone (≤ 960 px) | same aside | H:199–211; C:40–47, 928, 1008 | fixed bottom bar |
| Hidden by design | H:1850, 1880, 1884 | C:27, 44, 900–901, 999 | `#ax-collapse`, `#decisions-banner`, `.page-head` |
| Content column | H:1877 | H:155–160 (only `.dashboard-shell > *` of H:160); C:6, 25, 1009 | `max-width: 1720px`, padding `1.1rem 1.2rem 3rem` |

## Chosen design

**Port the design DOM and CSS; keep the product's server-owned state.** The shell's
look comes from the design's selectors, values and transitions unchanged. The
product keeps three things the design mocks on the client: the collapse state lives in
assigns (#1306), pause is a server event gated on `writable`, and nav items are URL
links from `RouteRegistry`.

### DOM (component output)

```heex
<div class="ax-frame" id="ax-frame">                          <%!-- PROPOSED wrapper, no CSS --%>
  <header class="ax-top">
    <div class="ax-brand">
      <img class="brand-logo" src="/aiur-logo.png" alt="Aiur" />
      <span class="wm">aiur</span>
      <div class="ax-set" id="ax-set" phx-hook="AxMenu" phx-mounted={…JS.ignore_attributes, see Menu…}>
        <button class="ax-ib ax-cog" id="ax-cog" type="button" title="Settings"
                aria-haspopup="menu" aria-expanded="false" aria-controls="ax-menu">…H:1828 svg…</button>
        <div class="ax-menu" id="ax-menu" role="menu" aria-labelledby="ax-cog" inert>
          <button class="ax-mi" id="ax-pause" role="menuitemcheckbox" …pause attrs…>…</button>
          <button class="ax-mi" id="theme-toggle" role="menuitem" phx-hook="ThemeToggle">…</button>
          <button class="ax-mi" id="ax-palette" role="menuitemcheckbox" phx-hook="PaletteToggle">…</button>
        </div>
      </div>
    </div>
    <div class="ax-title" id="ax-title">
      <.link :if={@back_path} patch={@back_path} class="ax-back" aria-label={@back_label}>…</.link>
      <b id="route-title" role="heading" aria-level="1">{@title || @route.label}</b>
      <span class="status-badge status-badge-offline brand-live">…Offline</span>
    </div>
    <span class={["ax-paused", @globally_paused == true && "show"]} id="ax-paused">All agents paused</span>
  </header>
  <div class="app-layout">
    <aside class="sidenav">
      <div class="ax-drag" id="ax-drag" phx-hook="NavToggle" data-nav-collapsed={…}
           role="separator" aria-orientation="vertical" aria-label="Drag to resize navigation"
           title="Drag to resize" tabindex="0" aria-controls="ax-nav"
           aria-valuemin="60" aria-valuemax="188" aria-valuenow={if @nav_collapsed, do: 60, else: 188}></div>
      <nav class="sidenav-nav" id="ax-nav" aria-label="Views">…route items…</nav>
    </aside>
    <section class="dashboard-shell" aria-labelledby="route-title">
      {render_slot(@banner)}
      {render_slot(@inner_block)}
    </section>
  </div>
</div>
```

- **Route item:** `<.link class={["snav", @active && "is-active"]} aria-current=…>`
  with `.snav-ic`, `.snav-label`, and `.snav-c`. Unavailable routes keep their span,
  with classes `snav is-soon` and a `.snav-soon` badge (H:180–182). No route is
  unavailable today.
- **Counts** (`nav_count/1`):
  - `:commands`: `<span class="snav-c attn" title="N need a command" aria-hidden="true">N</span>`
    plus `<span class="sr-only">, N need a command</span>`, only when N > 0. This is the
    design's `fc.title` (H:4966).
  - Other routes: `.snav-c` with the integer when `is_integer(count) and count >= 0`;
    nothing when the count is absent. The design shows `0` for Build (H:4967), so a
    *known* zero renders `0`; an unknown count is never rendered as `0`.
- **Nav label.** `Map.get(route, :nav_label, route.label)`. The Streamdeck entry gets
  `nav_label: "Streamdeck"` (H:1874) and keeps `label: "Streamdeck+"` for the title
  (H:3964). `nav_icon(:streamdeck)` becomes the design's six-dot icon (H:1871).
  `nav_icon(:build)` (PROPOSED clause, the H:1853 four-square) is added for C12-T01.
- **Back link.** The design hides the page head, which today holds Build Order's
  "Back to all Build Orders" link. It moves into `.ax-title`, before the title.
- **Offline badge.** It stays, moved from the brand row into `.ax-title`. It is hidden
  while connected (`[data-phx-main].phx-connected .status-badge-offline`,
  dashboard.css L2114), so connected parity screenshots are unaffected.
- **Decisions banner.** `Overview.decisions_banner/1` gives its link
  `id="decisions-banner"`, and the design rule `#decisions-banner { display:none !important }`
  (C:900) is ported verbatim. The "Command counts unavailable", "Partial" and
  global-pause error notices in the `:banner` slot stay visible: they are not the
  design's banner.
- **Page head.** `.route-context` (title, icon, description) is deleted. The heading
  moves to `#route-title` in the top bar.

### Pause item (EC-12)

`globally_paused` becomes `true | false | nil`, with default `nil` (unknown).
`DashboardLive` passes `global_pause_state(@payload)` (PROPOSED: `nil` when
`@payload.fleet` has `:error` or no `:globally_paused` key, otherwise the boolean).
Other LiveViews pass nothing, so they render the unknown state.

| State | `#ax-pause` | `.ax-sw` | `#ax-paused` |
| --- | --- | --- | --- |
| `false`, writable | enabled, `aria-checked="false"`, title "Pause all agents", text "Pause all agents" | off | hidden |
| `true`, writable | enabled, `aria-checked="true"`, class `on`, title "Resume all agents" | on (C:920) | `.show` |
| any, read-only | `disabled`, `aria-disabled="true"`, title "Read-only dashboard: pausing is unavailable" | per state | per state |
| `nil` (unknown) | `disabled`, no `aria-checked`, text "Pause state unknown", title "The daemon's pause state is not available" | not rendered | hidden |

`phx-click="toggle-global-pause"` stays. The server re-check stays in
`handle_writable_event` (dashboard_live.ex L712–714). The disabled look ports the
product's existing `.global-pause-toggle[disabled]` values (opacity .5,
`cursor: not-allowed`) to `.ax-mi[disabled]`, because the design has no disabled
state.

### ARIA fix that does not change pixels

The design puts `aria-pressed` on `role="menuitemcheckbox"` (H:1830, H:1837). ARIA does
not allow that attribute on that role, and axe flags it (C12-T05). The product uses
`aria-checked`, and the C:920 selector becomes `.ax-mi[aria-checked="true"] .ax-sw`.
The computed style is the same.

### Collapse (server-owned, html-mirrored)

- The server attribute (`data-nav-collapsed` on `#ax-drag`) is the only state.
  `NavToggle` mirrors it to `document.documentElement.classList` as `nav-collapsed`,
  so the design's `html.nav-collapsed …` selectors work unchanged. LiveView never
  patches `<html>`.
- **Phone.** The mirror applies the class only when `matchMedia("(min-width: 961px)")`
  matches, and it listens for changes. Below 961 px the page always gets the design's
  uncollapsed phone shell (see Decisions, item 4).
- **First paint (no flash).** One line is added to the existing early script
  (layouts.ex L25–33): if `localStorage["aiur-nav-collapsed"] === "true"` and the
  media query matches, add `nav-collapsed` to `<html>`.
- **`mounted`:** if the stored value differs from the server attribute, push
  `restore-nav` (existing) and set `pending = stored`. Do not mirror until
  `updated` sees `data-nav-collapsed === pending`. Otherwise mirror at once.
- **`updated`:** mirror, then write localStorage (existing behaviour).
- **Drag** (port of H:5086–5103, same constants):
  - On `pointerdown`, capture the pointer and add `html.nav-drag`.
  - On `pointermove`, set `--navw` on `<html>` to `clamp(50, w0+dx, 204)` and toggle
    `nav-collapsed` at the 124 px threshold.
  - On `pointerup`: `col = moved > 3px ? w < 124 : !collapsed`. Remove `nav-drag`,
    force a reflow, set the class, remove `--navw`, and push
    `restore-nav {collapsed: col}`. After 260 ms, dispatch `resize`.
  - The hook uses `restore-nav` with an explicit value, not `toggle-nav`, so a
    repeated event cannot flip the state twice.
  - On `pointercancel` or `lostpointercapture` (the design handles neither; a
    touch scroll or an OS gesture can end the drag without `pointerup`): remove
    the listeners, `nav-drag` and `--navw`, mirror the server attribute again, and
    push nothing. Without this, `html.nav-drag *` keeps `cursor: col-resize` and
    `user-select: none` on the whole page (C:998).
  - Every push uses the reply-callback form
    (`this.pushEvent("restore-nav", {collapsed: col}, () => {})`). Without a
    callback, LiveView 1.1 returns a promise that rejects while the socket is down,
    and the rejection is unhandled (a `pageerror`).
- **Keyboard** (EC-19; the design's only toggle is the pointer handle, and
  `#ax-collapse` is hidden at every width, C:44 and C:999): `#ax-drag` is focusable.
  Enter or Space toggles, ArrowLeft collapses, ArrowRight expands, through the same
  `restore-nav` push. `aria-valuenow` reports 60 or 188.

### Menu (`AxMenu`, PROPOSED inline hook)

- **Open state.** The hook sets `.open` on `#ax-set`, `aria-expanded` on `#ax-cog`
  and removes `inert` from `#ax-menu`. A server patch (a pause change, a count
  change) would put the server's values back, close the menu, and (by re-adding
  `inert` to the focused item's subtree) drop keyboard focus to `<body>`. This is
  the #1306 failure mode, for a class instead of an attribute. The fix reuses the
  framework instead of re-applying in `updated()`:
  `phx-mounted={JS.ignore_attributes(["class"]) |> JS.ignore_attributes(["aria-expanded"], to: "#ax-cog") |> JS.ignore_attributes(["inert"], to: "#ax-menu")}`
  on `#ax-set` (LiveView 1.1 `js.ex` L967). The server never changes these three
  values after the first render, so ignoring its later patches loses nothing.
  `phx-mounted` runs only after connect, which is also the only time the menu
  can open.
- **Closed menu is inert.** The design hides the menu only with
  `opacity:0; pointer-events:none`, so its items would stay in the Tab order. The
  server renders `inert`, and the hook removes it while the menu is open.
- **Keys** (WAI-ARIA menu button):
  - Enter, Space or ArrowDown on the cog opens the menu and focuses the first enabled
    item. ArrowUp opens it and focuses the last.
  - Inside the menu, ArrowUp and ArrowDown move with wrap-around, and Home and End jump.
    Disabled items are skipped.
  - Escape closes the menu and returns focus to the cog. Tab closes it.
  - A click outside closes it (H:5081). Activating Pause or Palette leaves it open,
    as in the design.
  - `destroyed` removes the document `click` and `keydown` listeners the hook adds
    (the design adds them for the page's life, H:5081–5082).

## Implementation steps

1. **`dashboard_shell.ex`**: replace L31–143 with the DOM above. Delete `theme_button/1`
   and `global_pause_button/1`, and add `pause_item/1` and `theme_item/1` (markup from
   H:1830–1836, SVGs copied byte for byte). Change the `globally_paused` attr to
   `:any, default: nil`. Change `navigation/1` and `route_item/1` to the `.snav`
   classes and drop the `:trailing` slot. Change `nav_count/1` per Chosen design.
   Change `nav_icon(:streamdeck)` to the H:1871 SVG with H:1871's own attributes
   (`fill="none" stroke="currentColor" stroke-width="2"`, no linecap or linejoin),
   not `@nav_svg_attrs`, so the bytes match. Add `nav_icon(:build)`.
   Delete `nav_toggle_label/1` and replace `global_pause_label/1` with the new
   titles: an unused private function is a compiler warning, and the build runs
   `--warnings-as-errors`. Move the C2-T01 interim `palette_button/1` into the menu
   as `#ax-palette` and delete the interim `#palette-toggle`.
2. **`route_registry.ex`**: add `nav_label: "Streamdeck"` to the Streamdeck map.
3. **`overview.ex`**: add `id="decisions-banner"` to the link at L48.
4. **`dashboard_live.ex`**: `globally_paused={global_pause_state(@payload)}`.
   Add `global_pause_state/1` next to `global_paused?/1` (which stays for the toggle).
5. **`layouts.ex`**:
   - Extend the early script with the collapse line.
   - Rewrite `Hooks.NavToggle` (mirror, pending restore, drag, keys, media listener;
     `destroyed` removes the listeners).
   - Add `Hooks.AxMenu`.
   - Delete the `aria-label` write in `ThemeToggle` (L166): the visible "Switch theme"
     text is now the accessible name, which WCAG 2.5.3 requires.
   - `Hooks.PaletteToggle` (C2-T01): write `aria-checked` instead of
     `aria-pressed`, in its sync and click paths. The role change is this ticket's,
     so the attribute change is too (C2-T01 ships `aria-pressed`, which is correct
     on its interim `tool-btn` button).
6. **`dashboard.css`**:
   - Delete the rules listed under Verified starting point: `.app-shell` (L227–235
     and the four responsive overrides), `.dashboard-shell` L237–241, every
     `.dashboard-shell[data-nav-collapsed]` rule, `.topbar` and its media rules,
     `.toolbar`, `.topbar-controls`, the brand row, `.shell-*`, `.route-*`,
     `.shell-nav-mobile`, `.shell-nav-toggle`, `.global-pause-toggle*`. Before each
     deletion, `grep -rn` the class in `lib/` and `test/browser/` to confirm no other
     user. If the product `.app-shell` padding stays, the header is inset at every
     width below 960 px and the parity check fails.
   - Add one section, "Shell (ported from design build.css v10)", in design source
     order: H:150 and H:152–154 (`::selection`, `html` overflow and scrollbar
     gutter: page-level rules this ticket owns, not C2-T01), H:155–156,
     `.dashboard-shell > *` from H:160, H:163–183, H:199–211, H:237–241; then
     C:5–28 and C:34–47 (C:29–32 are home rules: `.ax-acc`, `.bd-*`; C2-T04 owns
     them), C:899–928, the `.ax-menu` selector of C:983, C:991–1009, C:1077,
     C:1147. This is the C2-T04 §4.2 ownership table, line for line.
   - Remove `overflow-x: hidden` from `body` (`dashboard.css:160`). Once `html`
     sets its own overflow, a `body` value stays on `body`, which becomes a scroll
     container, and the sticky `.ax-top` would stick to a box that never scrolls.
   - Product-only lines, each with a one-line why comment: `.ax-mi[disabled]`;
     `a.snav { text-decoration: none; }` (anchors instead of the design's buttons);
     the `[aria-checked]` selector; `.ax-back` (reuse `.route-title-back` values).
   - Leave out `.sidenav-brand` and `.ax-top-r`: no product element uses them.
7. **Recompile** (`dashboard.css` is read at compile time by `static_assets.ex`).
8. **Browser fixture** (`test/browser/fixture_server.exs`):
   - Update the `NavToggle` copy (L43–63) to read `data-nav-collapsed` on `#ax-drag`
     and mirror the `html` class; add `AxMenu` and update the `PaletteToggle`
     copy, so the harness's own `/` and `/commands` still mount the shell.
   - Extend C2-T01's production-root probe LiveView with `globally_paused`,
     `writable` and `nav_counts` taken from query params, a `toggle-global-pause`
     handler that flips the assign (or records the event when read-only), and
     `Overview.decisions_banner` in the `:banner` slot. New browser tests run on
     this probe (production hooks and early script), never on the harness `/`.
9. **Tests**: update the files listed under Verified starting point, and add the new
   tests in Verification.
10. **Docs**: `website/docs-app/guide/gui.md`. Add a "Shell" paragraph (settings cog:
   pause all agents, theme, palette; drag or use the arrow keys on the sidenav edge to
   collapse it; the Commands red dot). Add the row "Fleet | Pause all agents (settings
   menu)" to "Writable controls". Replace any screenshot that shows the old top bar.

## Non-happy paths

| Case (owner EC) | Input | Expected | Proved by |
| --- | --- | --- | --- |
| Read-only (EC-12) | `writable: false`, a forged `toggle-global-pause` push | Item disabled with reason; server ignores the event; orchestrator state unchanged | T-3, T-4 |
| Pause unknown (EC-12, EC-08) | fleet payload `%{error: …}` | "Pause state unknown", disabled, no switch, no chip; never "Pause all agents" with switch off | T-2 (mutation) |
| Pause write fails | `{:error, {:global_pause_persistence_failed, _}}` | Existing `.global-pause-error` alert shows in the banner slot; switch keeps the old state | T-5 |
| Commands count unknown | `AwaitingCommands` counts `nil` | No dot; "Command counts unavailable" notice rendered (T-6) and visible, not caught by the `#decisions-banner` hide rule (B-10) | T-6, B-10 (mutation) |
| Count absent vs zero | `%{units: 0}` vs `%{}` | `0` vs no `.snav-c`. Component only: no producer emits `0` today (see Decisions, item 8) | T-7 (mutation) |
| Patch while menu open (EC-19) | open menu, server pushes pause change | menu stays open, focus kept | B-4 |
| Patch while dragging | count update during drag | drag continues (html is not patched) | B-6 |
| Disconnected | socket down, drag or menu use | Visual change is local; `restore-nav` is not delivered and raises no `pageerror` (reply-callback push); on reconnect the server value wins and the mirror reverts. The Offline badge is shown. A server restart resets the collapse to expanded and `updated` then stores `"false"`: this is today's behaviour, unchanged | B-7 |
| Drag ends without `pointerup` | `pointercancel` mid-drag | `nav-drag` and `--navw` removed; class mirrors the server value; no push | B-2 (mutation) |
| Corrupt storage | `aiur-nav-collapsed = "x"` | ignored (existing `restore/2` guard); expanded | T-8 |
| Storage throws | private mode | every `localStorage` call in `try` (existing pattern); expanded | B-8 |
| Two tabs | collapse in tab A | tab B unchanged until reload (per-socket assigns, as today) | — (unchanged behaviour) |
| Phone with stored collapse (EC-18) | 390 px, storage `"true"` | uncollapsed phone shell; cog visible; bottom bar shows all routes | B-9 |
| Reduced motion (EC-19) | `prefers-reduced-motion` | The design has no reduced-motion rule for the shell; transitions stay as designed (≤ 260 ms, no looping motion) | C1-T03 matrix |
| Keyboard only (EC-19) | Tab to cog, Enter, arrows, Escape; Tab to handle, ArrowLeft | menu pattern works; nav collapses | B-5 |

Security: no new data or endpoint. The pause event keeps its server-side writable
check. Untrusted text: `@title` is escaped by HEEx (unchanged).

## Compatibility and rollout

- **No config key, no migration, no CLI change.** localStorage keys and values are
  unchanged (`aiur-nav-collapsed` = `"true"`/`"false"`, `aiur-theme`). The design's
  `"1"`/`"0"` values are not adopted, so stored state from before the change keeps
  working.
- **App-wide visual change** (K-2, OQ-E8-1). Commands, Analytics, Streamdeck and Build
  Order all change. `visual-shell` baselines are regenerated in this PR, and the PR
  body lists them as the intended change.
- **Behaviour changes on other pages:**
  - Their pause item says "Pause state unknown" instead of showing a disabled
    unpressed button. This is more honest, and nothing that worked before stops working.
  - The page description line is gone (S-1).
  - Commands attention is a dot, not a number.
- **C12-T01 dependency.** The home page's pause item works only when the LiveView at `/`
  handles `toggle-global-pause` (see Interface notes).
- **Rollback.**
  - Revert the PR. It touches one component, three small call sites, the hooks and
    one CSS section.
  - If Kevin rejects only the hiding in S-1, delete the two lines C:900–901 from the
    port and restore `.route-context` from git. The heading id stays.

## Verification

ExUnit (PROPOSED `test/aiur_web/components/operator_control_center/dashboard_shell_test.exs`,
`render_component/2`, plus the listed LiveView tests):

- **T-1 structure.** The output has `header.ax-top .ax-brand #ax-set #ax-menu[role=menu][inert]`
  with exactly `#ax-pause`, `#theme-toggle` and `#ax-palette` inside it.
  `#route-title[role=heading][aria-level="1"]` text equals the route label, and
  `section.dashboard-shell[aria-labelledby=route-title]` is present. There is one
  `nav.sidenav-nav`, and no `.shell-nav-mobile`, `#nav-toggle` or `.route-context`.
  Fails on main (the old DOM).
- **T-2 pause unknown (mutation).** `globally_paused: nil` → text "Pause state
  unknown", `disabled`, no `aria-checked` attribute, no `.ax-sw`, `#ax-paused`
  without `show`. Mutation check: change the `nil` clause to the `false` rendering
  and confirm the test fails. A DashboardLive test with an error fleet payload asserts
  the same, which proves `global_pause_state/1` is wired.
- **T-3 read-only gate.** `writable: false, globally_paused: false` → `disabled`,
  `aria-disabled="true"`, and a title naming read-only. `writable: true` → enabled.
- **T-4 server re-check.** A read-only `DashboardLive`, then
  `render_click(view, "toggle-global-pause")` → the test orchestrator's pause state is
  unchanged. It fails if the `handle_writable_event` wrapper is removed. No current
  test covers the read-only push (the "global pause nav toggle" tests at L581–740 all
  run writable), so this is new, but it passes on main: it is a guard against a
  future regression, its name says so, and it does not count toward this change.
- **T-5 pause failure** stays visible: the existing persistence-failure test runs
  against the new DOM and asserts the `.global-pause-error` text and
  `aria-checked="false"`.
- **T-6 unknown Commands count (mutation).** Analytics with an unreadable Decision
  store → the Commands item has no `.snav-c` of any kind, and the "Command counts
  unavailable" text is present. Mutation check: render the `nil` count as a `0` dot
  (`count || 0` in the `:commands` clause) and confirm the test fails. The CSS half
  (the notice is not hidden) is B-10, because ExUnit cannot see a hide rule.
- **T-7 zero vs absent (mutation).** `nav_counts: %{units: 0}` renders `.snav-c`
  "0". `%{}` renders no `.snav-c`. Mutation check: `count || 0` fails the second
  assertion. `%{commands: 3}` renders `.snav-c.attn[title="3 need a command"]` and
  the sr-only text.
- **T-8 restore guard.** `restore-nav` with `"x"` leaves `nav_collapsed` false.
  This is an existing guard, kept, and does not count toward this change.
- **T-9 no Khala item** (S-2). It passes on main, so it is a guard against a future
  regression and its name says so.
- **T-10 Streamdeck label and icon.** The nav label is "Streamdeck" and the title is
  "Streamdeck+". Fails on main.

Browser (PROPOSED `browser/tests/shell.browser.spec.mjs`, run through
`node scripts/run-browser-tests.mjs` like every other spec, and added to the
`browser/package.json` `test` chain as PROPOSED `test:shell-chrome`). Every B-test
runs on the C2-T01 production-root probe route (step 8), which loads
`AiurWeb.Layouts.root` and its inline hooks. The harness's own `/` uses
`FixtureLayout`'s hook copies and no early script, so a B-test there would test the
copies, not the product. As in C12-T04, browser and parity tests never use `/` (the
fixture server owns it); a home-page check uses `/build`, and the phone widths are
C12-T04's `PHONE_CELLS` (390 px here). Each test collects `page.on("pageerror")` and asserts it
is empty.

- **B-1 first paint.** `addInitScript` sets storage `"true"`, at 1440 px. At
  `DOMContentLoaded` (before the socket connects), `html` has `nav-collapsed`. After
  connect, `#ax-drag[data-nav-collapsed="true"]`. Mutation check: remove the
  early-script line and confirm the test fails.
- **B-2 drag.**
  - A drag from x=188 to x=100 gives collapsed, `aria-valuenow="60"`, and storage
    `"true"`.
  - A drag back to x=180 gives expanded.
  - A click without movement toggles.
  - During the drag, `html.nav-drag` is set and the cursor is `col-resize`.
  - A `resize` event fires about 260 ms after `pointerup`.
  - `pointerdown`, a move to x=100, then `dispatchEvent("pointercancel")`: no
    `html.nav-drag`, no inline `--navw`, and the `html` class equals
    `#ax-drag[data-nav-collapsed]`. Mutation check: remove the `pointercancel`
    listener and confirm the test fails.
- **B-3 menu.**
  - A cog click gives `#ax-set.open`, `aria-expanded="true"`, and no `inert` on the menu.
  - An outside click closes it, and so does Escape, which also returns focus to `#ax-cog`.
  - The palette item flips `html[data-palette]` and `aria-checked`.
  - The theme item flips `data-theme`.
- **B-4 patch survival.** On the probe with `writable`, open the menu from the
  keyboard (focus on `#ax-pause`) and activate it, so the server flips
  `globally_paused` and patches the shell. The menu stays open, `#ax-menu` has no
  `inert`, the switch moves, the chip shows, and `document.activeElement` is still
  `#ax-pause`. Mutation check: remove the `JS.ignore_attributes` binding and confirm
  the test fails.
- **B-5 keyboard.**
  - Tab to the cog, then ArrowDown: focus is on `#ax-pause` (or `#theme-toggle` when
    pause is disabled).
  - ArrowDown wraps to the first item, End jumps to the last, and Escape returns
    focus to the cog.
  - While the menu is closed, Tab never lands on a menu item.
  - On `#ax-drag`, ArrowLeft collapses the nav.
- **B-6, B-7, B-8, B-9.**
  - B-6: drag during a server patch.
  - B-7: disconnect (`page.evaluate(() => window.liveSocket.disconnect())`; network
    emulation does not reliably close an open WebSocket). The Offline badge is
    visible in `.ax-title`. A drag then changes the class locally and `pageerror` stays
    empty. Mutation check: drop the reply callback from the push and confirm a
    `pageerror` appears.
  - B-8: storage that throws.
  - B-9: 390 px with storage `"true"`. The cog is visible, the bottom bar is fixed at
    `bottom: 0`, every route link is clickable, and
    `document.documentElement.scrollWidth <= 390`.
  - B-11 sticky survives (moved from C2-T01 with H:152–154): a `position: sticky;
    top: 0` probe under `body` keeps `getBoundingClientRect().top === 0` after
    `scrollTo(0, 400)`. Mutation check: put `overflow-x: hidden` back on `body`.
- **B-10 banner hide is exact (mutation).** Probe with `retained_counts` `%{}`
  (unknown): the "Command counts unavailable" notice is visible. Probe with
  `awaiting: 3`: `#decisions-banner` computes `display: none`, and
  `.snav-c.attn` is 8×8 px. Fails on main (no hide rule, no dot). Mutation checks:
  widen the hide rule to `.dashboard-shell > [role=status]` (first assertion fails);
  drop `id="decisions-banner"` from `overview.ex` (second fails).
- **Existing specs updated**: `visual-shell` (selectors `header.ax-top`, `aside.sidenav`,
  `#ax-title`; baselines regenerated; the nav-padding mutation proof retargeted to
  `.sidenav .snav`), `route-shell`, `shell-content-width` (content max 1720 px,
  centred; its `.shell-main`/`.shell-content`/`--shell-measure` probes are
  retargeted to `section.dashboard-shell` and the 1720 px cap), `browser/support/visual.mjs`
  L50 (`#ax-drag[data-nav-collapsed]`). Regenerate baselines with
  `npm run test:visual:docker` (the pinned Chromium), not a local browser.

Commands (from `src/`):

```bash
mise exec -- mix test test/aiur_web/components/operator_control_center/dashboard_shell_test.exs \
  test/aiur_web/live/dashboard_live_test.exs test/aiur_web/live/build_order_live_test.exs \
  test/aiur/extensions_test.exs
cd browser && node scripts/run-browser-tests.mjs tests/shell.browser.spec.mjs \
  tests/route-shell.browser.spec.mjs tests/shell-content-width.browser.spec.mjs tests/mp-e8-parity
cd browser && npm run test:visual
mise exec -- mix compile --warnings-as-errors && mise exec -- mix format --check-formatted
```

(`tests/mp-e8-parity` is C1-T02's PROPOSED directory; use its real name.) Run the
mutation checks in a worktree, per AGENTS.md, with `git status --porcelain` showing
only the reverted hunk. Name each result in the PR body.

**Manual check** (AGENTS.md "Manual testing"): `scripts/aiurdev --test` in the wrapper
tmux. Open `/` in a browser on the printed dashboard port. Pause all agents from the
cog. Confirm in the TUI agent list (`capture-pane` on `0.0`) that the fleet shows
paused, then resume.

## Pixel parity

The C1-T02 runner is used in element mode, at 1440, 1024 and 390 px, in dark and
light, with the default and Gruvbox palettes, a frozen clock and local fonts. The
pixel threshold is the anti-aliasing floor that C1-T02 records.
- **Design side.** Load H, run `switchTab("analytics")` (so the title is
  "Analytics", H:3962), and set `#tabcount-inbox` to the fixture's awaiting count
  through `page.evaluate`. The design file itself is never edited.
- **Product side.** `/analytics` on the fixture server (production root layout),
  with the same count, for the nav items. `/analytics` passes no pause state, so its
  pause item reads "Pause state unknown" and cannot match the design. The top bar
  and menu regions therefore use the C2-T01 probe route with `writable` and a known
  `globally_paused`, and the design side runs `switchTab("fleet")` so both titles
  read "Units" (H:3959).

| Region | States | Selector pair |
| --- | --- | --- |
| Top bar (probe) | expanded, collapsed, phone; paused (design: click `#ax-pause`; product: probe `globally_paused: true`, writable) | `header.ax-top` ↔ `header.ax-top` |
| Menu open (probe, `globally_paused: false`, writable) | each theme and palette; hover on item 1 | `#ax-menu` (after the 140 ms transition) |
| Nav items | Commands (with dot and without), Analytics active, Streamdeck | `.snav[data-tab=inbox]` ↔ `a.snav[href="/commands"]`, etc. |
| Drag handle hover | `::after` at `opacity .6` | `aside.sidenav` right edge clip |
| Phone bottom bar | 390 px | computed style of `aside.sidenav` (position, height, padding, background, border, shadow) and of one matching `.snav` (Commands); no screenshot of the whole bar, because the item set differs until C12-T01 |

- **Computed-style check** for the same elements: `getComputedStyle` on both sides,
  covering width, height, padding, margin, font, colour, background, border, radius,
  box-shadow, transition and transform. They must be equal, except for entries on the
  C1-T02 allowlist. The expected product-only differences are `text-decoration` on
  anchor `.snav` (already reset to `none`, so it should be equal) and `cursor` on a
  disabled item (product-only state, not compared).
- **Motion.** Sample computed `grid-template-columns` and `.ax-brand` width every frame
  across the collapse, and opacity/transform across the menu open. Compare the two
  curves (`.26s cubic-bezier(.22,1,.36,1)`; `.12s` / `.14s`) within one frame. This
  is the C1-T03 method applied to the shell.
- **Not compared here, with the reason:**
  - The whole `aside.sidenav` at desktop: the item set differs until C12-T01, which
    owns that comparison.
  - The Build and Units items: their labels differ until C12-T01.
  - States the design does not have: unknown pause, read-only, Offline badge, back
    link. Each one is shown in the C12-T08 sign-off package.
- Any other difference fails the check, unless Kevin approves it in writing (in the
  allowlist).

## Completion and handoff

- [ ] The shell DOM and CSS match the design in every row of the parity table.
- [ ] T-1 to T-10 and B-1 to B-11 pass with an empty `pageerror` list. T-2, T-6,
  T-7, B-1, B-2 (cancel), B-4, B-7, B-10 and B-11 fail with their production hunk
  reverted, and the PR body says so with the exact command. T-4, T-8 and T-9 are
  named as regression guards and are not counted.
- [ ] Every pre-existing shell test is updated, and none is deleted without a
  replacement.
- [ ] `visual-shell` baselines are regenerated, and the PR lists the intended changes (K-2).
- [ ] Pause all works on Units and is disabled with a reason (read-only) or an unknown
  label everywhere else. The server re-check is unchanged.
- [ ] The phone at 390 px has no horizontal scroll, and every route is reachable.
- [ ] `gui.md` is updated.
- [ ] Manual check done and reported.
- **Dependents:**
  - C3-T01 renders the shell with `nav_collapsed` and handles `restore-nav` and
    `toggle-nav`. It passes `writable={false}` and no `globally_paused`, so BuildLive
    shows "Pause state unknown" until C12-T01 (C3-T01 "Read-only dashboard").
  - C12-T01 adds `:build` (the icon is ready), emits a *known* Build count (the `0`
    clause is waiting for it), extracts the pause action into a shared module and
    wires it into BuildLive, and runs the full sidenav parity (see Interface note 3).
  - C12-T04 (phone): see Interface note 5.
  - C12-T05 adds focus rings (S-12) to `.ax-cog`, `.ax-mi`, `#ax-drag` and `.snav`.
- **Sources:** H:150–241, H:1820–1884, H:3955–3980, H:4966–4967, H:5061–5106;
  C:5–28, C:34–47, C:899–928, C:983 (`.ax-menu` only), C:991–1009, C:1077, C:1147;
  the product files cited above; `test/browser/fixture_server.exs`;
  `deps/phoenix_live_view` 1.1.33 (`js.ex` L967, `phoenix_live_view.js` L4092, L5421).

### Interface notes with neighbour rows

1. **C2-T04 overlaps this ticket.** Its row says "All of C". C2-T04's ticket already
   resolves this (its §4.2 line-ownership table and its "Interface notes for neighbour rows" items 3–4): this ticket
   owns C:5–28, 34–47, 899–929, 991–1009, 1077, 1147 and the `.ax-menu` selector of
   C:983; C2-T04 owns C:29–32, C:1010–1016 (the README row's "991–1016" overreaches:
   those lines are home progress hues, `.ax-seg` and `.bm-st`) and the `.ax-pop` half
   of C:983. Settled 2026-10-08: the `html`/`::selection` base rules (H:150,
   H:152–154) and C:1147 are this ticket's, not C2-T01's.
2. **C2-T01 provides `PaletteToggle` with `aria-pressed`** (C2-T01 steps 8–9, on an
   interim `#palette-toggle` `tool-btn`, where `aria-pressed` is correct). This
   ticket moves the hook to `#ax-palette` (`role="menuitemcheckbox"`) and changes its
   sync and click paths to write `aria-checked` (step 5), plus the fixture copy
   (step 8). Settled 2026-10-08: this ticket ports C:1147 (`.ax-top` in Gruvbox
   light).
3. **C12-T01 owns the shared pause action.** Only `DashboardLive` handles
   `toggle-global-pause` today. When `/` moves to BuildLive (C12-T01), pause all
   breaks on home unless BuildLive handles the event. C12-T01 already takes the
   extraction of `DashboardLive.toggle_global_pause/1` and `global_pause_state/1`
   into PROPOSED `AiurWeb.OperatorControlCenter.GlobalPauseControl` (its "Interface
   mismatches", C2-T02 → C3-T01 → C12-T01). C3-T01 needs no change. This ticket
   keeps `global_pause_state/1` private in `DashboardLive` so the extraction is a
   move, not a rewrite.
4. **The row asks for `#ax-collapse` and for the "mobile pill nav".** The design hides
   `#ax-collapse` at every width (C:44, C:999), so it is not rendered, and keyboard
   access moves to `#ax-drag`. Below 960 px the design turns the same aside into a
   fixed bottom bar (H:199–211) and has no separate pill. This ticket follows the design.
5. **C12-T04's S5 mutation names the wrong rule.** It says "remove `padding-bottom:
   5.5rem` from the ported `.app-shell` ≤ 960 rule". C:6 (`.app-shell { padding: 0 }`)
   comes after H:201 in the cascade, so H:201 has no effect. The bottom clearance
   is C:45 (`.dashboard-shell { padding: 1rem .9rem 5.5rem }`). C12-T04 should mutate
   C:45.

## Decisions made without the owner

1. **The heading is `<b id="route-title" role="heading" aria-level="1">`**, not an
   `<h1>`. This keeps the design's element and pixels, and screen readers keep a
   page heading.
2. **Pause has an unknown state** ("Pause state unknown", disabled). The design has
   none. Showing "not paused" when the daemon is unreachable would break the
   AGENTS.md unknown rule. Sign-off item S-20.
3. **Read-only disables the pause item with a reason** instead of hiding it. The design
   (H:1156) hides only `[data-write]` elements, and this item has no such attribute.
4. **Below 961 px, collapse is ignored.** In the design, a stored collapse would hide
   `.ax-set` on a phone (C:906) with no way to expand again (C:44, C:1008), so the
   settings would be unreachable. The product shows the designed uncollapsed phone shell.
   Sign-off item S-21.
5. **The closed menu is `inert`**, and the menu supports arrow, Home, End and Escape
   keys. The separator handle can be focused and toggled from the keyboard. No pixel
   changes.
6. **`aria-checked` replaces `aria-pressed`** on the two menuitemcheckbox items, with
   the selector changed to match.
7. **The Offline badge and the Build Order back link stay**, inside `.ax-title`. Both
   are product states the design does not show. Removing them would hide the
   disconnected state and the way back.
8. **A known zero count renders "0"; an unknown count renders nothing.** This follows
   the design's Build count (H:4967), and AGENTS.md says unknown is never 0. The
   Commands dot keeps main's rule (shown only when > 0). The separate "Command counts
   unavailable" notice carries the unknown case. **No producer is changed:**
   `DashboardLive.put_nav_count/3` (L1182–1185) keeps its `> 0` guard, because its
   source `UnitsPolicy.counts/2` returns zeros for a non-list catalog
   (`units_policy.ex` L79), so a `0` from it can mean "unknown". The `0` clause is
   therefore reached only when C12-T01 supplies a Build count that tells known zero
   from unknown. T-7 pins the component contract for that.
9. **The Streamdeck nav label is "Streamdeck" and the title is "Streamdeck+"**, as in
   the design, through a `nav_label` key.
10. **The shell hooks stay inline in `layouts.ex`**, like `NavToggle` and
    `ThemeToggle` today. They are app-wide, so they do not go in C2-T03's
    `build-home/` loader, which is for the home page only. Cost: the browser
    fixture keeps hand copies (step 8), and the new B-tests run on the
    production-root probe so they test the real hooks. Moving the hooks to a
    `priv/static/*-hook.js` file (the `ticket-context-dialog-hook.js` pattern) would
    remove the copies but adds registration in four places; it is left for later.
12. **Menu patch survival uses `JS.ignore_attributes`**, not a re-apply in
    `updated()`. Re-applying after the patch leaves a window in which the server's
    `inert` is back on the focused item's subtree, so keyboard focus can drop to
    `<body>`. The framework binding stops the patch from touching the three
    attributes at all.
13. **Drag cancel is handled** (`pointercancel`, `lostpointercapture`), though the
    design ignores it, so a cancelled drag cannot leave the page in `col-resize`
    with text selection off.
11. **localStorage keeps the product values** (`"true"`/`"false"`), not the design's
    `"1"`/`"0"`, so existing users keep their state.

## Review log

Adversarial review, 2026-10-08, against `58854d4c8`, the design source and the
neighbour tickets (C2-T01, C2-T04, C3-T01, C12-T01, C12-T04). Fixes made in place:

1. **CSS port ranges.** C:5–47 contained home rules (C:29–32, `.ax-acc`/`.bd-*`); now
   C:5–28 + C:34–47. Added C:1147 (C2-T01 and C2-T04 both assign it here; the ticket
   had sent it to C2-T01). C:983 limited to the `.ax-menu` selector. Added H:150,
   H:153–154 and `.dashboard-shell > *` of H:160 (C2-T04 note 4 hands them here).
2. **Deletion list was incomplete.** The product `.app-shell` (`<main>` in
   `Layouts.app/1`, max-width 1440 px, 16 px padding, four responsive overrides),
   `.dashboard-shell` L237–241, four `[data-nav-collapsed]` rules, `.shell-main`/
   `.shell-content`, `.topbar`/`.toolbar` media rules would have stayed and inset
   the new header. All are now listed with line numbers.
3. **Browser tests would have tested copies.** The harness `/` uses `FixtureLayout`,
   with hand copies of `NavToggle`/`ThemeToggle` and no early script. Added step 8
   (update the copies; extend C2-T01's production-root probe) and moved every
   B-test to the probe.
4. **Menu patch survival.** Re-applying state in `updated()` lets the server's
   `inert` return to the focused subtree. Replaced with `JS.ignore_attributes`
   (LiveView 1.1.33, verified in deps); B-4 now asserts focus and has a matching mutation.
5. **`PaletteToggle` attribute.** C2-T01 ships `aria-pressed`; this ticket now owns
   the change to `aria-checked` instead of asking C2-T01 for it.
6. **Pause extraction owner.** C12-T01 owns it, and C3-T01 adds no handler; the
   dependents list and Interface note 3 were contradicting both tickets.
7. **Disconnected push.** `pushEvent` without a callback rejects while the socket is
   down (an unhandled rejection). Pushes now use the reply-callback form. B-7 uses
   `liveSocket.disconnect()` (network emulation does not reliably close a WebSocket)
   and asserts no `pageerror`.
8. **Drag cancel.** Added `pointercancel`/`lostpointercapture` handling, a
   Non-happy row, a B-2 case with a mutation, and Decision 13.
9. **Compile gate.** Removing the old buttons leaves `nav_toggle_label/1` unused,
   which fails `--warnings-as-errors`; step 1 now deletes it.
10. **Streamdeck icon bytes.** H:1871 has no linecap/linejoin; step 1 says not to
    use `@nav_svg_attrs`.
11. **Paths and counts.** `support/visual.mjs` is `browser/support/visual.mjs`; the
    baselines are 141 PNGs; the spec line numbers were re-read.
12. **Vacuous or mislabeled tests.** T-4 passes on main (no read-only toggle test
    exists), so it is now a named guard. T-6's CSS mutation cannot fail an ExUnit
    test; it moved to new B-10, and T-6 got a mutation it can catch.
13. **Pixel parity product side.** `/analytics` shows "Pause state unknown", so it
    cannot match the design's menu or paused top bar; those regions now use the probe.
    The phone bottom bar compares computed style only (the item set differs).
14. **Inert zero clause.** `put_nav_count/3` drops 0 because `UnitsPolicy.counts/2`
    returns 0 for an unknown catalog. Decision 8 now says no producer changes and the
    clause is waiting for C12-T01.
15. **Commands.** Browser specs run through `scripts/run-browser-tests.mjs` (it starts
    the fixture server); the new spec joins the `package.json` `test` chain;
    baselines come from `test:visual:docker`.
16. **New Interface note 5.** C12-T04's S5 mutation targets H:201, which C:6
    overrides; the real rule is C:45.
17. **Verified starting point.** Added the app layout, the LiveView client API facts
    and the fixture harness facts the fixes above rely on.

Residual risks: the fixture hook copies can drift from `layouts.ex` (Decision 10);
the `restore-nav` replay after a server restart is still lost (today's behaviour);
C1-T02's parity runner and C2-T01's probe route are PROPOSED, so their real names
must be used.
- Reconciliation 2026-10-08 (coordinator): owns H:150 and H:152–154 (step 6, plus the `body` `overflow-x` removal and new B-11 sticky test moved from C2-T01) and C:1147 (interface notes 1–2 settled), pause unknown = S-20, phone collapse ignored below 961 px = S-21, browser/parity tests use `/build` and C12-T04 `PHONE_CELLS`; `toggle-global-pause` on BuildLive confirmed as C12-T01's.
