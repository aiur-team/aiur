// Dependency-light invariant checks for the dashboard sim. Run with
// `npm run assert`. Not wired into CI (website has no test gate); it guards
// the load-bearing invariants the refactor and beat re-timing could break.
import { readFileSync } from "node:fs";
import {
  renderFrame,
  buildDashboardLines,
  buildOpencodeLines,
  joinColumns,
  DASH_BOX_W,
  DASH_BOX_W_ABBR,
  OC_PANE_W,
} from "../src/dashboard";
import { EVENTS, BEAT, OC_TOTAL_ROWS } from "../src/simData";

// Mirror of the reduced-motion freeze offset hardcoded in startDashboard
// (baseMs + 17_000). Kept in sync by check 6 below.
const REDUCED_MOTION_SEC = 17;

let failures = 0;
const fail = (msg: string): void => {
  failures++;
  console.error("FAIL:", msg);
};
const ok = (msg: string): void => console.log("ok:", msg);

// 1. Full-width frame is byte-identical to the captured golden snapshot.
const golden = JSON.parse(
  readFileSync(new URL("./dashboard-golden.json", import.meta.url), "utf8"),
) as Record<string, string>;
let goldenMismatch = 0;
for (const [L, expected] of Object.entries(golden)) {
  const actual = renderFrame(Number(L) * 1000, 0);
  if (actual !== expected) {
    goldenMismatch++;
    fail(`full-width frame at loopSec=${L} differs from golden`);
  }
}
if (goldenMismatch === 0) ok(`full-width golden matches (${Object.keys(golden).length} frames)`);

// 2. Abbreviated dashboard rows are all exactly DASH_BOX_W_ABBR display cols.
// .e2 spans occupy 2 cols and .e1 spans 1 col regardless of the glyph's UTF-16
// length, matching the Seg width model the layout uses.
const visibleWidth = (line: string): number => {
  const e2 = (line.match(/<span class="e2">/g) ?? []).length;
  const e1 = (line.match(/<span class="e1">/g) ?? []).length;
  // The input cursor is an empty <span class="cursor"></span> that occupies one
  // column on the grid (CSS width:1ch) but carries no text, so count it like e1.
  const cur = (line.match(/<span class="cursor">/g) ?? []).length;
  const rest = line
    .replace(/<span class="e2">.*?<\/span>/g, "")
    .replace(/<span class="e1">.*?<\/span>/g, "")
    .replace(/<[^>]+>/g, "")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">");
  return [...rest].length + e2 * 2 + e1 + cur;
};
const abbr = buildDashboardLines(24, 0, { dropLatest: true, selectedId: 321 });
const widths = new Set(abbr.map(visibleWidth));
if (widths.size === 1 && abbr[0] && visibleWidth(abbr[0]) === DASH_BOX_W_ABBR) {
  ok(`abbreviated rows uniform at ${DASH_BOX_W_ABBR} cols (${abbr.length} rows)`);
} else {
  fail(`abbreviated rows not uniform: widths=${[...widths].join(",")} expected=${DASH_BOX_W_ABBR}`);
}

// 3. Two-occurrence ordering (R-V1): the human steering beat closes strictly
// before the autonomous #318 → #319 unblock receive fires, so they read as two
// distinct, sequential demonstrations (not one causal chain). The old
// #321 → #324 tie is removed; assert it no longer exists.
const receive319 = EVENTS.find((e) => e.id === 319 && e.kind === "receive");
if (receive319 && BEAT.close < receive319.t) {
  ok(`human beat closes (t=${BEAT.close}) before #318→#319 receive (t=${receive319.t})`);
} else {
  fail(`two-occurrence ordering broken: BEAT.close=${BEAT.close} receive=${receive319?.t}`);
}
const stale321 = EVENTS.find((e) => e.id === 321 && e.text.includes("schema migrated"));
const stale324 = EVENTS.find((e) => e.id === 324 && e.kind === "receive");
if (!stale321 && !stale324) {
  ok("removed #321 publish / #324 receive (no stale causal tie)");
} else {
  fail(`stale causal tie present: #321 publish=${!!stale321} #324 receive=${!!stale324}`);
}

// 4. Every opencode pane row is exactly OC_PANE_W cols and the pane keeps a
// fixed OC_TOTAL_ROWS height for every loopSec in [open, close), so the
// side-by-side split never grows or shrinks mid-beat. OC_TOTAL_ROWS must also
// fit under the abbreviated dashboard height.
let ocMismatch = 0;
let ocRows = 0;
let ocHeightMismatch = 0;
for (let sec = BEAT.open; sec < BEAT.close; sec++) {
  const pane = buildOpencodeLines(sec, sec % 10);
  if (pane.length !== OC_TOTAL_ROWS) {
    ocHeightMismatch++;
    fail(`opencode pane at loopSec=${sec} has ${pane.length} rows, expected ${OC_TOTAL_ROWS}`);
  }
  for (const row of pane) {
    ocRows++;
    if (visibleWidth(row) !== OC_PANE_W) {
      ocMismatch++;
      fail(`opencode row at loopSec=${sec} is ${visibleWidth(row)} cols, expected ${OC_PANE_W}`);
    }
  }
}
if (ocMismatch === 0) ok(`opencode rows uniform at ${OC_PANE_W} cols (${ocRows} rows across beat)`);
if (ocHeightMismatch === 0) ok(`opencode pane fixed at ${OC_TOTAL_ROWS} rows across beat`);
if (OC_TOTAL_ROWS <= abbr.length) {
  ok(`OC_TOTAL_ROWS=${OC_TOTAL_ROWS} fits under dashboard height (${abbr.length})`);
} else {
  fail(`OC_TOTAL_ROWS=${OC_TOTAL_ROWS} exceeds dashboard height ${abbr.length}`);
}

// 6. The reduced-motion freeze second falls in [replyAt, close): posted user
// block + agent reply visible, input empty (R-V7).
if (REDUCED_MOTION_SEC >= BEAT.replyAt && REDUCED_MOTION_SEC < BEAT.close) {
  ok(`reduced-motion freeze (t=${REDUCED_MOTION_SEC}) lands in [replyAt, close)`);
} else {
  fail(`reduced-motion freeze t=${REDUCED_MOTION_SEC} outside [${BEAT.replyAt}, ${BEAT.close})`);
}

// 5. The side-by-side join produces rows exactly DASH_BOX_W cols wide and pads
// the shorter (opencode) column to the dashboard's height, so borders align.
const joinDash = buildDashboardLines(17, 0, { dropLatest: true, selectedId: 321 });
const joinPane = buildOpencodeLines(17, 0);
const joined = joinColumns(joinDash, joinPane);
let joinMismatch = 0;
for (const row of joined) {
  if (visibleWidth(row) !== DASH_BOX_W) {
    joinMismatch++;
    fail(`joined row is ${visibleWidth(row)} cols, expected ${DASH_BOX_W}`);
  }
}
if (joined.length !== Math.max(joinDash.length, joinPane.length)) {
  fail(`join height ${joined.length} != max(${joinDash.length},${joinPane.length})`);
} else if (joinMismatch === 0) {
  ok(`side-by-side join uniform at ${DASH_BOX_W} cols (${joined.length} rows)`);
}

if (failures > 0) {
  console.error(`\n${failures} assertion(s) failed`);
  process.exit(1);
}
console.log("\nall assertions passed");
