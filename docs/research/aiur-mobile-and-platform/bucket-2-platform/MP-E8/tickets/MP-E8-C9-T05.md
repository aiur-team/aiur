---
ticket_id: MP-E8-C9-T05
feature_id: MP-E8
chunk_id: MP-E8-C9
bucket: 2-platform
title: Ticket cards in four tiers
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C9-T03]
complexity: 4
design_gate: DESIGN-E8
owns_edge_cases: [EC-30, EC-08]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C9-T05 — Ticket cards in four tiers

> **Wave 0b, client.** Paths are cited at `58854d4c8`. Paths marked PROPOSED do
> not exist yet. `J` = `design-source/assets/build.js`, `C` =
> `design-source/assets/build.css`. The design is the specification
> ([../claude-design-source-of-truth.md](../claude-design-source-of-truth.md)):
> port, do not redraw.

## Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history), chunk C9 (client timeline
  engine, port of `build.js`).
- **User value.** Every ticket on the board is a card that looks exactly like the
  design's card at every zoom level. It says what the ticket is (type, number,
  title, complexity), where it is (merged, running at N %, queued at Qn with its
  cues, not queued), and it never shows a made-up number. A ticket title cannot
  run script in the page.
- **Deliverables.**
  1. PROPOSED `src/priv/static/build-home/cards.js` (the file C9-T01's module
     table assigns to C9-T05): the port of `cardDetail`, `makeCard` and
     `decorate` (J:807–877) and `refreshTicket` (J:1543–1547), with the mock
     lookups removed and an explicit rendering for every unknown value. It
     replaces C9-T03's placeholder `fx.makeCard` (an empty `div.bd-card[data-id]`).
  2. A small "not in the design" block at the end of the home stylesheet
     (PROPOSED `src/priv/static/build-home/home.css`; C2-T03 creates and links
     it, C2-T04 fills it) with four rules: unknown complexity (one rule, dark and
     light selectors) and the three S-17 `not_planned` rules. The S-13
     letter-circle sizing is C9-T06's (§4.4 there), not this ticket's.
  3. One test dataset, PROPOSED `src/test/fixtures/build_home/unknowns.json`,
     registered (with C3-T02's existing `hostile.json`) in C3-T01's fixture
     dataset list; and the DOM half of C3-T02's `hostile.json` test.
  4. A browser spec, PROPOSED
     `src/browser/tests/build-home-cards.browser.spec.mjs`, and its npm script.
  5. Only if they are not in `main` at the base: PROPOSED
     `build-home/now-state.js` with C8-T01's exact code ("Client rules" there) and
     PROPOSED `build-home/match.js` with J:332–342 verbatim (the file name
     C9-T12 step 4 uses). The first ticket to land adds each file; the others
     import it.
- **Non-goals.**
  - The agent glow states, the stuck/idle animations, reduced-motion statics,
    the screen-reader agent-state label, the `agents.js` helpers and the S-13
    letter-circle CSS: C9-T06. This ticket emits the `bd-glow` span, the `ag-*`
    classes and the logo slots exactly as J:818–833 does (with the unknown
    guards below), so C9-T06 has the hooks it styles, tests and later moves into
    `agents.js` without changing the DOM.
  - Card positions, heights, recycling by uid and the ±700 px window: C9-T03.
    The density tier per row height (`L.det`): C9-T02.
  - Gantt geometry and Gantt-only card content (J:845–848 time and badges, the
    `gplan` height, "start unknown"): C9-T09. The Gantt branches stay in the
    ported function (see "Chosen design") but C9-T09 owns their tests.
  - Filter semantics (`match`, `epicOk`) and their option lists: C10-T02.
    Feature focus, ghosts, `also` and `feat-on` behaviour: C10-T03. This ticket
    ports `decorate`, which reads that state, and keeps it correct when no filter
    or feature is set.
  - The modal: C11-T01. This ticket only guarantees that every card carries the
    real ticket id and that a click reaches the modal entry point.
  - Keyboard focus on cards and the per-card screen-reader summary: C12-T05
    (EC-19). The list view (C9-T12) is the accessible view until then.

## Dependencies and blockers

- **Blocked by DESIGN-E8** (feature gate E8-D6). The S-items this ticket follows
  as written defaults, not as blockers:
  - **S-13** (unknown model logo → the `.ax-mono` letter circle sized to the
    slot). DESIGN-E8 lists C9-T06 for S-13, and C9-T06 owns its CSS (§4.4) and
    its `agents.js` helpers. But the line tier's `.bd-lg` logo and the full
    tier's `.bd-ag` slot are emitted by `makeCard`, which merges first, so the
    first card render must already handle an unknown model without throwing
    (J:828 throws on `MODELS[undefined]`). This ticket emits the S-13 markup in
    those two slots, byte-identical to C9-T06's `logoHTML`/`lineLogoHTML`
    (C9-T06 §4.1), so C9-T06's later refactor changes no DOM. Until C9-T06 lands
    the circle has the base `.ax-mono` size (18 px, C:58); that state is
    product-only and not in a parity cell. See "Interface notes".
  - **S-17** (`not_planned` look: the `failed` swatch family in the muted tone,
    label "Not planned"). C10-T02 collapses these rows by default; this ticket
    draws the card when they are shown.
- **Predecessor: MP-E8-C9-T03.** It gives this ticket:
  - the layout items `it = { t, ghost, key, y, h, sec, lanes?, gantt?, gt? }`
    (J:403, 442, 493) and the layout `L = { det, base, fs, … }` (J:416) from
    C9-T02;
  - the render loop that calls `fx.makeCard(it)` and adds `noanim` (J:671 for
    band cards, J:711 for section cards, with the two-frame removal), the uid map
    `ctx.R` of rendered section cards, and the live relayout
    (`relayout({ live: true })`, C9-T03 "dataChanged") that removes the element
    of every changed or removed id and lets `update()` rebuild it with `noanim`;
  - the module layout fixed by C9-T01: `state.js` (`S`, `ctx`, `fx`, `onReset`),
    `dom.js` (`$`, `$$`, `esc` with `'`), `clock.js` (`nowMs()`, `null` before the
    first snapshot), `life.js` (`ctx.life.every/on/frame`; rule 4: no bare
    `setInterval`), `store.js` (`acceptSnapshot`, `applyDiff`) and the identity
    rule "compare rows by `id`, never by object identity" (C9-T01 `store.js`).
  If C9-T03 or C9-T01 named these differently, this ticket uses their names and
  does not add a second copy.
- **Transitive inputs (not blockers).**
  - C3-T02: the v1 ticket row (types, enums, `null` for unknown; `end` required
    on `hist` rows; every non-null `epic` is a key of `epics`), `esc` with `'`
    added, and `hostile.json`. Its handoff says "C9-T05 adds the hostile-text DOM
    assertions" — this ticket does that.
  - C8-T01: `now-state.js` (`AST`, `agentState`, `progress`; unknown progress
    renders `—`, no `--pct`, no `--ph`, no `.bd-bar`), and the additive
    validator rules `agent.model` may be `null` and `agent.name` (string or
    `null`); there is no `agent.full` (R-G10). If `now-state.js` is not in `main`, this ticket adds it
    with C8-T01's exact code; C8-T01 then adds only its test.
  - C2-T03: `build-home/logos.js` `LOGOS` (null prototype, frozen; keys
    `claude codex deepseek kimi`, entries `{src, fill}`; any other key gives
    `undefined`).
  - C2-T04: `build-home/home.css` with C:225–316, 350–375, 430–470,
    650–658, 700–707, 860–872, 934–938 and the theme and palette overrides, in
    the design's order, with `.bd-fd` and `.bd-card.compact` deleted as dead
    rules (its §4.4).
  - C1-T02: `openParityPair`, `expectDesignParity` and the allowlist.
  - C3-T01: `GET /build-fixture/:dataset`, then `/build`; the fixed dataset list
    `@datasets` in PROPOSED `src/test/support/build_home/fixture_source.ex`.
  - C3-T02 step 7 / C9-T04 step 5: `GET /build-control/diff?name=<file>` with
    diff fixtures under `src/test/fixtures/build_home/diffs/`. C9-T04 may run
    concurrently; if `name` is not supported at the base, this ticket adds it
    exactly as C9-T04 step 5 describes, and C9-T04 reuses it.
- **Successors that read this ticket's output:** C9-T06 (agent indicators on the
  card), C9-T07 (edges between rendered cards, by `data-id`), C9-T08 (band cards),
  C9-T09 (Gantt cards), C9-T12 (list view; shares `match.js` and
  `now-state.js`), C10-T02 (filters call `decorateAll`, extend `match`), C11-T01
  (card click → modal), C11-T07 (calls `refreshTicket` after a pause/resume).
