---
ticket_id: MP-E8-C1-T01
feature_id: MP-E8
chunk_id: MP-E8-C1
bucket: 2-platform
title: Design fixture exporter
status: blocked
blocked_by: [DESIGN-E8]
complexity: 2
design_gate: DESIGN-E8
owns_edge_cases: [EC-20]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C1-T01 — Design fixture exporter

## Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history home page), chunk C1
  (parity harness and design fixtures). Level 0: the first E8 merge on the
  critical path (tickets/README.md "Dependency order"). Owns EC-20 for the
  fixtures: frozen clock and time zone (README row "Owns").
- **User value:** "pixel-perfect" becomes a machine check. The design file and
  the product can render the *same* data at the *same* clock, so every visual
  ticket after this one can prove itself by diff (plan §9 K-1).
- **Deliverable:**
  1. A vendored, unedited copy of the Claude Design export in the product repo.
  2. A Node script that runs the unmodified `build.js` data generator in a `vm`
     context and writes five JSON fixtures (`live`, `dense`, `newrepo`,
     `noqueue`, `offline`) plus the usage sets, with `NOW` = 2026-10-07 14:20
     America/Los_Angeles.
  3. A manifest with the sha256 of `build.js`, `build.css` and the HTML. A
     `--check` mode fails when the design or a fixture changes without a
     re-export.
  4. A mapping function (raw export → payload). In this ticket it is the
     identity plus explicit encodings. C3-T02 takes it over.
  5. A reusable, exported `vm` loader for `build.js`. C3-T03 reuses it to expose
     `readURL`/`writeURL`/`S` (C3-T03 step 4), so it takes the names to expose
     and context overrides as arguments.
- **Non-goals:** no payload schema v1 (C3-T02), no LiveView, DataSource or
  fixture route (C3-T01), no screenshots (C1-T02), no conversation mock data
  (`CV`, J:1285: it uses `Math.random` and is not part of `build()`; C11-T03
  extends this exporter for `convo(t)` / `conversations.json`), and no
  edit of any design file.

## Dependencies and blockers

