// Deterministic screenshot harness for the terminal sim. Renders a chosen
// loopSec frame with renderFrame (no animation/timing), wraps it in the real
// terminal chrome + styles.css, and screenshots it with headless chromium so
// the opencode pane can be eyeballed without serving the live dev server.
//
//   npx tsx scripts/shot.ts [loopSec] [theme] [outPath]
//
// Defaults: loopSec=19 (posted user block visible), theme=dark, out=/tmp/sim-<sec>.png
import { renderFrame } from "../src/dashboard";
import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";

const loopSec = Number(process.argv[2] ?? 19);
const theme = process.argv[3] ?? "dark";
const out = process.argv[4] ?? `/tmp/sim-${loopSec}.png`;

const css = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");
const frame = renderFrame(loopSec * 1000, 0);

const html = `<!doctype html>
<html lang="en" data-theme="${theme}">
<head><meta charset="utf-8"><style>
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); display: grid; place-items: center;
         min-height: 100vh; padding: 24px; }
${css}
</style></head>
<body>
  <div class="terminal" style="--term-h: 560px;">
    <div class="term-bar">
      <span class="dot r"></span><span class="dot y"></span><span class="dot g"></span>
      <span class="term-title">aiur — its-everdred/shopwave</span>
    </div>
    <div class="term-body"><div class="term-screen">${frame}</div></div>
  </div>
</body>
</html>`;

const dir = mkdtempSync(join(tmpdir(), "sim-shot-"));
const page = join(dir, "page.html");
writeFileSync(page, html);

execFileSync(
  "/usr/bin/chromium",
  [
    "--headless",
    "--no-sandbox",
    "--hide-scrollbars",
    "--force-device-scale-factor=2",
    "--window-size=1100,760",
    `--screenshot=${out}`,
    `file://${page}`,
  ],
  { stdio: "inherit" },
);
console.log("wrote", out);
