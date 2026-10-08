---
ticket_id: MP-E8-C9-T06
feature_id: MP-E8
chunk_id: MP-E8-C9
bucket: 2-platform
title: Agent indicators (logo, glow, stuck, idle)
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C9-T05, MP-E8-C8-T01]
complexity: 2
design_gate: DESIGN-E8
owns_edge_cases: [EC-19]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C9-T06 — Agent indicators (logo, glow, stuck, idle)

> **The design is the specification** ([../claude-design-source-of-truth.md](../claude-design-source-of-truth.md)).
> This ticket ports the design's agent indicators as they are. It changes no
> pixel of the design. It adds only things that have no pixels (screen-reader
> text, `aria-hidden`, true tooltip names) and corrects the size of the S-13
> letter circle that C9-T05 adds for models the design does not have.

## 1. Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history home page), chunk C9 (client
  timeline engine), ticket T06.
- **User value.** On the board, the operator sees at a glance which tickets have
  an agent, which model it is, and whether that agent is running, stuck, or
  paused or parked (E8-D12). A screen-reader user hears the same state. A model or
  state that Aiur cannot name is shown as unknown, never as another model or as
  "Running". The logo tooltip names the real model, not the design's mock string.
- **Deliverable.**
  1. One client module, PROPOSED `src/priv/static/build-home/agents.js` (listed
     for C9-T06 in C9-T01's module table). It takes over the agent parts of
     C9-T05's `makeCard` port (design J:818, 820–821, 826–828, 830, 832–833,
     837, 850, 864): the `ag-*` class, `has-ag`, the `span.bd-glow`, the
     `span.bd-ag` logo (with `.fill`) on full cards, the `img.bd-lg` logo on line
     cards, and the state label. It imports `AST`, `UNKNOWN_STATE`,
     `agentState(state)` and `modelLabel` from C8-T01's `now-state.js` (R-G9);
     it neither declares nor re-exports them.
  2. Screen-reader text for the agent state on every tier (EC-19, S-4 default),
     with `aria-hidden="true"` on the logo slots.
  3. Logo `title` from the payload's `agent.name` through C8-T01's
     `modelLabel(t.agent)` (with the design brand name as its fallback), then the
     raw key. There is no `agent.full` (R-G10).
  4. The two S-13 letter-circle sizing rules (§4.4), in C9-T05's "MP-E8
     additions" block. No new S-13 behaviour: C9-T05 already draws the letter
     circle and the unknown state (its "Unknown and odd values" table).
- **Non-goals.**
  - No CSS for the indicators themselves. The design's rules (C:226, 231, 240,
    246, 280–299, 312–314, 348, 370, 395–403, 457–463, 655, 704–705, 816–817,
    969–974, 1161–1181) arrive verbatim in C2-T04's consolidated sheet. This
    ticket proves they render; it does not copy or edit them.
  - No band header counts or `astate` filter buttons (C9-T08, C10-T02). They
    read C8-T01's `AST` table from `now-state.js`.
  - No `.bd-root.stale` styling (C9-T13), no forced-colours fallback for glows
    (C12-T05, S-12), no list-view `stClass`/`stText` (C9-T12), no tree nodes
    `.bd-tn` (C9-T11), no modal tone (C11-T01).
  - No server mapping of states or models (C8-T01), no change to the diff or
    recycle path (C9-T05's `refreshTicket` and C9-T03's relayout already rebuild
    changed cards through `makeCard`, §4.3).
  - No `prefers-reduced-motion` listener (C9-T01 adds it, §4.5).
  - No visible state glyph on the logo (S-4: the design's `glyph` is `""`, J:827).

## 2. Dependencies and blockers

- **Blocked by DESIGN-E8.** Two sign-off items apply, both at their written
  defaults (they do not block):
  - **S-4** "Agent-state glyph on the logo is empty in the design" → screen-reader
    label only, no visible glyph.
  - **S-13** "Logo for a model the design does not include" → the `.ax-mono` letter
    circle, sized to each logo slot. C9-T05 implements the circle; this ticket
    fixes its size and keeps it accessible.
  Kevin's answer to either may reopen this ticket.
- **Predecessor: C9-T05** (ticket cards in four tiers). C9-T05 ports `makeCard`,
  `decorate` and `refreshTicket`, emits the `ag-*` classes, the glow span, the
  logo slots, the S-13 letter circle and the "unknown state" label inline. This
  ticket moves those expressions into `agents.js`, adds the S-13 sizes and adds
  the accessible text.
  Through C9-T05 it also depends on C9-T03 (card recycling by uid), C9-T01
  (module layout, `dom.js` `esc`, the `.rm` toggle and its change listener),
  C3-T02 (payload `agent` field), C2-T04 (stylesheet) and C2-T03 (`LOGOS`).
- **Predecessor: C8-T01** (added in review). It owns PROPOSED
  `build-home/now-state.js` (`AST`, `agentState(state)` returning
  `{ label: "State unknown", cls: null }` for an unknown state, with an
  `Object.hasOwn` guard, `progress`, `modelLabel`) and the C3-T02 extension
  `agent.model: str | null`, `agent.name` (string or `null`); no `agent.full`. C8-T01 is not upstream of C9-T05 in the README graph, so it
  is named here. It depends only on C3-T02, so the critical path does not grow.
- **Successors that read this ticket's exports:** C9-T08 (band header counts by
  `AST[*].cls`), C9-T11 (tree nodes), C9-T12 (list view), C10-T02 (`astate` filter
  options, J:1102; imports `AST` from `now-state.js`, `modelInfo` from here),
  C11-T01 (modal tone and model logo; imports `rowState(t)`, `modelInfo`),
  C11-T07 (`modelInfo`), C12-T05 (per-card screen-reader summary reuses
  `agentText` and `rowState(t)`).
