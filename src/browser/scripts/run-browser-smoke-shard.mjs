import { spawnSync } from 'node:child_process';
import { appendFileSync } from 'node:fs';
import { performance } from 'node:perf_hooks';
import { fileURLToPath } from 'node:url';
import { shardCommands } from './browser-suites.mjs';

// Discovered tests/build-home-*.browser.spec.mjs suites are added by hash; list only explicit scripts here.
// The key count is the shard count: it must match the browser matrix in .github/workflows/ci.yml.
// Balanced by recorded durations (browser-smoke-durations.mjs); check-browser-smoke-shards.mjs keeps each shard under 75% of budgetMs.
export const shards = {
  1: ["test:build-home-columns","test:quota-panel","test:palette","test:build-home-chains","test:build-home-chains-unit"],
  2: ["test:build-home-band-parity","test:build-home-usage","test:build-home","test:build-home-span","test:build-home-offline","test:home-css-ci","test:build-home-edges-unit","test:command-history","test:build-home-layout","test:time-brush"],
  3: ["test:build-home-tools","test:build-home-render","test:shell-parity","test:build-order","test:build-queue","check:build-home-fixtures","test:ticket-context","test:command-answer"],
  4: ["test:build-home-motion","test:design-parity","test:shell","test:smoke","test:meter-row","test:models-panel","test:build-modal-motion"],
  5: ["test:build-home-band-motion","test:build-home-states-parity","test:build-home-edges-parity","test:streamdeck","test:interaction","test:performance","test:build-home-assets","test:harness","test:build-modal","test:shell-width"],
  6: ["test:build-home-cards:4","test:build-home-cards:3","test:build-home-cards:1","test:units","test:layout","test:responsive","test:streamdeck-flow","test:admission","check:elk","test:build-home-protocol","test:build-home-now-state","test:build-home-list-unit","test:build-home-now-band","test:tokens"],
  7: ["test:build-home-cards:2","test:build-home-span-parity","test:parity","test:experiments","test:build-home-conversation","test:build-home-chains-parity"],
  8: ["test:build-home-gantt","test:provider-meters","test:shell-chrome","test:build-index-live","test:build-modal-parity","test:build-home-edges"],
};

// Below the job's timeout-minutes, so a slow shard reports its slowest suites instead of being cancelled.
export const budgetMs = 33 * 60_000;
export { preflightSeconds, recordedSeconds } from './browser-smoke-durations.mjs';

function reportSlowest(heading, timings, limit = 10) {
  console.error(heading);
  for (const item of [...timings].sort((left, right) => right.durationMs - left.durationMs).slice(0, limit)) {
    console.error(`  ${item.command}: ${(item.durationMs / 1000).toFixed(1)}s`);
  }
}

function main() {
  const shard = Number(process.argv[2]);
  const plan = shardCommands(shards);
  if (!plan[shard]) throw new Error(`Unknown browser smoke shard: ${process.argv[2]}`);
  const timeoutMs = budgetMs;
  const deadline = performance.now() + timeoutMs;
  const preflight = spawnSync('npm', ['run', 'fixture:preflight'], { stdio: 'inherit' });
  if (preflight.error) throw preflight.error;
  if (preflight.status !== 0) process.exit(preflight.status ?? 1);
  const timings = [];
  for (const command of plan[shard]) {
    if (performance.now() >= deadline) {
      reportSlowest(`Browser smoke shard ${shard} reached its ${Math.round(timeoutMs / 1000)}s suite budget before ${command}; slowest completed suites:`, timings);
      process.exit(124);
    }
    const started = performance.now();
    const remainingMs = Math.max(1, Math.floor(deadline - started));
    const result = spawnSync('npm', ['run', ...command.split(' ')], { stdio: 'inherit', timeout: remainingMs });
    const durationMs = Math.round(performance.now() - started);
    timings.push({ command, durationMs });
    const timingFile = process.env.AIUR_BROWSER_TIMING_FILE;
    if (timingFile) appendFileSync(timingFile, `${JSON.stringify({ shard, script: command, durationMs })}\n`);
    if (result.error?.code === 'ETIMEDOUT') {
      reportSlowest(`Browser smoke shard ${shard} timed out in ${command}; slowest suites:`, timings);
      process.exit(124);
    }
    if (result.error) throw result.error;
    if (result.status !== 0) {
      reportSlowest(`Browser smoke shard ${shard} stopped at ${command}; slowest completed suites:`, timings);
      process.exit(result.status ?? 1);
    }
  }
  console.log(`Browser smoke shard ${shard} suite durations:`);
  for (const item of [...timings].sort((left, right) => right.durationMs - left.durationMs)) {
    console.log(`  ${item.command}: ${(item.durationMs / 1000).toFixed(1)}s`);
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
