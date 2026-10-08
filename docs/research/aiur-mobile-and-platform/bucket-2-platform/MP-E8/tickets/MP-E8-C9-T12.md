---
ticket_id: MP-E8-C9-T12
feature_id: MP-E8
chunk_id: MP-E8-C9
bucket: 2-platform
title: List view
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C9-T01, MP-E8-C9-T03, MP-E8-C9-T13, MP-E8-C8-T01]
complexity: 3
design_gate: DESIGN-E8
owns_edge_cases: [EC-19, EC-04]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C9-T12 — List view

> **Wave 0b.** Product paths are cited at `58854d4c8`. Paths marked PROPOSED do
> not exist yet. `J` = `design-source/assets/build.js`, `C` =
> `design-source/assets/build.css`, `H` = `design-source/Aiur Dashboard.html`.
> The design is the specification
> ([claude-design-source-of-truth.md](../claude-design-source-of-truth.md)): port
> the code, remove only the mock parts, and do not restyle or re-space.

## Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history), chunk C9 (client timeline
  engine, port of `build.js`).
- **User value.** `?view=list` shows every loaded ticket as one table row in four
  sections (Live, Planned, Not queued, History newest first), with the same
  state chips, agent, progress and dependency counts as the board. It is the
  view a keyboard or screen-reader user can read from top to bottom: every row
  is focusable, Enter opens the ticket modal, and every cell has a table role.
