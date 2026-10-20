import test from 'node:test';
import assert from 'node:assert/strict';
import { ctx, resetState } from '../../priv/static/build-home/state.js';
import { drawEdges, edgeClass, edgeEmphasis, edgeGeometry } from '../../priv/static/build-home/edges.js';

const t = (dep_states, cue) => ({ dep_states, cue });

test('edgeClass maps server dep states', () => {
  assert.equal(edgeClass(t({ a: 'cleared' }), 'a'), 'ok');
  assert.equal(edgeClass(t({ a: 'blocking' }), 'a'), 'bl');
  assert.equal(edgeClass(t({ a: 'terminal_unsatisfied' }), 'a'), 'bad');
  assert.equal(edgeClass(t({ a: 'cleared' }), 'a', true), 'gh');
});
test('edgeClass keeps unknown edges neutral', () => {
  for (const row of [t({ a: 'unknown' }), t({ a: 'cyclic' }), t({ a: 'bogus' }), t({}), t(null), t(undefined), t('x')]) assert.equal(edgeClass(row, 'a'), '');
});
test('edgeClass cue failure wins over blocking and unknown, not cleared', () => {
  assert.equal(edgeClass(t({ a: 'blocking' }, { failed: true }), 'a'), 'bad');
  assert.equal(edgeClass(t({ a: 'unknown' }, { blockedChain: true }), 'a'), 'bad');
  assert.equal(edgeClass(t({ a: 'cleared' }, { failed: true }), 'a'), 'ok');
});
test('edgeEmphasis', () => {
  const chain = new Set(['x', 'y']);
  assert.equal(edgeEmphasis(chain, 'x', 'y', false), ' hl');
  assert.equal(edgeEmphasis(chain, 'x', 'z', false), ' fade');
  assert.equal(edgeEmphasis(null, 'x', 'y', true), ' fade');
  assert.equal(edgeEmphasis(null, 'x', 'y', false), '');
});
const rect = (left, top, width, height) => ({ left, top, width, height, right: left + width, bottom: top + height });
test('edgeGeometry vertical, right and left cases', () => {
  const cr = rect(0, 0, 1000, 1000);
  assert.equal(edgeGeometry(rect(0, 0, 100, 50), rect(0, 100, 100, 50), cr).path, 'M50 50 C50 73.5 50 73.5 50 97');
  assert.match(edgeGeometry(rect(0, 0, 100, 50), rect(0, 100, 100, 50), cr).arrow, /^M46 91 L50 98 L54 91z$/);
  const r = edgeGeometry(rect(0, 0, 100, 50), rect(200, 10, 100, 50), cr);
  assert.equal(r.path, 'M100 25 C148.5 25 148.5 28 197 28');
  assert.equal(r.arrow, 'M191 24 L198 28 L191 32z');
  const l = edgeGeometry(rect(200, 0, 100, 50), rect(0, 10, 100, 50), cr);
  assert.equal(l.arrow, 'M109 24 L102 28 L109 32z');
});

const card = (id, left, top) => ({
  dataset: { id }, style: {}, classList: { contains: () => false },
  getBoundingClientRect: () => rect(left, top, 100, 50),
});
function draw(rows, cards) {
  const svg = { setAttribute() {}, classList: { toggle() {} }, innerHTML: '' };
  Object.assign(ctx, {
    content: { isConnected: true, scrollWidth: 1, scrollHeight: 1, getBoundingClientRect: () => rect(0, 0, 1000, 1000) },
    svg, bandEl: null, cols: [], hoverId: null, proto: { generation: Math.random() },
    D: { byId: Object.fromEntries(rows.map(r => [r.id, r])) }, L: { band: { items: [] } },
    R: new Map(cards.map(c => [c.dataset.id, c])),
  });
  drawEdges(true);
  return svg.innerHTML;
}
const count = (html) => (html.match(/class="bd-eh"/g) || []).length;
test('drawEdges skips self-loops, duplicates, missing ids and non-array deps', () => {
  const html = draw(
    [{ id: 'a', deps: ['a', 'b', 'b', 'zz'] }, { id: 'b', deps: [] }, { id: 'c', deps: 'b' }],
    [card('a', 0, 200), card('b', 0, 0), card('c', 300, 0)]);
  assert.equal(count(html), 1);
});
test('drawEdges tolerates cards and blockers without rows', () => {
  assert.equal(draw([{ id: 'a', deps: ['b'] }], [card('a', 0, 200), card('b', 0, 0), card('x', 0, 400)]), '');
  assert.equal(draw([{ id: 'b', deps: [] }, { id: 'a', deps: ['x'] }], [card('a', 0, 200), card('b', 0, 0), card('x', 0, 400)]), '');
});
test('drawEdges escapes ids in data-e', () => {
  const id = `a"b<c'd&`;
  const html = draw([{ id, deps: ['b'] }, { id: 'b', deps: [] }], [card(id, 0, 200), card('b', 0, 0)]);
  assert.ok(html.includes('data-e="a&quot;b&lt;c&#39;d&amp;"'));
});

test('state-only generation invalidates an unforced draw', () => {
  draw([{ id: 'a', deps: ['b'], dep_states: { b: 'blocking' } }, { id: 'b', deps: [] }], [card('a', 0, 200), card('b', 0, 0)]);
  ctx.D.byId.a.dep_states.b = 'cleared';
  drawEdges(false);
  assert.match(ctx.svg.innerHTML, /class="bd-e bl"/);
  ctx.proto.generation++;
  drawEdges(false);
  assert.match(ctx.svg.innerHTML, /class="bd-e ok"/);
});
test('detached content cannot be mutated by a draw', () => {
  draw([{ id: 'a', deps: ['b'] }, { id: 'b', deps: [] }], [card('a', 0, 200), card('b', 0, 0)]);
  ctx.content.isConnected = false;
  ctx.svg.innerHTML = 'detached';
  drawEdges(true);
  assert.equal(ctx.svg.innerHTML, 'detached');
});
test('reset clears the signature for a new mount', () => {
  const rows = [{ id: 'a', deps: ['b'] }, { id: 'b', deps: [] }], cards = [card('a', 0, 200), card('b', 0, 0)];
  draw(rows, cards); ctx.proto.generation = 1; drawEdges(false);
  const previous = { ...ctx }, svg = { ...ctx.svg, innerHTML: '' };
  resetState(); Object.assign(ctx, previous, { svg });
  drawEdges(false);
  assert.equal(count(svg.innerHTML), 1);
});
// Guard against a future recursive rewrite; the original implementation already handles cycles.
test('guard: cycle stays linear', () => {
  assert.equal(count(draw([{ id: 'a', deps: ['b'] }, { id: 'b', deps: ['a'] }], [card('a', 0, 0), card('b', 0, 100)])), 2);
});
