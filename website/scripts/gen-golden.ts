import { renderFrame } from "../src/dashboard";
import { writeFileSync } from "node:fs";
// Non-beat / non-animation loopSec values only. The golden locks the full-width
// frame (R2); seconds in [descentStart, ascentEnd) render the cursor walk or the
// split, so they are excluded.
const Ls = [0, 32, 44, 56, 68, 80];
const out: Record<number, string> = {};
for (const L of Ls) out[L] = renderFrame(L * 1000, 0);
writeFileSync(
  new URL("./dashboard-golden.json", import.meta.url),
  JSON.stringify(out, null, 2) + "\n",
);
console.log("captured", Ls.length, "frames");
