import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { AST, UNKNOWN_STATE, agentState, progress, modelLabel } from '../../priv/static/build-home/now-state.js';
import { loadBuildJs } from './export-build-home-fixtures.mjs';

test('unknown progress has no percentage or hue', () => {
  for (const value of [null, undefined, 70.5, 140, -1, '50'])
    assert.deepEqual(progress(value), { known: false, text: '—', style: '' });
});
test('known progress uses the design hue including zero', () => {
  assert.deepEqual(progress(0), { known: true, text: '0%', style: '--pct:0%;--ph:42' });
  assert.deepEqual(progress(64), { known: true, text: '64%', style: '--pct:64%;--ph:108' });
});
test('unknown and prototype states remain unknown', () => {
  for (const state of [null, undefined, 'bogus', '__proto__', 'constructor', 'toString'])
    assert.equal(agentState(state), UNKNOWN_STATE);
  assert.deepEqual(UNKNOWN_STATE, { label: 'State unknown', cls: null });
});
test('AST matches the vendored design and stays frozen', () => {
  const { AST: design } = loadBuildJs({ designDir: fileURLToPath(new URL('../../test/fixtures/build_home/design-source/', import.meta.url)), expose: ['AST'] });
  assert.deepEqual(AST, JSON.parse(JSON.stringify(design)));
  assert.ok(Object.isFrozen(AST));
  for (const key of Object.keys(AST)) {
    assert.equal(agentState(key), AST[key]);
    assert.ok(Object.isFrozen(AST[key]));
  }
});
test('model label prefers the provider name without inventing unknown labels', () => {
  assert.equal(modelLabel({ model: 'muse', name: 'Muse' }), 'Muse');
  assert.equal(modelLabel({ model: 'kimi', name: null }), 'Kimi');
  for (const agent of [null, { model: 'muse', name: null }, { model: '__proto__', name: null }])
    assert.equal(modelLabel(agent), null);
});