- **May run concurrently with** C9-T07 and C9-T12 (README "What may run
  concurrently"). This ticket edits `agents.js` (new), the agent lines of
  `cards.js` (C9-T05's file), two S-13 rules in C9-T05's CSS block in
  `build-home/home.css`, three rows of
  the `unknowns` fixture, and one spec.
- **Shared contracts:** the C3-T02 payload schema v1, `agent` field, as extended
  by C8-T01: `{ model: key | null, name: str | null, state: AST
  key | null, effort: none|minimal|low|medium|high|xhigh|max | null } | null`
  (MP-E8-C3-T02.md row table; MP-E8-C8-T01.md "Interface changes to C3-T02").
  `model` matches `^[a-z0-9][a-z0-9._-]{0,31}$` when not `null`.

## 3. Verified starting point (`58854d4c8`)

Live product (read-only checkout `aiur-worktrees/runtime`, HEAD `58854d4c8`):

- **No home hook exists yet.** `src/priv/static/` holds `build-order-grid-hook.js`,
  `aiur-dom-svg-layout/` and the other hooks. The `build-home/` directory is
  PROPOSED by C2-T03.
- `src/lib/aiur_web/static_assets.ex:13-27` `@revalidated_static_paths`. C2-T03
  adds the `build-home` directory entry once. This ticket adds no entry.
- `src/lib/aiur_web/components/layouts.ex:290` links `/dashboard.css`, and `:54`
  starts the inline `Hooks` map (`:253`
  `Hooks.DomSvgLayout = window.AiurDomSvgLayout.createLiveViewHook()` is the
  directory-loader precedent C2-T03 follows). No change here.
- `src/priv/static/dashboard.css:215-225` defines `.sr-only` (absolute, 1 × 1 px,
  `clip: rect(0, 0, 0, 0)`). It is already used in LiveView components, for
  example `operator_control_center/tickets_panel.ex:81` and `:95`. This ticket
  reuses it.
- `src/priv/static/dashboard.css:6865-6874` is a global
  `@media (prefers-reduced-motion: reduce)` rule on `*`, `::before`, `::after`:
  `animation-duration: 0.01ms !important; animation-iteration-count: 1 !important`.
  It also applies to the home page (MP-E8-C1-T03 records this). See §6 N-6.
- Model logos: `src/priv/static/claude-symbol.svg` and `codex-color.svg` differ
  from the design copies only by a trailing newline (MP-E8-C2-T03 table). The
  product also ships `muse.svg`, `openrouter.svg`, `kimi.svg`, `deepseek.svg`, which
  the design does not use. C2-T03's `LOGOS` table (PROPOSED `build-home/logos.js`)
  is a frozen null-prototype object with the four design keys only, each
  `{ src, fill }`: `claude`, `codex` (`/provider-assets/...`, `fill: false`),
  `deepseek`, `kimi` (`/build-home/logos/*.png`, `fill: true`). Any other key gives
  `undefined`.
- Model display names exist on the server:
  `src/lib/aiur/coding_agent/providers/claude.ex:51` `label: "Claude"`,
  `codex.ex:53` `label: "Codex"`, `muse.ex:37` `label: "Muse"`, read through
  `Aiur.CodingAgent.provider_descriptor/1` (`src/lib/aiur/coding_agent.ex:292-300`).
  C8-T01 sends that label as `agent.name`.
- Existing logo fallback elsewhere:
  `src/lib/aiur_web/components/operator_control_center/run_summary_strip.ex:781`
  `provider_logo/1` falls back to `/aiur-logo.png`. This ticket does **not** reuse
  that: on the home page an unknown model must not look like a known mark (S-13).
- Browser tests: `src/browser/package.json:10` `npm test` chain of
  `node scripts/run-browser-tests.mjs <spec>` scripts; `@playwright/test`
  `1.61.1` (`:38`). `src/browser/tests/support/browser-helpers.mjs:88-90` notes
  that a `reducedMotion: 'reduce'` context collapses every duration to 0.01 ms.

Neighbour tickets this ticket builds on (PROPOSED code, not yet in the product):

- **C9-T05** `cards.js` (its "Implementation steps" 4 and 8): `ag = t.sec ===
  "now" ? agentState(t.agent && t.agent.state) : null` (C8-T01); the now label
  `unk("state", "State unknown", …)` with `data-unknown="state"`; `modelOf`
  → `LOGOS` image or the `.ax-mono` letter (first letter of the name); an
  "MP-E8 additions" block in `build-home/home.css` with no S-13 sizes (they
  are this ticket's, §4.4); dataset `unknowns.json` (ids 9001–9013: 9007
  `model: "muse"`, 9008 `state: null`, 9009 `agent: null`); `refreshTicket(id)`
  rebuilds a changed, unmoved card from the current row with `makeCard`.
- **C8-T01** `now-state.js`: `AST` (J:88–91 verbatim), `UNKNOWN_STATE =
  { label: "State unknown", cls: null }`, `agentState(s)` (`Object.hasOwn(AST,
  s) ? AST[s] : UNKNOWN_STATE`), `modelLabel(agent)` (`agent.name`, else the
  brand label of a design key, else `null`).
- **C9-T01**: `dom.js` exports `esc` (J:9 plus `'` → `&#39;`); `state.js`
  exports `rmOn`; its Decision 8 adds a `prefers-reduced-motion` change listener
  that re-toggles `.rm`.
- **C9-T08** `bandClock(D, …)`: daemon `offline`/`stale` → `cached HH:MM` of
  `daemon.heartbeat_at`; `sources.agents.state` not `ok` → its `observed_at`;
  `null` → `—`.

Design source (`design-source/`, etag 1791431544512943; J = `assets/build.js`,
C = `assets/build.css`):

- **`AST`** J:88-91:

  | key | label | cls |
  | --- | --- | --- |
  | `active` | Running | `active` |
  | `error` | Error | `stuck` |
  | `retries` | Retries exhausted | `stuck` |
  | `command` | Awaiting command | `stuck` |
  | `paused` | Paused | `idle` |
  | `parked` | Parked | `idle` |

- **`MODELS`** J:82-87: `claude`, `codex`, `deepseek` (`fill`), `kimi` (`fill`).
  The `name` strings are brand names (Claude, Codex, DeepSeek, Kimi); the `full`
  strings ("Claude Sonnet 4.5", "GPT-5 Codex", ...) are mock data.
- **`makeCard`** J:814-866, agent parts:
  - J:818 `ag = t.sec === "now" ? AST[t.agent.state] : null` (throws for
    `agent: null`; an unknown state throws later at J:850 `ag.label`);
  - J:820 class `ag-<cls>` when `ag`; J:821 `has-ag` when `t.agent && det === "full"`;
  - J:826 `glow = ag ? '<span class="bd-glow"></span>' : ""`, the first child on
    every tier (J:830, 832, 837, 864);
  - J:827 `glyph = ""`; J:828 the logo `span.bd-ag[.fill][title="<full> ·
    <label>"]` with `img[src][alt=<name>]`, only when `t.agent && det ===
    "full"`, appended after `.bd-in` (J:864). History rows have `agent.state:
    null` (J:191), so a full history card shows the logo with no state;
  - J:833 the line tier's `img.bd-lg[alt=""]` on now cards;
  - J:830, 832, 837 the `.bd-in` `title` ends in `" · " + ag.label` on bar, line
    and mini cards;
  - J:850 the now status line prints `ag.label`.
- **Reduced motion:** J:540 `rmOn()`; J:560 `root.classList.toggle("rm", rmOn())`
  once in `shell()` (C9-T01's port).
- **`fmtT`** J:17 (`HH:MM` in the browser zone).
- **CSS, final cascade per state** (later rules win; this is what the design
  renders, and what the parity checks compare):

  | State | `.bd-glow` | `.bd-ag` | Card |
  | --- | --- | --- | --- |
  | any | `inset: -3px; z-index: 0; border-radius: calc(var(--r) + 3px); pointer-events: none; opacity: 0` (C:287); mini `inset: -2px; filter: blur(3px)` (C:314) | `top/right: -.6em; 1.85em` circle (content box: `.bd-ag` sets no `box-sizing`), `var(--bg-2)`, `1px var(--line-strong)`, `--shadow-sm` (C:280); img `1.15em` (C:281); `.fill` img 100 % cover (C:816-817) | `.has-ag .bd-cx { margin-right: 1.25em }` (C:240), 1.1em under 150 px (C:370) |
  | active | conic gradient `from var(--bd-a)`, stops transparent 0, `var(--accent)` 60, transparent 140 and 190, accent 65 % 260, transparent 330 deg, `blur(6px)`, opacity .9, `bdRot 9s linear infinite` (C:288; `@property --bd-a` C:226; keyframes C:295); light opacity .45 (C:972) | accent border, `color-mix(accent 24%, --bg-2)`, ring + 12 px glow, **`bdAg 3.6s ease-in-out infinite`** (C:396, keyframes C:400); light shadow C:974 | mini border accent (C:403) |
  | stuck | **static**: opacity 1 (C:289); `inset: 0; border-radius: var(--r); box-shadow: 0 0 16px 1px color-mix(block 38%); animation: none` (C:705 overrides C:289 and C:462); light `0 0 12px 0 block 22%` (C:973) | block border, `color-mix(block 26%)`, ring + glow (C:397), no animation | border `var(--block) !important` (C:704); red fill and bar (C:1161-1164) |
  | idle | opacity 0 (C:399) | `var(--line)`, `var(--surface-3)`, no shadow, opacity .75 (C:398); now cards `grayscale(1); opacity: .7 !important` (C:1181) | label and bar grey (C:1176, 459) |
  | history | none (`ag` is null) | `grayscale(1); opacity: .7; 1.6em; top/right -.5em` (C:282) | — |
  | `.rm` | active: `animation: none; background: none; filter: none; box-shadow: 0 0 0 1.5px accent, 0 0 14px accent 38%` (C:297); stuck none (C:298, 705); OS media rule `.ag-active .bd-glow { animation: none }` (C:348) | active `animation: none` (C:401) | transitions none (C:231) |
  | `.stale` (C9-T13) | `animation-play-state: paused; grayscale(1) blur(5px); opacity .35` (C:299) | active `animation: none` (C:401) | — |

  Two facts differ from the row text in tickets/README.md and from C2-T04's
  "Pixel parity" list: **the stuck glow does not pulse** (C:705 sets
  `animation: none` after `bdStuck` is declared at C:289), and **the active logo
  pulses** with `bdAg 3.6s` (C:396). The idle glow is invisible (opacity 0), not
  "a grey, static glow" as E8-D12 words it. The design wins (pixel mandate).
- `.bd-card .bd-status > span:first-child` (C:870) keeps the state label visible
  in narrow cards (it out-ranks the `display: none` at C:364 inside the 150 px
  container query), but truncates it with an ellipsis ("Retries exh…"). So the
  visible label is not a complete accessible name on narrow cards.
- `.ax-mono` (C:58-59, 782, 895, 1065): JetBrains Mono 700, white on `#8b6cf0`,
  round (C:782), gruvbox `saturate(.55)`. Sized only for the usage strip (18 or
  20 px).

## 4. Chosen design

### 4.1 One module, design names kept, one `AST`

`agents.js` exports frozen data and pure functions. C9-T05's `makeCard` calls
them at the exact points where the design inlines the same expressions. The DOM,
class names and attribute order match the design and C9-T05.

```js
// PROPOSED src/priv/static/build-home/agents.js
import { LOGOS } from "./logos.js"                            // C2-T03 (null prototype)
import { esc } from "./dom.js"                                // C9-T01 (J:9 with ' → &#39;)
import { AST, UNKNOWN_STATE, agentState, modelLabel } from "./now-state.js" // C8-T01 only (R-G9)
import { fmtT } from "./util.js"                              // C9-T02's J:17 port; reuse, do not copy

// The now-row state; null for rows that are not in the band.
export function rowState(t) {
  if (t.sec !== "now") return null
  return agentState(t.agent && t.agent.state)                  // UNKNOWN_STATE, never a plausible default (D-3)
}
export function modelInfo(key) {
  const k = typeof key === "string" && key !== "" ? key : null
  return {
    name: k ? (modelLabel({ model: k, name: null }) || k) : "Model unknown",
    logo: k && Object.hasOwn(LOGOS, k) ? LOGOS[k] : null,
    mono: k ? k.charAt(0).toUpperCase() : "?",                 // C8-T01 D10: null model → "?"
  }
}
function who(t) {                                              // C8-T01: payload name wins
  const m = modelInfo(t.agent && t.agent.model)
  return { m, name: modelLabel(t.agent) || m.name }
}
export function agentClasses(t, det) {                         // J:820-821
  const ag = rowState(t)
  return { ag: ag && ag.cls ? "ag-" + ag.cls : null, hasAg: !!t.agent && det === "full" }
}
export function glowHTML(t) {                                  // J:826
  const ag = rowState(t)
  return ag && ag.cls ? '<span class="bd-glow"></span>' : ""
}
export function logoHTML(t, det) {                             // J:828, appended after .bd-in
  if (!t.agent || det !== "full") return ""
  const { m, name } = who(t), ag = rowState(t)
  const title = esc(name + (ag ? " · " + ag.label : ""))
  const inner = m.logo ? '<img src="' + esc(m.logo.src) + '" alt="">' : '<span class="ax-mono">' + esc(m.mono) + "</span>"
  return '<span class="bd-ag' + (m.logo && m.logo.fill ? " fill" : "") + '" title="' + title + '" aria-hidden="true">' + inner + "</span>"
}
export function lineLogoHTML(t) {                              // J:833, now rows only
  const { m } = who(t)
  return m.logo ? '<img class="bd-lg" src="' + esc(m.logo.src) + '" alt="">'
                : '<span class="bd-lg ax-mono" aria-hidden="true">' + esc(m.mono) + "</span>"
}
export function agentText(t, D) {                              // §4.2
  const ag = rowState(t)
  if (!t.agent && !ag) return null
  const head = t.agent ? "Agent " + who(t).name : "Agent"
  if (!ag) return head
  return head + ": " + (ag.cls ? ag.label : "state unknown") + staleSuffix(D)
}
export function srHTML(t, D) {                                 // first child of .bd-in on every tier
  const s = agentText(t, D)
  return s ? '<span class="sr-only">' + esc(s) + "</span>" : ""
}
function staleSuffix(D) {                                      // same precedence as C9-T08 bandClock
  const d = D.daemon || {}, a = (D.sources && D.sources.agents) || {}
  const at = (ms) => (Number.isFinite(ms) ? ", as of " + fmtT(ms) : ", state age unknown")
  if (d.state === "offline" || d.state === "stale") return at(d.heartbeat_at)
  if (d.state !== "live") return ", state age unknown"
  if (a.state !== "ok") return at(a.observed_at)
  return ""
}
```

`Object.hasOwn` keeps a key like `"constructor"` or `"__proto__"` from reading a
prototype value. C8-T01's `agentState(s)` has that guard, so `rowState(t)` only
adds the now-section check. The server regex already blocks such keys; the
client does not rely on it. `LOGOS` has a null prototype, and `Object.hasOwn`
works on it.

### 4.2 Screen-reader text (EC-19, S-4)

`agentText(t, D)` returns one plain string, or `null` when the row has no agent:

| Row | Text |
| --- | --- |
| now, known state | `Agent Claude: Running` |
| now, state `null` or not in `AST` | `Agent Claude: state unknown` |
| now, `agent: null` | `Agent: state unknown` |
| now, `model: null`, `name: null` | `Agent Model unknown: Running` |
| history or plan with `agent` | `Agent Claude` |
| no `agent` | `null` (no span) |

The name is `agent.name` when the payload has it (C8-T01), else the design brand
name for the four design keys, else the raw key.

Stale suffix, now rows only, with the same precedence as C9-T08's `bandClock`, so
the screen reader and the band header agree:

| Input | Suffix |
| --- | --- |
| `daemon.state` `offline` or `stale` | `, as of HH:MM` of `daemon.heartbeat_at`; `null` → `, state age unknown` |
| `daemon.state` any other non-`live` value | `, state age unknown` |
| daemon live, `sources.agents.state` not `ok` | `, as of HH:MM` of `sources.agents.observed_at`; `null` → `, state age unknown` |
| daemon live, agents `ok` | none |

HH:MM uses the design's `fmtT` (J:17) through C9-T05's port. A stale "Running" is
never read as current (EC-07 applied to this text; the visual stale styling is
C9-T13's). The socket-down case (C8-T03's `socketDown`) is not in `D`; see §6 N-7.

Placement: a `.sr-only` span is the first child of `.bd-in` on all four tiers.
`.bd-in` is a flex container (C:232); an absolutely positioned child takes no
flex slot and no `gap`, so layout does not change. No design selector targets
`.bd-in > :first-child`. `.bd-ag` and `.bd-lg` get `aria-hidden="true"` and the
logo `img` gets `alt=""`. Without that, the name would be read twice ("Claude ...
Agent Claude: Running"). The visible `title` tooltips stay as in the design.

### 4.3 Calls from C9-T05 and the recycle path

C9-T05's `makeCard` uses, in the design's order:

- class list: `... + (cls.ag ? " " + cls.ag : "") + ... + (cls.hasAg ? " has-ag" : "")`;
- `el.innerHTML = glowHTML(t) + '<div class="bd-in" ...>' + srHTML(t, D) + ...`;
- the bar/line/mini `title` suffix and the now status line: `rowState(t).label`.
  For an unknown state the now label stays C9-T05's `unk("state", …)` span with
  `data-unknown="state"` and the text `UNKNOWN_STATE.label` ("State unknown",
  D-8);
- full tier: `... + "</div>" + logoHTML(t, det)`; line tier now rows:
  `lineLogoHTML(t)` in place of C9-T05's `logo("line")`.

C9-T05's inline `ag` and `modelOf` expressions are deleted from `cards.js`;
there is one `AST` (C8-T01) and one model lookup (`modelInfo`).

Recycling: C9-T05's `refreshTicket(id)` already rebuilds a changed, unmoved card
from the current row with `makeCard` (fresh element, `noanim`), and C9-T03's
relayout handles a row that moves (now → hist). A rebuilt element starts with no
classes, so no `ag-*` class, glow or logo can survive a state change (EC-10). This
ticket adds no class-patching helper and does not touch C9-T03; V-8 guards the
behaviour.

### 4.4 S-13 letter circle size

C9-T05 draws the circle with only the base `.ax-mono` size (18 px, C:58). A
naive rule that sets `width`/`height` in `em` on the element that also sets
`font-size` measures the box in the span's own (smaller) font (`1.15em × .62 ≈
.71em` of the card font). This ticket adds two rules inside C9-T05's "MP-E8
additions" block in `build-home/home.css` (no second block):

```css
.bd-ag > .ax-mono { width: 100%; height: 100%; border-radius: 50%; font-size: .57em; }
.bd-card.line .bd-lg.ax-mono { width: 1.75em; height: 1.75em; flex: none; border-radius: 50%; font-size: .6em; }
```

- `.bd-ag > .ax-mono` (specificity 0,2,0) beats `.ax-who img, .ax-mono` (C:58,
  895). It fills the 1.85em content box like a `.fill` logo (C:817). The letter is
  .57 of the slot, the ratio of `.ax-mono` in the usage strip (.64rem on 18 px).
- The line-tier slot is `1.05em` of the card font (C:655). The box is in the
  span's own em, so `1.75em × .6 = 1.05em`.
- Colour, weight and the gruvbox `saturate(.55)` come from the existing `.ax-mono`
  rules; no inline hue, so every unknown model looks the same.
- `.hist .bd-ag`, `.ag-idle .bd-ag` and `.bd-card.now.ag-idle .bd-ag` filters still
  apply, because they target `.bd-ag`.

### 4.5 Reduced motion

No new code. The design's `.rm` class (J:560, ported by C9-T01) plus C:297, 298,
348, 401 give the static equivalents. C9-T01's change listener (its Decision 8)
re-toggles `.rm` when the OS setting changes after load, and the product's global
rule (`dashboard.css:6865-6874`) also ends any running animation after 0.01 ms.
This ticket proves the load-time result (V-9); the mid-session toggle is
C1-T03's `reduce.live-toggle` sequence.

## 5. Implementation steps

1. Create `src/priv/static/build-home/agents.js` with §4.1. Export `rowState`,
   `modelInfo`, `agentClasses`,
   `glowHTML`, `logoHTML`, `lineLogoHTML`, `agentText`, `srHTML`. Register it the
   way C9-T01's module table says (a relative import from `cards.js`).
2. In C9-T05's `cards.js`, replace the inline `ag`, `modelOf` and `glow`
   expressions (the ports of J:818–828, 830–833, 837, 850, 864) with the calls
   in §4.3. The unknown-state text stays `UNKNOWN_STATE.label` (D-8).
3. Add the two §4.4 rules to C9-T05's block in `build-home/home.css`, keeping
   its block comment and adding `(S-13 sizes: C9-T06)`.
4. Fixture: add three rows to C9-T05's `src/test/fixtures/build_home/unknowns.json`
   with fixed ids 9014–9016: 9014 a now row with `agent.model: "zz-new"`; 9015 a
   history full-tier row with `agent.model: "openrouter"`; 9016 a now row with
   `agent: { model: null, name: null, state: "active" }`. Every value
   must pass `Payload.validate/1` (C3-T02 + C8-T01 rules). Add one row to the
   `live` copy used by V-13 through the spec's diff helper, not the fixture
   (`agent.name: "Claude Opus 4.1"` on a1).
5. Add `src/browser/tests/build-home-agents.browser.spec.mjs` (§8) and the script
   `"test:build-home-agents": "node scripts/run-browser-tests.mjs tests/build-home-agents.browser.spec.mjs"`
   in `src/browser/package.json`, chained into `npm test` after the other C9
   specs.
6. Add the S-13 letter-circle and unknown-state samples to C12-T08's sign-off
   package list (one line each in the ticket PR body; C12-T08 collects them).

## 6. Non-happy paths

| # | Case | Behaviour | Test |
| --- | --- | --- | --- |
| N-1 | Now row with `agent.state: null` (C8-T01 could not map a `UnitsPolicy` condition) | No `ag-*` class, no `.bd-glow`; logo shown without state filters; status label and `title` say "State unknown"; screen reader "Agent Claude: state unknown". Never "Running", never a glow. | V-5 |
| N-2 | State string outside `AST`, including `"constructor"` and `"__proto__"` (a newer server, or a bad diff) | Same as N-1 (`Object.hasOwn` check). No exception, so the rest of the board renders. | V-11 |
| N-3 | Now row with `agent: null` | No glow, no `.bd-ag`; line tier shows the `?` letter circle; sr text "Agent: state unknown". | V-11 |
| N-4 | Model key not in `LOGOS` (`muse`, `openrouter`, `zz-new`) | `.ax-mono` letter circle in `.bd-ag` and in `.bd-lg`; never another model's image. | V-6 |
| N-5 | Model `null` or `""` (C8-T01 D10) | Name "Model unknown" (unless `agent.name` is set), letter `?`. | V-11, V-6 |
| N-6 | Reduced motion set after load | C9-T01's listener re-toggles `.rm`; the global `dashboard.css:6865` rule ends every animation after 0.01 ms. | V-9 (load-time); C1-T03 `reduce.live-toggle` |
| N-7 | Stale board (daemon offline or stale, `sources.agents` stale or unavailable) | Glow paused and grey by C9-T13's `.stale` (C:299, 401); screen-reader text gains ", as of HH:MM" or ", state age unknown" (§4.2). A dropped socket with a live last snapshot gets no suffix: `D` does not carry `socketDown`; C9-T08's band clock shows it. | V-10 |
| N-8 | Diff changes a rendered card's state (active → stuck → paused) or moves it to history | Card rebuilt by `refreshTicket` / relayout; exactly one `ag-*` class or none; glow removed when the row leaves `now`. | V-8 |
| N-9 | Narrow card (< 150 px container) | Visible label truncates (C:870); the screen-reader span carries the full text. | V-4 |
| N-10 | Untrusted text (EC-30): `agent.name`, the key | Every string passes `esc` before it reaches `innerHTML` or an attribute; attributes stay double-quoted; the logo `src` comes only from `LOGOS`. | V-11 |
| N-11 | Browser without `@property` | `--bd-a` is not animatable; the conic glow is static. No error. Accepted degradation; the parity runner uses Chromium. | — |
| N-12 | Many active agents (20+) | Each runs `bdRot` with `blur(6px)` and `bdAg`. Kept as designed; C12-T06 measures phone cost (EC-27). | — |

Permissions, privacy, retries, idempotency of writes: not relevant. This ticket
renders read-only data and writes nothing.

## 7. Compatibility and rollout

- No configuration, migration or server change. Ships dark behind the home page
  until C12-T01 cutover, like the rest of C9.
- `MODELS` never enters the client, and `cards.js` loses its `AST` copy.
  Successors (C9-T12, C10-T02, C11-T01, C11-T07) import `modelInfo` from
  `agents.js` and `AST`/`agentState(state)` from `now-state.js` (R-G9) instead of
  copying the design table.
- Before C8-T01's fields arrive in a fixture, `agent.name` is absent and
  the title falls back to the brand name or the key; nothing breaks.
- Rollback: revert the PR. C9-T05's inline agent rendering does not come back by
  itself (step 2 deleted it), so a revert must revert the whole PR, including the
  `cards.js` hunk. No data is lost.
- Docs: none in this PR. The home page guide is C12-T07.

## 8. Verification

Spec `src/browser/tests/build-home-agents.browser.spec.mjs` on the C3-T01 fixture
route (`GET /build-fixture/<dataset>`, then `/build`), clock fixed at C1-T01's
`NOW`. Design ids map through C1-T01's id map. The `live` now cards are the
design's `ACTIVE` rows (J:203-212): a1, a2, a8 active; a3 command, a4 error, a5
retries; a6 paused, a7 parked; models claude, codex, claude, deepseek, kimi,
claude, codex, kimi.

Coverage. C9-T05 already emits the classes, glow and logo, so tests of those
pass with this ticket's hunks reverted. They are **regression guards**, named so
in the test title, and are not counted as coverage. The rows marked **covers**
fail with this ticket's production hunk reverted.

| ID | Kind | Test | Expected | Fails when (mutation) |
| --- | --- | --- | --- | --- |
| V-1 | guard | `state class per AST` (live) | a1, a2, a8 have `ag-active`; a3, a4, a5 `ag-stuck`; a6, a7 `ag-idle`; each card has exactly one `ag-*` class | map `command` to `active`; drop the class |
| V-2 | guard | `glow only on now cards` (live, span 1 and 7) | every now card with a known state has exactly one `.bd-glow` as first child; no `hist`, `plan` or `nq` card has one | emit the glow for every row with `agent` |
| V-3 | guard | `logo on full cards` (live, 1440 px) | full now and history cards have `.has-ag` and one `.bd-ag`; `img.src` ends with `LOGOS[model].src`; `.fill` exactly on deepseek and kimi; line-tier now cards have `img.bd-lg[alt=""]` | drop `.fill`; swap two `LOGOS` keys |
| V-4 | covers | `state in screen-reader text` (live, 1440 px; then one card forced to a 140 px container with an injected `width`) | each now card's `.bd-in > .sr-only:first-child` text equals the §4.2 table (for example a5: `Agent Kimi: Retries exhausted`); history full card: `Agent Codex`-style; `.bd-ag` and `.bd-lg` have `aria-hidden="true"`; logo `img` `alt=""`; on the forced-narrow card the visible label has `scrollWidth > clientWidth` and the span text is still the full label; the sr span's bounding box is 1 × 1 px and the card's `.bd-in` children's positions equal those with the span removed | remove `srHTML` from `makeCard`; remove `aria-hidden` |
| V-5 | guard | `unknown state is not Running` (unknowns 9008) | no `ag-*` class, no `.bd-glow`, status text "State unknown" with `data-unknown="state"`, sr text ends ": state unknown"; `getAnimations()` on the card's subtree is empty | replace `UNKNOWN_STATE` with `AST.active` |
| V-6 | covers | `unknown model uses the letter circle` (unknowns 9007, 9014, 9015, 9016) | muse: `.bd-ag > .ax-mono` text `M`, no `img`; `zz-new`: `Z`; 9016: `?`; line tier `.bd-lg.ax-mono`; history `openrouter`: `O`, computed `filter` of `.bd-ag` is `grayscale(1)`; the `.ax-mono` box equals the `.bd-ag` **content box** (`clientWidth`, ± 0.5 px; the 1 px border is outside); the line-tier circle's width equals 1.05 × the card's computed font size (± 0.5 px) | fall back to `LOGOS.claude`; remove the §4.4 rules, or size the box in the span's own em (≈ .71em / .63em) |
| V-7 | guard | `computed styles per state` (live, dark and light) | for one card per class: `.bd-glow` `animation-name`, `animation-duration`, `opacity`, `box-shadow`, `inset`, `filter`, `background-image`; `.bd-ag` `animation-name`, `border-color`, `box-shadow`, `opacity` equal the design page's values, compared with C1-T03 `compareRecords`. Active: `bdRot 9s` + `bdAg 3.6s`. Stuck: `animation-name: none`. Idle glow `opacity: 0`. | add `bdStuck` to the stuck glow (the README wording); any C2-T04 drift |
| V-8 | guard | `diff re-renders agent state` (live) | push a C3-T02 diff that upserts a1 with `state: "error"`: `ag-stuck`, no `ag-active`, no `bdRot` animation; then `state: "paused"`: `ag-idle`; then `sec: "hist"`: no `.bd-glow`, no `ag-*`, `.bd-ag` still present (history logo) | a `refreshTicket` that patches classes on the old element |
| V-9 | guard | `reduced motion is static` (live, `reducedMotion: 'reduce'`) | `#build-root.rm`; active `.bd-glow` `animation-name: none`, `background-image: none`, box-shadow equal to the design page; active `.bd-ag` `animation-name: none`; no running animation on any `.bd-glow` or `.bd-ag` | C9-T01 drops the `.rm` toggle or C2-T04 drops C:297/401 |
| V-10 | covers | `stale text carries the age` (offline; plus pure-function cases) | now cards' sr text ends `, as of 14:14` (the fixture heartbeat; C1-T01 offline `daemon`); pure cases: daemon `offline` with `heartbeat_at: null` → `, state age unknown`; daemon `unknown` → `, state age unknown`; daemon live, `sources.agents` `{state: "stale", observed_at: 14:10}` → `, as of 14:10`; live and `ok` → no suffix | drop the suffix; replace the null branch with the current time or `"—"`; read `observed_at` before `heartbeat_at` |
| V-11 | covers | `pure functions` (via `page.evaluate(() => import('/build-home/agents.js'))`) | `rowState({sec:"now", agent:{state:"zz"}})` is `UNKNOWN_STATE`; `"__proto__"` and `"constructor"` → `UNKNOWN_STATE`; `agent: null` → `UNKNOWN_STATE`; `rowState({sec:"hist", agent:{…}})` is `null`; `modelInfo(null)` and `modelInfo("")` → `{name: "Model unknown", logo: null, mono: "?"}`; `logoHTML` with `agent.name` `'a"b<i>'` contains `&quot;` and `&lt;i&gt;` and no raw `"` inside the attribute; `agentText` for a plan row with no agent is `null`; for a now row with `agent: null` it is `Agent: state unknown` (live `D`) | drop the `sec` check in `rowState`; removing `esc`; the old `"U"`/`"unknown"` default |
| V-12 | guard | `no page errors` (live, unknowns, offline) | `page.on('pageerror')` collects nothing during load and V-8's diffs | an unguarded `AST[state].label` |
| V-13 | covers | `logo title names the real model` (live, diff on a1 with `agent.name: "Claude Opus 4.1"`; a2 unchanged) | a1 `.bd-ag` `title` is `Claude Opus 4.1 · Running`; a2 (no `name`) is `Codex · Running`; a1 sr text `Agent Claude Opus 4.1: Running`; no title contains `Sonnet 4.5` or `GPT-5` | use the key (`claude · Running`); use the design's mock `full` |

The PR body names the revert result per **covers** test and the exact command,
run in a worktree with `git status --porcelain` showing only the reverted hunk
(AGENTS.md). Guards are listed separately with the reason they pass on revert.

Commands (from the repository root, isolated `HOME`):

```text
npm --prefix src/browser ci
npm --prefix src/browser run fixture:preflight
npm --prefix src/browser run test:build-home-agents
npm --prefix src/browser run test:build-home-cards     # C9-T05's spec, with its updated label
npm --prefix src/browser run test:design-parity        # C1-T02 enforced harness
npm --prefix src/browser run parity:matrix             # report mode; the agent cells must be at the floor
```

Manual check: open `/build-fixture/live` then `/build` in Chromium at 1440 and
390 px, dark and light. Hover a running card's logo: the tooltip reads
"Claude · Running". With Orca or VoiceOver, move to a stuck card and hear
"Agent DeepSeek: Error". Turn on reduced motion in the OS and reload: no glow
moves. Then open `unknowns` and see the letter circles fill their slots and the
"State unknown" card.

## Pixel parity

- **Design elements reproduced:** `span.bd-glow` and `span.bd-ag` (J:826-828, 864),
  `img.bd-lg` (J:833), classes `ag-active`, `ag-stuck`, `ag-idle`, `has-ag`
  (J:820-821); CSS listed in §3 (C:226, 231, 240, 246, 280-299, 312-314, 348,
  370, 395-403, 457-463, 655, 704-705, 816-817, 969-974, 1161-1181); keyframes
  `bdRot` (9 s linear), `bdAg` (3.6 s ease-in-out); the reduced-motion static
  ring (C:297).
- **What must match exactly:** the glow geometry (`inset -3px`, radius
  `var(--r) + 3px`, mini `-2px` and `blur(3px)`), the conic stops (60, 140, 190,
  260, 330 deg), `blur(6px)`, opacity .9 dark / .45 light; the stuck shadow
  `0 0 16px 1px` at 38 % (light `0 0 12px 0` at 22 %), `inset: 0`, static; the
  logo circle 1.85em at `-.6em` (history 1.6em at `-.5em`), image 1.15em or
  100 % for `.fill`; the idle logo opacity .7 with grayscale; timings 9 s and
  3.6 s.
- **How it is checked (C1-T02 / C1-T03 harness):**
  1. `expectDesignParity(pair, { name: "agents-band", region: ".bd-now" })` on
     dataset `live`, at the three matrix viewports × dark/light × default/gruvbox.
     `animations: 'disabled'` compares the first frame of each infinite loop.
  2. The same region with `reducedMotion: 'reduce'` (static ring, C:297).
  3. Whole-viewport `live` cells of the C1-T02 matrix cover history full cards
     with greyed logos.
  4. C1-T03 `pausedAnimations(page, ".ag-active .bd-glow, .ag-active .bd-ag")`
     on both pages, each animation set to 0, 25, 50 and 75 % of `bdRot` and
     `bdAg`, each frame compared with `expectDesignParity(pair, { name:
     "agents-frame-<p>", region: ".bd-now" })`. This proves the rotation and the
     logo pulse frame by frame.
  5. C1-T03 `inventory` group `'.bd-glow, .bd-ag'` (owned by this ticket in its
     `SEQUENCES` table) on every dataset: the set of running animations (name,
     duration, easing, iterations, play state) is equal; on `offline` the glows
     are `paused`. This ticket's PR turns that group from `fixme` to green.
- **Allowlist:** no entry. The `.sr-only` spans are clipped to nothing, and
  `aria-hidden`/`alt=""`/`title` change no pixel. The S-13 letter circle and the
  unknown state have no design counterpart. They are checked by V-5 and V-6 only
  and go to Kevin as samples in C12-T08.

## 9. Completion and handoff

- [ ] `agents.js` exports the §4.1 interface; `cards.js` has no `AST` copy and no
      inline agent expressions; `MODELS` does not exist in the client.
- [ ] V-1..V-13 pass; the PR body lists the revert result for each **covers**
      test, the reason each guard passes on revert, and the exact command.
- [ ] C9-T05's spec passes with the "State unknown" label.
- [ ] The agent parity cells (Pixel parity 1-5) are at `PARITY_FLOOR`, with no
      new allowlist entry; C1-T03's `inventory['.bd-glow, .bd-ag']` has no `fixme`.
- [ ] No page error on `live`, `unknowns`, `offline`.
- [ ] axe on the `live` fixture reports no new violation on `.bd-card`
      (C12-T05 owns the full pass).
- [ ] S-4 and S-13 named in the PR body as followed at their defaults; samples
      listed for C12-T08.
- **Dependent tickets:** C9-T08, C9-T11, C9-T12, C10-T02, C11-T01, C11-T07, C12-T05.
- **Documentation:** none (C12-T07).
- **Remaining blockers:** DESIGN-E8 sign-off; C9-T05 and C8-T01 merged.

## Decisions made without the owner

- **D-1. The design's final cascade wins over the written wording.** Stuck is a
  static red shadow (C:705), not a 3.2 s pulse; the active logo pulses (`bdAg`,
  C:396); the idle glow is invisible (C:399), not "grey static" (E8-D12). The
  ticket ports the CSS as rendered. Kevin confirms at C12-T08. Also for Kevin:
  E8-D12 says state is never shown by colour alone; on bar, mini and line cards
  the design shows it only by glow colour and a `title` tooltip (the sr text
  covers assistive technology, not sighted users). S-4's default keeps that;
  the colour-only question is S-35.
- **D-2. Tooltip names come from the payload.** The design's `full` strings
  ("Claude Sonnet 4.5") are mock. The title is `<agent.name | brand name | key>
  · <state>` and the sr name is the same name, through C8-T01's `modelLabel`.
  There is no `agent.full` (R-G10).
- **D-3. Unknown state renders as unknown, not as idle or active.** No `ag-*` class,
  no glow, label "State unknown". The design has no such state (it would throw).
  The copy is C8-T01's D7 and goes to the sign-off list.
- **D-4. One screen-reader string per card, logo hidden from AT.** `.bd-ag` and
  `.bd-lg` are `aria-hidden` and the `img` `alt` becomes `""` (the design had the
  model name). This avoids reading the name twice; it changes no pixel.
- **D-5. No reduced-motion code here.** C9-T01 owns the `.rm` toggle and its
  change listener; this ticket only checks the load-time result.
- **D-6. Muse and OpenRouter get the letter circle**, although the product ships
  `muse.svg` and `openrouter.svg`. S-13's written default says so. Kevin may choose
  the product SVGs instead; that is a two-line `LOGOS` change in C2-T03.
- **D-7. The stale suffix is screen-reader text only.** The visible age is C9-T08's
  "cached HH:MM" and C9-T13's banner. It uses `bandClock`'s precedence so the two
  never disagree.
- **D-8. One unknown-state label: "State unknown"** (R-G11). C8-T01, C9-T05,
  C9-T11, C9-T12 and C11-T01 all use `UNKNOWN_STATE.label`.
- **D-9. Reuse C9-T05's `unknowns` dataset** instead of a new `agents-odd`
  dataset; three rows are added (9014–9016). One fixture for "odd values" keeps
  C3-T01's dataset list short.
- **D-10. The S-13 circle fills the `.bd-ag` slot** (100 %) rather than the
  1.15em image size: the two fill-logos (deepseek, kimi) already fill the slot
  (§4.4).

## Interface notes for neighbour rows

- **tickets/README.md C9-T06 row and C2-T04 "Pixel parity"** say the stuck glow
  runs `bdStuck (3.2 s)`. The design cascade turns it off (C:705). C2-T04's T-1
  compares computed styles, so it will pass on the real values, but its listed
  expectation (C2-T04 line "the stuck glow `bdStuck 3.2s ease-in-out infinite`
  (C:289)") is wrong and should be corrected. Neither document mentions the
  active logo's `bdAg 3.6s` pulse.
- **The README row cites C:1110-1124** for agent indicators. Those lines are the
  band header `.bd-now-st` / `.bd-now-sum` rules and the band background, which
  belong to C9-T08. The agent rules are at C:226-314, 395-403, 457-463, 704-705,
  816-817, 969-974 and 1161-1181.
- **README predecessors.** Settled 2026-10-08: C8-T01 is in `blocked_by`.
- **C9-T05.** Settled 2026-10-08: C9-T05 uses "State unknown" and C8-T01's
  `agentState`, takes its S-13 sizes from this ticket, and the sheet is
  `build-home/home.css` (R-G8, R-G11). C9-T05 calls `glowHTML`, `srHTML`,
  `logoHTML`, `lineLogoHTML`, `rowState(t).label` and `agentClasses` after this
  ticket lands (step 2).
- **C8-T01 prototype keys.** Settled 2026-10-08: C8-T01's `agentState` uses
  `Object.hasOwn` (R-G9).
- **C9-T08 and C10-T02** count and filter by `AST` keys. A now row with an unknown
  state is in none of the running, stuck or paused counts; they must not add it to
  "running".
- **C9-T08 and this ticket** both format a stale age; if C9-T08 exports
  `bandClock` first, `staleSuffix` should call it instead of repeating the table.
- **C12-T05 dataset.** Settled 2026-10-08: C12-T05 uses `unknowns` (D-9).
- **C11-T01** expects `UNKNOWN_STATE.label === "State unknown"`; that holds.

## Sources

- Design: `design-source/assets/build.js` J:9, 17, 82-91, 191, 203-212, 540, 560,
  814-866, 1102; `design-source/assets/build.css` lines listed in §3.
- Pack: [../plan.md](../plan.md) §8 EC-07, EC-08, EC-10, EC-19, EC-27, EC-30, §10
  item 7; [../decisions.md](../decisions.md) E8-D12;
  [DESIGN-E8](../../../owner-design-tasks/DESIGN-E8.md) S-4, S-13;
  [README.md](README.md) C9-T06 row; MP-E8-C1-T02, C1-T03 (`SEQUENCES`,
  `pausedAnimations`, `compareRecords`, decision 4), C2-T03 (`LOGOS`), C2-T04,
  C3-T01, C3-T02, C8-T01 (`now-state.js`, interface changes), C9-T01 (module
  table, `dom.js`, Decision 8), C9-T05 (inline agent code, S-13 rules,
  `unknowns`, `refreshTicket`), C9-T08 (`bandClock`), C11-T01, C12-T05 ticket docs.
- Product at `58854d4c8`: `src/lib/aiur_web/static_assets.ex:13-27`,
  `src/lib/aiur_web/components/layouts.ex:54, 253, 290`,
  `src/priv/static/dashboard.css:215-225, 6865-6874`,
  `src/lib/aiur/coding_agent.ex:292-300`,
  `src/lib/aiur/coding_agent/providers/claude.ex:51`, `codex.ex:53`, `muse.ex:37`,
  `src/lib/aiur_web/components/operator_control_center/run_summary_strip.ex:781`,
  `src/browser/package.json:10, 38`,
  `src/browser/tests/support/browser-helpers.mjs:88-90`.

## Review log

Adversarial review, 2026-10-08, against design-source, `runtime/src` at
`58854d4c8`, README, chunks.md and the neighbour tickets (C1-T03, C2-T03,
C2-T04, C3-T02, C8-T01, C9-T01, C9-T05, C9-T08, C10-T02, C11-T01, C11-T07,
C12-T05).

1. **Duplicate ownership removed.** C9-T05 already implements the S-13 letter
   circle, its CSS, the unknown-state card and the `unknowns` fixture. The
   ticket no longer re-implements them; it moves C9-T05's inline code into
   `agents.js`, corrects the S-13 sizes in place (C9-T05's rules measured `em`
   in the span's own font) and extends `unknowns` instead of adding
   `agents-odd` (D-9, D-10).
2. **One `AST`.** C8-T01 owns `AST` and `agentState(state)` in `now-state.js`;
   `agents.js` re-exports and wraps it (with `Object.hasOwn`) instead of
   declaring a third copy. C8-T01 added to `blocked_by`.
3. **D-2 reversed.** C8-T01 adds `agent.name`, `agent.full` and `model: null`;
   the title and sr name now use them. New test V-13. `modelInfo(null)` gives
   `?` / "Unknown model" (C8-T01 D10), not `U` / "unknown".
4. **Reduced-motion facts.** C9-T01's Decision 8 adds the change listener;
   §4.5, N-6 and D-5 said no listener exists.
5. **Recycle path.** Removed `applyAgent` and the C9-T03 edit; C9-T05's
   `refreshTicket` already rebuilds a changed card with `makeCard`.
6. **Stale precedence** aligned with C9-T08's `bandClock` (heartbeat first when
   the daemon is offline); V-10 extended; socket-down gap recorded in N-7.
7. **Imports.** `esc` from `dom.js` (C9-T01), not `util.js`; `fmtT` reused, not
   copied.
8. **Design line numbers.** `has-ag` J:821, glow J:826, logo J:828, line logo
   J:833, tier titles J:830/832/837 (were off by one). Stuck glow opacity 1
   (C:289) and C:348, C:370 added to the cascade.
9. **Harness names.** `compareElement` does not exist in C1-T02; replaced by
   C1-T03 `compareRecords` and `expectDesignParity({ region })`; the C1-T03
   `inventory['.bd-glow, .bd-ag']` group is named as this ticket's.
10. **Honest coverage.** V-1, V-2, V-3, V-5, V-8 pass with this ticket reverted
    (C9-T05 emits the same DOM); they are now labelled guards. Covers: V-4, V-6,
    V-10, V-11, V-13.
11. **V-6 box check** compared against the `.bd-ag` border box, which is 2 px
    larger than the 100 % child; now compares the content box and adds a line-tier
    size check that fails on C9-T05's old rules. V-4 now forces a narrow card
    instead of hoping one truncates at 390 px.
12. **Interface notes** corrected (C2-T03 names `build-home.css`; C9-T05 names
    `home.css`), and new notes for C8-T01's prototype-key gap, C12-T05's dataset
    name and the README predecessor list.
- Reconciliation 2026-10-08 (coordinator): `agent.full` removed, names via C8-T01 `modelLabel` (R-G10), `AST`/`UNKNOWN_STATE`/`agentState` imported from `now-state.js` not re-exported, row wrapper renamed `rowState` (R-G9), "Model unknown" wording aligned with C8-T01/C9-T05, S-13 rules added rather than corrected (C9-T05 ships none), stylesheet `home.css` (R-G8), `fmtT` from `util.js`, colour-only item cited as S-35, interface notes settled.
