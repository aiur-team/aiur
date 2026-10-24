import { test } from 'node:test';
import assert from 'node:assert/strict';
import { activeFeature, layoutExt, figuresHTML, loadFeatureSpan } from '../../priv/static/build-home/features.js';
import { S, ctx, fx, resetState } from '../../priv/static/build-home/state.js';
import { H } from '../../priv/static/build-home/history.js';
const row = (id, feature, end = null, deps = [], also = []) => ({ id, feature, end, deps, also });
function setup() {
  resetState(); S.feature = 'f'; S.fmode = 'compact'; S.histFrom = 20;
  const all = [row('u1', null, 1), row('u2', null, 2), row('owner', 'f', 3, ['ghost', 'missing']), row('ghost', null, 4), row('also', 'other', 5, [], ['f']), row('plan', null)];
  ctx.D = { all, byId: Object.fromEntries(all.map(t => [t.id, t])), features: { f: { oldest: 1 } } };
  return all;
}
test('own-key activation leaves unknown and prototype slugs inactive', () => {
  setup(); assert.equal(activeFeature(), 'f');
  for (const key of ['nope', 'constructor', 'toString', null]) {
    S.feature = key; assert.equal(activeFeature(), null); assert.deepEqual(layoutExt(ctx.D, S), { compact: false });
  }
});
test('compact entries preserve members, also-affects, loaded ghosts and every gap count', () => {
  const all = setup(), ext = layoutExt(ctx.D, S);
  assert.equal(ext.compact, true);
  assert.deepEqual(ext.entries(all), [{ gap: { n: 2, a: 1, b: 2 } }, { t: all[2], ghost: false }, { t: all[3], ghost: true }, { t: all[4], ghost: false }, { gap: { n: 1, a: null, b: null } }]);
  S.fmode = 'focus'; assert.deepEqual(layoutExt(ctx.D, S), { compact: false });
});
test('unknown figures retain explicit lower bounds and unavailable branches', () => {
  const s = { done: null, done_min: 5, total: 12, pct: null, pct_min: 41, reasons: ['progress', 'status'], baseline: false, spark: [], also: 0 };
  const html = figuresHTML(s, 42);
  assert.match(html, /at least 5 done · unknown: progress, status">—\/12/);
  assert.match(html, /at least 41% weighted · unknown: progress, status">—<\/b>/);
  assert.match(html, /No baseline set">— → 12<svg/); assert.ok(!html.includes('<em>'));
  assert.match(figuresHTML({ ...s, pct_min: null, reasons: ['no_weight'] }, 42), /No weighted tickets">—/);
  assert.match(figuresHTML({ ...s, pct_min: null, reasons: ['complexity'] }, 42), /unknown: complexity">—/);
  assert.equal(figuresHTML(null, 42).match(/Feature figures unavailable">—/g).length, 3);
  assert.ok(!figuresHTML(null, 42).includes('polyline'));
});
test('known figures and sparkline keep exact design coordinates without titles', () => {
  const s = { done: 7, total: 12, pct: 64, orig: 10, added: 2, baseline: true, spark: [10, 11, 12] };
  const html = figuresHTML(s, 42);
  assert.match(html, />7\/12<\/b>/); assert.match(html, />64%<\/b>/);
  assert.match(html, /10 → 12 <em>\+2<\/em>/); assert.match(html, /points="1.0,20.0 38.0,11.0 75.0,2.0"/); assert.ok(!html.includes('title='));
  assert.match(figuresHTML({ ...s, spark: [12] }, 42), /points="0.0,10.0"/);
});
test('feature span starts a page for an active feature and skips inactive features', async () => {
  setup(); ctx.root = { isConnected: true, dataset: {} }; ctx.life = { disposed: false }; H.more = true; ctx.proto.epoch = 'e';
  let calls = 0;
  ctx.push = async () => { calls++; return { kind: 'error' }; };
  fx.renderHeads = () => {};
  ctx.D.features.null = { oldest: 1 }; S.feature = null;
  await loadFeatureSpan(null); assert.equal(calls, 0);
  S.feature = 'f';
  await loadFeatureSpan('f'); assert.equal(calls, 1);
  assert.equal(H.state, 'error'); assert.equal(S.feature, 'f');
  S.feature = null; await loadFeatureSpan('f'); assert.equal(calls, 1);
  ctx.life.disposed = true;
});
test('fixture mapper supplies the actual oldest owner or also closure', async () => {
  const { buildAll } = await import('./export-build-home-fixtures.mjs');
  const files = buildAll(), live = JSON.parse(files['live.json']);
  assert.equal(live.features.khala.oldest, 1789577727067);
  assert.equal(live.features.pag.oldest, 1790702007063);
  assert.notEqual(live.features.khala.oldest, live.features.khala.from);
});
