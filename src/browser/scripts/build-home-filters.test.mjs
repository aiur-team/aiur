import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const root = process.env.FILTER_MUTATION_ROOT;
const moduleURL = name => root ? pathToFileURL(root + '/src/priv/static/build-home/' + name + '.js') : new URL('../../priv/static/build-home/' + name + '.js', import.meta.url);
const { resetState, S, ctx } = await import(moduleURL('state'));
const { tstate, astate, match } = await import(moduleURL('match'));
const { FOPTS, rowOk, layoutKey } = await import(moduleURL('filters'));
const { intake } = await import(moduleURL('protocol'));
const fixture = name => JSON.parse(readFileSync(new URL('../../test/fixtures/build_home/' + name + '.json', import.meta.url)));
function init(name = 'unknowns') { resetState(); ctx.D = intake(fixture(name)); }
test('unknown history status and closed never become merged', () => {
  init(); S.f.tstate = ['merged'];
  for (const status of ['closed', 'weird']) {
    const t = { sec: 'hist', status }; assert.equal(tstate(t), null); assert.equal(match(t), false);
  }
  assert.equal(match({ sec: 'hist', status: 'done' }), true);
});
test('unknown agent is never running or no agent; missing cue stays unknown', () => {
  init(); assert.equal(tstate({ sec: 'plan', cue: null }), null);
  for (const agent of [null, { state: null }, { state: 'bogus' }]) {
    const t = { sec: 'now', agent }; assert.equal(astate(t), null);
    for (const value of ['active', 'none']) { S.f.astate = [value]; assert.equal(match(t), false); }
  }
});
test('not planned changes layout eligibility and key, other states only match', () => {
  init(); const t = ctx.D.byId['9010'];
  assert.equal(rowOk(S, t), false); const before = layoutKey(S);
  S.f.tstate = ['not planned']; assert.equal(rowOk(S, t), true); assert.notEqual(layoutKey(S), before);
  S.f.epic = ['docs']; assert.equal(rowOk(S, t), false);
  S.f.epic = []; S.f.model = ['codex']; assert.equal(rowOk(S, t), true); assert.equal(match(t), false);
});
test('model options include selected unloaded keys but never null models', () => {
  init(); S.f.model = ['unloaded'];
  const opts = FOPTS().model.opts;
  assert.deepEqual(opts.map(o => o[0]), ['claude', 'codex', 'deepseek', 'kimi', 'muse', 'openrouter', 'unloaded', 'zz-new']);
  assert.deepEqual(opts.slice(4).map(o => [o[2], o[5]]), [[null, 'M'], [null, 'O'], [null, 'U'], [null, 'Z']]);
});
test('feature options sort independently of map order and preserve unknown progress', () => {
  init('dense'); S.feature = 'd0'; ctx.D.features = Object.fromEntries(Object.entries(ctx.D.features).reverse());
  ctx.D.features.d9.stats = { ...ctx.D.features.d9.stats, pct: null, pct_min: 40, reasons: ['progress'] };
  ctx.D.features.d8.stats = null;
  const opts = FOPTS().feature.opts;
  assert.deepEqual(opts.map(o => o[0]), ['d6', 'd7', 'd8', 'd9', 'khala', 'pag', 'd0']);
  assert.equal(opts.find(o => o[0] === 'd9')[1], 'Notifications  —');
  assert.equal(opts.find(o => o[0] === 'd9')[6], 'at least 40% weighted · unknown: progress');
  assert.equal(opts.find(o => o[0] === 'd8')[1].endsWith('  —'), true);
});

test('unknown epic counts keep defined options; known zero counts stay excluded', () => {
  init('live'); const D = ctx.D;
  D.order = ['bugs', 'infra', 'docs', 'absent'];
  for (const counts of [null, undefined]) {
    D.counts = counts;
    assert.deepEqual(FOPTS().epic.opts.map(o => o[0]), ['bugs', 'infra', 'docs']);
  }
  D.counts = { bugs: 0, infra: 3, docs: 0, absent: 5 };
  assert.deepEqual(FOPTS().epic.opts.map(o => o[0]), ['infra']);
});
