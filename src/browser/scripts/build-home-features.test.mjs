import { test } from 'node:test';
import assert from 'node:assert/strict';
import { activeFeature, layoutExt, figuresHTML, loadFeatureSpan } from '../../priv/static/build-home/features.js';
import { S, ctx, fx, resetState } from '../../priv/static/build-home/state.js';
import { H } from '../../priv/static/build-home/history.js';
import { listHTML } from '../../priv/static/build-home/list.js';
// The subtitle shows the viewer's local date, so pin the viewer's timezone here instead of
// assuming a negative UTC offset: these date assertions must also pass on a UTC machine.
process.env.TZ = 'America/Los_Angeles';
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
test('feature list rows are table rows of name, bar, merged/total and remaining; registry rows are focusable', () => {
  resetState(); S.list = 'features';
  const bars = [{ key: 'pag', label: 'Pagination', merged: 3, total: 4 }, { key: 'mp-e2', label: 'mp-e2', merged: 2, total: 2 }];
  const html = listHTML({ features: { pag: { label: 'Pagination' } }, feature_progress: { bars }, repo: { url: 'https://github.com/o/aiur/' } }, S, {}, {}, Date.UTC(2026, 10, 1));
  assert.match(html, /<div class="lr-cap fp-sum" role="row"><span role="cell">5 of 6 tickets merged - 2026-10-31<\/span><\/div><\/div>$/);
  assert.ok(!html.includes('data-fsort'));
  assert.ok(!html.includes('<h1'));
  // Same card and header row as the Tickets table.
  assert.match(html, /^<div class="bd-list fp-list" role="table" aria-label="Feature progress" tabindex="-1"><div class="lr lr-h fp-grid" role="row"><span class="fp-name" role="columnheader">Feature<\/span><span class="fp-pg" role="columnheader">Progress<\/span><span class="fp-count" role="columnheader">Merged<\/span><span class="fp-left" role="columnheader">Remaining<\/span><\/div>/);
  assert.match(html, /<div class="lr fp-grid fp-row fp-go" role="row" data-feature="pag" tabindex="0" aria-label="Focus Pagination feature"><span class="fp-name" role="cell" title="Pagination">Pagination<\/span><span class="fp-pg" role="cell"><span class="fp-bar" role="img" aria-label="3 of 4 merged"><i style="width:75%"><\/i><\/span><\/span><span class="fp-count" role="cell">3\/4<\/span><span class="fp-left" role="cell">1<\/span><\/div>/);
  assert.match(html, /<div class="lr fp-grid fp-row" role="row" data-feature="mp-e2"><span class="fp-name" role="cell" title="mp-e2">mp-e2<\/span><span class="fp-pg" role="cell"><span class="fp-bar done"/);
  assert.match(html, /<div class="lr fp-grid fp-row fp-all" role="row"><span class="fp-name" role="cell" title="All features">All features<\/span><span class="fp-pg" role="cell"><span class="fp-bar all" role="img" aria-label="5 of 6 merged">/);
  S.fsort = 'pct';
  assert.ok(listHTML({ features: {}, feature_progress: { bars } }, S, {}, {}, 0).indexOf('mp-e2') < listHTML({ features: {}, feature_progress: { bars } }, S, {}, {}, 0).indexOf('"pag"'));
});
test('epic rows carry their own bar and their features follow in the epic order', () => {
  resetState(); S.list = 'features';
  const bars = [
    { key: 'pag', label: 'Pagination', merged: 3, total: 4 },
    { key: 'mp-e2', label: 'Commands', merged: 2, total: 2 },
    { key: 'loose', label: 'Loose ends', merged: 1, total: 3 }
  ];
  const epics = [{ key: 'launch', label: 'Launch', merged: 4, total: 6, features: ['mp-e2', 'pag'] }];
  const D = { features: { pag: { label: 'Pagination' }, 'mp-e2': { label: 'Commands' } }, feature_progress: { bars, epics } };
  const html = listHTML(D, S, {}, {}, Date.UTC(2026, 10, 1));
  // The epic row keeps the shipped row shape: name, bar, merged/total.
  assert.match(html, /<div class="lr fp-grid fp-row fp-epic-row fp-go" role="row" data-epic="launch" tabindex="0" aria-label="Focus Launch epic features"><span class="fp-name" role="cell" title="Launch">Launch<\/span><span class="fp-pg" role="cell"><span class="fp-bar" role="img" aria-label="4 of 6 merged"><i style="width:66\.6[0-9]*%"><\/i><\/span><\/span><span class="fp-count" role="cell">4\/6<\/span><span class="fp-left" role="cell">2<\/span><\/div>/);
  // Its features follow it in the epic's order; the feature no epic lists comes last, under "No epic".
  assert.deepEqual([...html.matchAll(/data-feature="([^"]+)"/g)].map(match => match[1]), ['mp-e2', 'pag', 'loose']);
  assert.match(html, /<div class="lr fp-grid fp-row fp-noepic-row" role="row"><span class="fp-name" role="cell">No epic<\/span><\/div><div class="lr fp-grid fp-row fp-feat" role="row" data-feature="loose"/);
  // The flat "All features" total still sums the feature rows and sits after the groups.
  assert.match(html, /<div class="lr fp-grid fp-row fp-all" role="row">/);
  assert.ok(html.indexOf('fp-all') > html.indexOf('fp-noepic-row'));
});
test('toolbar sorting reorders features inside an epic without moving the epic row', () => {
  resetState(); S.list = 'features'; S.fsort = 'pct';
  const bars = [
    { key: 'low', label: 'Low', merged: 1, total: 4 },
    { key: 'high', label: 'High', merged: 3, total: 4 },
    { key: 'other', label: 'Other', merged: 0, total: 2 }
  ];
  const epics = [{ key: 'launch', label: 'Launch', merged: 4, total: 8, features: ['low', 'high'] }, { key: 'second', label: 'Second', merged: 0, total: 2, features: ['other'] }];
  const html = listHTML({ features: {}, feature_progress: { bars, epics } }, S, {}, {}, 0);
  assert.deepEqual([...html.matchAll(/data-(?:epic|feature)="([^"]+)"/g)].map(match => match[1]), ['launch', 'high', 'low', 'second', 'other']);
});
test('a payload without epic rows keeps the flat feature list', () => {
  resetState(); S.list = 'features';
  const bars = [{ key: 'pag', label: 'Pagination', merged: 3, total: 4 }];
  const html = listHTML({ features: {}, feature_progress: { bars } }, S, {}, {}, 0);
  assert.ok(!html.includes('fp-epic-row'));
  assert.ok(!html.includes('No epic'));
  assert.match(html, /<div class="lr fp-grid fp-row" role="row" data-feature="pag">/);
});
test('unavailable feature bars render no invented totals', () => {
  resetState(); S.list = 'features';
  const html = listHTML({ features: {}, feature_progress: { bars: null } }, S, {}, {}, 0);
  assert.match(html, /<div class="lr-cap fp-sum" role="row"><span role="cell">Feature progress unavailable - 1969-12-31<\/span><\/div>/);
  assert.ok(!html.includes('fp-all')); assert.ok(!html.includes('0 of 0'));
});
test('feature subtitle uses the viewer local date and keeps sorting outside the list', () => {
  resetState(); S.list = 'features'; S.view = 'list';
  const now = Date.UTC(2026, 10, 1, 2);
  const html = listHTML({ features: {}, feature_progress: { bars: [] } }, S, {}, {}, now);
  assert.match(html, /tickets merged - 2026-10-31/);
  assert.ok(!html.includes('data-fsort'));
  assert.ok(!html.includes('fp-sort'));
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
