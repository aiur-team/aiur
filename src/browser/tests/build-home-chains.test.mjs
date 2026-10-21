import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { chainOf, chainGaps, fitFrom, treeLayout, treeStatus } from '../../priv/static/build-home/chains.js';
import { agentState } from '../../priv/static/build-home/now-state.js';
import { chainsD, fixtureD } from './fixtures/chains-d.mjs';

// Verbatim design oracles (J:933–938, J:1186), on its complete acyclic fixtures.
function oracleChain(D, id) {
  const s = new Set([id]);
  const up = x => (D.byId[x].deps || []).forEach(d => { if (!s.has(d) && D.byId[d]) { s.add(d); up(d); } });
  const dn = x => (D.children[x] || []).forEach(c => { if (!s.has(c)) { s.add(c); dn(c); } });
  up(id); dn(id); return s;
}
function oracleDepth(D, ids) {
  const set = new Set(ids), depth = {};
  const dep = (x) => { if (depth[x] != null) return depth[x]; depth[x] = 0; let d = 0; D.byId[x].deps.forEach((p) => { if (set.has(p)) d = Math.max(d, dep(p) + 1); }); return (depth[x] = d); };
  ids.forEach(dep); return depth;
}
const fixtures = ['live', 'dense', 'offline', 'newrepo', 'noqueue'];
for (const name of fixtures) test(`U1 chain order and depths equal design: ${name}`, () => {
  const snapshot = JSON.parse(readFileSync(new URL(`../../test/fixtures/build_home/${name}.json`, import.meta.url)));
  const D = fixtureD(snapshot);
  for (const id of Object.keys(D.byId)) {
    const ids = [...oracleChain(D, id)];
    assert.deepEqual([...chainOf(D, id)], ids, `${name}: ${id}`);
    assert.deepEqual({ ...treeLayout(D, id, 800, 600).depth }, oracleDepth(D, ids));
  }
});

test('chain walks remain directional across a shared blocker', () => {
  const D = chainsD([{ id: 'blocker' }, { id: 'root', deps: ['blocker'] },
    { id: 'sibling', deps: ['blocker'] }, { id: 'child', deps: ['root'] }]);
  assert.deepEqual([...chainOf(D, 'root')], ['root', 'blocker', 'child']);
});

test('U2 cycles terminate with design depths and only occupied levels', { timeout: 1000 }, () => {
  for (const n of [2, 3]) {
    const D = chainsD(Array.from({ length: n }, (_, i) => ({ id: String(i), deps: [String((i + 1) % n)] })));
    const layout = treeLayout(D, '0', 800, 600);
    assert.equal(chainOf(D, '0').size, n);
    assert.deepEqual({ ...layout.depth }, oracleDepth(D, layout.ids));
    assert.equal(layout.levels, n);
    assert.equal(layout.depth['0'], n);
  }
});

test('U3 self-loop produces one level, depth zero, and no edge', () => {
  const D = chainsD([{ id: 'A', deps: ['A'] }]);
  const layout = treeLayout(D, 'A', 800, 600);
  assert.deepEqual([...chainOf(D, 'A')], ['A']);
  assert.equal(layout.depth.A, 0);
  assert.equal(layout.levels, 1);
  assert.deepEqual(layout.edges, []);
});

test('U4 20,000-member chain is stack-safe in both directions and layout', () => {
  const D = chainsD(Array.from({ length: 20000 }, (_, i) => ({ id: String(i), deps: i ? [String(i - 1)] : [] })));
  assert.equal(chainOf(D, '0').size, 20000);
  assert.equal(chainOf(D, '19999').size, 20000);
  const layout = treeLayout(D, '19999', 800, 600);
  assert.equal(layout.depth['19999'], 19999);
  assert.equal(layout.edges.length, 19999);
});

test('U5 unloaded neighbors are skipped and distinct first-hop gaps counted', () => {
  const D = chainsD([{ id: 'A', deps: ['outside', 'B'], children: ['child', 'outside'] }, { id: 'B', deps: ['outside'] }]);
  const set = chainOf(D, 'A');
  assert.deepEqual([...set], ['A', 'B']);
  assert.deepEqual(chainGaps(D, set), { unloaded: 2, missing: 0 });
  assert.equal(treeLayout(D, 'A', 800, 600).ids.length, 2);
  assert.deepEqual([...chainOf(D, 'removed')], ['removed']);
});

