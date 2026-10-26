import { test } from 'node:test';
import assert from 'node:assert/strict';
import { activeFeature, layoutExt, figuresHTML, loadFeatureSpan } from '../../priv/static/build-home/features.js';
import { S, ctx, fx, resetState } from '../../priv/static/build-home/state.js';
import { H } from '../../priv/static/build-home/history.js';
import { listHTML } from '../../priv/static/build-home/list.js';
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
test('feature progress keeps known closed ratios and hatches only the unknown remainder', () => {
  resetState(); S.list = 'features';
  const rows = [
    ['f-part-2', 'part2', 'Wave 1 refactor (part 2/3)', '1', 88, 6, 0, 94],
    ['f-part-3', 'part3', 'Wave 1 refactor (part 3/3)', '1', 49, 20, 0, 71],
    ['f-other', 'other', 'Other work', '2', 298, 32, 0, 330],
    ['f-bo-6368', 'unassigned', 'Unassigned tickets', '2', 0, 0, 0, 0]
  ];
  const epics = Object.fromEntries(rows.map(([key, feature, label]) => [key, { key, feature, label: key.startsWith('f-bo-') ? 'Build Order 6368' : label }]));
  const features = Object.fromEntries(rows.map(([key, feature, label]) => [feature, { label, epics: [key] }]));
  const progress = {
    features: Object.fromEntries(rows.map(([key, feature, summary, wave, closed, open, unpublished, total]) => [key, {
      feature, closed, open, ci_wait: ['part2', 'part3'].includes(feature) ? null : 0,
      unpublished, total, wave, summary, reason: null
    }])),
    observed_at: Date.now(), plan_version: 'v1', extras: 0
  };
  const html = listHTML({ features, epics, feature_progress: progress }, S, {}, {}, Date.now());
  assert.match(html, /435 \/ 495 tickets closed/);
  assert.match(html, /class="fp-closed" style="width:87\.8787/);
  assert.match(html, /class="fp-open" style="width:11\.7171/);
  assert.match(html, /class="fp-unknown" style="width:0\.4040/);
  assert.match(html, /class="fp-closed" style="width:93\.6170/);
  assert.match(html, /class="fp-closed" style="width:69\.0140/);
  assert.match(html, /class="fp-open" style="width:28\.1690/);
  assert.match(html, /class="fp-unknown" style="width:0\.4040/);
  assert.ok(!html.includes('Unassigned: 0 / 0'));
  const emptyRow = html.split('<button type="button" class="fp-row" data-feature="unassigned"')[1].split('</button>')[0];
  assert.match(emptyRow, /class="fp-bar fp-meter" role="img" aria-label="No tickets to count"/);
  assert.ok(!emptyRow.includes('fp-unknown'));
  const unknownFeatures = { unknown: { label: 'Unknown closed count', epics: ['f-bo-6369-core'] } };
  const unknownEpics = { 'f-bo-6369-core': { key: 'f-bo-6369-core', feature: 'unknown', label: 'Build Order 6369 · Core' } };
  const unknownProgress = { features: { 'f-bo-6369-core': { feature: 'unknown', closed: null, open: 3, ci_wait: 0, unpublished: 0, total: 10, wave: '3' } } };
  const unknownHtml = listHTML({ features: unknownFeatures, epics: unknownEpics, feature_progress: unknownProgress }, S, {}, {}, Date.now());
  const unknownRow = unknownHtml.split('<button type="button" class="fp-row" data-feature="unknown"')[1].split('</button>')[0];
  assert.match(unknownRow, /class="fp-bar fp-meter unknown"/);
  assert.match(unknownRow, /class="fp-unknown"/);
  assert.ok(!unknownRow.includes('fp-closed'));
  assert.match(unknownRow, /class="fp-open" style="width:30%/);
});
test('feature span starts a page for an active feature and skips inactive features', async () => {
  setup(); ctx.root = { isConnected: true, dataset: {} }; ctx.life = { disposed: false }; H.more = true; ctx.proto.epoch = 'e';
  let calls = 0;
  ctx.push = async () => { calls++; return { kind: 'error' }; };
  fx.renderHeads = () => {};
  ctx.D.features.null = { oldest: 1 }; S.feature = null;
  await loadFeatureSpan(null); assert.equal(calls, 0);
  S.feature = 'f'; ctx.D.features.f.oldest = null;
  await loadFeatureSpan('f'); assert.equal(calls, 0);
  ctx.D.features.f.oldest = 1;
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
