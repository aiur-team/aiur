import { renderFrame } from "../src/dashboard";
import { writeFileSync } from "node:fs";
const Ls = [0, 5, 10, 18, 26, 45, 60, 80];
const out: Record<number, string> = {};
for (const L of Ls) out[L] = renderFrame(L * 1000, 0);
writeFileSync(
  new URL("./dashboard-golden.json", import.meta.url),
  JSON.stringify(out, null, 2) + "\n",
);
console.log("captured", Ls.length, "frames");
