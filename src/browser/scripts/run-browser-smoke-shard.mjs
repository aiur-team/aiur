import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { shardCommands } from './browser-suites.mjs';

// Discovered tests/build-home-*.browser.spec.mjs suites are added by hash; list only explicit scripts here.
export const shards = {
  1: ['test:home-css-ci', 'test:admission', 'check:elk', 'check:build-home-fixtures', 'test:build-home-protocol', 'test:build-home-now-state', 'test:harness', 'test:smoke', 'test:build-home-assets', 'test:shell', 'test:shell-chrome', 'test:tokens', 'test:units', 'test:provider-meters', 'test:meter-row', 'test:models-panel', 'test:build-home', 'test:parity', 'test:build-home-layout'],
  2: ['test:shell-width', 'test:command-history', 'test:build-order', 'test:build-queue', 'test:interaction', 'test:time-brush', 'test:performance', 'test:responsive', 'test:layout', 'test:ticket-context', 'test:shell-parity', 'test:streamdeck', 'test:quota-panel', 'test:streamdeck-flow', 'test:palette'],
  3: ['test:build-home-motion', 'test:build-home-offline', 'test:build-home-render', 'test:experiments'],
  4: ['test:design-parity', 'test:build-home-tools', 'test:build-home-span', 'test:build-home-span-parity'],
};

function main() {
  const shard = Number(process.argv[2]);
  const plan = shardCommands(shards);
  if (!plan[shard]) throw new Error(`Unknown browser smoke shard: ${process.argv[2]}`);
  const preflight = spawnSync('npm', ['run', 'fixture:preflight'], { stdio: 'inherit' });
  if (preflight.error) throw preflight.error;
  if (preflight.status !== 0) process.exit(preflight.status ?? 1);
  for (const command of plan[shard]) {
    const result = spawnSync('npm', ['run', ...command.split(' ')], { stdio: 'inherit' });
    if (result.error) throw result.error;
    if (result.status !== 0) process.exit(result.status ?? 1);
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
