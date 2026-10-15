import { spawnSync } from 'node:child_process';

const shards = {
  1: ['test:home-css-ci', 'test:admission', 'check:elk', 'check:build-home-fixtures', 'test:build-home-protocol', 'test:build-home-now-state', 'test:harness', 'test:smoke', 'test:build-home-assets', 'test:shell', 'test:shell-chrome', 'test:design-parity', 'test:tokens', 'test:units', 'test:provider-meters', 'test:meter-row', 'test:models-panel', 'test:build-home', 'test:parity'],
  2: ['test:shell-width', 'test:command-history', 'test:build-order', 'test:build-queue', 'test:interaction', 'test:time-brush', 'test:performance', 'test:responsive', 'test:layout', 'test:ticket-context', 'test:shell-parity', 'test:streamdeck', 'test:quota-panel', 'test:streamdeck-flow', 'test:palette'],
  3: ['test:build-home-motion', 'test:build-home-layout', 'test:build-home-offline', 'test:build-home-tools'],
};

const shard = Number(process.argv[2]);
if (!shards[shard]) throw new Error(`Unknown browser smoke shard: ${process.argv[2]}`);
const preflight = spawnSync('npm', ['run', 'fixture:preflight'], { stdio: 'inherit' });
if (preflight.error) throw preflight.error;
if (preflight.status !== 0) process.exit(preflight.status ?? 1);
for (const script of shards[shard]) {
  const result = spawnSync('npm', ['run', script], { stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