- **May run concurrently with** C9-T04 (columns; different module), C9-T10, C9-T12
  and all server chunks.

## Verified starting point (`58854d4c8`)

**Product code.** There is no home page and no card code yet. Relevant code:

- `src/lib/aiur_web/static_assets.ex:13-27` — `@revalidated_static_paths`, which
  C2-T03 extends with one `build-home` directory entry. Files added under it need
  no new registration (C2-T03's design).
- `src/priv/static/aiur-dom-svg-layout-loader.js:1-56` — the loader precedent
  C2-T03 copies: a classic script that `import()`s a module and forwards the
  LiveView hook callbacks.
- `src/priv/static/build-order-grid-hook.js:474-476` — the current Build Order
  hook's `escapeAttr` (`& " <` only). It is **not** reused: it misses `>` and `'`,
  and the design's `esc` (J:9, plus `'` from C3-T02) is the one the port keeps.
- `src/priv/static/` already has `claude-symbol.svg` and `codex-color.svg`;
  the `Plug.Static` at `src/lib/aiur_web/endpoint.ex:51-52` serves them at
  `/provider-assets`, which `LOGOS` uses.
- `src/browser/package.json:10` — the `test` chain; one script per spec
  (`:11-31`). `src/browser/tests/support/browser-helpers.mjs:12-24` `openFixture`.
  `src/test/browser/fixture_server.exs:2260-2265` — the `pipe_through(:browser)`
  scope where C3-T01 adds `/build-fixture/:dataset`.
- No browser test in `src/browser/tests` asserts script injection today
  (`grep -rn "__xss\|onerror"` finds nothing). This spec adds the first one.

**Design source** (what the port must reproduce):

- **`cardDetail(it)`** (J:807–813). For non-Gantt items it returns `L.det`. For
  Gantt items it picks from `["bar","mini","line","full"]` by height:
  `h ≥ 8.8·fs` → full, `h ≥ 2.1·fs` → line, `h ≥ 20` → mini, else bar; capped at
  `mini` with 3+ lanes and `line` with 2 lanes; never above `L.base`.
- **Tiers.** `computeLayout` only ever produces `bar`, `mini`, `line`, `full`
  (J:362, 390–391: `baseDet = "full"`). The `det === "compact"` branch in J:841
  is unreachable, and C2-T04 deletes `.bd-card.compact` (C:304–307) as dead.
- **`makeCard(it)`** (J:814–866):
  - class list: `bd-card <det> <sec>` + `failed` (status failed) + `ag-<cls>`
    (now rows, from `AST`) + `ghost` + `unsorted` (epic) + `gplan` (Gantt plan) +
    `blk` (plan with `cue.failed` or `cue.blockedChain`) + `has-ag` (agent and
    full tier); `tall` for `mini` with `h > 34` or `line` with `h > 3.2·fs`
    (J:825);
  - custom properties: `--h` = epic hue; `--ft` = feature hue (read only by the
    dead `.bd-fd`, C:238); on now rows `--pct: <pct>%` and
    `--ph: round(42 + pct·1.03)` (J:824);
  - `bar` (J:830): `glow` + `.bd-in` with `title="#N · <title>[ · <state>]"`;
  - `line` (J:831–835): `.bd-dot`, `.bd-id #N`, `.bd-title`, then for now rows
    `img.bd-lg` (logo, `alt=""`) + `.bd-bar > i[style=width:pct%]`, or for failed
    rows `.bd-lx` with the warn icon;
  - `mini` (J:836–838): `.bd-dot`, `.bd-id #N`;
  - `full` (J:840–865): `.bd-top` (`.bd-ic` type icon: bug, docs, chore, else
    `pen` in the `design` epic, else `feature`; `.bd-id`; the feature dot `fd`;
    `.bd-cx` with `--cxh` from `[145,110,80,50,25][cx-1]`, glyph `CX[cx-1]`
    `❶…❺`, title `Complexity c/5 · p pts`), `.bd-title`, a body, `.bd-status`,
    then the `.bd-ag` logo span after `.bd-in`;
  - per section (J:843–862):
    - **hist:** "Failed · closed" or "Merged", right side `fmtD(end)`
      (`Oct 6`); Gantt variants show `fmtH(end-start)` or the `.bd-time` and
      `.bd-badges` body (C9-T09);
    - **now:** `AST[state].label` and `pct%`, then `.bd-bar`;
    - **plan:** cues in this order — `promo` "promoted <age>", `held` (title =
      held text), "waits on #N" (unless `blockedChain`), "prereq chain failed"
      (inline block colours, unless `failed`), `ovr` "estimate overridden"
      (title = reason); in full tier the body is the `.bd-alert`
      "Prereq #N failed · blocks #a #b" if `failed`, else `.bd-cues`; status
      `Q<qpos> · held|prereq failed|waiting|queued` and `≈<est>h · <pts> pts`
      (override hours win);
    - **nq:** "Open · not queued" and `<pts> pts`.
- **`decorate(el)`** (J:868–876): toggles `dim` (`!match(t)`, or focus mode and
  not in the feature), `also`, `feat-on`, and sets `--fh`. `decorateAll` (J:877)
  re-runs it and redraws edges.
- **`refreshTicket(t)`** (J:1543–1547): rebuilds a band card in place with
  `noanim`. It does not refresh section cards.
- **Click** (J:632–634): the content click handler opens
  `openModal(D.byId[card.dataset.id])` (through the chain lock when one is set,
  J:633, C9-T11).
- **Raw values the design interpolates unescaped** (C3-T02 inventory): `t.num`,
  `t.pct`, `t.qpos`, `t.pts`, `est`, `c.wait`, `c.failed.by/blocks`, `c.promoted`,
  and `MODELS[...]` strings. Titles, `held` and `override.reason` go through `esc`.
- **What the design does with values this product can have unknown** (so the
  port cannot copy it as is):

  | Value `null` | Design result | Why it is wrong |
  | --- | --- | --- |
  | now `pct` | `--ph` = 42 (orange), `--pct: null%`, text `null%`, bar `<i style="width:null%">` → invalid width → full-width bar in hue 60 | an "early progress" amber and a full bar for an unknown value |
  | `cx` | `--cxh: undefined` → fallback hue 80 (C:1184), glyph text `undefined` | hue 80 is the colour of complexity 3 |
  | `pts` | `null pts` | |
  | `est` (plan) | `≈nullh` | |
  | `qpos` (unfiled pack row) | `Qnull · queued` | |
  | hist `end` | `fmtD(null)` = `Jan 1` (1970) | a plausible wrong date |
  | `agent.model` not in `MODELS`, or `null` (C8-T01) | `TypeError` at J:828 (full) or J:833 (line); the whole render stops | |
  | now `agent` `null` or `state` not in `AST` | `TypeError` on `ag.label` (J:850) | |
  | `cue.promoted` | the design's preformatted string; C3-T02 sends ms | must be turned into an age |

**CSS that must match exactly** (C2-T04 carries it; this ticket's markup must hit
it): `.bd-card` (C:227, transitions `left/width .34s cubic-bezier(.22,1,.36,1)`,
`opacity/filter .25s`; C:466 adds `top/height`), `.bd-card.noanim` (C:231,
`transition: none`), `.bd-in` (C:232, `.6em .7em`, gap `.38em`, radius `--r:.9em`,
transitions `.14s`), hover lift `translateY(-1px)` (C:233), `.bd-top`/`.bd-ic`
(1.95em square, radius .6em)/`.bd-id` (700 .78em JetBrains Mono)/`.bd-cx`
(1.05em; colour `oklch(.74 .13 var(--cxh,80))`, light `.6 .14`, C:1184–1185)/
`.bd-title` (600 .92em/1.22, 2-line clamp)/`.bd-status` (.74em mono, no wrap,
label truncates, value stays, C:869–871)/`.bd-bar` (.32em)/`.bd-q`
(600 .68em, pill)/`.bd-alert` (C:234–258); section looks C:260–277; tiers
`mini` (C:308–314, 440–444: 11px mono, 7px dot, radius 6px), `line`
(C:650–658: radius 8px, bar 2px at `bottom:3px`), `bar` (C:934–938: radius 2px,
epic hue at `/ .7`, failed `--block`), `full` (C:706–707); container tiers
`@container (max-width:150px)` (C:359–371: hides cues, time, status label, feature
dot; title 3 lines at .8em) and `(max-width:96px)` (C:372–375: hides `.bd-cx`);
progress fill and bar hues C:456–459, 967–968, 986–988, 1011–1012, 1053–1057,
1149–1153, 1161–1181 (the final rule paints running fills in one warm tone,
`oklch(.8 .06 85)` at 9 %, and only the bar keeps the `--ph` hue).

## Chosen design

### One module, the design's functions

PROPOSED `src/priv/static/build-home/cards.js` exports `cardDetail(it)`,
`makeCard(it)`, `decorate(el)`, `decorateAll()` and `refreshTicket(id)`, and
registers them with `Object.assign(fx, { makeCard, decorateAll, refreshTicket })`
(C9-T01 rules 1–2; `import "./cards.js"` in `hook.js`). The bodies are J:807–877
and J:1543–1547 with these changes only:

1. **Mock lookups out.**
   - `MODELS[key]` → `LOGOS[key]` (C2-T03), read with `Object.hasOwn` like
     C9-T06's `modelInfo`. The design's `full` strings are mock. The tooltip
     name is C8-T01's `modelLabel(t.agent)` (`agent.name`, else the brand label
     of a `LOGOS` key, J:83–86 `name`), else the model key, else "Model
     unknown". There is no `agent.full` (R-G10). The `img` `alt` is the same
     name.
   - `AST[...]` and `t.pct` are read through C8-T01's `agentState` and
     `progress` (`now-state.js`), as C8-T01 requires of this ticket.
   - The `--ft` property and the `fd` feature dot are removed (`.bd-fd` is
     `display:none !important` at C:1183 and deleted by C2-T04).
   - The unreachable `det === "compact"` branch of J:841 is removed.
