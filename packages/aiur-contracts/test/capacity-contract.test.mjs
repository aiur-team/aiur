import assert from 'node:assert/strict';
import test from 'node:test';
import { capacity, capacityUnknown, validateCapacity } from '../scripts/validate.mjs';

const errors = () => JSON.stringify(validateCapacity.errors);
const FIGURE_KEYS = ['observed_at', 'age_ms', 'freshness'];

// Every object in the view that holds a figure: energy, accounts, balances, limits.
const figurePaths = (view) => [
  ['energy'],
  ...view.limits.map((_, i) => ['limits', i]),
  ...view.sources.flatMap((source, s) => [
    ...source.accounts.map((_, a) => ['sources', s, 'accounts', a]),
    ...(source.balance ? [['sources', s, 'balance']] : []),
    ...source.limits.map((_, l) => ['sources', s, 'limits', l]),
  ]),
];
const at = (root, path) => path.reduce((node, key) => node[key], root);

test('all-unknown view reports energy level null with state unknown', () => {
  assert.equal(validateCapacity(capacityUnknown), true, errors());
  assert.equal(capacityUnknown.energy.level, null);
  assert.equal(capacityUnknown.energy.state, 'unknown');
});

test('all-unknown view rejects a numeric level such as empty or full', () => {
  for (const level of [0, 1, 0.5]) {
    const wrong = structuredClone(capacityUnknown);
    wrong.energy.level = level;
    assert.equal(validateCapacity(wrong), false, `level ${level} passed as unknown`);
  }
});

test('a known energy state rejects a null level', () => {
  const wrong = structuredClone(capacity);
  wrong.energy.level = null;
  assert.equal(validateCapacity(wrong), false);
});

test('every figure carries observed_at, age_ms and freshness', () => {
  for (const fixture of [capacity, capacityUnknown]) {
    const paths = figurePaths(fixture);
    assert.ok(paths.length > 1);
    for (const path of paths) {
      for (const key of FIGURE_KEYS) {
        const missing = structuredClone(fixture);
        delete at(missing, path)[key];
        assert.equal(validateCapacity(missing), false, `${path.join('.')} accepted without ${key}`);
      }
    }
  }
});

test('an unknown figure carries no value and no reading time', () => {
  const cases = [
    [['sources', 0, 'accounts', 0], 'remaining_percent', 50],
    [['sources', 0, 'accounts', 0], 'projected_percent', 50],
    [['sources', 0, 'accounts', 0], 'observed_at', '2026-11-09T11:00:00Z'],
    [['sources', 0, 'accounts', 0], 'age_ms', 1000],
    [['energy'], 'observed_at', '2026-11-09T11:00:00Z'],
  ];
  for (const [path, key, value] of cases) {
    const wrong = structuredClone(capacityUnknown);
    at(wrong, path)[key] = value;
    assert.equal(validateCapacity(wrong), false, `unknown ${path.join('.')} accepted ${key}=${value}`);
  }

  const unknownLimit = structuredClone(capacity);
  const limit = unknownLimit.sources[2].limits[1];
  assert.equal(limit.freshness, 'unknown');
  limit.spent_usd = 0;
  assert.equal(validateCapacity(unknownLimit), false);

  const unknownBalance = structuredClone(capacity);
  unknownBalance.sources[3].balance.remaining_usd = 0;
  assert.equal(validateCapacity(unknownBalance), false);
});

test('energy level stays within 0 to 1', () => {
  for (const level of [-0.1, 1.1, 62]) {
    const wrong = structuredClone(capacity);
    wrong.energy.level = level;
    assert.equal(validateCapacity(wrong), false);
  }
});
