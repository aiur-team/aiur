---
ticket_id: MP-E8-C9-T13
feature_id: MP-E8
chunk_id: MP-E8-C9
bucket: 2-platform
title: Loading, empty and stale board states
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C9-T03, MP-E8-C8-T03]
complexity: 3
design_gate: DESIGN-E8
owns_edge_cases: [EC-01, EC-02, EC-03, EC-06, EC-07]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C9-T13 — Loading, empty and stale board states

> **Wave 0b.** Product paths are cited at `58854d4c8` in
> `/home/everdred/github/everdred/aiur-worktrees/runtime/src`. Paths marked
> PROPOSED do not exist yet. `J` = `design-source/assets/build.js`, `C` =
> `design-source/assets/build.css`, `H` = `design-source/Aiur Dashboard.html`.
> The design is the specification
> ([../claude-design-source-of-truth.md](../claude-design-source-of-truth.md)).

## Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history), chunk C9 (client timeline
  engine, port of `build.js`).
- **User value.** The board never lies about what it knows. Before data it shows
  the design's skeleton. A new repository says "No history yet". An empty queue
  says "Nothing planned". A queue, history or open-ticket index that **could not
  be read**, or was read only in part, says so, with its age, and is never drawn
  as empty. Data that is old is marked old. When the socket drops, the cached
  board stays on screen in stale mode.
- **Deliverables.**
  1. PROPOSED `src/priv/static/build-home/states.js`, the `states.js` row of
     C9-T01's "Module layout" (owner C9-T13). It registers itself with one line
     in `hook.js` (`import "./states.js"`, C9-T01 rule 2) and
     `Object.assign(fx, { renderLoading, renderUnavailable })`. It exports:
     - `renderLoading()`: the port of J:1249–1253 (replaces C9-T01's no-op
       `fx.renderLoading`);
     - `renderUnavailable(reason)`: the whole-board failure state (replaces
       C9-T01's `defaultUnavailable`, which C9-T01 calls from `showServerState`
       and from `receive` on an error reply);
     - `sectionState(P, D, H, sec, filtered)`: one pure function that decides
       what a board section shows (rows, empty, filtered-empty, window-empty,
       incomplete, unavailable, disabled) and whether it is stale;
     - `emptyMark(sec, st, ctx)`: the `.bd-mk.empty` mark object for
       `computeLayout` (replaces C9-T02's interim source-aware marks, which
       replace the literal marks at J:419 and J:499);
     - `headNote(sec, st, now)`: the text appended to a section header em;
     - `reasonText(tag)`: a small map from known reason tags to words;
     - `ageText(src, now)`: the `age` expression of "Marker copy" (C9-T12's
       list heads use it);
     - `syncStates()`: writes `ctx.bdStates` and `#build-root[data-bd-states]`,
       and arms the 30 s age tick.
  2. Edits in other modules, each a call into `states.js`, made in this
     ticket's PR (R-G4):
     - C9-T02's `layout.js` `computeLayout`: the interim empty-mark table
       (C9-T02 "Interim source-aware empty marks") becomes
       `sectionState` + `emptyMark`;
     - C9-T03's `render.js`: `headHTML(sec, D, S, H, sources)` appends
       `headNote`; the interim `History <em>unavailable</em>` branch is replaced;
       `relayout()` calls `syncStates()` after the loading gate;
       `onDataChanged` and a new `requestLivePass()` force a live pass on a
       sources-only diff and on the age tick; `update()`'s marks loop refreshes
       a marker's text when it changes;
     - C9-T01's `hook.js` `writeOwnData()`: one line that rewrites
       `data-bd-states` (LiveView drops hook-owned `data-*` on every server
       patch, C9-T01 "`writeOwnData`").
  3. A `degraded` fixture dataset in C3-T01's fixture source.
  4. Tests: a Playwright module spec for `states.js`, an end-to-end spec on the
     fixture routes, and the enforced parity cells listed in "Pixel parity".
- **Non-goals.**
  - The dead-render skeleton and the server load state machine
    (`data-build-state`, 15 s timeout): C3-T01. This ticket only adds
    `role="status"` to its `.bd-loading`.
  - Flipping `S.loading` when the first snapshot arrives: C9-T01 (`firstPaint`
    replaces the 600 ms timer, J:1565–1572).
  - The offline banner, `.bd-daemon` state, the `.bd-root.stale` class toggle,
    Reconnect, `fmtAge` and `fmtWhen`: C8-T03. This ticket uses them and
    enforces C8-T03's parity cells and end-to-end spec (C8-T03 handoff).
  - **The now band**: the "cached HH:MM" clock (`bandClock`) and the
    `.bd-now-empty` text for no agents or unavailable agents (`bandEmpty`,
    "Agent state unavailable · as of HH:MM") are C9-T08's (C9-T08 rules table
    and B-6). This ticket does not touch J:665 or J:669.
  - Any CSS rule. `.bd-skel*`, `.bd-loading`, `.bd-spin`, `.bd-mk.empty` and
    the `.bd-root.stale` rules come from C2-T04's consolidated stylesheet, and
    `@keyframes khSpin` (H:720) with it (C2-T04 T-2).
  - List-view empty and unavailable heads: C9-T12 places them, calling this
    ticket's `sectionState`, `headNote`, `reasonText` and `ageText` (see
    "Interface notes" 6).
  - The features source (`sources.features`): C10-T03 renders it. This ticket
    only lists it in `data-bd-states`.
  - Producing `sources` on the server: C3-T02 (schema, validator), C8-T03
    (`Freshness.source/1`), C8-T04 (the real joins, including `queue` and
    `index`).

## Dependencies and blockers

- **Blocked by DESIGN-E8** (feature gate E8-D6). **S-9** is this ticket's sign-off
  item. It follows the S-9 default: "Same `.bd-mk.empty` marker with
  'unavailable' copy and the age". Kevin's answer may reopen the copy.
- **Predecessor MP-E8-C9-T03.** It exposes `relayout({live})`, `update()`,
  `headHTML(sec, D, S, H, sources)`, `onDataChanged`/`flushLive` with
  `pendingLive`, the history state `H` (`more` = `ctx.snap.history.more`,
  `total` = `ctx.snap.history.total`, `state`), and the interim header branch
  "`History <em>unavailable</em>` until C9-T13 brings the S-9 copy" (C9-T03
  "Section headers"). Transitively after C9-T02 (`computeLayout`, the interim
  empty marks with `source` and `state` fields) and C9-T01 (module layout:
  `state.js` with `S`, `ctx`, `fx`, `onReset`, `SEC = 36`, `gutW`; `life.js`;
  `clock.js` with `nowMs()`; `dom.js` with `esc`; `ctx.snap` (payload form) and
  `ctx.D` (from `intake`, which drops `sources` and `history`)).