- **Blocked by DESIGN-E8** (Kevin's explicit go). No other predecessor.
- **No OQ-E8 or S-n item applies.** No owner question changes the fixture data.
- **Can run at the same time as** C2-T03, C4-T01 and C5-T01 (level 0, different
  files: tickets/README.md "What may run concurrently").
- **Dependents:** C1-T02 (serves the vendored design and compares it with the
  product), C3-T01 (the fixture DataSource serves these JSON files), and C3-T02
  (owns the mapping function and the schema from then on).
- **Shared contracts:** none. MP-E8 owns no shared contract
  (CONTRACT-REQUESTS.md).

## Verified starting point (`58854d4c8` product, design etag 1791431544512943)

**Design source** (research pack `bucket-2-platform/MP-E8/design-source/`,
imported 2026-10-08; `J` = `assets/build.js`, 1577 lines):

- J:5–6 the whole file is one IIFE (`(function () { "use strict"; …`). Nothing
  is exported except `window.AiurBuild` (J:1559–1576).
- J:11 `const NOW = new Date(2026, 9, 7, 14, 20).getTime();`. This is a
  **local-time** constructor. Every date in `build()` is built the same way
  (for example J:126, 131–132, 145), so the data depends on the process time zone.
- J:82–95 `MODELS`, `AST`, `CX`, `PTS`, `EST`; J:96–111 `GENERAL`, `POOL`,
  `FPOOL`; J:113 `function build(kind)`; J:203 `ACTIVE`; J:213 `PLAN`;
  J:294 the return value is
  `{ kind, epics, features, order, all, byId, hist, now, plan, nq, children, counts, failedId }`.
- J:296–297 `cache` and `dataFor(demo)`. Any unknown kind, `"offline"`
  included, maps to `"live"`.
- `build()` uses only the seeded `rng` (J:27). `Math.random` (J:1461, 1497,
  1512) and `Date.now()` (J:1516) appear only in the modal mock, and
  `performance.now()` (J:882–885, 1238) only in animation, so the data is
  deterministic for a fixed zone (grep of J for `Math.random`, `Date.now`,
  `new Date()`, `performance.now`).
- `offline` is a render flag only: J:665 (`"cached " + fmtT(NOW - 6 * 6e4)`),
  J:1066 (banner "last heartbeat 6 min ago (14:14)"), J:1067 (`root.stale`),
  J:1139 (`.bd-daemon.off`, "Daemon offline").
- J:989 logo path constants (`CL`, `CX_`, `KI`, `DS`), J:991–1012 `PSETS`
  (keys `2`, `4`, `7`). The default is `S.models = 4` (J:303).
  The API rows (GitHub core 5 %, "4,736 of 5,000", reset 37m; GraphQL 0 %,
  "4,998 of 5,000", 20m; Search credits "90.0K", 22d) are **literals inside
  `renderUsage`** (J:1031–1036), not data. No `PSETS` row uses `none: true`
  (searched for it; J:1024 handles that case but no fixture reaches it).
- The anchor text `  window.AiurBuild = {` occurs exactly once (J:1559), and
  `dataFor`, `NOW` and `PSETS` are in scope there.

**Feasibility probe (2026-10-07, Node v24.18.0, scratch copy, not committed).**
Insert `window.__E8 = { dataFor, NOW, PSETS };` before the anchor and run the
script in `vm.createContext({ window, document: {}, location: { search: "" }, history: {} })`:

| Dataset | all | hist | now | plan | nq | features | failedId | compact JSON bytes of `data` |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| live | 332 | 248 | 8 | 54 | 22 | 2 | AIUR-595 | 114,925 |
| dense | 1384 | 1300 | 8 | 54 | 22 | 12 | AIUR-1286 | 474,331 |
| newrepo | 64 | 0 | 4 | 54 | 6 | 2 | null | 25,767 |
| noqueue | 278 | 248 | 8 | 0 | 22 | 2 | AIUR-595 | 92,723 |

- Byte counts are `JSON.stringify` of the exported `data` (the return value
  without `kind`, `all`, `byId`; `children` and `counts` kept), re-measured by
  the reviewer on 2026-10-08 with Node v24.18.0. `dataFor("offline") ===
  dataFor("live")` (the same cached object).
- Under `TZ=America/Los_Angeles`, `NOW` = `1791408000000` (`2026-10-07T21:20:00.000Z`).
  Under `TZ=UTC`, `NOW` = `1791382800000`. The counts stay the same, but the
  content hash changes (live `6e7dbf2b…` vs `2790764a…`). So the zone guard is needed.
- **`JSON.stringify` loses data silently.** `features.pag.to` is `Infinity`
  (J:132, an open feature) and is written as `"to": null`. That is the same
  value as "unknown", which AGENTS.md forbids. It is the only non-finite value
  in each of the four datasets, there is no `undefined` value and no `-0`, and no
  string value equals `"Infinity"` (so the string encoding below decodes without
  ambiguity today).
- **Cross-realm objects.** Objects built inside the `vm` context have that
  context's `Object.prototype`. `assert.deepStrictEqual(JSON.parse(…), data)`
  therefore fails ("same structure but are not reference-equal") even when the
  values are equal. `structuredClone(data)` first gives current-realm objects
  and keeps `Infinity`; the comparison then passes (probe, 2026-10-08).
- `start` is a non-integer millisecond value on 184 `hist`/`now` rows in `live`
  (324 rows have at least one non-integer `start`/`end`/`created`).
  Plan and not-queued rows have **no** `start` key (76 rows), hist rows have no
  `est`, and `agent.state` is `null` on history rows. These are
  absences, and the export must keep them as absences.
- `all` = `hist ++ now ++ plan ++ nq` in insertion order (J:179 `add`, called in
  that order). `byId` is an index of `all`.
- `sha256` prefixes: `build.js` `b1a13092f3c4947d`, `build.css`
  `cd5cbab8ec9461e1`, `Aiur Dashboard.html` `e0e01de831fb196e`.

**Product code to reuse (`/home/everdred/github/everdred/aiur-worktrees/runtime/src` at `58854d4c8`):**

- `src/browser/scripts/check-vendored-elk.mjs:30` `sha256` helper, `:135`
  "hash does not match committed bytes" assertion, `:141` `assert`. These are
  the pattern for the hash check.
- `src/browser/package.json:7` `"check:elk"` is a check script, and `:10` is
  the `test` chain that starts with `npm run check:elk`. The new check goes
  in the same place.
- `src/test/aiur/opencode/input_identity_plugin_test.exs:15–18` is the
  precedent for an ExUnit test that runs a `.mjs` file under `src/test/fixtures/`
  with `System.cmd("node", …)`. C3-T01 can use the same pattern if it wants an
  ExUnit guard.
- `src/test/fixtures/` holds the existing per-surface fixture folders
  (`usage/`, `analytics/`, `status_dashboard_snapshots/`, …). PROPOSED
  `build_home/` goes next to them.
- CI: `.github/workflows/ci.yml:618–623` sets up Node `"20"` for the browser
  job (`browser:` job at `:603`), `:647–648` runs `npm test` in `src/browser`.
  The classifier (`:128`) runs the full suite for any path outside `website/`
  and `packages/aiur-style/`, so these files are always checked on a PR.

## Chosen design

**Vendoring.** Copy the research pack's `design-source/` byte for byte to
PROPOSED `src/test/fixtures/build_home/design-source/` (HTML, `assets/*`,
`IMPORTED.md`, `Build Order - feature constraints.md`). This is about 1.8 MB.
C1-T02 serves this folder as static files. Nothing edits it. A re-import
replaces the folder and its `IMPORTED.md`, then re-runs the exporter.

**Exporter.** PROPOSED `src/browser/scripts/export-build-home-fixtures.mjs`
(ESM, Node standard library only: `node:fs`, `node:vm`, `node:crypto`,
`node:path`).

```text
guardZone():  Intl.DateTimeFormat().resolvedOptions().timeZone === "America/Los_Angeles"
              else exit 2 "export needs TZ=America/Los_Angeles, got <zone>"
export loadBuildJs({ designDir, expose, context = {} }):   // C3-T03 reuses this
              src = read(<designDir>/assets/build.js)
              count(src, ANCHOR) === 1 else throw "build.js anchor '<ANCHOR>' found <n> times"
              expose matches /^[A-Za-z_$][\w$]*$/ for each name, else throw
              patched = src.replace(ANCHOR, "  window.__E8 = { " + expose.join(", ") + " };\n" + ANCHOR)
              ctx = { window: {}, document: {}, location: { search: "" }, history: {}, ...context }
              vm.runInContext(patched, vm.createContext(ctx), { filename: "build.js", timeout: 10000 })
              return ctx.window.__E8
load():       { dataFor, NOW, PSETS } = loadBuildJs({ designDir, expose: ["dataFor", "NOW", "PSETS"] })
              NOW === 1791408000000 else throw "NOW moved: <iso>"   // zone + design pin
raw(k):       d = dataFor(k)
              assert ids(d.all) === ids(d.hist ++ d.now ++ d.plan ++ d.nq)
              return { epics, features, order, hist, now, plan, nq, children, counts, failedId }
              // drop kind, all, byId: derivable; dropping them halves dense
daemon(k):    k === "offline" ? { state: "offline", heartbeat_at: NOW - 360000, observed_at: NOW }
                              : { state: "live",    heartbeat_at: NOW,          observed_at: NOW }
              // field names = C3-T02 v1 `daemon` (state, heartbeat_at, observed_at)
dataset(k):   { meta: { dataset: k, now: NOW, tz: "America/Los_Angeles", design_etag },
                data: raw(k === "offline" ? "live" : k),
                usage: { models: PSETS[4], apis: API_ROWS },
                daemon: daemon(k) }
export encode(value):
              pre-walk value with a key path; throw "<path>: <NaN|-Infinity>" on any other
              non-finite number, and "<path>: string \"Infinity\" would decode as a number"
              on a string equal to "Infinity" (keeps the decode unambiguous)
              return JSON.stringify(value, (k, v) => v === Infinity ? "Infinity" : v) + "\n"
export decode(text): JSON.parse(text, (k, v) => v === "Infinity" ? Infinity : v)
write:        encode(mapRawToPayload(dataset(k)))
manifest:     { schema: "build-home-raw/1", now, now_iso: "2026-10-07T14:20:00-07:00", tz, design_etag,
                datasets: ["live", "dense", "newrepo", "noqueue", "offline"],
                design_sha256: { "assets/build.js", "assets/build.css", "Aiur Dashboard.html" },
                fixture_sha256: { "<k>.json", "usage-sets.json" },
                utc_offsets_min: sorted set of -getTimezoneOffset() for every finite number
                                 in [1.7e12, 1.9e12] (the timestamps), node: process.version }
files:        default --out = <script dir>/../../test/fixtures/build_home (from import.meta.url,
              not the cwd); build every file in memory, then write each to "<f>.tmp" and rename
main:         run only when the module is the entry point (import.meta.url === pathToFileURL(argv[1]))
--check:      recompute every byte in memory, compare with the checked-in files,
              fail with one line per mismatch:
              "design file <f> changed (sha …) — run npm run fixtures:build-home"
              "fixture <f> is stale — run npm run fixtures:build-home"
```

- `API_ROWS` is a short constant that copies the J:1031–1036 literals, with a
  comment that cites the lines. A test proves that each literal is still present
  in `build.js`.
- `usage-sets.json` is `PSETS` unchanged (`2`, `4`, `7`), as the raw source.
  C10-T04 needs the n2/n7 layouts. The product has no `?models=` parameter
  (C3-T03), and C3-T01's fixture source has no usage-set selector, so C10-T04
  extends this exporter to write `usage/n2.json` and `usage/n7.json` through the
  C3-T02 mapper (C10-T04 step 6). This ticket does not write them.
- **Mapping.** PROPOSED `src/browser/scripts/build-home-fixture-map.mjs`
  exports `mapRawToPayload(dataset)`. In this ticket it returns its input
  unchanged. It is a separate module only so that C3-T02 can replace its body
  and bump `schema` without editing the exporter. C6-T05 adds a prelude
  argument to `loadBuildJs` and a second `mapRawToPayload` argument in its PR.
- **Invariants:**
  - The export adds no default values: an absent key stays absent, and `null`
    stays `null`.
  - The export loses nothing: `decode(file).data` deep-strict-equals
    `structuredClone(raw(k))` (the clone moves the `vm`-realm objects into the
    test realm; see "Cross-realm objects").
  - `offline.data` deep-equals `live.data`.
  - Output bytes are deterministic for one Node major version.
- **Outputs** (PROPOSED, in `src/test/fixtures/build_home/`): `live.json`,
  `dense.json`, `newrepo.json`, `noqueue.json`, `offline.json`,
  `usage-sets.json`, `manifest.json`. They are compact JSON (about 830 KB in
  total: the `data` sizes in the probe table, `live` twice for `offline`) with
  one trailing newline.

## Implementation steps

1. Copy `design-source/` into `src/test/fixtures/build_home/design-source/`
   unchanged (`cp -a`; compare `sha256sum` of the source and the copy).
2. Write `build-home-fixture-map.mjs` (identity, about 5 lines).
3. Write `export-build-home-fixtures.mjs` as in the pseudocode above (about 140
   lines). It exports `loadBuildJs`, `encode`, `decode` and `buildAll` (the
   in-memory file map) for the tests and for C3-T03. Flags: `--out <dir>`
   (default resolved from the script location, never the cwd), `--design <dir>`
   (default `<out>/design-source`), `--check`. Unknown flags exit 2.
4. Write `export-build-home-fixtures.test.mjs` (`node --test`). See the
   test table below. Tests use temporary directories and never write into the
   checked-in folder.
5. `src/browser/package.json`: add
   - `"fixtures:build-home": "TZ=America/Los_Angeles node scripts/export-build-home-fixtures.mjs"`;
   - `"check:build-home-fixtures": "TZ=America/Los_Angeles node scripts/export-build-home-fixtures.mjs --check && TZ=America/Los_Angeles node --test scripts/export-build-home-fixtures.test.mjs"`;
   - in `test`: `npm run check:elk && npm run check:build-home-fixtures && …`.
6. Run `npm run fixtures:build-home`, commit the outputs and the manifest.
7. Add `src/test/fixtures/build_home/README.md` with five lines: what the files
   are, how to re-export, and the re-import rule ("replace `design-source/`,
   re-export, the C1-T02 diff shows what changed").

## Non-happy paths

- **Wrong time zone** (developer laptop, CI default UTC): the exporter exits 2
  and writes nothing. The `--check` mode does the same, so the npm scripts set
  `TZ`. A shell that ignores the `TZ` prefix (Windows `cmd`) fails loudly; it
  never writes wrong data.
- **Re-imported design changed the anchor or touches the DOM at load:** the
  anchor count check, or a `TypeError` from the empty `document` stub, stops the
  export with the build.js location. A load-time loop stops at the 10 s `vm`
  timeout. Nothing is half-written, because all files are built in memory first
  and written only when every dataset succeeds; each file is written to
  `<f>.tmp` and renamed, so an interrupted write leaves the old file.
- **Design changed but fixtures were not re-exported:** `--check` fails in the
  browser CI job and names the file.
- **Fixture edited by hand:** `--check` fails ("fixture … is stale").
- **Non-finite numbers:** `Infinity` is encoded. `NaN` and `-Infinity` stop the
  export with their key path. Neither occurs today, so either would be a design
  change that needs a decision. A string value `"Infinity"` (none today) also
  stops the export, because it would decode as a number.
- **DST:** every timestamp in the five datasets is in PDT
  (`utc_offsets_min` = `[-420]`; 2026 DST runs from March 8 to November 1). The
  fixtures therefore **cannot** exercise a DST day boundary (EC-20). The
  manifest field makes this visible. The DST cases are synthetic and are owned
  by C9-T02 (N14) and C8-T04 (W3), not by these fixtures.
- **Node version drift:** CI uses Node 20 and the probe used 24. If ICU or
  tzdata differs, `--check` reports a stale fixture. The fix is to re-export
  under the CI version; the manifest records `node`.
- **Security:** `build.js` is checked-in and hash-pinned. It runs in a `vm`
  context with no `require`, `process` or file system. `vm` is not a security
  sandbox; it is used here only for isolation. Fixture strings are untrusted
  data for the renderer (EC-30 belongs to C3-T02).
- **Concurrency, permissions, retries and disconnects:** not relevant. This is
  an offline developer and CI script.

## Compatibility and rollout

No product code, config, migration or runtime change. It ships no new CLI flag,
config key or user-facing surface, so no docs page is needed (AGENTS.md "Docs ship with
the change"). The only interface change is the new npm scripts in the browser
harness. Repository size grows by about 2.5 MB (design copy about 1.7 MB plus
fixtures about 830 KB).
Rollback: revert the commit.

## Verification

Tests in PROPOSED `src/browser/scripts/export-build-home-fixtures.test.mjs`
(`node --test`). Each test runs the exporter into a temporary `--out` folder
unless the row says otherwise.

| Test | Expected | Fails without (mutation) |
| --- | --- | --- |
| "refuses a zone other than America/Los_Angeles" | spawn with `TZ=UTC`: exit 2, stderr names `UTC`, `--out` dir stays empty | the zone guard (the export succeeds and writes data with a different hash) |
| "NOW is 2026-10-07 14:20 Pacific" | `manifest.now === 1791408000000`, `manifest.now_iso === "2026-10-07T14:20:00-07:00"`; every dataset `meta.now` is equal | writing `now` from `Date.now()` instead of the design `NOW`, or omitting it (removing only the pin assert does not fail this test while the zone guard holds; the pin assert is covered by "refuses a zone" with the guard removed) |
| "open-ended feature keeps Infinity" | `live.json` `data.features.pag.to === "Infinity"`, and the decoded value is `Infinity`; `"to": null` occurs nowhere | `encodeNonFinite` (plain `JSON.stringify` writes `null`) |
| "export is lossless" | for each dataset, `decode(file).data` deep-strict-equals `structuredClone(dataFor(k))` without `kind`/`all`/`byId` (`dataFor` from `loadBuildJs`) | any default filling or field drop in the exporter or the map |
| "absent stays absent" | in `live.json` no `plan`/`nq` row has a `start` key (76 rows); no `hist` row has `est`; every `hist` `agent.state === null`; no such field is `0` | a mapping that fills `start ?? 0` or `est ?? 0` (replace the identity map to check) |
| "dataset census" | the counts in the table above (all/hist/now/plan/nq, features, failedId) for all four generated datasets | passing `"offline"` or a typo to `dataFor` (it falls back to `live` silently) |
| "offline is live plus a daemon block" | `offline.data` deep-equals `live.data`; `offline.daemon` deep-equals `{state:"offline", heartbeat_at:1791407640000, observed_at:1791408000000}`; `live.daemon` deep-equals `{state:"live", heartbeat_at:1791408000000, observed_at:1791408000000}` | the `daemon(k)` branch (offline would equal live, or its heartbeat would be `NOW`) |
| "check fails on design drift" | copy the design to tmp, append `"\n"` to `assets/build.js` (still valid JS, same data), run `--check --design tmp`: exit ≠ 0, stderr names `assets/build.js`, and no fixture is reported stale | the hash comparison in `--check` |
| "check fails on a stale fixture" | copy the fixtures to tmp, change one byte of `dense.json`, run `--check --out tmp`: exit ≠ 0, stderr names `dense.json` | the byte comparison in `--check` |
| "anchor must occur once" | a copy of `build.js` with the anchor removed, and one with it duplicated: both exit ≠ 0 with "anchor … found 0/2 times" | the count check (`.replace` silently does nothing, then a `TypeError`) |
| "API usage literals still in build.js" | for each `API_ROWS` row, the source fragment `tag: "<tag>", pct: <pct>, bar: bar([<pct>]), reset: "<reset>", win: "<win>"` and its `rows` literal (`"4,736 of 5,000"`, `"4,998 of 5,000"`, `"90.0K"`) are found in `build.js` (a bare `"37m"` could match elsewhere) | an `API_ROWS` value that is wrong or edited by hand |
| "encode refuses ambiguous values" | `encode({a:{b:NaN}})` and `encode({a:-Infinity})` throw with `a.b` / `a`; `encode({t:"Infinity"})` throws with `t`; `decode(encode({to:Infinity}))` deep-equals `{to:Infinity}` | the pre-walk in `encode` (plain `JSON.stringify` writes `null` for both, and the string would decode as a number) |
| "loader exposes what it is asked for" | `loadBuildJs({ designDir, expose: ["readURL", "S"], context: { location: { search: "?view=list" } } })` returns a function `readURL` and an object `S`; an expose name `"a; b"` throws | a hard-coded expose list (C3-T03's reuse would break) or a missing name check |
| "deterministic" | two exports into two tmp dirs are byte-identical | any use of `Date.now()` or `Math.random` in the exporter |
| "no DST inside the fixtures" | `manifest.utc_offsets_min` deep-equals `[-420]` | the offset census (a guard against a *future* re-import; it passes on today's data and does not count as coverage of a change) |

Mutation discipline (AGENTS.md): for each row, remove the named code in a
worktree and confirm the test fails. Restore it and confirm the test passes. List
each result in the PR body. Before each run, `git status --porcelain` must show
only the intended revert.

Commands:

```bash
npm --prefix /path/to/worktree/src/browser run fixtures:build-home
npm --prefix /path/to/worktree/src/browser run check:build-home-fixtures
TZ=UTC node /path/to/worktree/src/browser/scripts/export-build-home-fixtures.mjs --out "$(mktemp -d)"; echo "exit $?"   # expect exit 2
# Node 20 parity with CI (mise has no node pin):
mise exec node@20 -- env TZ=America/Los_Angeles node /path/to/worktree/src/browser/scripts/export-build-home-fixtures.mjs --check
```

Manual check: open `src/test/fixtures/build_home/design-source/Aiur Dashboard.html`
from that folder in a browser with `?example=dense`. The page renders
(this proves that the vendored copy is complete and its relative `assets/` paths
work). No TUI manual test applies: there is no runtime surface.

## Pixel parity

This ticket draws no pixels. It gives both sides of every later parity check
the same data, and that is a condition for parity.

- **Design elements reproduced as data:** `NOW` (J:11); `build`/`dataFor` and
  its constants `GENERAL`, `POOL`, `FPOOL`, `ACTIVE`, `PLAN`, `MODELS`, `AST`,
  `PTS`, `EST` (J:82–297); `PSETS` (J:989–1012); the `renderUsage` API
  literals (J:1031–1036); the offline flag and its strings and times
  (J:665, 1066–1067, 1139: "cached 14:14", "last heartbeat 6 min ago (14:14)").
- **What must match exactly:** every number and string that `build()` returns,
  bit for bit. The non-integer millisecond timestamps are not rounded, because
  rounding moves card `top`/`height` by a sub-pixel, and C1-T02 would report
  that as drift. The time zone is America/Los_Angeles and the clock is
  `1791408000000`, the same values C1-T02 freezes in the browser.
- **How parity is checked:**
  1. Here: the "export is lossless" and "dataset census" tests.
  2. In C1-T02's side-by-side runner: the design opened with
     `?example=<dataset>` against the product's fixture route serving
     `<dataset>.json`, at 1440/1024/390 px, dark and light, Gruvbox and
     default. A data difference shows up there as a pixel difference.

## Decisions made without the owner

1. **The design copy is vendored into the product repo**
   (`src/test/fixtures/build_home/design-source/`). The row asks for hashes of
   the design files and C1-T02 serves them, but the research pack is not on
   `main`. The cost is about 1.8 MB of binary and text in git.
2. **`Infinity` is encoded as the string `"Infinity"`,** not `null`, because
   `null` is "unknown" and an open feature is not unknown. C3-T02 picks the
   final schema encoding.
3. **`all`, `byId` and `kind` are not exported.** The exporter proves that they
   can be derived (`all` = `hist ++ now ++ plan ++ nq`). `children` and `counts`
   are kept, as a reference for the port.
4. **The live datasets get `daemon = { state: "live", heartbeat_at: NOW,
   observed_at: NOW }`.** The design prints "Daemon live" and `fmtT(NOW)` and
   has no heartbeat value. For offline, `heartbeat_at` is `NOW - 6 min`, as the
   design prints it ("cached 14:14", J:665; "last heartbeat 6 min ago
   (14:14)", J:1066), and `observed_at` is `NOW`. No raw `cached_at` is kept:
   the C3-T02 mapper drops it. The field names are C3-T02's v1 `daemon` shape
   (`state`, `heartbeat_at`, `observed_at`), so C3-T02's mapper does not rename
   them.
5. **Usage:** every dataset carries `PSETS[4]` (the design default) plus the API
   literals copied from J:1031–1036. All three sets go to `usage-sets.json`.
6. **The check runs in the browser harness `npm test` chain** (with `check:elk`),
   not in ExUnit. The data is produced and consumed by Node, and the exporter
   check runs in the CI browser job (Node 20).
7. **Relative design strings stay as the design wrote them** (`cue.promoted:
   "6m ago"`, `cue.held: "Held by Maya · …"`, logo paths `assets/…`). The raw
   export does not interpret them. The mapping (C3-T02) converts them.

## Completion and handoff

- [ ] `design-source/` vendored unedited; its sha256 values match the research pack.
- [ ] The five dataset files, `usage-sets.json` and `manifest.json` are committed.
      `--check` passes under Node 20 and Node 24.
- [ ] The 15 tests pass. The 14 mutation rows (all except "no DST inside the
      fixtures") each fail with the named code removed. The PR body lists the
      result for each.
- [ ] `npm test` in `src/browser` runs `check:build-home-fixtures`.
- [ ] `src/test/fixtures/build_home/README.md` explains how to re-export.
- **Dependents and what they get:**
  - **C1-T02:** the static design folder and `manifest.json` (`datasets`,
    `now`, `now_iso`, `tz`, `design_sha256`). This ticket writes no `ids` map:
    the raw export keeps the design ids. The C3-T02 fixture mapper writes an
    `ids` map {design id -> payload id} into the manifest; C1-T02 and C1-T03
    read it. C1-T02
    must also freeze `Math.random` (J:1461, 1497, 1512) and `Date.now()`
    (J:1516) for the modal mock; its plan already does both (seeded
    `Math.random`, `page.clock.setFixedTime`).
  - **C3-T01:** `<dataset>.json` and `usage-sets.json` for the fixture
    DataSource, with `meta.now` as its fixed clock.
  - **C3-T02:** owns `build-home-fixture-map.mjs` from now on.
  - **C3-T03:** imports `loadBuildJs` for its URL golden script (C3-T03 step 4).
  - **C10-T04:** extends this exporter for `usage/n2.json` and `usage/n7.json`.
  - **C11-T03:** extends this exporter for `convo(t)` / `conversations.json`.
  - **C6-T05:** adds the `loadBuildJs` prelude argument and the second
    `mapRawToPayload` argument.
- **Notes for the neighbours (interface mismatches found):**
  - **C3-T02** (resolved in its file): an open feature end is `to: null`
    in v1 and `intake()` turns it back into `Infinity` (C3-T02 step 4 and its
    schema notes). This raw export writes `"Infinity"`; the C3-T02 mapper
    replaces it. The daemon block here already uses C3-T02's field names.
  - **C3-T02** and CR-E8-5: the design's `cue.promoted` is a relative string
    ("6m ago") and `cue.held` joins the actor and the reason in one string. The
    schema's promoted-at time and hold actor/reason need a conversion rule in the
    mapping.
  - **C3-T01** and C3-T03: C1-T02 compares "the same dataset" on both sides, but
    C3-T03 drops `example` and `models` in the product. The fixture route needs
    its own dataset selector (C3-T01's `:build_fixture_dataset`). It must not
    reuse `?example=`. The usage-set selector is C10-T04's fixture route.
  - **C10-T04** and C8-T02 (EC-25): no design dataset contains a "not
    observed" (`none: true`) usage row, so its parity needs a synthetic fixture.
  - **C9-T02 (N14) and C8-T04 (W3)** (EC-20): the fixtures contain no DST
    change; these tickets own the synthetic DST cases.
- Docs: none needed. This is test tooling only.
- Sources: tickets/README.md C1 rows; chunks.md "MP-E8-C1"; plan.md §7, §8
  (EC-20), §9 (K-1), §11; claude-design-source-of-truth.md;
  design-source/IMPORTED.md; brief.md §9.
- Remaining blocker: DESIGN-E8 only.

## Review log

Adversarial review, 2026-10-08 (sources re-opened; probe re-run with Node
v24.18.0 under `TZ=America/Los_Angeles` and `TZ=UTC`):

1. Front matter: added `owns_edge_cases: [EC-20]` (README row "Owns"), and the
   same note in "Identity and outcome".
2. Byte counts in the probe table were for `data` without `children`/`counts`,
   which this ticket keeps. Replaced them with re-measured values and corrected
   the total size (about 830 KB) and the repo growth (about 2.5 MB).
3. Corrected line refs: `PSETS` starts at J:991 (J:989 holds the logo
   constants); `check-vendored-elk.mjs` `assert` is at `:141`, not `:142`;
   the CI classifier also excludes `packages/aiur-style/`.
4. Added `Date.now()` at J:1516 (modal mock) to the determinism note and to
   the C1-T02 handoff.
5. Found that `assert.deepStrictEqual` fails on `vm`-realm objects. The
   lossless invariant and test now compare against `structuredClone(...)`.
6. Daemon block renamed `cached_at` → `observed_at`, with live
   `observed_at = NOW`, to match C3-T02's v1 `daemon` shape. Test row updated.
7. Infinity encoding: added a pre-walk that throws on `NaN`, `-Infinity` and a
   string `"Infinity"` (so decode is unambiguous), plus a test. The C3-T02
   note is now marked resolved (`to: null` = open in v1).
8. "NOW" test: its mutation was vacuous (removing the pin assert cannot fail it
   while the zone guard holds). It now guards writing `now` from the design
   `NOW`.
9. "API literals" test now matches whole source fragments, not bare `"37m"`.
10. "Design drift" test appends `"\n"` so the JS stays valid and only the hash
    differs.
11. The loader is exported with `expose` and `context` arguments (C3-T03 step 4
    reuses it), with a name check, a 10 s `vm` timeout and a new test.
12. Default `--out` resolves from the script location; the listed commands run
    the script by absolute path from any cwd. Writes go through `<f>.tmp` and
    rename.
13. Manifest gains `datasets` and `now_iso` (C1-T02 reads them); the `ids` map
    is assigned to C3-T02.
14. `usage-sets.json`: corrected the claim that C3-T01 selects the usage set;
    C10-T04 extends this exporter for `usage/n2.json` and `n7.json`.
15. Test and mutation counts updated (15 tests, 14 mutation rows).
- Reconciliation 2026-10-08 (coordinator): offline daemon `observed_at` = `NOW` (pseudocode, test row, Decision 4), raw `cached_at` dropped by the C3-T02 mapper, C3-T02 mapper writes the `ids` map, C6-T05/C10-T04/C11-T03 exporter extensions named, DST cases owned by C9-T02 (N14) and C8-T04 (W3), Node 20 CI browser job.
