// Dependency-light invariant checks for the dashboard sim. Run with
// `npm run assert`. Not wired into CI (website has no test gate); it guards
// the load-bearing invariants the refactor and beat re-timing could break.
import { readFileSync } from "node:fs";
import { renderFrame, buildDashboardLines, DASH_BOX_W_ABBR } from "../src/dashboard";
import { EVENTS } from "../src/simData";

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
  const rest = line
    .replace(/<span class="e2">.*?<\/span>/g, "")
    .replace(/<span class="e1">.*?<\/span>/g, "")
    .replace(/<[^>]+>/g, "")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">");
  return [...rest].length + e2 * 2 + e1;
};
const abbr = buildDashboardLines(24, 0, { dropLatest: true, selectedId: 321 });
const widths = new Set(abbr.map(visibleWidth));
if (widths.size === 1 && abbr[0] && visibleWidth(abbr[0]) === DASH_BOX_W_ABBR) {
  ok(`abbreviated rows uniform at ${DASH_BOX_W_ABBR} cols (${abbr.length} rows)`);
} else {
  fail(`abbreviated rows not uniform: widths=${[...widths].join(",")} expected=${DASH_BOX_W_ABBR}`);
}

// 3. #321 publishes "schema migrated to uuid pks" strictly before #324 ingests it.
const publish = EVENTS.find((e) => e.id === 321 && e.text.includes("schema migrated"));
const receive = EVENTS.find((e) => e.id === 324 && e.kind === "receive");
if (publish && receive && publish.t < receive.t) {
  ok(`#321 publish (t=${publish.t}) precedes #324 receive (t=${receive.t})`);
} else {
  fail(`unblock ordering broken: publish=${publish?.t} receive=${receive?.t}`);
}

if (failures > 0) {
  console.error(`\n${failures} assertion(s) failed`);
  process.exit(1);
}
console.log("\nall assertions passed");