- **Predecessor MP-E8-C8-T03.** It defines the `sources.<name>` mapping
  (`Freshness.source/1`: `ok | stale | incomplete | unavailable | disabled`,
  `observed_at`, `reason`), exports `fmtAge(ms)` and `fmtWhen(t, now)` from
  `build-home/offline.js`, toggles `.bd-root.stale` from `daemonView()`, and
  hands this ticket the `offline` parity cells and the end-to-end reconnect
  spec.
- **Shared contract.** C3-T02 schema v1: `sources` has the five keys `history`,
  `features`, `queue`, `agents`, `index`, each `{state: "ok"|"stale"|
  "incomplete"|"unavailable"|"disabled", observed_at: ms|null, reason:
  str|null}`; a missing key is a validation error; a part failure is a
  `sources` entry inside a valid snapshot; `set.sources` replaces the whole
  block. `history` is `{from, more, total, undated, tz}`.
- **Runs in parallel with** C9-T04..T11 and C10. C9-T12 waits for this ticket
  (it uses `states.js`). It touches the same module files as C9-T01, T02 and
  T03, so it rebases on them (README "File conflicts").
- **No unresolved research.**

## Verified starting point (`58854d4c8`)

**Product.** No home page and no `build-home/` directory exist yet. Everything
this ticket edits is PROPOSED by C2-T03, C3-T01, C3-T02, C8-T03 and C9-T01..T03.
What exists and is reused or avoided:

- `lib/aiur_web/components/layouts.ex:272-287` creates the `LiveSocket`, calls
  `liveSocket.connect()` and sets `window.liveSocket`. The end-to-end spec drives
  `window.liveSocket.disconnect()` / `connect()`.
- `browser/tests/support/browser-helpers.mjs:121-126` `reconnectLiveView(page)`
  drives the same two calls, but waits on `#worker-status[data-live-status]`,
  which only the test harness page has (`test/browser/assets/browser_harness.js:18-23`).
  C8-T03's handoff asks for `reconnectLiveView`; on `/build` it would time out,
  so the spec calls the two `liveSocket` methods directly and waits on
  `.bd-root.stale` instead (Interface notes 5).
- `lib/aiur_web/components/operator_control_center/dashboard_shell.ex:37-39`: the
  shell's "Offline" badge, hidden by `priv/static/dashboard.css:2114`
  (`[data-phx-main].phx-connected .status-badge-offline`) once the socket
  connects. It covers the one case this ticket cannot (the socket never
  connects, so the hook never mounts).
- **Patterns not to copy.**
  `lib/aiur_web/components/operator_control_center/build_order_status.ex:57`
  labels a stale source "Available", and
  `lib/aiur_web/operator_control_center/current_run_outcomes_presenter.ex:265`
  labels stale freshness "Healthy". Both present stale data as current. EC-07
  forbids that here; this ticket's mutation tests catch the same shape.
- `browser/package.json:10` the `test` chain, where the new script is appended
  (each spec has one `node scripts/run-browser-tests.mjs tests/<spec>` script,
  e.g. `:12` `test:shell`).

**Design (the specification).**

| Element | Where | Must match exactly |
| --- | --- | --- |
| Loading markup | J:1249–1253 `renderLoading()` | `content = null`; `#bd-vp` innerHTML = `.bd-lanes` › `.bd-skel-lanes` › `<i class="bd-skel-i">` + 3 `<i>`; then `.bd-skel` with 16 `<i>`; then `.bd-loading` › `.bd-spin` + `Loading build timeline…` (U+2026); each `.bd-skel-lanes i` gets inline `background: var(--surface-3)` (J:1252) |
| Loading gate | J:639 `if (S.loading) return renderLoading();`, J:1267 | `relayout()` draws the skeleton while loading; the board is not built |
| Skeleton styles | C:317–321, C:223 | `.bd-skel` padding `60px 90px 30px`, 4 columns, gap 16px; cells 92px, radius 12px, `--surface-3`, `bdPulse 1.4s ease-in-out infinite` (`50% { opacity: .35 }`), delays `.2s` (3n), `.4s` (4n+1); `.bd-skel-lanes` absolute `left 90px; right 16px; top 8px`, 4 columns, gap 16px; cells 30px, radius 9px |
| Lanes bar | C:169 | `.bd-lanes` sticky, height 46px, `--surface-2` 92%, `blur(5px)`, bottom 1px `--line` |
| Loading pill | C:322 | absolute centre (`50%`, `translate(-50%,-50%)`), flex, gap .6rem, padding `.55rem 1rem`, radius 999px, `--bg-2`, 1px `--line-strong`, `600 .74rem "JetBrains Mono"`, `--muted` |
| Spinner | C:323–324, H:720 | 16×16, radius 50%, 2px `--line-strong`, top `--accent`, `khSpin .8s linear infinite` (`to { transform: rotate(360deg) }`); `.bd-root.rm` → 3s |
| Reduced motion | C:298 | `.bd-root.rm .bd-skel i { animation: none }` |
| Empty marker, history | J:419 | `{ kind: "empty", y: SEC, h: 96, label: "No history yet", sub: "A new repo — nothing has merged. The first tickets are running in the Now band below." }`; section height `SEC + 104` |
| Empty marker, planned | J:499 | `{ kind: "empty", y: SEC, h: 96, label: "Nothing planned", sub: "The build queue is empty. " + NQL.length + " open tickets are not queued — promote some to keep agents busy." }`; height `SEC + 104` |
| Marker DOM | J:716–724 | `div.bd-mk.empty` › `<b>label</b><p>sub</p>`, both through `esc` (J:9, J:720); created once per uid `sec + ":m" + i` (J:716–722); `top = y`, `height = h`, `left = gutW()`, `width = cw − gutW() − 12` (J:723–724) |
| Marker styles | C:202, C:210–212 | `.bd-mk` absolute flex centre, `pointer-events: none`; `.empty` column, gap .3rem, `pointer-events: auto`; `b` .95rem; `p` margin 0, .82rem, `--muted`, centred, `max-width: 46ch` |
| Section headers | J:656–660; C:193, C:195, C:29 | `History <em>empty</em>`, `Planned <em>queue empty</em>`, `Not queued <em>N open · not in the queue</em>`; `.bd-sech` 36px, `700 .64rem` mono uppercase `--muted`; `em` 500, `--faint`, `white-space: nowrap` |
| Stale root | C:299–301, C:392, C:401 | glows paused, `grayscale(1) blur(5px)`, opacity .35; `.bd-gl` `--faint`; `.bd-now` border `--line-strong`, `--bg-2`; `.bd-now::before` `--line-strong`, no shadow; `.ag-active .bd-ag` no animation |
| Filter input | J:357, J:381 | `PLANL`, `NQL`, `histList` are filtered by `epicOk`, so the design shows "No history yet" when an epic filter hides every row |
| Mock timers | J:1261–1263 (650 ms), J:1565–1572 (600 ms) | mock only; the product ends loading on the first payload (C3-T01, C9-T01) |

