import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isUnfiled, refText, refTitle, queueText, srcLine, findWas } from '../../priv/static/build-home/unfiled.js';
import { stClass, stText } from '../../priv/static/build-home/list.js';
import { treeStatus } from '../../priv/static/build-home/chains.js';
import { headerHTML } from '../../priv/static/build-home/modal/header.js';
const pack = { id: 'pack:demo/A', sec: 'plan', num: null, qpos: null, src: { kind: 'pack', path: 'docs/build-plan.md', wave: null }, title: '<img src=x>', wave: 1 };
test('filed unknown references and invalid queues remain distinct from unfiled', () => {
  for (const num of [null, undefined, NaN, Infinity, '1<b>']) {
    assert.equal(refText({num}), '#—');
    assert.equal(refTitle({num}), 'Ticket number unknown');
  }
  for (const qpos of [NaN, Infinity, '1<b>']) assert.equal(queueText({num: 9, qpos}), 'Q—');
  assert.equal(queueText({num: 9, qpos: null}), 'Q?');
  assert.equal(refText(pack), '—');
  assert.equal(queueText(pack), 'Not filed');
});
test('unfiled identities and unknown queue positions are explicit', () => {
  assert.equal(isUnfiled(null), false); assert.equal(isUnfiled(undefined), false); assert.equal(isUnfiled(pack), true); assert.equal(refText(pack), '—'); assert.equal(refTitle(pack), 'Not filed yet');
  assert.equal(refText({num: 57}), '#57'); assert.equal(queueText(pack), 'Not filed');
  assert.equal(queueText({num: 9, qpos: null}), 'Q?'); assert.equal(queueText({num: 9, qpos: 3}), 'Q3');
  assert.equal(stClass(pack), 'open'); assert.equal(stText(pack), 'Not filed'); assert.equal(treeStatus(pack), 'Not filed · W1');
});
test('source phases preserve zero and omit unknown phase', () => {
  assert.equal(srcLine(pack), 'docs/build-plan.md · not filed yet');
  assert.equal(srcLine({...pack, src: {...pack.src, wave: 0}}), 'docs/build-plan.md · wave 0 · not filed yet');
});
test('filed alias lookup resolves old pack identity', () => {
  const filed = {id:'57', was:pack.id}; assert.equal(findWas([filed], pack.id), filed); assert.equal(findWas([filed], 'pack:demo/X'), null);
});
test('modal header uses the source and safely renders a pack title', () => {
  const html = headerHTML(pack);
  assert.match(html, /Planned · not filed/); assert.match(html, /title="Not filed yet">—/);
  assert.match(html, /aria-disabled="true" title="From docs\/build-plan.md"/);
  assert.match(html, /&lt;img src=x&gt;/); assert.doesNotMatch(html, /#null|Qnull/);
});
test('pack-only first wave is not ready and unavailable packs retain the marker', async () => {
  const { computeLayout } = await import('../../priv/static/build-home/layout.js');
  const { resetState, S } = await import('../../priv/static/build-home/state.js');
  resetState();
  const D = {hist:[],now:[],plan:[{...pack,epic:null}],nq:[],epics:{},features:{},byId:{}};
  const sources = {queue:{state:'ok'},index:{state:'ok'},history:{state:'ok'},packs:{state:'unavailable',observed_at:0,reason:'1 of 2 planning packs could not be read'}};
  const L = computeLayout(D,S,{vpW:1440,vpH:1000,gut:80},sources);
  assert.equal(L.secs.plan.labels[0].t, '1');
  assert.equal(L.secs.plan.marks.at(-1).label, 'Planning packs unavailable');
  assert.match(L.secs.plan.marks.at(-1).sub, /1 of 2.*checked/);
  const healthy = computeLayout(D,S,{vpW:1440,vpH:1000,gut:80},{...sources,packs:{state:'ok'}});
  assert.equal(healthy.secs.plan.marks.length,0);
  assert.ok(Math.abs(L.secs.plan.h - healthy.secs.plan.h - 104) < 0.001);
});
test('an empty planned list preserves escaped pack failures and observation time', async () => {
  const { listHTML } = await import('../../priv/static/build-home/list.js');
  const { resetState, S } = await import('../../priv/static/build-home/state.js');
  resetState();
  const D = {hist:[],now:[],plan:[],nq:[],epics:{},features:{},children:{}};
  const sources = {queue:{state:'ok'},index:{state:'ok'},history:{state:'ok'},packs:{state:'unavailable',observed_at:0,reason:'1 of 2 <broken> packs'}};
  const html = listHTML(D,S,{more:false},{sources},0);
  assert.match(html, /data-sec="plan"/);
  assert.match(html, /Planning packs unavailable.*1 of 2 &lt;broken&gt; packs.*checked/);
  assert.doesNotMatch(html, /<broken>/);
});