2. **Numbers are checked before they reach HTML or CSS.** One helper,
   `finite(x, lo, hi)`, returns `x` when `Number.isFinite(x)` and `lo ≤ x ≤ hi`,
   else `null`. It guards the row's `num`, `pct` (0–100; then passed to
   `progress`, whose `typeof` check alone would let `NaN` through), `cx`
   (integer 1–5), `pts`, `qpos`, `est`, `override.hours`, `cue.wait`,
   `cue.failed.by` and each `cue.failed.blocks` entry, `end`, `cue.promoted`,
   and the epic `hue` (0–360). C3-T02 validates the same on the server; this is
   the client half of the trust boundary, so a bad value becomes "unknown",
   never markup.
3. **Every string goes through `esc`** from `dom.js` (C3-T02's version with
   `'`): title, `held`, `override.reason`, the model name and key, and the
   `data-id` value.
4. **Explicit unknowns** (the table below). An unknown value renders `—` (the
   board-wide unknown text: C8-T01 `progress`, C9-T12 cells, C7-T03 `Q4 · W2 ·
   —`), wrapped in `<span data-unknown="<field>" title="<what is unknown>">`, so
   tests and users can tell an unknown from an absence.
5. **`cue.promoted` is a time** (C3-T02 decision 5: ms). It renders as
   `promoted <age>`, with `age(nowMs() − promoted)`: under 1 min "just now", under
   60 min "Nm ago", under 24 h "Nh ago", else "Nd ago" (floor). `nowMs()` is
   C9-T01's `clock.js`, never `Date.now()`. A promoted time after `nowMs()` (clock
   skew) renders "just now". `nowMs()` returning `null` (before the first
   snapshot) renders `promoted —` with `title="Promotion time unknown"`. With the
   fixture (`promoted = NOW − 6 min`) this gives the design's exact "promoted 6m
   ago".
6. **Ages stay current.** On the first `makeCard` call after a mount that
   renders a promoted cue, `cards.js` registers one
   `ctx.life.every(60_000, tickAges)` (C9-T01 rule 4; a flag cleared by
   `onReset` makes it once per mount, and `ctx.life.dispose()` in `destroyed`
   clears it). `tickAges` walks the rendered cards (`ctx.R` values and
   `ctx.L.band.items[*].el`), looks up `D.byId[el.dataset.id]`, and rewrites
   only the `.bd-q.promo` span's content (`I.up + " promoted " + age`). It does
   not rebuild or move cards, so no layout or animation runs.
7. **`refreshTicket(id)` keeps the design's scope** (band cards, J:1545), with
   C9-T01's identity rule: `it.t.id === id`, and the row re-read from
   `D.byId[id]`. Changed rows from live diffs do not need it: C9-T03's
   `relayout({ live: true })` removes the element of every changed id and
   `update()` rebuilds it, and the band is rebuilt on every relayout (J:669–671).
   The remaining caller is C11-T07 (pause/resume).
8. **Gantt branches stay** (J:845–848 and the `it.gantt`/`it.gt` paths of
   `cardDetail`). They are unreachable until C9-T09 adds Gantt items, and C9-T09
   owns their tests and the unknown-start case. Keeping them avoids a second edit
   of the same function.

### Unknown and odd values (EC-08)