The design datasets that reach these states (J:297, J:1142): `newrepo` (no
history; `nqN = 6`, J:267), `noqueue` (`plan = []`, J:258; 22 not-queued rows),
`offline` (render flag only; `live` data).

## Chosen design

### Source per section

`P` is `ctx.snap` (payload form; it carries `sources` and `history`). `D` is
`ctx.D` (from `intake`). `H` is C9-T03's history state.

| Board part | `sources` key | Rows |
| --- | --- | --- |
| History section (`#bd-sec-hist`) | `history` | `D.hist` |
| Planned section (`#bd-sec-plan`) | `queue` | `D.plan` |
| Not-queued section (`#bd-sec-nq`), and the count in "Nothing planned" | `index` | `D.nq` |
| Now band | `agents` | C9-T08 (not here) |
| List-view Live head (C9-T12, `sec = "now"`) | `agents` | `D.now` |
| Feature header | `features` | C10-T03 (not here) |

C8-T04 fills `queue` (from C7-T01) and `index` (from C7-T04; `:unsupported` →
`disabled`, reason `tracker_unsupported`).

### `sectionState(P, D, H, sec, filtered)`

`src = P.sources?.[key]`. A missing entry or a `state` outside the five C3-T02
values is read as `{ state: "unavailable", observed_at: null, reason: "unknown" }`.
It is never read as `ok`. (The server validator already rejects a missing key;
this is the client's defence, the same rule as C9-T02's interim check.)

`sec` is `"hist"`, `"plan"`, `"nq"` or `"now"` (key `agents`; only C9-T12's
list Live head passes it). Result `{ show, stale, src }`, first match wins:

| Condition | `show` |
| --- | --- |
| `src.state` is `disabled` and no loaded rows | `"disabled"` |
| `src.state` is `unavailable` and no loaded rows | `"unavailable"` |
| `src.state` is `incomplete` and no loaded rows | `"incomplete"` |
| loaded rows > 0 and `filtered` is empty | `"filtered"` |
| `sec === "hist"`, no loaded rows, and (`H.more === true` or `H.total > 0`) | `"window"` |
| no loaded rows | `"empty"` |
| otherwise | `"rows"` |

`stale` is true when `src.state` is `stale` or `incomplete`, or when it is
`unavailable`/`disabled` while rows are still loaded (the client holds rows from
before the source failed: they are cached, not current).

### Marker copy (`emptyMark`)

Every marker is the design's object: `kind: "empty"`, `y: SEC`, `h: 96`,
section height `SEC + 104`. Only `label` and `sub` change. The mark also keeps
C9-T02's `source` and `state` fields and adds `observed_at`, so the text can be
rebuilt when the age moves. `age` is `"read " + fmtAge(now − observed_at) + " ("
+ fmtWhen(observed_at, now) + ")"`, or `"no successful read recorded"` when
`observed_at` is `null` **or `now` (`nowMs()`) is `null`**. `why` is
`reasonText(src.reason)`.