- **Deliverable.**
  1. PROPOSED `src/priv/static/build-home/list.js`: the port of `stClass`,
     `stText` and `renderList` (J:1151–1181), split into pure string builders
     (exported `stClass`, `stText`, `listHTML`; private `rowHTML`, `secHead`)
     and the DOM side (`renderList`, one delegated click/keydown binding).
     `stText` is exported because C12-T05 reads it (C12-T05 interface note 4).
  2. Additions to C2-T04's home stylesheet (PROPOSED `build-home/home.css`):
     rules for states the design does not draw (`not_planned` chip, unknown-model
     circle in the 15 px slot, keyboard focus ring, wrapping of a non-`ok`
     section head).
  3. Tests: a Node unit test of the pure builders, a browser spec, a fixture
     dataset `list-edges` (registered in C3-T01's dataset list), and region
     checks in C1-T02's parity runner. The PR also removes the `pending: true`
     flag of C1-T03's `view.switch.list` entry, which names this ticket as owner.
- **Scope.**
  - The table: header row `.lr-h`, section heads `.lh`, rows `.lr.<sec>`, cells
    `.c-id .c-tt .c-ep .c-st .c-ag .c-pg .c-dp`, state chips `.lst.st-*`, epic
    icon `.lr-ep`, feature diamond `.lr-f`, progress `.lr-pg` with `--ph`, deps
    `↑N ↓M`, the "Load earlier day" button `.lr-more`, the dim class for feature
    focus, and the three container-query layouts (C:742, 767, 768).
  - Truthful rendering of unknown, stale and unavailable values inside the list
    (EC-08 subset, EC-03 and EC-07 for the list's section heads). The decision
    and the copy come from C9-T13's `states.js`; this ticket only places them
    in the list's heads (C9-T13 handoff: "list-view empty and unavailable rows
    use `sectionState` and the same copy").
  - Keyboard and screen-reader behaviour of the list (EC-19 for this view).
  - Sections of any length, including empty and several hundred rows (EC-04).
- **Non-goals.**
  - The toolbar view segment that switches to the list, and the toolbar's
    list-mode branches that hide span, zoom and legend (J:1132, 1136, 1140):
    C10-T01. This ticket is reached through `?view=list` (C3-T03 already
    accepts it).
  - Filter popovers and the `not_planned` default filter: C10-T02. This ticket
    applies the filter state that is in `S.f` with the design's `match`.
  - Feature focus UI (`S.feature`, `S.fmode`): C10-T03. The list ports the
    design's `dim` rule only.
  - The modal itself, its focus trap and focus return: C11-T01.
  - `jumpNow`'s list branch (`scrollVP(0, …)`, J:1243) and the no-snap guards
    for list view (J:584, 593): C9-T08 ports them.
  - Unfiled planning-pack rows (`num: null`, `qpos: null`): C7-T02 patches the
    list's `"#" + t.num` and `"Q" + t.qpos` call sites with `refText`/`queueText`
    (C7-T02 "Call-site changes", J:1161, 1163). Until C7-T02 lands, the payload
    has no such rows (C3-T02: `num: null` only for `pack:` rows).
  - Row virtualisation. See "Decisions made without the owner" 1.
  - User docs: C12-T07 (`guide/gui.md`) describes the home page and its three
    views.

## Dependencies and blockers

- **DESIGN-E8** (Kevin's go). Design gaps this ticket meets, with the written
  defaults it follows (DESIGN-E8 sign-off table):
  - **S-13** (model logo the design lacks): `.ax-mono` letter circle, sized to
    the slot. This ticket is listed for S-13.
  - **S-17** (`not_planned` look): the `failed` swatch family in the muted tone,
    label "Not planned". This ticket and C10-T02 both need `.lst.st-np` (list
    chip, filter swatch); whichever lands first adds it, with C10-T02's values
    (which are C9-T05's card values).
  - **S-9** (unavailable vs empty): "unavailable" copy plus the age, never
    shown as empty. C9-T13 owns the copy and the decision (`states.js`); this
    ticket calls them for the list's section heads.
  - **S-12** (focus rings, forced colours): `:focus-visible` ring in the accent
    token, keyboard only. C12-T05 owns the app-wide pass; this ticket adds the
    ring for list rows because the rows become focusable here.
- **MP-E8-C9-T01** (row predecessor): module layout, `S`, `ctx`, `fx`,
  `resetState` (clears `ctx` on every mount), `ctx.life`, `nowMs` (`clock.js`),
  `esc` (`dom.js`), `hook.js` registration line.
- **MP-E8-C9-T03** (added; see "Interface notes" 1): `history.js` exports
  `loadEarlier()` and the history state `H` (`more`, `state`, `retryArmed`;
  C9-T03 interface table); `render.js` keeps `relayout`'s list branch (J:643), makes
  `takeAnchor()`/`restoreAnchor(null)` null-safe, and adds the `fx.renderList`
  and `fx.openModal` no-op defaults. Without it the "Load earlier day" button
  has nothing to call. Because C9-T03 needs C9-T01 and C9-T02, `util.js` and
  `icons.js` (C9-T01) are on `main` before this ticket starts.
- **MP-E8-C9-T13** (added; see "Interface notes" 7): `states.js` exports
  `sectionState`, `headNote` and `reasonText`, the one copy of the S-9 rules.
  C9-T13 hands the list heads to this ticket and expects it to use them. Its
  own blocker C8-T03 supplies `fmtAge`/`fmtWhen` (`offline.js`).
- **MP-E8-C8-T01** (added; see "Interface notes" 2): `now-state.js` exports
  `AST`, `agentState`, `progress`, `modelLabel`. The design's
  `AST[t.agent.state].cls` (J:1152) throws on `state: null`; the payload allows
  `null` (C3-T02 "Ticket row" `agent`, widened by C8-T01).
- **Shared contracts.** C3-T02 payload v1 (row fields, `status` including
  `closed`, `sources`, `history`); C3-T03 URL state (`view=list`); C3-T01
  fixture dataset list; C1-T02 parity runner and allowlist; C1-T03 `OWNER`
  table (`view.switch.list`).
- **May run concurrently with** C9-T04..T11, C10-T01. File overlap:
  `hook.js` (one import line each), `home.css` (append-only section),
  `match.js` (C9-T05 may create it first). C7-T02, C7-T03 and C10-T02 later
  edit a few lines of `list.js`.
- **Owner questions.** None block. OQ-E8-4 (no type filter) and OQ-E8-5 (no
  extra Units fields) mean no extra list columns.

## Verified starting point (`58854d4c8`)

**Product.** No home page, no `build-home/` directory and no list view exist.
Everything this ticket edits or imports is PROPOSED by C1-T02, C1-T03, C2-T03,
C2-T04, C3-T01, C3-T02, C8-T01, C8-T03, C9-T01, C9-T02, C9-T03 and C9-T13.
Reused product code:

- `src/browser/package.json:10` the `test` chain a new `test:*` script is
  appended to; `:37` `@axe-core/playwright` 4.11.3 is installed (no new
  dependency).
- `src/browser/tests/liveview-smoke.spec.mjs:1` `import AxeBuilder from
  '@axe-core/playwright'`; `:55-61` the pattern
  `new AxeBuilder({ page }).analyze()` then
  `expect(accessibility.violations).toEqual([])`.
- `src/browser/tests/units.browser.spec.mjs:213-216` the keyboard pattern
  (`focus()`, `page.keyboard.press('Enter')`, then assert the effect). `:218-220`
  is the house rule in test form: "A missing value stays last … instead of
  becoming a fabricated zero".
- `src/browser/support/visual.mjs:28` `openVisualRoute(page, { theme, route,
  collapsed, mode })` (C1-T02 builds on it).
- `src/lib/aiur_web/components/operator_control_center/build_order_graph.ex:113-130`
  the dashboard's existing ARIA table idiom (`role="grid"`, `role="row"`,
  `role="columnheader"`, `role="rowgroup"`, `role="rowheader"` on `div`s). The
  list follows the same idiom with the design's `role="table"`.

**Design (the specification).**

- **J:1152 `stClass`**: hist → `failed` | `merged`; now → `AST[state].cls`
  (`active`, `stuck`, `idle`); plan → `held` | `blocked` (`cue.failed ||
  cue.blockedChain`) | `queued`; nq → `open`.
- **J:1153 `stText`**: hist → "Failed" | "Merged"; now → `AST[state].label`;
  plan → "Held" | "Blocked" | "Waiting on #N" (`cue.wait`) | "Queued"; nq →
  "Not queued".
- **J:1154–1156**: `renderList` clears `L`, `content`, `R` and `cols`; `keep =
  epicOk && match`; `dim` = feature focus mode and the ticket is neither owned
  by nor "also" in the focused feature.
- **J:1157–1167 `row(t)`**, cell by cell:
  - `.lr.<sec>[.dim]`, `role="row"`, `data-id`, `style="--h:<epic hue>"`;
  - `.c-id`: `.lr-ep[.un]` with `I[e.icon]`, then `#<num>`;
  - `.c-tt`: `esc(title)` then, when the ticket has a feature,
    `<i class="lr-f" style="--ft:<feature hue>" title="<feature label>">`;
  - `.c-ep`: `esc(epic label)`;
  - `.c-st`: `<span class="lst st-<cls>"><u></u><text></span>`;
  - `.c-ag`: `<img src=<logo> alt="">` + model name, or
    `<span class="lr-mu">—</span>` when there is no agent **or** the model is
    not in `MODELS`;
  - `.c-pg`: now → `.lr-pg` with `style="--pct:N%;--ph:round(42+N*1.03)"`, a
    `.bd-bar` with `<i style="width:N%">` and `<b>N%</b>`; hist →
    `fmtD(end) · fmtH((end−start)/H)`; plan → `Q<qpos> · W<wave> · ≈<h>h`
    (override hours, else `est`); nq → `<pts> pts`;
  - `.c-dp`: `title="<ups> dependencies · unblocks <dn>"`, text `↑ups` and
    ` ↓dn`, each only when non-zero; `ups = deps.length`, `dn =
    (D.children[id] || []).length`.
- **J:1168 `sec(label, sub, list, extra)`**: a section renders only when it has
  rows or an extra (the button); otherwise it is the empty string.
- **J:1169–1170**: `now`, `plan`, `nq` filtered by `keep`; `hist` filtered by
  `end >= histFrom` and `keep`, sorted `b.end − a.end` (newest first).
- **J:1171–1178**: `vp.innerHTML = <div class="bd-list" role="table">` +
  header row (Ticket, Title, Epic, State, Agent, Progress, Deps) + sections:
  `<i class="lh-live"></i>Live` / "N running"; "Planned" / "N in build-queue
  order"; "Not queued" / "N open"; "History" / "N loaded · newest first", with
  `<button type="button" class="lr-more" id="lr-more">Load earlier day</button>`
  when `moreHistory()`.
- **J:1179**: one click listener per row → `openModal(D.byId[id])`. No
  keyboard handling, no `tabindex`, no cell roles.
- **J:1180**: the button moves `S.histFrom` one loaded day back, re-renders, and
  restores `scrollTop`. Client-side only.
- **J:643**: `relayout()` returns `renderList()` in list view; J:644 rebuilds
  the board (`viewport()`) when `content` is null on the way back.
- **J:1126**: `filtersChanged` calls `renderList()` in list view.
- **J:695–696**: `update()` returns at once when `L` is null, so the scroll
  handler (J:567) does nothing in list view.
- **J:744–745**: `histDays` and `moreHistory()` (a client-side test). In the
  product, `H.more` (C9-T03, from `ctx.snap.history.more`) replaces it.
- **J:9 `esc`**, **J:10 `H = 36e5`** (the hour constant, see "Port" note 8),
  **J:15 `fmtD`**, **J:17 `fmtT`**, **J:19 `fmtH`**, **J:88–91 `AST`**,
  **J:301 `epicOk`**, **J:332 `colKey`**, **J:333–342 `tstate`, `astate`,
  `match`**.

**CSS that must match exactly** (port verbatim; C2-T04 consolidates):

| Selector | Line | Values |
| --- | --- | --- |
| `.lst` | C:726 | inline-flex, gap .4rem, height 22px, padding 0 .55rem, radius 7px, 1px `--line`, bg `--bg-2`, `600 .68rem JetBrains Mono`, nowrap |
| `.lst u` | C:727 | 6×6 px dot, radius 50%, `--faint` |
| `.st-active` | C:728 | border `--accent`, glow `0 0 8px` accent 35%, dot accent |
| `.st-stuck`, `.st-failed` | C:729–730 | border `--block`, ink `--block-ink`, dot `--block`; stuck adds the 8px glow |
| `.st-idle` | C:731 | grayscale(1), `--muted`, bg `--surface-2` |
| `.st-merged u` | C:732 | dot `--good` |
| `.st-queued` | C:733 | dashed `--line-strong`, 135° stripes 4px/8px at `--fg` 5% |
| `.st-held` | C:734 | dashed `--attn-line`, ink `--attn-ink`, dot `--attn` |
| `.st-blocked` | C:735 | dashed `--block-line`, ink `--block-ink`, dot `--block` |
| `.st-open` | C:736 | dashed `--line-strong`, `--muted`, hollow dot (inset 1px `--faint`) |
| `.bd-list` | C:741 | `container-type: inline-size` |
| `.lr` | C:742 | grid `96px minmax(0,1fr) 150px 170px 120px 150px 64px`, gap .9rem, min-height 44px, padding 0 1rem, bottom border `--line` 50% |
| `.lr[data-id]:hover` | C:743 | bg `--fg` 4% |
| `.lr.dim` | C:744 | opacity .35 |
| `.lr-h` | C:745, 770 | sticky top 0, z 3, min-height 36px, bg `--surface-2` 94% + blur 5px, `700 .6rem` mono, .08em, uppercase, `--faint` |
| `.lh`, `.lh b`, `.lh em` | C:746–748, 771 | flex baseline, gap .7rem, padding 1.1rem 1rem .45rem; b `700 .68rem` uppercase `--fg`; em `.66rem` `--faint`; nowrap |
| `.lh-live` | C:749 | 7×7 px `--good` dot, `0 0 0 3px --good-soft, 0 0 8px --good` |
| `.c-id`, `.lr-ep`, `.lr-ep.un`, `.lr-ep svg` | C:750–753 | 24×24 radius 7px, `oklch(.72 .14 var(--h))` on `/.12`; unsorted muted on `--surface-3`; svg 13px |
| `.c-tt`, `.lr-f` | C:754–756 | .86rem/550, ellipsis; diamond 7px rotated 45°, `oklch(.66 .14 var(--ft))` |
| `.c-ep`, `.lr-mu` | C:757 | `.72rem` mono `--muted`, ellipsis |
| `.c-ag`, `.c-ag img` | C:758–759 | flex gap .4rem, `600 .72rem` mono; img 15×15 contain |
| `.lr-pg`, bar, b | C:760–762 | bar height 4px, fill `oklch(.74 .16 var(--ph))`; b `oklch(.78 .15 var(--ph))`, min 3ch, right |
| `.lr.now` | C:763 | `linear-gradient(90deg, oklch(.74 .15 var(--ph, 90) / .05), transparent)` |
| `.c-dp` | C:764–765 | `.7rem` mono `--faint`, right |
| `.lr-more` | C:766 | block, margin `1rem auto 1.4rem`, height 30px, pill, dashed `--line-strong`, `600 .72rem` mono `--muted` |
| container ≤ 980px | C:767 | 5 columns `90px 1fr 160px 110px 130px`; hide `.c-ep`, `.c-dp` |
| container ≤ 640px | C:768 | 3 columns `74px 1fr 120px`, gap .6rem, padding 0 .7rem; hide `.c-ag`, `.c-pg` |
| light / Gruvbox | C:968, 982, 1011, 1016, 1053, 1063 | bar fill and `b` colour per theme with `--ph` fallback 60; light `.lst` bg `--surface`; Gruvbox `.lr-ep { --sat: .1 }` |
| base `.bd-bar` | C:244–245 | track `--surface-3`, radius 999px; `i` block 100% height |

Design facts worth knowing before porting:

- `.lr.now`'s gradient reads `--ph` from the row, but the design sets `--ph` on
  the inner `.lr-pg`, so the row always uses the fallback hue 90. Keep it.
- `.lr.now .st-stuck ~ .bd-bar i` (C:1163) never matches: the chip and the bar
  are in different cells. A stuck agent's list bar keeps its `--ph` hue. Keep it
  (parity); C2-T04 may list the selector as dead.
- The design hides `.bd-fd` on cards (C:1183) but **not** `.lr-f` in the list.
  The list keeps its feature diamond.
- `.ax-mono` is 18 px (C:58–59), round (C:782) and then 20 px (C:895) globally.
  The list's logo slot is 15 px (C:759), so an S-13 circle needs a scoped size.

## Chosen design

### Port, then change only what real data forces

`list.js` is J:1152–1181 line for line, with these changes and no others:

1. **Pure builders.** `listHTML(D, S, H, P, now)` returns the string that the
   design assigns to `vp.innerHTML` (`P` = `ctx.snap`, the payload that carries
   `sources`; `now` = `nowMs()` from C9-T01's `clock.js`). `renderList()` calls
   it. This lets a Node test render 600 rows without a DOM (EC-04) and keeps
   the markup in one place.
2. **Unknown values have their own rendering** (table below), never `0`, `NaN`,
   `null` text, a plausible default or another model's logo.
3. **Section heads tell empty from unavailable** (EC-03, EC-07; S-9 default)
   through C9-T13's `sectionState` and `headNote`, so the list and the board
   use the same words.
4. **Accessibility attributes** that do not change pixels: cell roles,
   `tabindex="0"` on ticket rows, `aria-label` where the design relies on
   `title` or on arrows, `aria-hidden` on decorative marks, one keyboard handler.
5. **One delegated listener** (click + keydown on `#bd-vp`, through
   `ctx.life.on`) instead of one listener per row per render. The design's
   per-row listeners leak on every re-render once live diffs arrive.
6. **"Load earlier day" calls the server** through C9-T03's `loadEarlier()`.
   The button shows when `H.more` is true, in place of the design's
   `moreHistory()` (J:745).
7. **Scroll and focus survive a re-render** (a live diff re-renders the whole
   list, unlike the design, whose data never changes).
8. **Name clash.** `list.js` imports C9-T03's history state as `H`. The
   design's `H` in `fmtH((t.end - t.start) / H)` (J:1161) is the hour constant
   `36e5` (J:10). Write the literal `36e5` there; do not import an hour `H`.

### Cell rendering rules

| Cell | Known (design, unchanged) | Unknown or odd input | Rendered |
| --- | --- | --- | --- |
| State chip, now | `agentState(state)` → `st-active` / `st-stuck` / `st-idle` + AST label | `agent` null, or `state` null or not in `AST` | `lst st-unknown`, "State unknown" (no CSS rule: the base `.lst` look) |
| State chip, hist | `failed` → `st-failed` "Failed"; `done` → `st-merged` "Merged" | `status: not_planned` | `lst st-np`, "Not planned" (S-17) |
| | | `status: closed` (closed for another reason, C3-T02 / C8-T04 decision 6) | `lst st-closed`, "Closed" (no CSS rule: the base `.lst` look; the same label as C9-T05's card) |
| | | any other `status` | `lst st-unknown`, "State unknown" (cause-neutral) |
| State chip, plan | J:1152–1153 verbatim | — | — |
| State chip, nq | `st-open`, "Not queued" | — | — |
| Agent | `<img src=LOGOS[m].src alt="">` + `modelLabel(agent)` | no `agent` | `<span class="lr-mu">—</span>` (design) |
| | | `agent` present, `model` not in `LOGOS` (muse, openrouter, `null`) | `<span class="ax-mono" aria-hidden="true">L</span>` + name; `L` = first letter of `agent.name` upper-cased, or `?` when `name` is null; name text = `agent.name`, else "Model unknown" |
| Progress, now | `progress(pct).known` → design markup | `pct` null | `<span class="lr-mu">—</span>`: no `.lr-pg`, no `<b>`, no `--pct`, no `--ph`, no `.bd-bar` (C8-T01 rule and its interface note 5: in light theme `.lr-pg b` is `oklch(.6 .15 var(--ph, 60))`, C:1016, the amber "early progress" hue). `.lr-mu` is the design's own muted cell text (C:757), as in the hist, plan and nq cells |
| Progress, hist | `fmtD(end) · fmtH((end−start)/36e5)` | `start` null, or `end < start` | `fmtD(end) · —` |
| Progress, plan | `Q<qpos> · W<wave> · ≈<h>h` | `est` and `override` null (always, until C7-T03 wires them, R-G12); `wave` null (valid, C3-T02) | `· —` for the estimate (C7-T03 rule `Q4 · W2 · —`; never the design's `EST[cx-1]` fallback); `W?` for the wave |
| Progress, nq | `<pts> pts` | `pts` null | `— pts` |
| Deps | `↑N ↓M`, title "N dependencies · unblocks M" | — | same, plus `aria-label` = the title text |
| Epic | `D.epics[colKey(t)]` | key missing from `D.epics` | `D.epics.unsorted` (the design's Unsorted look, EC-21) |
| Feature diamond | `D.features[t.feature]` | key missing from `D.features` | no diamond |

- `modelLabel(agent)` is C8-T01's export in `now-state.js`: `agent.name` when
  it is a string; else the design label (`Claude`, `Codex`, `DeepSeek`, `Kimi`,
  J:83–86) when the key is an own key of its `LABELS`; else `null`. This ticket
  imports it and adds nothing to `now-state.js`.
- Every string from the payload goes through `esc` (C9-T01's `dom.js` version,
  which also escapes `'`, C3-T02 decision 8), including `data-id`, `agent.name`, the source `reason`, the logo
  path and the numbers the design interpolates raw (`num`, `pct`, `qpos`,
  `wave`, `pts`, `hue`). Numbers are checked with `Number.isFinite` before they
  reach a `style` attribute; a non-finite hue is omitted (the CSS fallback hue
  applies).

### Section heads and source states

Each section maps to one `sources` key (C9-T13 "Section · source" table; C3-T02
snapshot and `set.sources`):

| Section | `sec` | Key | Head when `ok` and rows exist | Head when `ok` and 0 rows |
| --- | --- | --- | --- | --- |
| Live | `now` | `agents` | "N running" | hidden (design) |
| Planned | `plan` | `queue` | "N in build-queue order" | hidden (design) |
| Not queued | `nq` | `index` | "N open" | hidden (design) |
| History | `hist` | `history` | "N loaded · newest first" | hidden (design), unless `H.more` (the button, J:1178) |

`open_tickets` alone governs Not queued: C7-T04 already folds the queue's state into
it (queue `store_unavailable` → index `:unavailable`, reasons
`[:queue_unavailable]`, rows `[]`, C7-T04 lines 183–185), and C8-T04 copies
C7-T04's state and reasons into `sources.open_tickets` (`sources.index` is the Index process's own health, C8-T04).

For each section, `secHead(sec, label, sub, list)` calls C9-T13:

1. `st = sectionState(P, D, H, sec, list)` (`list` = the rows after `keep`). A
   missing entry or an unknown state string is `unavailable` with reason
   `unknown`, never `ok` (C9-T13's client defence).
2. `note = headNote(sec, st, now)`: `""` for `ok`; `stale, <age>`; `partial,
   <age>`; `unavailable, showing the <age>`; or, with no rows, the bare word
   `unavailable`, `incomplete` or `disabled`.
3. The head is shown when the design shows it (rows, or the History button) or
   when `st.src.state` is not `ok`. An `ok` empty section stays hidden, as in
   the design.
4. The `<em>` text:
   - rows exist (or the History button), or the state is `ok`/`stale`: the
     design sub, then ` · ` + `note` when `note` is not empty;
   - no rows and the state is `unavailable` or `incomplete`: `note` + ` · ` +
     `reasonText(reason)` + ` · ` + `ageText(src, now)`;
   - no rows and `disabled`: `note` + ` · ` + `reasonText(reason)`.

   `ageText(src, now)` is C9-T13's `age` expression (`"read " + fmtAge(now −
   observed_at) + " (" + fmtWhen(observed_at, now) + ")"`, or `"no successful
   read recorded"` when `observed_at` or `now` is `null`), exported from
   `states.js` (interface note 7). So an unavailable section always shows its
   cause and its age, and the age is rendered, not only computed (AGENTS.md).
5. A non-`ok` head carries `data-st="<state>"` on `.lh`. One added rule lets
   only those heads wrap (`.lh[data-st] em { white-space: normal; }`), because
   C:771 sets `nowrap` and the longer text would overflow at 390 px. `ok` heads
   have no `data-st`, so their pixels are the design's.

Examples (fixture `now` = Oct 7 14:20 America/Los_Angeles, `observed_at` 6 min
earlier):

| Source | Rows | `<em>` |
| --- | --- | --- |
| `queue` `{unavailable, "timeout"}` | 0 | `unavailable · timed out · read 6 min ago (14:14)` |
| `history` `{stale}` | 3 | `3 loaded · newest first · stale, read 6 min ago (14:14)` |
| `history` missing | 0 | `unavailable · unknown cause · no successful read recorded` |
| `queue` `{disabled, "queue disabled in config"}` | 0 | `disabled · queue disabled in config` |
| `index` `{incomplete, "incomplete"}` | 0 | `incomplete · the read was partial · read 6 min ago (14:14)` |

The offline banner (`#bd-offline`, C8-T03) stays outside `#bd-vp` and shows in
list view too, so the list does not repeat the daemon state.

The History head's `<em>` also carries C9-T03's paging error: while
`H.state === "error"`, ` · earlier days could not load` is appended. The button
stays enabled so a click retries. The list does not use the board's "scroll up
to retry" wording, because in the list the button is the retry.

The ages move without a data change: C9-T13's 30 s tick calls
`fx.requestLivePass()` → `flushLive` → `relayout({live: true})`, which in list
view is `renderList()` (J:643).

### Markup changes that do not move pixels

```html
<div class="bd-list" role="table" aria-label="Build tickets" tabindex="-1">
  <div class="lr lr-h" role="row">
    <span class="c-id" role="columnheader">Ticket</span> … (7 headers)
  </div>
  <div class="lh" role="row" data-sec="now">
    <b role="cell"><i class="lh-live" aria-hidden="true"></i>Live</b>
    <em role="cell">3 running</em>
  </div>
  <div class="lh" role="row" data-sec="plan" data-st="unavailable">
    <b role="cell">Planned</b>
    <em role="cell">unavailable · timed out · read 6 min ago (14:14)</em>
  </div>
  <div class="lr now" role="row" tabindex="0" data-id="123" style="--h:200"
       aria-label="#123 Flaky websocket reconnect, Running">
    <span class="c-id" role="cell"><span class="lr-ep" aria-hidden="true">…svg…</span>#123</span>
    <span class="c-tt" role="cell">Flaky…<i class="lr-f" role="img" aria-label="Feature: Pagination" title="Pagination" style="--ft:150"></i></span>
    … (role="cell" on the other five)
    <span class="c-dp" role="cell" title="2 dependencies · unblocks 1" aria-label="2 dependencies · unblocks 1">↑2 ↓1</span>
  </div>
  …
  <div role="row"><div role="cell">
    <button type="button" class="lr-more" id="lr-more">Load earlier day</button>
  </div></div>
</div>
```

- The button's wrapper divs have no class, no padding and no border, so the
  button's vertical margins collapse through them and the box is where the
  design puts it. C1-T02's region check proves it.
- `data-sec` on `.lh` lets tests and allowlist selectors name a section head
  without relying on order. `data-st` appears only on a non-`ok` head.
- `tabindex="-1"` on `.bd-list` makes it a programmatic focus target (not a Tab
  stop) for the case where the focused row leaves the list. `#bd-vp` has no
  `tabindex` (J:550), so `vp.focus()` would do nothing and focus would drop to
  `<body>`.
- The row `aria-label` gives a screen reader the id, title and state in one
  announcement; the cells stay readable in table-navigation mode.

### Behaviour

```js
// list.js (PROPOSED) — sketch; strings exactly as J:1157–1178
export function renderList() {
  const vp = ctx.vp, rows = () => [...vp.querySelectorAll(".lr[data-id]")];
  const fr = document.activeElement?.closest?.(".lr[data-id]");
  const prevFocus = fr && vp.contains(fr) ? { id: fr.dataset.id, i: rows().indexOf(fr) } : null;
  const anchor = takeListAnchor(vp);            // first row whose top ≥ scrollTop: {id, off}; else {st}
  ctx.L = null; ctx.content = null; ctx.R.clear(); ctx.cols = [];   // J:1155
  vp.innerHTML = listHTML(ctx.D, S, H, ctx.snap, nowMs());
  restoreListAnchor(vp, anchor);                 // same id → same offset; else raw scrollTop
  if (prevFocus) {                               // same ticket; else the row now at that index; else the table
    const all = rows();
    (vp.querySelector('.lr[data-id="' + CSS.escape(prevFocus.id) + '"]') ||
     all[Math.min(prevFocus.i, all.length - 1)] || vp.querySelector(".bd-list"))?.focus({ preventScroll: true });
  }
  bindOnce(vp);
}
function bindOnce(vp) {
  if (ctx.listVp === vp) return; ctx.listVp = vp;               // keyed on the element: a remount (resetState clears ctx)
                                                                 // or a rebuilt #bd-vp binds again, never twice
  ctx.life.on(vp, "click", (e) => {
    if (S.view !== "list") return;
    if (e.target.closest("#lr-more")) return earlier(e.target.closest("#lr-more"));
    const r = e.target.closest(".lr[data-id]"); if (r) open(r.dataset.id);
  });
  ctx.life.on(vp, "keydown", (e) => {
    if (S.view !== "list" || e.key !== "Enter" || e.target.matches("button")) return;
    const r = e.target.closest(".lr[data-id]"); if (r) { e.preventDefault(); open(r.dataset.id); }
  });
}
const open = (id) => { const t = ctx.D.byId[id]; if (t) fx.openModal(t); };   // id compare, never object identity
async function earlier(btn) {
  if (H.state === "loading") return;
  H.retryArmed = true;                          // an explicit click is a retry (C9-T03 retry rule)
  btn.disabled = true; btn.setAttribute("aria-busy", "true");
  await loadEarlier();                          // C9-T03; on success it calls relayout → renderList
  if (btn.isConnected) { btn.disabled = false; btn.removeAttribute("aria-busy"); renderList(); }
}
```

- **View switch to list:** C3-T03 patches `S.view`; C9-T01's `onServerURL`
  calls `fx.relayout()` → `fx.renderList()` (J:643), then `jumpNow` scrolls to
  the top (C9-T08, J:1243).
- **Back to the board:** `relayout()` finds `ctx.content === null` and calls
  `viewport()` (J:644, C9-T03). Nothing in this ticket is needed for that.
- **Live diff in list view:** C9-T03's `onDataChanged` → `relayout({live:true})`
  → `renderList()`. The list re-renders whole; the anchor keeps the first
  visible row still, and focus stays on the same ticket. If the focused ticket
  left the list (filtered out or removed), focus moves to the row that now has
  its index (or the last row), else to `.bd-list`. C9-T03's `onDataChanged` and
  `flushLive` must not read `ctx.content.classList` while `ctx.content` is
  `null` (interface note 1); B3 fails on that page error.
- **Filter change:** C10-T02's `filtersChanged` calls `fx.relayout()`, as
  J:1126 does.
- **`disabled` on the button** only while a page is in flight: an author
  `color` beats the UA `:disabled` colour, so the look does not change; it only
  blocks a double click. `aria-busy` tells a screen reader.

### Invariants

1. In list view `ctx.L === null` and `ctx.content === null`, so `update()`,
   edges, columns and the band do nothing (J:696).
2. `listHTML` is pure: same `D`, `S`, `H`, `P`, `now` → same string. It reads
   no clock itself: `now` is a parameter, and dates come from row times via
   `fmtD`/`fmtT`/`fmtWhen`.
3. No unknown value renders as `0`, `0%`, `NaN`, `null`, `undefined`, "Merged",
   "Running", "Queued" or a logo of another model.
4. A section whose source is not `ok` (`stale`, `incomplete`, `unavailable`,
   `disabled`, or missing) is never hidden and never shows only a count; an
   `unavailable` or `incomplete` one always shows its cause and its age.
5. Every listener goes through `ctx.life`; after `destroyed` none remains.

## Implementation steps

1. **`list.js`** (PROPOSED `src/priv/static/build-home/list.js`): port
   J:1152–1181 into `stClass(t)`, `stText(t)` (both exported), `progCell(t)`,
   `agentCell(t)`, `rowHTML(t, D, S)`, `secHead(sec, label, sub, list, extra,
   P, D, H, now)`, `listHTML(D, S, H, P, now)` (exported) and `renderList()`.
   Imports, all from files on `main` once the blockers have merged:
   - `esc` (`dom.js`); `S`, `ctx`, `fx` (`state.js`); `nowMs` (`clock.js`)
     (C9-T01);
   - `fmtD`, `fmtH` (`util.js`, C9-T02), `I` (`icons.js`, C9-T01);
   - `loadEarlier`, `H` (`history.js`, C9-T03);
   - `sectionState`, `headNote`, `reasonText`, `ageText` (`states.js`, C9-T13);
   - `agentState`, `progress`, `modelLabel` (`now-state.js`, C8-T01);
   - `LOGOS` (`logos.js`, C2-T03);
   - `epicOk`, `match`, `colKey` (`match.js`, step 3).

   End with `Object.assign(fx, { renderList })`. No `onReset` is needed:
   `resetState` clears `ctx`, so `ctx.listVp` is empty on every mount.
2. **`render.js`** (C9-T03): confirm that `relayout()` keeps J:643 as
   `if (S.view === "list") return fx.renderList()` after `syncHistory()`, that
   `takeAnchor()` returns `null` when `ctx.L` is null, that `fx.renderList` and
   `fx.openModal` have no-op defaults, and that `onDataChanged`/`flushLive` read
   `ctx.content?.classList` (null-safe). Add any missing guard (one line each)
   if C9-T03 did not (R-G4).
3. **`match.js`**: if C9-T05 has not added it at your base, add PROPOSED
   `build-home/match.js` with `epicOk`, `colKey`, `tstate`, `astate`, `match`
   (J:301, 332–342) verbatim; `match`/`colKey` live only there (R-G9).
   C9-T05 step 5 names the same file. C10-T02 later replaces `keep` in
   `list.js` with `rowOk(S, t) && match(t)` (C10-T02 step 4; interface note 8).
4. **`hook.js`**: `import "./list.js"`.
5. **`home.css`** (C2-T04's file): the ported rules come with C2-T04. Append
   under the `/* MP-E8 additions: states the design does not show … */` block
   (C9-T05 step 8):

   ```css
   /* list (C9-T12; S-17, S-13, S-12, S-9) */
   .lst.st-np { border-color: color-mix(in srgb, var(--block-line) 45%, var(--line)); color: var(--muted); }
   .lst.st-np u { background: color-mix(in srgb, var(--block) 45%, var(--faint)); }
   .c-ag .ax-mono { width: 15px; height: 15px; font-size: .5rem; }
   .lr[data-id]:focus-visible { outline: 2px solid var(--accent); outline-offset: -2px; }
   .lh[data-st] em { white-space: normal; }
   ```

   The two `st-np` lines are C10-T02's step 6 lines, character for character.
   They use C9-T05's `np` card values (the `failed` family, muted). This ticket
   adds them; C10-T02 does not redeclare them (settled 2026-10-08).
   If C2-T04 dropped C:1163 or `.lr-f` as dead, restore them: both are rendered.
6. **Fixture** PROPOSED `src/test/fixtures/build_home/list-edges.json`: a small
   valid snapshot built from `live` (same `{meta, data, daemon}` shape and
   frozen `now`; it passes C3-T02 `Payload.validate/1`), about 8 rows:
   - now: one row `pct: null`, `agent.state: null`; one with `agent.model:
     "muse"`, `name: "Muse"`; one with `model: null`, `name: null`;
   - hist: `not_planned`; `closed`; `start: null`; `end < start`; title
     `<img src=x onerror=window.__xss=1>`;
   - plan: `[]`; nq: `[]`;
   - `sources.queue = {state: "unavailable", reason: "timeout", observed_at:
     <now − 6 min>}` and `sources.open_tickets = {state: "unavailable", reason:
     "queue_unavailable", observed_at: <now − 6 min>}` (C7-T04 folds an
     unavailable queue into `open_tickets`, so a real payload has both);
     `sources.history = {state: "stale", reason: null, observed_at: <now −
     6 min>}`; `agents` `ok`.

   Record the `jq` command that made it in the spec header (as C9-T05 does).
   Add `list-edges` to `@datasets` in C3-T01's
   `src/test/support/build_home/fixture_source.ex` (the list is fixed in code;
   C9-T05 adds `unknowns` the same way) and extend C3-T01's fixture-source test
   case to load it.
7. **Node test** PROPOSED `src/browser/scripts/build-home-list.test.mjs` (next
   to C3-T02's and C8-T01's Node tests; a `*.test.mjs` file under `tests/`
   would also be matched by Playwright's default `testMatch`) and npm script
   `"test:build-home-list-unit": "TZ=America/Los_Angeles node --test
   scripts/build-home-list.test.mjs"` (`fmtD`, `fmtT` and `fmtWhen` use local
   time; the TZ is the parity runner's `timezoneId`).
8. **Browser spec** PROPOSED `src/browser/tests/build-home-list.browser.spec.mjs`
   and npm script `"test:build-home-list": "node scripts/run-browser-tests.mjs
   tests/build-home-list.browser.spec.mjs"`; append both scripts to the `test`
   chain at `src/browser/package.json:10`.
9. **Parity cells** in C1-T02's harness spec (see "Pixel parity").
10. **C1-T03 `OWNER` table**: delete `pending: true` from
    `'view.switch.list': { owners: ['MP-E8-C9-T12'], pending: true }`, so the
    view-switch motion sequence runs from this PR on (C1-T03 decision 12).

## Non-happy paths

| Case | Input | Expected | Test |
| --- | --- | --- | --- |
| Unknown progress | now row `pct: null` | `<span class="lr-mu">—</span>`; no `.lr-pg`, no `<b>`, no bar, no `--ph` | U1 |
| Unknown agent state | now row `agent.state: null`, or `agent: null` | chip "State unknown", class `st-unknown`, no `st-active` | U2 |
| `not_planned` closure | hist row `status: "not_planned"` | chip "Not planned", `st-np` | U3 |
| Closed for another reason | hist row `status: "closed"` | chip "Closed", `st-closed`; not Merged, not Failed | U3 |
| Unknown status | hist row `status: "running"` (injected) | chip "State unknown" | U3 |
| Unknown start | hist row `start: null` | `Oct 7 · —` | U4 |
| Clock skew | hist `end < start` | `Oct 7 · —` (never `5m`) | U4 |
| Unknown estimate | plan row `est: null`, `override: null` | `Q4 · W2 · —` | U5 |
| Override on unknown est | `est: null`, `override.hours: 6` | `Q4 · W2 · ≈6h` | U5 |
| Unknown wave | `wave: null` (valid, C3-T02) | `Q4 · W? · ≈7h` | U5 |
| Unknown points | nq `pts: null` | `— pts` | U6 |
| Model not in the logo set | `model: "muse"`, `name: "Muse"` | `.ax-mono` "M" + "Muse"; no `<img>` | U7 |
| Model and name unknown | `model: null`, `name: null` | `.ax-mono` "?" + "Model unknown" | U7 |
| No agent | `agent: null` | `<span class="lr-mu">—</span>` | U7 |
| Untrusted text (EC-30) | title `<img src=x onerror=…>`, `agent.name` `"><b>`, `reason` `<i>` | escaped text; no element created; `window.__xss` undefined | U8, B7 |
| Epic or feature key missing | `epic: "gone"`, `feature: "gone"` | Unsorted look; no diamond; no exception | U9 |
| Queue unavailable (EC-03) | `sources.queue` `{unavailable, "timeout"}`, `plan: []`; `sources.open_tickets` `{unavailable, "queue_unavailable"}`, `nq: []` | Planned em `unavailable · timed out · read 6 min ago (14:14)`; Not queued em `unavailable · queue_unavailable · read 6 min ago (14:14)` | U10, B5 |
| Unavailable with rows | `sources.queue` unavailable, 2 plan rows still loaded | Planned em `2 in build-queue order · unavailable, showing the read 6 min ago (14:14)` (C9-T13 `headNote`) | U10 |
| Incomplete source | `sources.open_tickets` `{incomplete, "incomplete"}`, `nq: []` | Not queued em `incomplete · the read was partial · read 6 min ago (14:14)`; never hidden, never `0 open` | U10 |
| Queue empty (EC-03) | `noqueue`, `sources.queue.state: "ok"` | no Planned head (design) | U10, B5 |
| Source key missing (injected; the validator rejects it) | `sources` without `history` | History em `unavailable · unknown cause · no successful read recorded` | U10 |
| Stale source (EC-07) | `sources.history.state: "stale"`, 3 rows | `3 loaded · newest first · stale, read 6 min ago (14:14)`; `· stale, no successful read recorded` when `observed_at` is null | U10 |
| Queue disabled | `sources.queue` `{disabled, "queue disabled in config"}`, `plan: []` | Planned em `disabled · queue disabled in config` | U10 |
| Several hundred rows (EC-04) | 600 nq rows | 600 `.lr.nq` rows, head "600 open" | U11 |
| No rows at all | empty sections, sources `ok` | only the header row (design) | U11 |
| Live diff while a row is focused | focus row X, a diff changes another row | focus stays on X; first visible row does not move; no page error (C9-T03's live path with `ctx.content === null`) | B3 |
| Focused row removed | X leaves the list | focus on the row now at X's index (or the last row), else `.bd-list`; never `<body>`; no exception | B3 |
| Age moves without data | 30 s pass with a `stale` source | C9-T13's tick re-renders the list; the age text changes | covered by C9-T13's tick test; the list path is `relayout` → `renderList` (J:643) |
| Page in flight | click "Load earlier day" twice fast | one `load-earlier` request | B4 |
| Page fails | `earlier?fail=1` | History head ends `· earlier days could not load`; next click sends one request | B4 |
| Reply after unmount | navigate away during `earlier?delay=500` | no exception (`btn.isConnected` false; C9-T03 drops the reply) | B4 |
| Remount (LiveView navigation) | leave `/build` and return | one click listener (`ctx.listVp` cleared by `resetState`): Enter opens once | B2 |
| Reduced motion | `prefers-reduced-motion: reduce` | the list adds no animation or transition; scroll to top is instant (C9-T08 owns `scrollVP`) | covered by C9-T08 |
| Forced colours | `forced-colors: active` | chip and progress text remain (dots and bar fills drop, the text carries the state); focus outline visible | B6 |
| Phone width (EC-18) | 390 px | 3-column layout (C:768); rows still focusable and tappable | parity cells |

**Security.** The list only reads the payload. It sends no new server event
except `load-earlier` (C9-T03, already validated server side). No new data
reaches the browser.

## Compatibility and rollout

- No config, migration or server change. No new dependency.
- The page is unreleased until C12-T01's cutover; `?view=list` works on the
  fixture and the hidden `/build` route before that.
- Rollback: remove the `import "./list.js"` line; the `fx.renderList` default
  then renders nothing in list view (only reachable by URL before C10-T01).

## Pixel parity

**Design elements reproduced:** `.bd-list`, `.lr`, `.lr-h`, `.lh`, `.lh-live`,
`.c-id`, `.c-tt`, `.c-ep`, `.c-st`, `.c-ag`, `.c-pg`, `.c-dp`, `.lr-ep`,
`.lr-ep.un`, `.lr-f`, `.lr-mu`, `.lr-pg`, `.lr-more`, `.lr.dim`, `.lr.now`,
`.lst` with `st-active`, `st-stuck`, `st-idle`, `st-failed`, `st-merged`,
`st-queued`, `st-held`, `st-blocked`, `st-open`, and the container layouts at
980 and 640 px (C:726–771 and the theme lines above).

**How parity is checked** (C1-T02's runner). Both sides open through
`openParityPair({ dataset, query: { view: "list" } })`; C1-T02 applies `query`
to the design URL and to `/build` (R-G7; design `readURL` accepts `view=list`,
J:304–315). Enforced cells in
`design-parity-harness.browser.spec.mjs`:

| Cell | Region | Scroll |
| --- | --- | --- |
| `live` × 1440 / 1024 / 390 × dark × Gruvbox | `#bd-vp` | top, and `scrollTop = scrollHeight` (History and the button) |
| `live` × 1440 × light × default palette | `#bd-vp` | top |
| `dense` × 1440 × dark × Gruvbox | `#bd-vp` | top and bottom |
| `newrepo` and `noqueue` × 1440 × dark × Gruvbox | `#bd-vp` | top (hidden empty sections) |
| `offline` × 1440 × dark × Gruvbox | `#bd-vp` | top |

- 1024 px hits the 980 px container layout (sidenav plus gutters make the list
  narrower than 980 px; the cell asserts `.c-ep` is `display: none` so it
  cannot silently test the wide layout). 390 px hits the 640 px layout.
- Hover: one more cell (`live` × 1440 × dark × Gruvbox) runs
  `locator('.lr[data-id]').nth(2).hover()` on both pages that `openParityPair`
  returns, then compares `#bd-vp`. C1-T03 has no list sequence, so this stays
  a C1-T02 cell.
- Expected allowlist entries for these cells: **none**. Roles, `tabindex`,
  `aria-*`, `data-sec` and the button wrapper do not change pixels; if a cell
  differs, the port is wrong.
- The `st-np`, `st-unknown`, `.ax-mono` and unavailable/stale head looks exist
  only in `list-edges`, which has no design counterpart. They are not in the
  parity matrix. They go into the C12-T08 sign-off package under S-9, S-13 and
  S-17, with one screenshot of `list-edges` per theme.
- Filters and feature dimming (`.lr.dim`) get their parity cells in C10-T02 and
  C10-T03, which own the UI that sets them.

## Verification

**Node unit** (`src/browser/scripts/build-home-list.test.mjs`,
`TZ=America/Los_Angeles node --test`). Rows are built inline from the `live`
fixture row shapes; `now` is the fixture's frozen `meta.now`. Each test names
the production hunk whose removal must make it fail. `list.js` and its imports
must not touch `document` or `window` at import time (C9-T01 rule: modules only
register in `fx` and `onReset` at import); if one does, the writer moves that
test into the browser spec as a `page.evaluate` of `listHTML` and says so in
the PR body.

| Test | Input | Expected | Fails when |
| --- | --- | --- | --- |
| U1 `unknown pct is not 0%` | now row `pct: null` | `progCell` is `<span class="lr-mu">—</span>`: no `%`, no `--ph`, no `bd-bar`, no `lr-pg`, no `<b>` | `progress()` is replaced by the design's `t.pct + "%"`, or by `t.pct ?? 0`, or the `—` is put back inside `.lr-pg b` (amber in light theme) |
| U2 `unknown agent state is not Running` | `agent.state: null`; `agent: null` on a now row | `stClass` → `"unknown"`, `stText` → `"State unknown"`; no throw | `agentState` replaced by `AST[state]` (throws) or by a default to `active` |
| U3 `not_planned and closed are not Merged` | hist `status: "not_planned"`; `"closed"`; `"running"` | `np`/"Not planned"; `closed`/"Closed"; `unknown`/"State unknown" | the design's `stClass`/`stText` restored (all three give Merged), or the `closed` branch dropped (gives "State unknown") |
| U4 `unknown start gives no duration` | hist `start: null`; `start > end` | `Oct 7 · —` both; no `NaN`, no `5m` | the design's `fmtH((end − start)/H)` restored |
| U5 `unknown estimate` | plan `est: null`; `override.hours: 6`; `wave: null` | `Q4 · W2 · —`; `Q4 · W2 · ≈6h`; `Q4 · W? · ≈7h` | the design's `"≈" + est + "h"` restored (`≈nullh`), or `"W" + t.wave` |
| U6 `unknown points` | nq `pts: null` | `— pts` | `t.pts + " pts"` restored |
| U7 `model outside the logo set` | `muse`/"Muse"; `null`/`null`; `agent: null` | `ax-mono` + `M` + `Muse`, no `<img`; `?` + `Model unknown`; `lr-mu">—` | the design's `m ? img : "—"` restored (an agent shows as "no agent"), or a default logo |
| U8 `text is escaped` | title, `agent.name`, `reason` with `<`, `"`, `'` | no raw `<img`, `"><`, or `'` in the output | any `esc` call removed |
| U9 `missing epic or feature key` | `epic: "gone"`, `feature: "gone"` | no throw; `lr-ep un`; no `lr-f` | the `D.epics.unsorted` / feature guard removed |
| U10 `empty is not unavailable` | each row of the "Section heads" examples table, plus: queue `ok` + 0 rows; queue unavailable + 2 rows; `history` stale with `observed_at: null` | no Planned head for `ok` + 0 rows; every other `<em>` exactly as in the examples and the Non-happy table | the design's `sec()` (hides any empty section) restored; a missing key treated as `ok`; the no-rows branch without `reasonText` or `ageText` (cause or age missing); `headNote` not appended when rows exist (stale shown as current) |
| U11 `long and empty sections` (EC-04) | 600 nq rows; all sections empty and `ok` | 600 `class="lr nq"` and head `600 open`; only the header row | a row cap, or `sec()` returning a head for an empty `ok` section |
| U12 `history newest first` (parity guard) | 3 hist rows | order by `end` descending | — (passes on the design too; kept as a regression guard, not counted as coverage) |

**Browser spec** (`src/browser/tests/build-home-list.browser.spec.mjs`; fixture
server, `/build-fixture/<dataset>` then `/build?view=list`). Each test records
page errors and fails on any.

| Test | Steps | Expected | Fails when |
| --- | --- | --- | --- |
| B1 `sections and counts` | `live` | heads in order Live, Planned, Not queued, History; each `<em>` count equals the fixture's section length; History `data-id` order = fixture rows by `end` desc | `listHTML` not wired to `fx.renderList` (board shows instead) |
| B2 `keyboard opens the modal` | spy: `import('/build-home/state.js')` then replace `fx.openModal` (same module instance); Tab to the first ticket row; Enter; then navigate away and back, Enter again | spy called once each time with the row's `id`; the focused row shows a 2 px accent outline | the keydown handler or `tabindex` removed; `ctx.listVp` replaced by a module-level flag that survives the remount (second mount: no call) |
| B3 `focus and position survive a diff` | `live`; focus the 5th row X; record its `getBoundingClientRect().top`; `GET /build-control/diff?op=title&id=<the 2nd row's id>` (C9-T03 control); then, through `import('/build-home/state.js')`, set `S.f.epic` to an epic X is not in and call `fx.relayout()` (the filter path, J:1126) | after the diff: `activeElement.dataset.id` is X, X's top moved ≤ 1 px, no page error; after the filter: `activeElement` is the row at X's old index (or the last row, or `.bd-list`), never `<body>` | refocus or anchor removed; the fallback focuses `#bd-vp` (no `tabindex`: focus drops to `<body>`); C9-T03's live path reads `ctx.content.classList` with `ctx.content === null` (page error) |
| B4 `load earlier day` | `live`; wait for `#build-root[data-bd-paging="idle"]`; wrap `ctx.push` through `state.js` to count `load-earlier`; scroll to bottom; `earlier?delay=500`; click twice | exactly one `load-earlier` push; button `disabled` + `aria-busy` while in flight; after reply History count grows and `scrollTop` unchanged ±1; with `earlier?fail=1` the head ends `earlier days could not load` and one more click sends one request | the call to `loadEarlier`, the in-flight guard, or `retryArmed = true` removed |
| B5 `unavailable is not empty` | `list-edges`, then `noqueue` | `list-edges`: `.lh[data-sec="plan"] em` = `unavailable · timed out · read 6 min ago (14:14)`, `.lh[data-sec="nq"]` present with `data-st="unavailable"`, `.lh[data-sec="hist"] em` ends `stale, read 6 min ago (14:14)`; `noqueue`: no `.lh[data-sec="plan"]` | the `sectionState` call replaced by the design's `sec()` |
| B6 `accessibility` | `live` and `list-edges`, dark; `new AxeBuilder({ page }).include('#bd-vp').analyze()`; then `emulateMedia({ forcedColors: 'active' })`, Tab to a row | `violations` = `[]`; under forced colours the focused row's computed `outline-style` is `solid` and every chip's text is non-empty | a cell role, the button wrapper (axe `aria-required-children`), or the `:focus-visible` rule removed |
| B7 `no script from data` | `list-edges` | `window.__xss` undefined; the title cell's text contains `<img src=x` literally | `esc` on the title removed |

Mutation check (AGENTS.md): for each row above, revert the named hunk in a
worktree, confirm `git status --porcelain` shows only that file, run the one
test, see it fail, restore, see it pass. Record each command in the PR body.

Commands:

```bash
env -C src/browser npm run test:build-home-list-unit
env -C src/browser npm run test:build-home-list
env -C src/browser npm run test:design-parity
```

Manual check (AGENTS.md "Manual testing" applies to the TUI chat path, which
this ticket does not touch; C12-T01 drives the full CLI). Here: open the fixture
page with `?view=list` in a browser, Tab through ten rows with a screen reader
(Orca or VoiceOver), confirm each row announces id, title and state, and Enter
opens the modal once C11-T01 is in.

## Completion and handoff

- [ ] `list.js` ports J:1152–1181 with the cell rules and section-state rules
      above; `listHTML` is pure.
- [ ] U1–U11 and B1–B7 pass, and each fails with its hunk reverted (U12 is a
      labelled guard).
- [ ] The parity cells above pass with no allowlist entry.
- [ ] `fx.renderList` and `fx.openModal` defaults exist (C9-T03); `stClass`,
      `stText` and `listHTML` are exported; `.lst.st-np` is in `home.css`
      once (added here), with C10-T02's values.
- [ ] Section heads call `sectionState`/`headNote`/`reasonText`/`ageText`;
      `list.js` has no S-9 string of its own except
      ` · earlier days could not load`.
- [ ] `list-edges` is in C3-T01's `@datasets`; `view.switch.list` has no
      `pending` flag in C1-T03's `OWNER` table.
- [ ] `list-edges` screenshots (dark, light) are attached to the PR for the
      C12-T08 sign-off package (S-9, S-13, S-17).
- **Dependents.**
  - C10-T01: the view segment switches to `list`; its list branches hide span,
    zoom and legend.
  - C10-T02: reuse `.lst.st-np` (do not redeclare it); import `match`/`colKey`
    from `match.js` and `AST` from `now-state.js`; replace
    `keep` in `list.js` with `rowOk(S, t) && match(t)` (its step 4); put
    `not_planned` in the one `tstate` (interface note 8). The list's
    `stClass`/`stText` already map `not_planned` to `st-np` "Not planned", so
    C10-T02 interface note 6's second half is done here.
  - C10-T03: `.lr.dim` parity cell with a focused feature.
  - C11-T01: implement `fx.openModal(t)`; on close, return focus to
    `[data-id="<id>"]` looked up by id (the opener element may have been
    replaced by a diff).
  - C7-T02: replace `"#" + t.num` and `"Q" + t.qpos` in `list.js` with
    `refText`/`queueText`, and `stClass`/`stText`'s plan branch for unfiled
    rows (C7-T02 already lists J:1152–1153).
  - C7-T03 (lands after this ticket, R-G12): replace the interim `—` estimate
    with `estHours`/`estLabel` from `estimate.js` (C7-T03 step 7, J:1161).
  - C12-T05: the app-wide focus and forced-colours pass keeps the list rule and
    reads the exported `stText`.
  - C12-T07: `guide/gui.md` names the list view as the keyboard and
    screen-reader view.
- **Sources.** J:9, 10, 15, 17, 19, 82–91, 301, 332–342, 550, 575–578, 584,
  593, 604–635, 643–644, 665, 695–696, 744–745, 1126, 1132–1140, 1151–1181,
  1243; C:58–59, 244–245, 726–771, 782,
  895, 968, 982, 1011, 1016, 1053, 1063, 1163, 1183; DESIGN-E8 S-9, S-12, S-13,
  S-17; plan §8 EC-03, EC-04, EC-07, EC-08, EC-19, EC-30; C9-T03 "History
  state", "`loadEarlier()` as a request", "Live mode", interface table; C9-T13
  "`sectionState`", "Header notes", handoffs; C8-T01 "Client rules" and
  interface notes 4–5; C8-T03 `fmtAge`/`fmtWhen`; C7-T04 lines 178–185; C3-T01
  "Fixture source"; C3-T02 "Ticket row"; C10-T02 steps 4 and 6; C9-T05 steps 5
  and 8; C1-T02 "Parity pair"; C1-T03 `OWNER`; C12-T05 interface note 4.

## Interface notes (mismatches with neighbour rows)

1. **C9-T03 is a blocker.** "Load earlier day" calls C9-T03's `loadEarlier()`
   (in `history.js`; it returns the in-flight promise while a page loads), reads
   `H.more`/`H.state` and sets `H.retryArmed`. Settled 2026-10-08: C9-T03 guards
   `ctx.content?.classList` in its live path (`onDataChanged`, `flushLive`), so a
   live diff or age tick in list view (`ctx.content === null`, J:1155) does not
   throw; it also keeps the `fx.renderList`/`fx.openModal` defaults. B3 fails
   without the guard.
2. **C8-T01 is a blocker.** Settled 2026-10-08: `AST`, `agentState` (with the
   `Object.hasOwn` guard), `progress` and `modelLabel` live only in
   `now-state.js`; the unknown `—` is `<span class="lr-mu">—</span>`, never
   inside the hue-60 `.lr-pg b`.
3. **Parity query.** Settled 2026-10-08: `openParityPair` takes
   `{ dataset, ticket?, query? }` and applies `query` on both sides (R-G7).
4. **`fx` defaults.** Settled 2026-10-08: C9-T03 adds `renderList` and
   `openModal` no-op defaults (R-G2).
5. **Pack ids and `stText`.** Settled 2026-10-08: pack ids are
   `pack:<pack>/<item>` (C7-T02); `data-id` lookups use whatever `id` the payload
   carries. C7-T02 lists J:1152–1153 among its call sites.
6. **Predecessors.** Settled 2026-10-08: the front matter lists C9-T01, C9-T03,
   C9-T13 and C8-T01; nothing is needed from C9-T05 (the list draws no cards).
7. **C9-T13 is a blocker.** Settled 2026-10-08: C9-T13 exports `ageText` and
   accepts `sec = "now"` (key `agents`) in `sectionState` and `headNote`; the
   list uses its S-9 copy only.
8. **`match`/`colKey` and `.lst.st-np`.** Settled 2026-10-08: `match`/`colKey`
   live only in `match.js` (created by whichever of C9-T05 / C9-T12 merges
   first); C10-T02's `filters.js` imports them and adds `rowOk`; C10-T02 does
   not redeclare `.lst.st-np` and adds `st-np` through this ticket's
   `stText`/`stClass`.
9. **Dataset list.** Settled 2026-10-08: `list-edges` is one entry in C3-T01's
   `@datasets` (`fixture_source.ex`), added in this PR (R-G1).
10. **C12-T05 needs `stText` exported** (its interface note 4). Done here:
    `stClass`, `stText` and `listHTML` are exports.

## Decisions made without the owner

1. **No row virtualisation in the list.** The design renders every loaded row
   (J:1171). History is already bounded by day paging, and plan, now and nq are
   the open work. 600 rows of seven cells is about 5,000 nodes, well inside a
   desktop budget. A windowed list would add spacer elements and break the
   sticky header's parity. `ponytail:` the limit is a phone WebView with
   several thousand open tickets; C12-T06 measures list render time on the
   `dense` dataset and a 1,000-row `nq` case and adds windowing if its budget
   fails. EC-04's "virtualised like the rest" is met by the timeline (C9-T03)
   and by day paging here.
2. **Every ticket row is a Tab stop; no arrow-key navigation.** The row asks for
   focusable rows and Enter. A roving tabindex is the better pattern for long
   tables, but it is new interaction the design does not have. C12-T05 (S-12)
   can add it.
3. **`role="table"` stays** (the design's role), not `role="grid"`. Section
   heads and the button wrapper are given `row`/`cell` roles so the table's
   required children are valid.
4. **Unknown model:** the S-13 circle in the 15 px slot, with the agent's name or
   "Model unknown". "No agent" keeps the design's `—`. The design's own code
   shows `—` for both, which conflates "no agent" with "unknown model".
5. **`not_planned` chip** (`st-np`): C10-T02's and C9-T05's values (a solid
   border mixed from `--block-line` and `--line`, muted text, a `--block` dot
   mixed with `--faint`). This is S-17's default ("`failed` swatch family in
   the muted tone"). A dashed border was rejected: in the list, dashed means
   "not run yet" (queued, held, blocked, open, C:733–736), and a closure has
   run. `closed` (another reason) gets the plain base `.lst` with "Closed".
6. **Section heads for any non-`ok` source are always shown**, with C9-T13's
   words; a section with no rows adds the cause and the age after the bare
   state word. An `ok` empty section stays hidden, as in the design (EC-03's
   "Nothing planned" is the board's marker; the list has no marker slot). A
   missing `sources` key is unavailable with "unknown cause", never `ok`.
7. **Not queued reads only `sources.open_tickets`.** C7-T04 already turns an
   unavailable queue into an unavailable `open_tickets` entry, so reading `queue` as well
   would count one cause twice.
8. **Unknown duration, estimate, wave and points render as `—`**, following
   C8-T01 (`progress`) and C7-T03 (`Q4 · W2 · —`).
9. **The list does not repeat the daemon state.** The offline banner sits above
   the toolbar in every view (C8-T03).
10. **"Live · N running" counts every now row**, paused and stuck included, as
    the design does. Changing the copy is a design change for Kevin.
11. **A click on "Load earlier day" after a failed page retries at once.** It is
    an explicit user action, so C9-T03's "leave the trigger zone" rule (which
    exists to stop a scroll loop) does not apply.
12. **Complexity is 3, not the row's 2.** The unknown-value rules, the section
    states, the focus and anchor handling and the three added blockers are more
    than a port.
13. **C9-T13 is a blocker, not a later patch.** Writing a second S-9 rule set
    now and replacing it later would ship two wordings for one state between
    the merges. C9-T12 is not on the critical path (C12-T01 waits for every
    C9 ticket), so the extra wait costs no calendar time on that path.
14. **Wrapping only non-`ok` heads.** `.lh[data-st] em { white-space: normal }`
    lets the longer unavailable text wrap at phone width without changing any
    design pixel (no design head has `data-st`).
15. **Focus fallback.** When the focused row leaves the list, focus goes to the
    row now at its index, else the last row, else `.bd-list` (`tabindex="-1"`).
    `#bd-vp` cannot take focus (no `tabindex`, J:550), and focus on `<body>`
    loses a keyboard user's place.

## Review log

Adversarial review, 2026-10-08, against design-source, the runtime tree at
`58854d4c8` and the neighbour tickets. Changes:

1. Added **C9-T13** to `blocked_by`. Its scope and handoff give the list heads
   to this ticket with its `sectionState` and copy; the draft had its own
   `secState` and different words ("cached", "checked"). Rewrote "Section heads
   and source states", U10, B5, the Non-happy rows and decisions 6 and 13.
2. Handled the C3-T02 `incomplete` source state, which the draft's `secState`
   collapsed into `ok`.
3. Not queued reads only `index`: C7-T04 folds the queue state into it. The
   draft's "C8-T04 sends `nq: []` when the queue is unavailable" had no source.
4. Added the C3-T02 hist status `closed` ("Closed", `st-closed`); the draft
   rendered a known value as "State unknown". U3 covers it.
5. Unknown progress is `<span class="lr-mu">—</span>`, not `<b>—</b>` inside
   `.lr-pg` (C8-T01 interface note 5: amber hue 60 in light theme, C:1016).
6. `.lst.st-np` now uses C10-T02/C9-T05's values (solid, not dashed) and is
   added once; recorded the duplicate-rule and `match`/`colKey` conflicts with
   C10-T02 (interface note 8).
7. Dropped the `modelLabel` step and the `fx` defaults step: C8-T01 and C9-T03
   now ship them. Updated interface notes 1, 2, 4, 5 to "resolved" where true.
8. Recorded that C9-T03's live path reads `ctx.content.classList` while
   `ctx.content` is `null` in list view (page error on every diff); step 2 adds
   the guard; B3 catches it.
9. Focus fallback: `#bd-vp` has no `tabindex` (J:550), so `vp.focus()` did
   nothing. Now: same index row, last row, then `.bd-list[tabindex=-1]`. B3's
   removal case now uses the real filter path (no fixture control removes a
   row).
10. Listener binding keyed on the element (`ctx.listVp`), so a rebuilt
    `#bd-vp` binds again; dropped the redundant `onReset`.
11. Named the `H` clash: C9-T03's history `H` vs the design's hour `H = 36e5`
    (J:10).
12. Imports corrected: `I` from `icons.js`, `colKey` from `layout.js`
    (C9-T02); `fmtT`/`fmtH` already exist once C9-T02 has merged.
13. Fixture: C3-T01's `@datasets` is fixed in code, so `list-edges` must be
    registered; removed `wave: null` (the validator rejects it); made the
    sources consistent with C7-T04 (queue and index both unavailable, rows
    `[]`).
14. Node test moved to `src/browser/scripts/` with `TZ=America/Los_Angeles`
    (as C3-T02 and C8-T01 do): the expected `Oct 7` and `14:14` depend on the
    zone, and a `tests/*.test.mjs` file is matched by Playwright's default
    `testMatch`. Gave the exact browser-spec script.
15. Parity: product side uses C1-T02's existing `productRoute`; the design
    side still needs a query option (note 3). Replaced the invented C1-T03
    `list.hover` sequence with a C1-T02 hover cell. Added the C1-T03
    `view.switch.list` `pending` flag removal, which C1-T03 assigns here.
16. Exported `stClass`/`stText`/`listHTML` (C12-T05 note 4). B4 now waits for
    an idle paging state and says how pushes are counted.

Checked and correct as written: every runtime citation
(`browser/package.json:10,37`, `liveview-smoke.spec.mjs:1,55-61`,
`units.browser.spec.mjs:213-220`, `support/visual.mjs:28`,
`build_order_graph.ex:113-130`), J:1151–1181 cell by cell, and every CSS line
in the table.
- Reconciliation 2026-10-08 (coordinator): `loadEarlier`/`H` from C9-T03 `history.js`, `icons.js` from C9-T01, `match`/`colKey` only in `match.js` (R-G9), `.lst.st-np` added here and not redeclared by C10-T02, `wave: null` valid and rendered `W?`, interim plan estimate `—` until C7-T03 (R-G12), parity via `openParityPair` `query` (R-G7), `sectionState(P, D, H, sec, list)` signature aligned with C9-T13, interface notes 1–9 settled.
- Reconciliation 2026-10-08 (coordinator, second pass): Not queued reads `sources.open_tickets` (C7-T04/C8-T04), not `sources.index`.
