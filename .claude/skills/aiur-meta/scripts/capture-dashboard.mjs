// Capture every operator-facing dashboard page for one Aiur meta-check.
//
// Two details here are load-bearing and are the reason this is a script rather
// than something rewritten each run:
//
//   1. Basic auth needs Playwright's httpCredentials. Inline URL credentials
//      do not survive the LiveView websocket upgrade.
//   2. LiveView hydrates AFTER domcontentloaded. Without the settle wait every
//      metric reads empty and the check reports false positives on every page,
//      every hour.
//
// Usage:
//   AIUR_DASHBOARD_URL=http://host:port \
//   AIUR_DASHBOARD_USERNAME=… AIUR_DASHBOARD_PASSWORD=… \
//   node capture-dashboard.mjs <output-dir>
//
// Prints a JSON report to stdout and writes <name>.png per page.
// Stream Deck is deliberately excluded: it is a control surface, not a report.

import { chromium } from '@playwright/test';
import fs from 'node:fs';
import path from 'node:path';

const BASE = process.env.AIUR_DASHBOARD_URL || 'http://127.0.0.1:4099';
const USER = process.env.AIUR_DASHBOARD_USERNAME || 'aiur';
const PASS = process.env.AIUR_DASHBOARD_PASSWORD;
const OUT = process.argv[2] || './meta-captures';
const SETTLE_MS = Number(process.env.AIUR_META_SETTLE_MS || 6000);

if (!PASS) {
  console.error('AIUR_DASHBOARD_PASSWORD is required.');
  process.exit(64);
}

fs.mkdirSync(OUT, { recursive: true });

const PAGES = [
  ['units', '/'],
  ['commands', '/decisions'],
  ['build-orders', '/build-orders'],
  ['analytics', '/analytics'],
];

const browser = await chromium.launch();
const ctx = await browser.newContext({
  httpCredentials: { username: USER, password: PASS },
  viewport: { width: 1600, height: 1200 },
});

const report = [];

for (const [name, route] of PAGES) {
  const page = await ctx.newPage();
  const consoleErrors = [];
  const failedRequests = [];
  page.on('console', (m) => { if (m.type() === 'error') consoleErrors.push(m.text().slice(0, 200)); });
  page.on('pageerror', (e) => consoleErrors.push('PAGEERROR: ' + String(e).slice(0, 200)));
  page.on('requestfailed', (r) => failedRequests.push(`${r.method()} ${r.url().slice(0, 120)}`));

  let status = null;
  const started = Date.now();
  try {
    const resp = await page.goto(BASE + route, { waitUntil: 'domcontentloaded', timeout: 45000 });
    status = resp ? resp.status() : null;
    await page.waitForTimeout(SETTLE_MS); // LiveView hydration — see header
  } catch (e) {
    consoleErrors.push('NAV: ' + String(e).slice(0, 200));
  }

  const signals = await page.evaluate(() => {
    const txt = document.body ? document.body.innerText : '';
    const cells = Array.from(document.querySelectorAll('td')).map((c) => c.innerText.trim());
    const dashCells = cells.filter((c) => c === '—' || c === '–' || c === '-').length;
    return {
      title: document.title,
      chars: txt.length,
      liveViewConnected: !!document.querySelector('[data-phx-main]'),
      rows: document.querySelectorAll('tbody tr').length,
      cells: cells.length,
      // a metric column that is entirely em-dashes is the #1616 signature
      dashCells,
      dashRatio: cells.length ? +(dashCells / cells.length).toFixed(2) : 0,
      hasNA: /\bN\/A\b/.test(txt),
      staleBanners: (txt.match(/stale|not fresh|not available|unavailable/gi) || []).length,
      head: txt.replace(/\s+/g, ' ').slice(0, 700),
    };
  }).catch((e) => ({ evalError: String(e).slice(0, 200) }));

  await page.screenshot({ path: path.join(OUT, `${name}.png`), fullPage: true }).catch(() => {});
  report.push({ name, route, status, elapsedMs: Date.now() - started, consoleErrors, failedRequests, ...signals });
  await page.close();
}

await browser.close();
console.log(JSON.stringify(report, null, 2));