| Section · `show` | `label` | `sub` |
| --- | --- | --- |
| hist · `empty` | No history yet | design string, unchanged |
| plan · `empty`, `index` ok/stale | Nothing planned | design string, with `N = NQL.length` (unchanged, including "1 open tickets") |
| plan · `empty`, `index` not ok/stale | Nothing planned | `The build queue is empty. The open-ticket index is unavailable, so the number not queued is unknown.` (C9-T02's interim text, kept) |
| hist · `unavailable` | History unavailable | `The build history could not be read (${why}). Last ${age}. This does not mean nothing has merged.` |
| plan · `unavailable` | Queue unavailable | `The build queue could not be read (${why}). Last ${age}. This does not mean the queue is empty.` |
| nq · `unavailable` | Open tickets unavailable | `The open-ticket index could not be read (${why}). Last ${age}.` |
| hist · `incomplete` | History incomplete | `The build history was only partly read (${why}). Last ${age}. This does not mean nothing has merged.` |
| plan · `incomplete` | Queue incomplete | `The build queue was only partly read (${why}). Last ${age}. This does not mean the queue is empty.` |
| nq · `incomplete` | Open tickets incomplete | `The open-ticket index was only partly read (${why}). Last ${age}.` |
| any · `disabled` | History disabled / Build queue disabled / Open-ticket index disabled (C9-T02 labels) | `${why}.` |
| hist · `filtered` | No history in the selected epics | `Clear the epic filter to see the loaded history.` |
| plan · `filtered` | No planned tickets in the selected epics | `Clear the epic filter to see the build queue.` |
| hist · `window` | No history in the loaded days | `Scroll up to load earlier days.` |

For an `empty` marker whose source is `stale`, the sub gets
` Last ${age}; this may be out of date.` appended. `nq · empty` and
`nq · filtered` keep the design (no marker; the header says `0 open`), because
the index answered. When every source is `ok` and the design case applies, the
mark object is exactly the design's (C9-T02 rule: no extra fields), so the
oracle compares it unchanged.

`reasonText(tag)`: `not_wired` → "not connected", `timeout` → "timed out",
`crashed` → "the reader crashed", `snapshot_unpublished` → "the daemon is
starting", `orchestrator_unavailable` → "the orchestrator is down",
`incomplete` → "the read was partial", `backfill_running` → "the history
backfill is still running", `structurally_invalid` → "the stored data is
malformed", `tracker_unsupported` → "this tracker has no open-ticket index";
`unknown`, `unavailable`, `null` or a non-string → "unknown cause" (the
cause-neutral word C9-T01 and C9-T12 use); any other string → itself, cut to 80
characters (the `disabled` reason may be config text). Everything goes through
`esc` at the existing J:720 call.

### Header notes (`headNote`)

C9-T03's `headHTML(sec, D, S, H, sources)` keeps its strings. For each section,
`headNote` returns text that is appended inside the first `<em>`, after ` · `:

| State | History / Planned / Not-queued em |
| --- | --- |
| `ok` | nothing (design string exactly) |
| `stale` | `stale, ${age}` |
| `incomplete` with rows | `partial, ${age}` |
| `unavailable` with rows | `unavailable, showing the ${age}` |
| `unavailable`/`incomplete`/`disabled`, no rows | the whole em is `unavailable`, `incomplete` or `disabled` (replaces `empty`, `queue empty`, `0 open · not in the queue`) |

So the history header never reads `empty` and the planned header never reads
`queue empty` unless the source answered `ok` or `stale`. The not-queued header
never shows `0 open` for an index that did not answer in full.

### Loading and the board-level failure

- `S.loading` is true until C9-T01's `firstPaint()` applies the first snapshot
  of this hook instance. While it is true, `relayout()` calls
  `fx.renderLoading()` (J:639). **If `#bd-vp` already holds the loading frame**
  (it has `.bd-skel` and `.bd-spin`, which is the case right after the dead
  render), `renderLoading()` returns without writing. Rewriting it would restart
  the `bdPulse` animation, a visible jump at mount. Otherwise it writes the
  design's markup, which is structurally equal to C3-T01's dead render (same
  nodes, classes and computed styles; the inline style text differs only in a
  trailing `;`).
- **The board never returns to the skeleton** in the same hook instance. A
  disconnect, a resync or a gap keeps the drawn board; stale mode (C8-T03) marks
  it (EC-06). A new hook instance (a remount) starts from the skeleton again.
- `renderUnavailable(reason)` keeps C9-T01's `defaultUnavailable` contract
  exactly: inside `.bd-loading`, remove `.bd-spin` and set the text with
  `textContent` to `Build timeline unavailable · <words>`, with C9-T01's word
  table (`not_wired` → "no data source", `timeout` → "timed out", `crashed` →
  "source crashed", `version` → "page out of date, reload", `invalid` →
  "invalid data", `unavailable` → "source unavailable", anything else →
  "unknown cause"). It adds one thing: each `.bd-skel i` gets inline
  `animation: none` (same inline-style approach as J:1252). A pulsing skeleton
  would say "loading", which is false. Keeping C9-T01's text keeps C9-T01's
  B2/B2b/N2 tests valid.
- `role="status"` on `.bd-loading` (client and dead render), so a screen reader
  hears "Loading build timeline…" and then the failure. It changes no pixel.

### Ages move

Markers are created once per uid (J:716–722). Whether C9-T03's live relayout
keeps mark nodes or not, `update()`'s marks loop sets `el.innerHTML` again when
the mark's text differs from `el.dataset.txt`, so a kept node never shows old
text.

The text itself is built in `computeLayout`, so the age moves only when the
layout is recomputed. `syncStates()` arms, once per mount and only when some
source is not `ok`, `ctx.life.every(30_000, tick)` (C9-T01 rule 4; the same
pattern as C8-T03's banner tick). `tick` returns when every source is `ok`;
else it calls `fx.requestLivePass()`. That is a new two-line export of C9-T03's
`render.js`: it sets `pendingLive.meta = true` and schedules
`ctx.life.frame("live", flushLive)`. `flushLive` runs when `meta` is set even if
both id sets are empty, and clears `meta`. So the age pass keeps all of C9-T03's
guards (no move under a finger, a scrollbar drag or a snap) and the scroll
anchor. The live fixture (all `ok`) arms no interval, so C9-T01's B11 count of
two intervals is unchanged.

`now` is `nowMs()` from C9-T01's `clock.js` (the server clock advanced by
`performance.now()`). The browser wall clock is never the data clock.

### Sources-only diffs

C9-T03's `onDataChanged(msg)` queues a live pass only for upsert or remove ids.
A diff whose only change is `set.sources` or `set.history` would leave the
markers and headers wrong. This ticket adds: when `msg.set` has `sources` or
`history`, set `pendingLive.meta = true` before the guard check.

### Interface this ticket exposes

| Name | Caller |
| --- | --- |
| `fx.renderLoading()` | `relayout()` (C9-T03) while `S.loading` |
| `fx.renderUnavailable(reason)` | C9-T01 `showServerState` and `receive` (existing calls) |
| `sectionState(P, D, H, sec, filtered)` | `computeLayout` (C9-T02), `headHTML` (C9-T03), C9-T12 `secHead` |
| `emptyMark`, `headNote`, `reasonText` | C9-T02, C9-T03; `headNote`, `reasonText` also C9-T12 |
| `ageText(src, now)` | C9-T12 list heads; `emptyMark` |
| `syncStates()` | `relayout()` (C9-T03) after the loading gate |
| `ctx.bdStates`, `#build-root[data-bd-states]` = sorted list of non-ok sources over all five keys, e.g. `"history:unavailable index:stale queue:disabled"`, or `""` | tests, C1-T02 ready checks; rewritten by C9-T01's `writeOwnData()` |

## Implementation steps

1. **`states.js`** (PROPOSED `src/priv/static/build-home/states.js`). Write the
   functions above. Import `ctx`, `fx`, `onReset`, `S`, `SEC` from
   `./state.js`, `nowMs` from `./clock.js`, `$`, `$$`, `esc` from `./dom.js`,
   and `fmtAge`, `fmtWhen` from `./offline.js` (C8-T03). Port J:1249–1253 line
   for line into `renderLoading`, adding only `role="status"` on the pill and
   the "already showing" early return. Reset the "tick armed" flag with
   `onReset`. Add `import "./states.js"` to `hook.js`.
2. **Dead render** (C3-T01's HEEx for `#bd-vp`): add `role="status"` to
   `.bd-loading`, and the same attribute to C3-T01's U1 expectation. This is the
   only server-side edit.
3. **`computeLayout`** (C9-T02's `layout.js`): replace the interim
   source-aware check with `const hst = sectionState(P, D, H, "hist", histList);
   if (hst.show !== "rows") { hs.marks.push(emptyMark("hist", hst, mctx)); hs.h =
   SEC + 104; }`, the planned one the same way with `PLANL`, and the
   not-queued one when the state is `unavailable`, `incomplete` or `disabled`.
   `mctx` carries `NQL.length`, the `index` state and `nowMs()`. The Gantt
   branch (J:420) stays after the marker test, as in the design.
4. **`headHTML`** (C9-T03's `render.js`): replace the interim `unavailable`
   branch with `headNote`, for all three sections.
5. **`relayout()`** (C9-T03): call `syncStates()` right after the loading gate,
   so it also runs in list view.
6. **`update()` marks loop** (C9-T03): store the text in `el.dataset.txt`; when
   the new text differs, set `innerHTML` again. Same `esc` calls.
7. **Live pass** (C9-T03): add `export function requestLivePass()`, register it
   as `fx.requestLivePass`, add the `meta` flag to `pendingLive`, the
   `set.sources`/`set.history` rule in `onDataChanged`, and the `meta` term in
   `flushLive`'s "nothing pending" test.
8. **`writeOwnData()`** (C9-T01's `hook.js`): add
   `if (ctx.bdStates != null) el.dataset.bdStates = ctx.bdStates`.
9. **Fixture.** In C3-T01's fixture source, append `degraded` to the fixed
   `datasets/0` list (C3-T01 B5 and C3-T02's "fixtures validate" list gain the
   name). It is `live` with `sections.hist = []`, `sections.plan = []`,
   `history` = live's block with `more: false, total: 0, undated: 0`, and
   `sources`: `history` unavailable (`observed_at = NOW − 12 min`, reason
   `timeout`), `queue` disabled (reason `build queue is off in .aiur/config`),
   `index` stale (`NOW − 3 h`), `agents` and `features` ok. One function
   clause; no new JSON file. It must pass `Payload.validate/1`.
   Add the named diff body PROPOSED
   `src/test/fixtures/build_home/diffs/queue-unavailable.json` (the `?name=`
   form of C3-T02's `/build-control/diff`, as C9-T08 uses it): the five `sources`
   entries of `live` with `queue` set to unavailable, reason `timeout`.
10. **Tests** as in "Verification". Add `"test:build-home-states": "node
    scripts/run-browser-tests.mjs tests/build-home-states.browser.spec.mjs"` to
    `src/browser/package.json` and append it to `test` (`:10`).

## Non-happy paths

Each case: input → expected → the test that proves it (Verification IDs).

- **EC-01, first paint.** Dead render + hook mount before the snapshot → the
  skeleton, unchanged and not rewritten, no `#bd-content` → B1, B1b, P4.
- **Snapshot never comes** (source hangs) → C3-T02's bounded read replies
  `unavailable` (about 5 s, C9-T01 N1) or C3-T01 sets `unavailable/timeout`
  after 15 s → pill "Build timeline unavailable · source unavailable" or "· timed
  out", no spinner, cells still → B2, E3.
- **Socket never connects.** The hook never mounts; the skeleton stays and the
  shell badge says "Offline" (`dashboard_shell.ex:37-39`). Not fixable here;
  recorded.
- **EC-02, new repository.** `history` ok, no rows, `more: false` → "No history
  yet" exactly → P1, B3.
- **History exists but none loaded** (`more: true` or `total > 0`) → "No history
  in the loaded days", never "No history yet" → B6.
- **History backfill running** (`incomplete`, no rows; C8-T04 "History
  incomplete") → "History incomplete", never "No history yet" → B18.
- **Epic filter hides every row** → the filtered copy, never "No history yet" or
  "The build queue is empty" → B7.
- **EC-03, queue empty / disabled / unavailable** → three different markers and
  headers; disabled never collapses into unavailable (AGENTS.md "collapsed
  cause") → P2, B4, B5.
- **Index unavailable while the queue is empty** → no count in the sub (never
  "0 open tickets") → B8.
- **EC-07, stale source with rows** → header `stale, read 3 h ago (11:20)`; with no
  rows the marker sub says "this may be out of date" → B10, B11.
- **A source fails after rows were drawn** (`set.sources` flips `queue` to
  `unavailable`, rows kept) → rows stay, header `unavailable, showing the read
  12 min ago (14:08)`; the sources-only diff relayouts → B12, E6.
- **`observed_at` null, or `nowMs()` null** → "no successful read recorded";
  never `0 min`, `—`, or the current time → B13 (mutation).
- **Missing or unknown source entry** (client defence) → unavailable "unknown
  cause", never ok → B14.
- **EC-06, socket offline** → the cached board stays, `.bd-root.stale`, banner
  (C8-T03); the skeleton never comes back; markers stay as they were → E1, E5.
- **Hostile reason string** (`<img src=x onerror=…>`) → shown as text through
  `esc`; no element created → B16.
- **Long copy at 390 px.** The header em is `nowrap` (C:29). The appended notes
  are short (`stale, read 12 min ago (14:08)`); the marker `p` wraps at 46ch → P5.
- **Reduced motion.** Skeleton pulse off and spinner 3 s come from C:298/324 under
  `.bd-root.rm` (set by C9-T01) → covered by C1-T03's `loading.spin` cell.
- **Read-only dashboard, auth.** No write; nothing here depends on
  `writable`. Reasons never contain secrets: the server sends fixed tags or
  config text (C8-T03, C3-T01).

## Compatibility and rollout

- No configuration key, CLI flag or environment variable. No user-facing docs:
  the page is not reachable before C12-T01, which documents the home page.
- The `degraded` dataset is test-only (C3-T01's fixture source is loaded with
  `Code.require_file` and never ships).
- Rollback: revert the commit. The board falls back to C9-T02's interim marks,
  C9-T03's interim headers and C9-T01's default unavailable pill.

## Pixel parity

**Design elements reproduced:** `renderLoading` markup (J:1249–1253); `.bd-skel`,
`.bd-skel i`, `.bd-skel-lanes`, `.bd-lanes`, `.bd-loading`, `.bd-spin`,
`khSpin`, `bdPulse` (C:169, 223, 317–324; H:720); `.bd-mk.empty` with `b` and `p`
(J:419, 499, 716–724; C:202, 210–212); `.bd-sech em` (C:193, 195);
the `.bd-root.stale` effects (C:299–301, 392, 401).

Checks through C1-T02's harness (`openParityPair`, `expectDesignParity`), with
the frozen clock and `PARITY_FLOOR`:

| # | Dataset | Region | Matrix |
| --- | --- | --- | --- |
| P1 | `newrepo` | `#bd-sec-hist` (header and "No history yet" marker) | 3 viewports × 2 themes × 2 palettes |
| P2 | `noqueue` | `#bd-sec-plan` ("Nothing planned · 22 open tickets…") | same |
| P3 | `offline` | `#bd-offline`, then the whole viewport (stale glows); and `live` → `#bd-offline` empty on both sides | same; C8-T03's cells, enforced here. The band clock is C9-T08's cell |
| P4 | loading | `#bd-vp`. Design: clock installed before load, never advanced past 599 ms (J:1565). Product: `productUrl("hold")`, captured **after** `#build-root[data-bd-mounted]` (C9-T01) and while `[data-build-state=loading]` | C9-T01 already gates this cell; this ticket keeps it green with `role="status"` and the no-rewrite rule |
| P5 | `degraded` (no design side) | geometry only: each `.bd-mk.empty` has the same `top`, `left`, `width`, `height` as the design's `newrepo` marker in the same cell, and the same computed font, colour and `max-width` on `b` and `p`; `#bd-vp.scrollWidth === clientWidth` at 390 | 1440 and 390, dark |

P1–P3 move from C1-T02's report-mode matrix into the enforced spec for these
regions. C1-T02's ready rule (`#build-root[data-bd-mounted]` and
`[data-bd-paging="idle"]`, R-G7) applies to P1–P3; P4 uses the loading rule
from C3-T01. The new strings (the S-9 copy, the incomplete, filtered and window
markers, the header notes) have no design pixel. They are added to C1-T02's
allowlist as `copy` entries with status `pending-sign-off` citing S-9 (R-G6),
as C9-T03 did for its header strings, and Kevin approves or replaces them in
C12-T08.

## Verification

**Module spec** (PROPOSED `src/browser/tests/build-home-states.browser.spec.mjs`).
It loads `/build-home/states.js` (and `/build-home/render.js` for `headHTML`)
as modules on a blank fixture page with `page.clock.install({ time: NOW })`
(NOW = 14:20) and a minimal `#bd-vp` host, and calls the functions with
hand-built `P`/`D`/`H` (as C9-T01's and C9-T03's specs import modules). Every
row lists the mutation that must make it fail (AGENTS.md).

| # | Input | Expected | Fails when |
| --- | --- | --- | --- |
| B1 | empty `#bd-vp`; `renderLoading()` | `vp.innerHTML` equals the HTML the design's own `renderLoading` (J:1251–1252) leaves in its `#bd-vp`, with `role="status"` added on `.bd-loading`; 16 `.bd-skel i`; 4 lane cells with inline `--surface-3` | the port drifts (one `<i>` fewer) |
| B1b | `#bd-vp` holds the dead-render frame; mark a probe property on the first `.bd-skel i`; `renderLoading()` | the same element (probe still set) | always rewrite (pulse restarts) |
| B2 | loading frame; `renderUnavailable("timeout")` | no `.bd-spin`; text "Build timeline unavailable · timed out"; every `.bd-skel i` has `animation-name: none` | keep the spinner; keep the pulse; keep the "Loading…" text |
| B3 | hist, `history` ok, no rows, `more: false`, `total: 0` | mark equals the design object exactly (no extra fields); section height 140 | — (port guard, not counted as coverage) |
| B4 | plan, `queue` unavailable (reason `timeout`, `observed_at NOW−12 min`) | label "Queue unavailable"; sub contains "timed out", "read 12 min ago (14:08)", "does not mean the queue is empty"; header em `unavailable`; no "Nothing planned", no "queue empty" | map unavailable to the empty branch |
| B5 | plan, `queue` disabled | label "Build queue disabled"; sub is the reason | collapse disabled into the unavailable copy |
| B6 | hist, `history` ok, no rows, `more: true` | "No history in the loaded days" | drop the `window` row |
| B7 | hist rows loaded, `filtered = []`; plan rows loaded, `PLANL = []` | the two filtered labels | drop the `filtered` row (design copy returns) |
| B8 | plan empty, `index` unavailable, `NQL = []` | sub has no digit before " open tickets"; contains "number not queued is unknown" | use `NQL.length` (renders "0 open tickets") |
| B10 | `headHTML("hist", …)` with rows, `history` stale `NOW−3 h` | first em ends ` · stale, read 3 h ago (11:20)` | drop the stale note; use `now` as `observed_at` ("less than 1 min ago") |
| B11 | plan empty, `queue` stale | sub ends "this may be out of date." | drop the stale suffix |
| B12 | `headHTML("plan", …)` with rows and `queue` unavailable at `NOW−12 min` | em contains "unavailable, showing the read 12 min ago (14:08)"; `sectionState(...).show === "rows"` | hide rows on unavailable, or show the `ok` header |
| B13 | hist, `history` unavailable, `observed_at: null`; and `observed_at` set with `nowMs()` null (no `setNow`) | sub contains "no successful read recorded" in both; no `0 min`, no `—`, no `14:20` | **AGENTS.md unknown-path mutation:** replace the null branch with `0`, with `"—"`, and with `now`; each must fail |
| B14 | `P.sources = {}`; and `queue: {state: "weird"}` | both read as unavailable, "unknown cause" | default a missing entry to `ok` |
| B16 | reason `<img src=x onerror="window.__xss=1">` | shown as text; `window.__xss` undefined; no `img` in `#bd-vp` | skip `esc` on `sub` |
| B17 | `computeLayout` + `update()` with `queue` unavailable at `NOW−12 min`; `page.clock.runFor(60_000)` | the same marker element (identity kept) now reads "read 13 min ago (14:08)" | drop the age tick, or drop the `dataset.txt` refresh |
| B18 | hist, `history` incomplete (reason `backfill_running`), no rows | label "History incomplete"; sub contains "the history backfill is still running"; never "No history yet" | treat `incomplete` like `ok` (C9-T02's interim rule) |

B9 and B15 are retired: the band empty state is C9-T08's (its B-6), and the
disconnect check needs a drawn board, so it is E5.

**End-to-end spec** (same file, `describe("fixture routes")`), opened with
C1-T02's `productUrl(dataset)` (`GET /build-fixture/<dataset>`, then `/build`,
C3-T01):

| # | Steps | Expected | Fails when |
| --- | --- | --- | --- |
| E1 | `live`; wait for ready; count `.bd-card`; `liveSocket.disconnect()`; `page.clock.runFor(600)` (past C8-T03's 500 ms debounce) | `.bd-root.stale`, `#bd-offline .bd-offline` visible, same `.bd-card` count, no `.bd-skel`; then `connect()` → banner gone, `.stale` removed | the C8-T03 handoff spec (EC-06) |
| E2 | `degraded` | `[data-bd-states="history:unavailable index:stale queue:disabled"]`, still present after a server patch (click `#nav-toggle`); history marker "History unavailable"; planned marker "Build queue disabled"; not-queued header has `stale, read 3 h ago` | the server→client path for `sources`; the `writeOwnData` line |
| E3 | `unavailable` (C3-T01: reason `unknown`) | `[data-build-state=unavailable]`; pill "Build timeline unavailable · unknown cause"; no `.bd-spin`; `.bd-skel i` not animated | `renderUnavailable` not registered (pulse keeps running) |
| E4 | `hold`, then axe on `#bd-vp` | `.bd-loading[role=status]`; no violations | the role |
| E5 | `newrepo`; wait for ready; `liveSocket.disconnect()`; `page.clock.runFor(600_000)` | "No history yet" marker still there; no `.bd-skel`; `#bd-content` still there | set `S.loading` again on disconnect |
| E6 | `live`; wait for ready; `GET /build-control/diff?name=queue-unavailable` (a diff whose only key is `set.sources`, `queue` unavailable at `NOW−12 min`) | planned header gains `unavailable, showing the …` within one frame; no card replaced | drop the `set.sources` rule in `onDataChanged` |

**Parity:** P1–P5 above, in the enforced parity spec.

Commands (isolated HOME, per the "mix test clobbers agent-token" note; the
ExUnit file is C3-T01's PROPOSED `test/aiur_web/live/build_live_test.exs`):

```bash
env -C /path/to/aiur/src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur_web/live/build_live_test.exs
env -C /path/to/aiur/src/browser npm run test:build-home-states
env -C /path/to/aiur/src/browser npm run parity:matrix   # report mode; P1–P4 cells green
```

**Mutation check (AGENTS.md).** For each row with a mutation: apply it in a
worktree, confirm `git status --porcelain` shows only that hunk, run the spec,
see it fail, restore, see it pass. Put the commands and results in the PR body,
one line per test.

**Manual (AGENTS.md "Manual testing").** After C12-T01, on `scripts/aiurdev
--test` in the wrapper tmux: open the home page, run `aiurdev stop` from a fresh
shell, and confirm the cached board stays with greyed glows and the banner.
C12-T01 runs it; this ticket lists the steps.

## Completion and handoff

- [ ] `states.js` with the functions and copy tables above; B1–B18 (except the
      retired B9, B15) green.
- [ ] `computeLayout`, `headHTML`, `relayout`, `onDataChanged`/`flushLive`,
      the marks loop and `writeOwnData` call `states.js` as in the steps; no
      literal "No history yet" or "Nothing planned" outside `states.js`.
- [ ] E1–E6 green; P1–P4 match the design; P5 geometry matches.
- [ ] Every listed mutation fails, with commands in the PR body.
- [ ] The new strings are `copy` allowlist entries, status `pending-sign-off`,
      citing S-9.
- [ ] No CSS rule added; no design string changed for `newrepo`, `noqueue`,
      `offline` or loading.

**Handoffs.**

- **C9-T01:** one line in `writeOwnData()` (step 8), made in this PR (R-G4).
  `fx.renderUnavailable` and `fx.renderLoading` are replaced at import time; no
  other change.
- **C9-T02:** its interim empty-mark table is replaced by `sectionState` and
  `emptyMark`; its labels and the "index unavailable" sub are kept.
- **C9-T03:** `requestLivePass`, the `meta` flag, `syncStates()` in
  `relayout`, `headNote` in `headHTML`, the `dataset.txt` refresh.
- **C9-T12:** calls `sectionState(P, D, H, sec, list)` (including
  `sec = "now"`), `headNote`, `reasonText` and `ageText` for its list heads, so
  the list and the board use one S-9 copy.
- **C12-T08:** the S-9 strings are in the sign-off package.
- **Sources:** tickets/README.md row C9-T13 and rows C8-T03, C9-T01..T03;
  chunks.md C9; plan §8 (EC-01, 02, 03, 06, 07); DESIGN-E8 S-9, S-16;
  C3-T01 (load state, `hold`/`unavailable` datasets, fixed dataset list),
  C3-T02 "Messages (schema v1)", C8-T03 "Server: source entries" and "Client:
  `offline.js`", C8-T04 "Parts and their failure states", C9-T01 "Module
  layout" and "`hook.js`", C9-T02 "Interim source-aware empty marks", C9-T03
  "Live mode of `relayout`" and "Section headers", C9-T08 rules table; J, C and
  H lines cited above.

## Interface notes (mismatches with neighbour rows)

1. **EC-06 and EC-07 are owned twice** (C8-T03 and this row). Split used here:
   C8-T03 owns the daemon signals, banner and root class; C9-T08 owns the band
   clock and band empty text; this ticket owns the per-section board states and
   enforces C8-T03's parity cells and end-to-end spec. The row's
   "`.bd-root.stale` styling" needs no code here: the CSS is C2-T04's and the
   toggle is C8-T03's.
2. **The board-level failure pill.** C3-T01's handoff gives "render
   `unavailable` in the `.bd-loading` pill with the S-9 default copy pattern" to
   C9-T01, and C9-T01 ships `defaultUnavailable` with "C9-T13 replaces it". This
   ticket replaces it but keeps C9-T01's text and word table; it only stops the
   pulse.
3. **`incomplete` and `features`.** The README row and the first draft of this
   ticket named four sources and four states. C3-T02 has five keys and five
   states. C9-T02's interim rule draws the design mark for an empty `incomplete`
   list; this ticket overrides that, because an empty partial read is not "No
   history yet".
4. **Clock.** Settled 2026-10-08: C9-T01 `clock.js` exports `nowMs()` and
   `stampMs()` only (no `now`, no `serverNow`); C8-T03 and this ticket import
   `nowMs`.
5. **Reconnect helper.** Settled 2026-10-08: C8-T03 drops the
   `reconnectLiveView` / `?fixture=` hand-off; E1 uses `productUrl("live")` and
   direct `window.liveSocket` calls (R-G7).
6. **List view.** Settled 2026-10-08: C9-T12 uses this ticket's S-9 copy
   (`sectionState`, `headNote`, `reasonText`, `ageText`); this ticket exports
   `ageText` and accepts `sec = "now"`.
7. **Dead-render attribute.** `role="status"` on `.bd-loading` changes C3-T01's
   U1 structure expectation; this ticket edits both (R-G4). Settled 2026-10-08:
   C1-T03's DOM inventory ignores that `role="status"`.

## Decisions made without the owner

1. **S-9 default applied to three board sources**, not two: history, queue and
   the open-ticket index. Each one can be unread, and each would otherwise
   render a plausible empty or zero. The agents source is C9-T08's.
2. **Disabled, incomplete and unavailable have different copy.** They have
   different causes (config, partial read, failure); AGENTS.md forbids
   collapsing them.
3. **Rows outlive a failed source.** When a source goes unavailable after rows
   were drawn, the rows stay and the header says they are from the last read.
   Hiding them would turn "unknown" into "empty".
4. **The design's "No history yet" and "The build queue is empty" are replaced
   when an epic filter hides every row**, and when history exists but is not
   loaded. The design shows them in those cases (J:357, J:381), which would be
   false. The datasets the design shows (`newrepo`, `noqueue`) keep the design
   strings exactly.
5. **"1 open tickets" stays** as in the design (J:499). Changing the grammar is a
   pixel change Kevin has not asked for.
6. **The whole-board failure keeps C9-T01's pill text** and the skeleton, but
   stops the pulse. There is no retry button: C3-T01's state machine ends a
   mount in `unavailable`, and a reload or rejoin is the retry (C9-T01
   decision 12).
7. **The skeleton never returns after the first snapshot** in the same hook
   instance. A disconnect is stale mode, not loading. **And it is never
   rewritten over the dead render**, so the pulse does not restart at mount.
8. **Reason tags get plain words** for the known tags; unknown tags read
   "unknown cause"; other strings are shown escaped and cut to 80 characters.
9. **Ages refresh every 30 s** through a `ctx.life.every` armed only while a
   source is not `ok`, as C8-T03's banner does, and through C9-T03's live pass,
   so the refresh keeps C9-T03's scroll guards.
10. **`role="status"` on the loading pill.** Accessibility is never cut; no pixel
    changes.
11. **No new fixture file.** `degraded` is derived from `live` in the fixture
    source.
12. **Complexity 3, not the row's 2:** three sources, seven states, edits in
    four neighbour modules, and three test suites with mutation checks.

## Review log

Adversarial review, 2026-10-08 (sources: runtime `58854d4c8`, design-source,
README rows, chunks.md, C3-T01, C3-T02, C8-T03, C8-T04, C9-T01, C9-T02, C9-T03,
C9-T08, C9-T12). Product cites all opened and correct; design values all
checked and correct.

1. Removed the band scope (`bandEmptyHTML`, step 6, B9, C9-T08 handoff): C9-T08
   already owns `bandEmpty` and "Agent state unavailable" (its B-6). Fixed the
   non-goal that gave the band "cached HH:MM" to C8-T03; it is C9-T08's
   `bandClock`.
2. Used C9-T01's real seams: `fx.renderUnavailable(reason)` (not a new
   `renderBoardUnavailable(vp, reason)`), `fx.renderLoading`, `nowMs()` from
   `clock.js`, `esc` from `dom.js`, `ctx.snap`/`ctx.D`, `import "./states.js"`.
   Dropped the invented `data-bd-mounted` (C9-T01 already writes
   `data-build-home-hook="mounted"`) and the "export one server-time function"
   handoff (it exists).
3. Kept C9-T01's unavailable pill text and word table instead of new copy, so
   C9-T01's tests stay valid; fixed E3's expected text (the `unavailable`
   dataset's reason is `unknown`, not `timeout`).
4. Added the `incomplete` state (C3-T02/C8-T03/C8-T04) and the `features` key;
   added B18. Fixed "four keys" to five.
5. Fixed the age refresh: the marker text is built in `computeLayout`, so
   rewriting `dataset.txt` alone could never move the age. It now runs through
   a C9-T03 live pass (`requestLivePass`, `meta` flag) on a 30 s `ctx.life`
   tick armed only when a source is not `ok` (keeps C9-T01 B11's two-interval
   count). The previous plan hijacked shell.js's 250 ms poller.
6. Fixed the sources-only diff seam: it is C9-T03's `onDataChanged`/`flushLive`,
   not C9-T01's intake; added E6.
7. `data-bd-states` is now rewritten in `writeOwnData()`, because LiveView
   drops hook-owned `data-*` on every server patch; E2 asserts it after a patch.
8. `renderLoading` no longer rewrites the dead render (that restarted the
   pulse); added B1b. Fixed B1's expected string (the inline styles are set by
   J:1252, so J:1251 alone is not the result) and "byte-equal" wording.
9. Header notes now go through C9-T03's pure `headHTML`; B10/B12 call it.
10. Moved B15 (needs a drawn board) to E-spec as E5; P3 no longer claims C9-T08's
    `.bd-now-h` cell and gains C8-T03's `live` empty-banner cell; P4 marked as
    C9-T01's gate.
11. Interface notes rewritten: removed the stale "C8-T04 does not fill
    queue/index" and "serverNow private" notes; added the clock-name, reconnect
    helper, list-view and C1-T03 notes. C9-T12 handoff no longer orders it to
    call `sectionState`.
12. Fixture: `degraded` is appended to C3-T01's fixed dataset list and carries
    a full `history` block so it validates. Unknown reason fallback unified to
    "unknown cause". Fixed "active logo" (C:401 is `.ag-active .bd-ag`).
13. E6 drives the sources-only diff through C3-T02's `/build-control/diff`
    with a named body (`?name=queue-unavailable`, the form C9-T08 uses); the
    stock `diff` action only bumps one plan row's `pct`.
- Reconciliation 2026-10-08 (coordinator): exports `ageText` and accepts `sec = "now"` for C9-T12, C9-T12 uses this ticket's S-9 copy (non-goal, handoff, parallelism fixed), edits to C9-T01/C9-T02/C9-T03/C3-T01 made in this PR (R-G4), allowlist `copy` kind with `pending-sign-off` (R-G6), ready condition `data-bd-mounted` and `productUrl` (R-G7), interface notes 4–7 settled.
