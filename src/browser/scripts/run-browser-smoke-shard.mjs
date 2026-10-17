import { spawnSync } from 'node:child_process';
import { appendFileSync } from 'node:fs';
import { performance } from 'node:perf_hooks';
import { fileURLToPath } from 'node:url';
import { shardCommands } from './browser-suites.mjs';

// Discovered tests/build-home-*.browser.spec.mjs suites are added by hash; list only explicit scripts here.
// The key count is the shard count: it must match the browser matrix in .github/workflows/ci.yml.
export const shards = {
  1: ['test:home-css-ci', 'test:admission', 'check:elk', 'check:build-home-fixtures', 'test:build-home-protocol', 'test:build-home-now-state', 'test:build-home-edges-unit', 'test:harness', 'test:smoke', 'test:shell', 'test:shell-chrome', 'test:tokens', 'test:units', 'test:provider-meters', 'test:meter-row', 'test:models-panel', 'test:parity', 'test:build-home-cards:1'],
  2: ['test:shell-width', 'test:command-history', 'test:build-order', 'test:build-queue', 'test:interaction', 'test:time-brush', 'test:performance', 'test:responsive', 'test:layout', 'test:ticket-context', 'test:shell-parity', 'test:streamdeck', 'test:quota-panel', 'test:streamdeck-flow', 'test:palette', 'test:build-home-cards:2'],
  3: ['test:build-home-edges-parity', 'test:build-home-motion', 'test:build-home-offline', 'test:experiments', 'test:build-home-states-parity', 'test:build-home-cards:3'],
  4: ['test:design-parity', 'test:build-home-tools', 'test:build-home', 'test:build-home-span-parity', 'test:build-home-cards:4'],
  5: ['test:build-home-edges', 'test:build-home-assets', 'test:build-home-layout', 'test:build-home-render', 'test:build-home-span', 'test:build-home-columns'],
};

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
  // Below the job's timeout-minutes, so a slow shard reports its slowest suites instead of being cancelled.
  const timeoutMs = 19 * 60_000;
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