test('U6 unknown missing links stay unknown while numeric missing links sum', () => {
  const D = chainsD([{ id: 'A', deps: ['B'], deps_missing: 2 }, { id: 'B', deps_missing: 3 }]);
  assert.deepEqual(chainGaps(D, chainOf(D, 'A')), { unloaded: 0, missing: 5 });
  D.byId.B.deps_missing = null;
  assert.deepEqual(chainGaps(D, chainOf(D, 'A')), { unloaded: 0, missing: null });
});

test('U7 fit ignores null and non-finite history ends, returns local midnight', () => {
  const early = new Date(2026, 8, 6, 13).getTime(), later = early + 86400000;
  const D = chainsD([{ id: 'A', sec: 'hist', end: null, deps: ['B', 'C', 'D'] }, { id: 'B', sec: 'hist', end: later },
    { id: 'C', sec: 'hist', end: early }, { id: 'D', sec: 'hist', end: NaN }]);
  assert.equal(fitFrom(D, 'A'), new Date(2026, 8, 6).getTime());
  D.byId.B.end = null; D.byId.C.end = null;
  assert.equal(fitFrom(D, 'A'), null);
});

test('U8 unknown status fields never claim known progress, dates, state or queue', () => {
  assert.equal(treeStatus({ sec: 'hist', status: 'done', end: null }), 'Merged · date unknown');
  assert.equal(treeStatus({ sec: 'hist', status: 'done', end: new Date(2026, 8, 6).getTime() }), 'Merged Sep 6');
  assert.equal(treeStatus({ sec: 'hist', status: 'failed', end: null }), 'Failed');
  assert.equal(treeStatus({ sec: 'hist', status: 'not_planned', end: null }), 'Not planned');
  assert.equal(treeStatus({ sec: 'hist', status: 'closed', end: null }), 'Closed');
  assert.equal(treeStatus({ sec: 'now', agent: { state: null }, pct: null }), 'State unknown · —');
  assert.equal(treeStatus({ sec: 'now', agent: null, pct: null }), 'State unknown · —');
  assert.equal(agentState(null).cls, null);
  assert.equal(treeStatus({ sec: 'now', agent: { state: 'active' }, pct: 0 }), 'Running · 0%');
  assert.equal(treeStatus({ sec: 'now', agent: { state: 'error' }, pct: 63 }), 'Error · 63%');
  assert.equal(treeStatus({ sec: 'plan', qpos: null, wave: null }), 'Q? · W?');
  assert.equal(treeStatus({ sec: 'plan', qpos: 2, wave: 3 }), 'Q2 · W3');
  assert.equal(treeStatus({ sec: 'plan', wave: 1 }, () => 'Not filed'), 'Not filed · W1');
  assert.equal(treeStatus({ sec: 'nq' }), 'Not queued');
});

test('U9 null numbers sort by stable id after numbered members and epic order', () => {
  const D = chainsD([{ id: 'root', deps: ['z', 'a', 'numbered', 'infra'] },
    { id: 'z', num: null }, { id: 'a', num: null }, { id: 'numbered', num: 7 }, { id: 'infra', epic: 'infra', num: 1 }]);
  assert.deepEqual(treeLayout(D, 'root', 800, 600).rows[0], ['numbered', 'a', 'z', 'infra']);
});

test('layout uses design wrapping, centering, scaling and cubic geometry', () => {
  const D = chainsD([{ id: 'root', deps: ['a', 'b', 'c', 'd', 'e'] }, ...['a', 'b', 'c', 'd', 'e'].map(id => ({ id }))]);
  const layout = treeLayout(D, 'root', 400, 200);
  assert.equal(layout.per, 2);
  assert.equal(layout.natW, 406);
  assert.equal(layout.natH, 268);
  assert.equal(layout.sc, 0.8);
  assert.deepEqual(layout.pos.e, { x: 105, y: 124 });
  assert.deepEqual(layout.pos.root, { x: 105, y: 218 });
  assert.equal(layout.edges[0].path, 'M98 50 C98 132 203 132 203 214');
  assert.equal(layout.edges[0].arrow, 'M199 208 L203 215 L207 208z');
});
