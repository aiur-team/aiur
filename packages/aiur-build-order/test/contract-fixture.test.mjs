import { existsSync, readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

// The package fixtures are copies of the published contract fixtures. A copy
// only stays honest if it is checked against its source, so this test fails the
// moment `@aiur/contracts` re-pins a fixture and this package does not follow.
const contracts = fileURLToPath(new URL('../../aiur-contracts/fixtures/', import.meta.url));

const PINNED = [
  'build-order.v1.json',
  'build-order-unavailable.v1.json',
  'build-order.golden.v1.json',
];

test('the package fixtures are the published contract fixtures', (t) => {
  if (!existsSync(contracts)) {
    // An installed copy of this package has no sibling contracts checkout.
    t.skip('@aiur/contracts is not checked out beside this package');
    return;
  }
  for (const name of PINNED) {
    const published = readFileSync(`${contracts}${name}`, 'utf8');
    const pinned = readFileSync(new URL(`../fixtures/${name}`, import.meta.url), 'utf8');
    assert.equal(pinned, published, `${name} has drifted from @aiur/contracts`);
  }
});

test('the pinned fixtures all parse', async () => {
  const { parseBuildOrder } = await import('../src/index.js');
  for (const name of PINNED) {
    const parsed = parseBuildOrder(readFileSync(new URL(`../fixtures/${name}`, import.meta.url), 'utf8'));
    assert.equal(parsed.ok, true, `${name}: ${parsed.ok ? '' : parsed.error.message}`);
  }
});