"Valid" means the case passes C3-T02's `Payload.validate/1` (plus C8-T01's
additive rules) and is in `unknowns.json`. "Injected" means the validator rejects
it, so the browser test puts it in page-side (Verification) to prove the client
guard.

| Input (row field) | Source | Card renders | Never renders |
| --- | --- | --- | --- |
| now, `pct: null` | valid | C8-T01 rule: no `--pct`, no `--ph` on the card; status value `—` (`data-unknown="pct"`, `title="Progress unknown"`); **no** `.bd-bar` element (full and line tier) | `0%`, the last known %, hue 42 or 60, a full-width `<i>` |
| now, `pct` `NaN`, `-1`, `101`, `"50"`, a CSS string | injected | the same as `pct: null` | clamped values, the string in a `style` |
| now, `agent: null`, or `state` `null` / not an `AST` key | valid | `agentState` → `{label: "State unknown", cls: null}` (C8-T01, C9-T06, C9-T12 words); status label "State unknown"; no `ag-*` class, no `bd-glow` span; `title` suffix ` · State unknown` | "Running", any `ag-*` look, a thrown `TypeError` |
| `agent.model` not in `LOGOS` (`muse`) | valid | S-13 markup as C9-T06 §4.1: full tier `<span class="bd-ag" title="…"><span class="ax-mono">M</span></span>` (no `fill`); line tier `<span class="bd-lg ax-mono" aria-hidden="true">M</span>` in place of `img.bd-lg`. Letter = first character of the tooltip name, upper case | another model's logo, a broken `<img>`, a thrown error |
| `agent.model: null` (C8-T01) | injected until C8-T01's validator rule lands | the same S-13 markup with letter `?` and name "Model unknown" when `agent.name` is also `null` | `undefined`, a thrown error |
| `cx: null` | valid | `.bd-cx.unk` with text `—`, no `--cxh`, `title="Complexity unknown · <pts> pts"`; colour `var(--faint)` from the new rule in both themes | the hue-80 fallback (C:1184–1185, the colour of complexity 3), `undefined` |
| `cx` `0`, `9`, `2.5` | injected | as `cx: null` | `CX[8]` = `undefined` |
| `pts: null` | valid | `— pts` with the `—` in a `data-unknown="pts"` span; the `.bd-cx` title reads `Complexity c/5 · points unknown` | `0 pts`, `null pts` |
| plan `est: null` and no valid `override.hours` (every plan row until C7-T03 wires `est`, R-G12) | valid | status value `≈— · <pts> pts`, `data-unknown="est"`, `title="Estimate unknown"`; C7-T03 later replaces this site with `estLabel` | `≈0h`, `≈nullh`, the complexity default `EST[cx-1]` (J:94) |
| hist `end: null` | injected (`end` is required on `hist` rows) | status value `—`, `data-unknown="end"`, `title="Close time unknown"` | `Jan 1`, `fmtD(start)` |
| hist `status: not_planned` | valid | S-17: class `np` (not `failed`); label "Not planned"; line tier without the `.bd-lx` warn icon | "Merged", "Failed · closed" |
| hist `status: closed` (duplicate or other reason, C8-T04 decision 6) | valid | label "Closed"; no `failed`, no `np` | "Merged", "Failed · closed" |
| hist `status` outside `done`/`failed`/`not_planned`/`closed` (`running`) | injected | label "State unknown" (cause-neutral) | "Merged" |
| unfiled pack row (`id: "pack:alpha"`, `num: null`, `qpos: null`) | valid | `.bd-id` text `—` with `title="Not filed yet"` and **no** `data-unknown` (an absence, not an unknown); status label "Planned · not filed" (the modal's words, J:1379) | `#null`, `Qnull · queued` |
| `num` not a finite number on a filed row (`"1<b>"`) | injected | `.bd-id` `#—` (`data-unknown="num"`) and `#—` in the `title` | `#null`, `#1<b>` as markup |
| plan `cue.failed.blocks: []` | valid | "Prereq #N failed" without " · blocks" | "blocks " with nothing after it |
| epic key not in `D.epics` | injected (the validator requires the key) | the Unsorted look (`unsorted` class, `--ec: var(--muted)`), one `console.warn` per key | another epic's hue, a thrown error |

### Untrusted text (EC-30)

- Title, `held`, `override.reason`, the model name and key, and `data-id` are
  escaped with `esc` before `innerHTML` or an attribute value. All attributes
  stay double-quoted.
- Numbers pass `finite()` first, so `"50%;background:url(x)"` as a `pct` can
  never reach a `style` attribute.
- The epic `hue` is set with `el.style.setProperty("--h", hue)` only when
  `finite(hue, 0, 360)` is not `null`.
- The logo `src` comes only from the frozen `LOGOS` table, never from the
  payload.

### The `noanim` first-paint rule

- Band cards keep `noanim` for their whole life (J:671).
- A new section card gets `noanim` and loses it two animation frames later
  (J:711), so it appears in place and only later moves animate.
- `refreshTicket` builds the replacement with `noanim` (J:1545).
- C9-T03 owns these call sites. This ticket keeps them intact and tests them,
  because a card that animates in from `left: 0` on first paint is the visible
  failure.

## Implementation steps

1. **Import the shared helpers; copy only what is missing.** `esc`, `$` from
   `dom.js` (C9-T01); `S`, `ctx`, `fx`, `onReset` from `state.js`; `nowMs` from
   `clock.js`; `fmtD`, `fmtT`, `fmtH`, `dayKey` from C9-T02's `util.js`
   (C9-T02 "Predecessor"); the icon table `I` from C9-T01's `icons.js`; `LOGOS`
   from `logos.js`; `agentState`, `progress`, `modelLabel` from `now-state.js` (C8-T01; add the file with
   C8-T01's exact code if it is not in `main`); `colKey`, `match` from
   `match.js` (step 5). Copy into `cards.js` only `CX` (J:92) and the cx hue list
   `[145, 110, 80, 50, 25]` (J:841). Do not re-type SVG paths.
2. **Add `finite()`, `age()` and the unknown helper** `unk(field, title, text =
   "—")` → `<span data-unknown="<field>" title="<esc(title)>">—</span>`.
3. **Port `cardDetail`** verbatim.
4. **Port `makeCard`** with the changes in "Chosen design" and the unknown table.
   Pseudocode for the parts that change:

   ```js
   const ag  = t.sec === "now" ? agentState(t.agent && t.agent.state) : null   // {label, cls|null}
   const pg  = t.sec === "now" ? progress(finite(t.pct, 0, 100)) : null        // C8-T01
   const key = colKey(t), e = D.epics[key] || unsortedEpic(key)                // warns once per key
   const hue = finite(e.hue, 0, 360); if (hue != null) el.style.setProperty("--h", hue)
   if (pg && pg.known) { const p = finite(t.pct, 0, 100); el.style.setProperty("--pct", p + "%"); el.style.setProperty("--ph", Math.round(42 + p * 1.03)) }
   const pctTxt = !pg ? "" : pg.known ? pg.text : unk("pct", "Progress unknown")
   const bar    = pg && pg.known ? '<span class="bd-bar"><i style="width:' + finite(t.pct, 0, 100) + '%"></i></span>' : ""
   const agCls  = ag && ag.cls ? " ag-" + ag.cls : ""                         // no class for "State unknown"
   const glow   = ag && ag.cls ? '<span class="bd-glow"></span>' : ""
   const m      = t.agent ? modelOf(t.agent) : null   // {logo: LOGOS entry|null, name, tip, mono}
   ```

   `modelOf` follows "Chosen design" 1 and returns the same `logo`/`mono`
   values as C9-T06's `modelInfo`. The full-tier slot is
   `'<span class="bd-ag' + (m.logo && m.logo.fill ? " fill" : "") + '" title="' + esc(m.tip + (ag ? " · " + ag.label : "")) + '">' + (m.logo ? '<img src="' + esc(m.logo.src) + '" alt="' + esc(m.name) + '">' : '<span class="ax-mono">' + esc(m.mono) + "</span>") + "</span>"`.
   Keep the class order, the attribute order and the whitespace of J:818–862,
   so the DOM that C2-T04 snapshots is the same.
5. **Port `decorate` and `decorateAll`** verbatim, except that `decorate` skips
   `--fh` when `D.features[F]` is missing and returns early when
   `D.byId[el.dataset.id]` is missing (a removed row whose element has not been
   recycled yet). They read `match`, `S.feature` and `S.fmode`. With no filter
   set, the design's `match` (J:335–342) returns `true`. If neither
   `match.js` (C9-T12) nor C10-T02's `filters.js` exports `match` at the base,
   add PROPOSED `build-home/match.js` with `colKey`, `tstate`, `astate` and
   `match` (J:332–342) verbatim, so C9-T12 and C10-T02 extend one function.
   Guard `astate` (J:334) for a now row with `agent: null` (returns `"none"`).
6. **Port `refreshTicket(id)`** (Chosen design 7) and register it in `fx`. Add
   the age tick (Chosen design 6) through `ctx.life.every`, with the once-per-
   mount flag reset in `onReset`.
7. **Wire the call site.** `Object.assign(fx, { makeCard, decorateAll,
   refreshTicket })` replaces C9-T03's placeholder; `import "./cards.js"` in
   `hook.js`. A card click calls `fx.openModal(row, {origin: card})` (no-op
   default per R-G2 until C11-T01). Leave C9-T03's `noanim` handling as it is.
8. **CSS block** at the end of `build-home/home.css`, under the comment
   `/* MP-E8 additions: states the design does not show (C9-T05; S-17, EC-08) */`:

   ```css
   .bd-cx.unk, html[data-theme="light"] .bd-cx.unk { color: var(--faint) !important; }
   .bd-card.np .bd-in { border-color: color-mix(in srgb, var(--block-line) 45%, var(--line)); }
   .bd-card.np .bd-status { color: var(--muted); }
   .bd-card.bar.np .bd-in { background: color-mix(in srgb, var(--block) 35%, var(--faint)); }
   ```

   The light selector is needed because `html[data-theme="light"] .bd-cx`
   (C:1185, `!important`, specificity 0,2,1) beats `.bd-cx.unk` (0,2,0). The
   S-13 letter-circle sizes are C9-T06 §4.4. Nothing else in the sheet changes.
   C2-T04's "dead classes are absent" test (T-3) is unaffected: no class here is
   in its §4.4 list.
9. **Fixtures.**
   - Add `src/test/fixtures/build_home/unknowns.json`: the `live` fixture (same
     `{meta, data, daemon}` shape, same frozen `now`) plus one row per "valid"
     line of the unknown table, with fixed ids `9001`… (`pack:alpha` for the
     pack row). Record the `jq` command that made it in the spec header, as
     C9-T06 step 5 does. Every row must pass `Payload.validate/1`; the "injected"
     lines are not in the file.
   - Add `unknowns` and `hostile` to `@datasets` in C3-T01's
     `fixture_source.ex`, so `/build-fixture/unknowns` and
     `/build-fixture/hostile` answer 302 to `/build`, and extend C3-T01's F1
     case (`test/aiur_web/build/fixture_source_test.exs`) to load both names
     with the frozen `now`. (`hostile.json` exists
     from C3-T02 but no ticket registers it; C10-T02, C10-T03 and C10-T04 reuse
     it after this ticket.)
   - Add `unknowns.json` to C3-T02's "fixtures validate" ExUnit case
     (`src/test/aiur_web/build/payload_test.exs`), which today lists the five
     fixtures and `hostile.json`.
   - Diff fixtures under `src/test/fixtures/build_home/diffs/`:
     `card-pct-null.json` (upsert row 9002 with `pct: null`) and
     `card-clock-3h.json` (no upsert, `now = NOW + 3 h`), sent with
     `/build-control/diff?name=<file>` (add `name` if C9-T04 has not).
10. **Browser spec and script.** `src/browser/tests/build-home-cards.browser.spec.mjs`
    and `"test:build-home-cards": "node scripts/run-browser-tests.mjs tests/build-home-cards.browser.spec.mjs"`,
    added to the `test` chain in `src/browser/package.json:10`. The spec sets
    Playwright `timezoneId: "America/Los_Angeles"` (the fixtures' `tz`), because
    `fmtD` uses local time.

## Non-happy paths

- **Hostile text (EC-30):** covered by the `hostile.json` DOM test. A title of
  `<img src=x onerror="window.__xss=1">'"&` renders as literal text in `.bd-title`
  and appears literally inside every `title` attribute that carries it (the bar,
  mini and line `.bd-in` titles are `#N · <title>[ · <state>]`).
- **Hostile numbers:** a `pct` of `"50"`, `NaN`, `-1`, `101` or a CSS string is
  shown as unknown. It is never clamped, because clamping would invent a value.
- **Unknown model, unknown state, missing agent:** never throw. One throwing card
  would stop the whole render loop (the design's `forEach` has no guard), so the
  test asserts that every other card in the dataset still renders.
- **Missing epic or feature key** (a payload that references a key the `epics`
  or `features` map lacks): the card renders with the Unsorted look; `decorate`
  skips `--fh` when `D.features[F]` is missing.
- **Live diffs:** a diff that makes `pct` unknown after a known value must clear
  `--pct`, `--ph` and the `.bd-bar` (the "last known value" mutation). C9-T03's
  live relayout rebuilds the card through `makeCard` from the current row, and
  `makeCard` reads nothing from an old element, so nothing from the old card is
  kept. The rebuilt card gets `noanim` for that pass (C9-T03).
- **Stale data:** when C8-T03 sets `.bd-root.stale`, cards keep their values and
  the stale styling comes from CSS (C:299–301, 392; C9-T13). Cards do not hide values.
- **Clock skew:** promoted after `nowMs()` → "just now". `now` missing from a
  snapshot is rejected by `acceptSnapshot` (C9-T01); `nowMs()` is `null` only
  before the first snapshot, and then the age renders `—` (Chosen design 5).
- **Destroyed hook and remount:** `ctx.life.dispose()` clears the age tick;
  `onReset` clears the once-per-mount flag, so a LiveView navigation away and
  back (ES modules are cached, C9-T01 rule 3) registers exactly one new tick.
  `refreshTicket` with no layout (`!ctx.L`) is a no-op (J:1544).
- **Removed row with a live element:** `decorate` returns early when
  `D.byId[id]` is missing, instead of the design's `TypeError` on `t.feature`.
- **Read-only dashboards, auth, financial data:** cards carry no write action and
  no usage data. Not applicable.

## Compatibility and rollout

- No config key, CLI flag or environment variable. No user-facing docs: the home
  page's docs ship with C12-T01 (cutover). This ticket changes no documented
  behaviour.
- The page is the temporary `/build` route (C3-T01) until C12-T01. Rollback:
  revert the PR; C9-T03's placeholder renderer comes back.
- The CSS additions only match classes the design never emits (`unk`, `np`), so
  they cannot change a design-parity cell.
- Order with neighbours: C9-T06 later moves the agent expressions into
  `agents.js` and adds the S-13 CSS; C9-T12 and C10-T02 import `match.js`. None
  of them changes the DOM this ticket emits.

## Pixel parity

- **Design elements:** `.bd-card` in the tiers `full`, `line`, `mini` and `bar`
  for each of `hist`, `hist.failed`, `now` (each `AST` state), `plan` (each cue,
  `blk`, the `.bd-alert`), `nq`, `unsorted`; inside them `.bd-in`, `.bd-top`,
  `.bd-ic`, `.bd-id`, `.bd-title`, `.bd-cx`, `.bd-status`, `.bd-bar`, `.bd-cues`,
  `.bd-q` (`promo`, `held`, `ovr`), `.bd-alert`, `.bd-dot`, `.bd-lg`, `.bd-lx`;
  the container tiers at 150 and 96 px.
- **How it is checked** (C1-T02 harness, `openParityPair` +
  `expectDesignParity`):
  1. **Whole-viewport cells** for `live`, `dense`, `newrepo` and `noqueue` at
     `?span=1`, `7`, `21` and `30`, at 1440 and 390 px, dark and light, both
     palettes. Each cell first asserts which tiers it contains
     (`.bd-card.full|line|mini|bar` counts > 0 on both sides, equal counts per
     tier), so a passing cell proves the tiers it names. The implementer records
     the span → tier table in the spec. Expected: `span=1` full; the others line,
     mini and bar on `dense`; if a tier is unreachable through span on these
     datasets, the spec says so and uses the C1-T02 element mode on a reachable
     cell instead of skipping it.
  2. **Region `.bd-now`** (unique on both sides) for full-tier now cards with all
     six `AST` states (`live`).
  3. **Container tiers:** at 390 px, assert that at least one rendered card is
     ≤ 150 px wide and one ≤ 96 px wide (measured `getBoundingClientRect`) in
     the cells used, so the `@container` rules are exercised by the diff.
  4. **Zero difference** outside C1-T02's allowlist. This ticket adds no
     allowlist entry. A difference is a failing test unless Kevin approves it in
     writing.
- **Not compared with the design** (the design has no such state): the
  `unknowns` dataset, the S-13 markup and S-17. They are captured by C1-T02's report mode
  as product-only screenshots and go into the C12-T08 sign-off package, where
  Kevin approves or replaces the defaults.
- **Computed style:** C2-T04's computed-style snapshot covers the card elements
  in the design datasets; this ticket must keep it green (same DOM, same classes).

## Verification

Browser spec `src/browser/tests/build-home-cards.browser.spec.mjs` (fixture
server; `GET /build-fixture/<dataset>`, then `/build`; `timezoneId:
"America/Los_Angeles"`). Every test also asserts that no `pageerror` fired.

**Injection** (for the "injected" rows of the unknown table, which the server
validator rejects): `page.evaluate` imports `/build-home/store.js` and
`/build-home/state.js`, calls `acceptSnapshot` with a copy of the current
`ctx.snap` in which the named rows were changed, then `fx.relayout()`.
`acceptSnapshot` checks only `now` (C9-T01), so the bad values reach `intake`
and the cards, which is the path a broken producer would take.

| Test | Input | Expected | Fails without (mutation) |
| --- | --- | --- | --- |
| tiers render | `dense` at `?span=1,7,21,30` | each tier class present; `full` cards have `.bd-top`, `.bd-title`, `.bd-status`; `mini` only `.bd-dot`+`.bd-id`; `bar` an empty `.bd-in` with `title` | replace `cardDetail` with `() => "full"` |
| section content | `live`, one card per section | hist: "Merged" + `Oct 6`-style date; failed: "Failed · closed"; now: AST label + `N%`; plan: `Q<n> · queued`, `≈— · <pts> pts` (no `est` until C7-T03, R-G12); nq: "Open · not queued" | remove the per-section branch |
| cues | `live` plan rows `p1`, `p4` and the design's wait, chain, failed and override rows | "promoted 6m ago"; `held` title = held text; "waits on #N"; "prereq chain failed"; `.bd-alert` "Prereq #N failed · blocks #a #b"; `ovr` title = reason | drop any one cue (one assertion each) |
| promoted age from the payload clock | `live` (`promoted = NOW − 6 min`); then `/build-control/diff?name=card-clock-3h` | "promoted 6m ago", then "promoted 3h ago" | `Date.now()` instead of `nowMs()` (the fixture clock is frozen at 2026-10-07 14:20, so the wall clock gives days) |
| ages stay current | `live` with Playwright `page.clock` installed; advance 60 s with no diff | "promoted 6m ago" becomes "promoted 7m ago"; the card element is the same node (no rebuild) | remove the `ctx.life.every` registration |
| one age tick after remount | `live`; navigate to `/` and back to `/build` (LiveView navigation); advance 60 s | "promoted 6m ago" becomes "promoted 7m ago" after the remount | drop the `onReset` flag clear (the flag stays set from the first mount, so no tick is registered and the text stays "6m ago") |
| unknown pct | `unknowns` row 9001 (`pct: null`) | no `--pct`/`--ph` inline; status value `—` with `data-unknown="pct"`; no `.bd-bar` in the card | `progress(t.pct ?? 0)` → `0%`; the design's `t.pct + "%"` → `null%` and a full-width bar |
| unknown pct after a known one | `unknowns`, then `diff?name=card-pct-null` (9002 `pct 40 → null`) | card shows `—`, no `.bd-bar`, no `--ph`; never `40%` | `makeCard` that keeps the old `--pct`/`--ph` when the new value is unknown (copying them from the replaced element) |
| hostile pct | injected 9001 with `pct` `"50"`, `NaN`, `-1`, `101` (one case each) | as "unknown pct"; no `NaN%`, no `-1%` | pass `t.pct` to `progress` without `finite()` (`NaN` and `-1` are numbers) |
| unknown cx | 9003 (`cx: null`), dark and light | `.bd-cx.unk` text `—`; computed `color` equals the computed `--faint` in both themes; no `--cxh` | omit the `.unk` rule (hue-80 fallback); drop its light selector (light case fails) |
| unknown pts / est | 9004 (`pts: null`), 9005 (`est: null`) | `— pts` with `data-unknown="pts"`; `≈— · 2 pts` with `data-unknown="est"` | replace the branch with `0`, or with the EST default `[1,2,4,7,11][cx-1]` |
| unknown end | injected hist row with `end: null` | status value `—` with `data-unknown="end"`; no `Jan 1` | `fmtD(t.end)` (gives `Dec 31`/`Jan 1`); `fmtD(t.start)` |
| unknown model | 9007 (`model: "muse"`), full and line tiers | full: `.bd-ag > .ax-mono` text "M", no `img`, no `fill`; line: `.bd-lg.ax-mono` "M"; no `img.bd-lg` | `LOGOS[k] \|\| LOGOS.claude`; the design's `MODELS[k].logo` (throws, `pageerror`) |
| model null | injected now row `agent: {model: null, name: null, state: "active"}` | `.ax-mono` text `?`; `.bd-ag` title starts "Model unknown" | `k[0].toUpperCase()` on the key (throws) |
| unknown state / no agent | 9008 (`state: null`), 9009 (`agent: null`) on now | status label "State unknown"; no `ag-*` class, no `.bd-glow`; every other card still renders (`.bd-card` count equals the dataset's rendered rows) | `agentState` replaced by `AST[s] \|\| AST.active` |
| not planned | 9010 (`status: not_planned`), full and line tiers | class `np`, not `failed`; "Not planned"; line tier without `.bd-lx` | render as `failed` |
| closed | 9011 (`status: closed`) | "Closed"; no `failed`, no `np` | the design's `failed ? … : "Merged"` |
| hist status outside the enum | injected hist row `status: "running"` | "State unknown" | the design's `"Merged"` default |
| pack row | `pack:alpha` (`num: null`, `qpos: null`) | `.bd-id` `—` with title "Not filed yet" and no `data-unknown`; "Planned · not filed"; no `#null`/`Qnull` | the design's `"#" + t.num` and `"Q" + t.qpos` |
| empty blocks | 9012 (`failed: {by: 7, blocks: []}`) | `.bd-alert` text "Prereq #7 failed" exactly | the design's `" · blocks " + join` |
| missing epic key | injected row `epic: "ghost-epic"` | `unsorted` class; exactly one `console.warn` for two such rows | `D.epics[k].hue` (throws) |
| hostile numbers | injected row: `pct: "50%;background:red"`, `cx: 9`, `num: "1<b>"`, epic `hue: "1);x"` | `—` for pct, `.bd-cx.unk`, `.bd-id` `#—`; no element's `style` attribute contains `background:red` or `1);x`; no `b` element inside `.bd-id` | remove `finite()` |
| hostile text (C3-T02 handoff) | `/build-fixture/hostile` | `window.__xss === undefined` (also after hovering a card); no `img[src="x"]` in the board; `.bd-title` `textContent` equals the raw title; each bar/mini/line `.bd-in` `title` contains the raw title; `held` and `ovr` titles equal the raw `held`/`reason` | replace `esc(t.title)` with `t.title`; replace `esc(c.held)` with `c.held` |
| noanim | `live`, new section card after a `?span` change; band card | section card has `noanim` in frame 0 and not after 2 frames; band card keeps it | remove the two-frame removal, or add `noanim` removal to band cards |
| click → modal | click a full card in `live` with a spy on `fx.openModal` | the spy is called as `fx.openModal(row, {origin})`: `row.id` equals the card's `data-id` and `origin` is the clicked card | set `data-id` to `"#" + num` |
| decorate with no filter | `live`, no URL filters | no card has `dim`, `also` or `feat-on` | `match` returning `false` |
| refreshTicket | `live`; `page.evaluate` changes `D.byId[<band id>].pct` and calls `fx.refreshTicket(id)` | the band card is a new node with the new `N%` and `noanim`, at the same `left`/`top` | the design's `it.t === t` identity test (rows are new objects, so nothing refreshes) |

The pixel-parity cells in "Pixel parity" run in the same spec file in a
`describe('parity')` block.

Commands:

```bash
env -C src/browser npm run fixture:preflight
env -C src/browser npm run test:build-home-cards
env -C src/browser npm run test:design-parity
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur_web/build/payload_test.exs test/aiur_web/build/fixture_source_test.exs
# payload_test: the "fixtures validate" case now includes unknowns.json
# fixture_source_test: unknowns and hostile are accepted dataset names
```

Mutation check (AGENTS.md): for each row with a mutation, apply it in a worktree,
check that `git status --porcelain` shows only that hunk, run the test, see it
fail, restore, see it pass. Record the exact commands in the PR body, one line
per test.

Manual check (not a substitute for the above): open `/build` on the fixture
server at 1440 and 390 px, zoom through every span, and compare with the design
side by side.

## Completion and handoff

- [ ] `build-home/cards.js` with `cardDetail`, `makeCard`, `decorate`,
      `decorateAll`, `refreshTicket`, `finite`, `age`; registered in `fx`; the
      placeholder from C9-T03 replaced.
- [ ] `now-state.js` and `match.js` imported, or added verbatim when missing.
- [ ] Every row of the unknown table renders as specified; no `null`, `NaN`,
      `undefined`, `Jan 1` or hue-42/60/80 fallback reaches the page.
- [ ] The CSS block (four rules) at the end of `home.css`, with its
      comment.
- [ ] `unknowns.json` added and valid under `Payload.validate/1` (added to the
      "fixtures validate" case); `unknowns` and `hostile` in C3-T01's
      `@datasets`; the two diff fixtures added.
- [ ] The hostile-text DOM assertions from C3-T02's handoff pass.
- [ ] The parity cells pass with zero difference and no new allowlist entry.
- [ ] Every listed mutation makes its test fail; commands in the PR body.
- [ ] Product-only screenshots of the `unknowns` cards (S-13 markup, S-17,
      EC-08) are attached to the PR for the C12-T08 sign-off package.
- **Dependents:** C9-T06 moves the agent expressions into `agents.js`, styles
  the `ag-*` classes, the `bd-glow` span and the logo slots, and adds the S-13
  CSS; C9-T07 draws edges between cards by `data-id`; C9-T08 uses band cards;
  C9-T09 tests the Gantt branches; C9-T12 shares `match.js` and `now-state.js`;
  C10-T02 calls `decorateAll` after filter changes and extends `match`;
  C11-T01 opens the modal from a card click; C11-T07 calls `refreshTicket`;
  C12-T05 adds focus and the per-card summary.
- **Docs:** none (internal until C12-T01).
- **Sources:** `tickets/README.md` row C9-T05; `chunks.md` C9; `plan.md` §5, §8
  (EC-08, EC-30), §10 items 7, 19, 26; DESIGN-E8 S-13, S-17; C3-T02 (row schema,
  `esc`, `hostile.json`, extension table); C8-T01 ("Client rules",
  `now-state.js`, `agent.name`, `modelLabel`); C9-T01 (module table, `clock.js`,
  `life.js`, identity rule); C9-T03 (`fx.makeCard` placeholder, live
  relayout); C9-T06 (§4.1, §4.4); C9-T12 (cell rules, `match.js`,
  `LABELS`); C2-T03 (`LOGOS`); C2-T04 (§4.4 dead rules);
  C1-T02 (harness); C3-T01 (fixture switch, `@datasets`); J and C lines cited
  above.

## Interface notes (for the coordinator)

1. **Model display name.** Settled 2026-10-08: payload `agent.name` only, read
   through C8-T01's `modelLabel`; there is no `agent.full` (R-G10).
2. **S-13 owner.** Settled 2026-10-08: this ticket emits the S-13 markup
   (identical to C9-T06 §4.1); the S-13 sizes are C9-T06's (its §4.4), with the
   accessible label, the glow states and their parity checks.
3. **`AST`/`agentState` copies.** Settled 2026-10-08: they live only in C8-T01's
   `now-state.js` (R-G9); this ticket and C9-T06 import them.
4. **`match` location.** Settled 2026-10-08: `match`/`colKey` live only in
   `build-home/match.js`, created by whichever of C9-T05 / C9-T12 merges first;
   C10-T02's `filters.js` imports them and adds `rowOk` (R-G9).
5. **`refreshTicket` scope.** The design refreshes band cards only, and so does
   this port. Changed section cards are rebuilt by C9-T03's live relayout; no
   diff path calls `refreshTicket`.
6. **`closed` status.** Settled 2026-10-08: `closed` reads "Closed" everywhere,
   including C9-T12 (R-G11).
7. **Estimate precision.** Settled 2026-10-08: C7-T03 rounds estimates to 0.25 h
   and replaces this ticket's interim estimate site with `estLabel` (R-G12).
8. **Unfiled pack rows** (C7-T02) have `num: null` and `qpos: null` in C3-T02.
   The design never draws such a card (its `fromDoc` items keep a number), so the
   card text here is a new default.
9. **`hostile` dataset.** No ticket registered `hostile.json` as a fixture
   dataset; this ticket does, and C10-T02, C10-T03 and C10-T04 can load it with
   `/build-fixture/hostile`.

## Decisions made without the owner

1. **`—` is the unknown text on cards** (pct, pts, est, end, num, cx), with a
   `data-unknown` attribute and a `title` naming what is unknown. It is the
   board-wide convention (C8-T01 `progress`, C9-T12, C7-T03). The pack row's `—`
   is an absence and carries no `data-unknown`, so tests can tell the two apart.
   Because `—` is the chosen output, the AGENTS.md "replace with `—`" mutation is
   replaced by the `0`, last-value and design-default mutations in the table.
2. **Unknown `pct` shows no bar** (C8-T01's rule). The card loses the 0.32em
   bar, and the status line still shows `—`, so the row reads as "progress
   unknown", not "0 %".
3. **Out-of-range numbers are unknown, not clamped.**
4. **S-17 `not_planned`** uses a new `np` class, not `failed`, so failure styling,
   edges (`bad`) and the "failed" filter do not count these closures as failures.
   Its look is the default in DESIGN-E8: a muted mix of the failed border, muted
   status text and a muted bar. In the light theme the bar tier's
   `html[data-theme="light"] .bd-card.bar .bd-in` (C:978) beats the `np` bar
   rule, exactly as it beats the design's own `.bd-card.bar.failed` rule
   (C:937); the port keeps that cascade and does not raise the `np` specificity.
5. **Unknown complexity** gets one new rule (`--faint`, both themes) instead of
   the fallback hue 80, which is the colour of complexity 3.
6. **Promoted ages** use a minute-precision format matching the design's "6m
   ago" and update once a minute in place, because a computed age must be
   rendered and must not go stale (AGENTS.md).
7. **`closed` hist rows read "Closed"**, a cause-neutral label for a known
   status (AGENTS.md "collapsed cause" rule); not "Merged", not "State unknown".
8. **The Gantt branches of `makeCard` are ported but not tested here**; C9-T09
   owns them.
9. **The dead `compact` tier branch is removed,** matching C2-T04's dead-rule
   deletion.
10. **The epic icon rule stays the design's** (`pen` for features in an epic
    whose key is `design`). Real epic keys come from config (C5-T01); an epic
    named differently gets the `feature` icon, as in the design.
11. **Cards are not focusable in this ticket.** Keyboard access is C12-T05, and
    the list view (C9-T12) is the accessible view until then. Adding `tabindex`
    here would add focus rings the design has no style for (S-12).
12. **The full-tier logo keeps the design's `alt` (the model name).** C9-T06 D-4
    later sets `alt=""` and `aria-hidden` together with its screen-reader text;
    doing half of that here would leave the logo unnamed with no replacement.

## Review log

Adversarial review, 2026-10-08 (sources: design-source J/C, runtime `58854d4c8`,
README, chunks, C2-T03, C2-T04, C3-T01, C3-T02, C8-T01, C9-T01, C9-T02, C9-T03,
C9-T04, C9-T06, C9-T08, C9-T12, C10-T02, C11-T07). Changes:

1. Unknown `pct` now follows C8-T01's binding rule (`progress`, `—`, no
   `.bd-bar`) instead of `?%` with an empty track; README row requires it.
2. Unknown marker changed from `?` to `—` for board-wide consistency (C8-T01,
   C9-T12, C7-T03); `data-unknown` kept as the test hook; decision 1 rewritten.
3. Unknown state label "Agent state unknown" → "State unknown" (C8-T01, C9-T06,
   C9-T12 agree).
4. Removed the S-13 `.ax-mono` CSS: it duplicated C9-T06 §4.4 with different
   sizes, and its em math was wrong (`width: 1.15em` with `font-size: .62em`
   resolves to 0.71em of the slot). Markup aligned byte for byte with C9-T06.
5. Added the light-theme selector to `.bd-cx.unk`: C:1185 (0,2,1, `!important`)
   would otherwise win and show hue 80; added a light-theme test case.
6. Stylesheet path `home.css` → `build-home.css` (C2-T04 note 8).
7. `refreshTicket` back to the design's band-only scope with the id identity
   rule; the claim that C9-T01's diff applier calls it was false (C9-T03's live
   relayout rebuilds changed cards).
8. Age interval moved onto `ctx.life.every` (C9-T01 rule 4 and its S2 scan
   forbid bare `setInterval`), updates text in place, once per mount via
   `onReset`; `now` → `now()` with its `null` case. Replaced the vacuous
   `clearInterval` spy test with "ages stay current" and "one tick after
   remount" tests.
9. Fixture validity: hist `end: null` and a missing epic key fail C3-T02's
   validator, so they moved from `unknowns.json` to page-side injection; added
   `unknowns.json` to the "fixtures validate" case; registered `unknowns` and
   `hostile` in `@datasets` (hostile was never registered); named diff
   fixtures via `?name=` (C9-T04 step 5) for the two diff tests.
10. Added the `closed` status (valid in C3-T02) as "Closed"; it had fallen into
    "State unknown".
11. Added `agent.model: null` and `agent.name`/`full` (C8-T01); rewrote
    interface note 1, which said the payload has no name.
12. Helper `num()` renamed `finite()` (it clashed with the row field `num`); it
    now also guards `end`, `cue.promoted` and runs before `progress` (whose
    `typeof` check passes `NaN`).
13. Corrected citations: click handler J:632–634 (not 628–635); icon table
    J:31–73 with `sv` (not 33–74); `static_assets.ex:13-27`; `endpoint.ex:51-52`.
    Helpers now imported from `dom.js`/`util.js`/`clock.js` instead of copied.
14. `match` goes to `match.js` (C9-T12's name), not "the shared state module";
    `decorate` guards a missing row and a missing feature.
15. Hostile-text test: `title` attributes contain the raw title (they are
    `#N · <title>`), not equal to it; added `held`/`reason` assertions.
16. Added a `refreshTicket` test (identity mutation), hostile-pct cases for
    `NaN`/`-1`, model-null, closed and status-outside-enum rows; Playwright
    `timezoneId` for `fmtD`.
17. Interface notes 3, 4, 6, 9 added (duplicate `AST`, `match` location,
    `closed` wording, `hostile` dataset); dependents and sources updated.
- Reconciliation 2026-10-08 (coordinator): stylesheet `home.css` (R-G8), clock `nowMs()` (R-G9), `agent.full` removed and `modelLabel` used (R-G10), `I` from `icons.js`, interim `≈—` estimate until C7-T03 (R-G12), click calls `fx.openModal(row, {origin})`, interface notes 1-4, 6, 7 settled.
