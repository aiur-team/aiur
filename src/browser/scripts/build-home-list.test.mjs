import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { listHTML, stClass, stText } from '../../priv/static/build-home/list.js';
import { resetState, S } from '../../priv/static/build-home/state.js';
const P = JSON.parse(readFileSync(new URL('../../test/fixtures/build_home/live.json', import.meta.url)));
resetState();
const state = structuredClone(S);
const row = (sec, patch = {}) => ({ ...P.sections[sec][0], ...patch });
const data = sections => ({ epics: P.epics, features: P.features, children: {}, now: [], plan: [], nq: [], hist: [], ...sections });
const html = (sections, sources = P.sources, history = { more: false }) => listHTML(data(sections), state, history, { sources }, P.now);
const cell = (t, key) => html({ [t.sec]: [t] }).match(new RegExp('class="c-' + key + '" role="cell"[^>]*>(.*?)</span>(?=<span class="c-|</div>)'))?.[1];

test('U1 unknown pct has no progress hue, bar or percentage', () => {
  assert.equal(cell(row('now', { pct: null }), 'pg'), '<span class=\"lr-mu\">—</span>');
  assert.match(cell(row('now', { pct: 42 }), 'pg'), /--pct:42%;--ph:85.*width:42%.*42%/);
});
test('U2 unknown state does not become Running', () => {
  for (const agent of [null, { state: null }, { state: 'nope' }]) {
    const t = row('now', { agent }); assert.equal(stClass(t), 'unknown'); assert.equal(stText(t), 'State unknown');
  }
});
test('usage limits and CI wait keep their causes; unknown states never become Parked', () => {
  const usage = row('now', { agent: { state: 'usage_limited', resume_at: 1791408000000 } });
  assert.equal(stText(usage), 'Paused · usage limit (resumes at 21:20 UTC)');
  assert.notEqual(stText(usage), 'Parked');
  assert.equal(stText(row('now', { agent: { state: 'usage_limited', resume_at: null } })), 'Paused · usage limit');
  assert.equal(stText(row('now', { agent: { state: 'ci_wait' } })), 'Waiting for CI');
  assert.equal(stText(row('now', { agent: { state: null } })), 'State unknown');
});
test('U3 closures preserve their reason', () => {
  for (const [status, cls, label] of [['not_planned', 'np', 'Not planned'], ['closed', 'closed', 'Closed'], ['running', 'unknown', 'State unknown']]) {
    const t = row('hist', { status }); assert.equal(stClass(t), cls); assert.equal(stText(t), label);
  }
});
test('U4 unknown or reversed start has no invented duration', () => {
  for (const start of [null, P.now + 1]) assert.equal(cell(row('hist', { start, end: P.now }), 'pg'), '<span class=\"lr-mu\">Oct 7 · —</span>');
});
test('U5 unknown estimate and wave remain unknown; override wins', () => {
  const t = row('plan', { qpos: 4, wave: 2, est: null, override: null });
  assert.equal(cell(t, 'pg'), '<span class=\"lr-mu\">Q4 · W2 · —</span>');
  assert.match(cell({ ...t, override: { hours: 6 } }, 'pg'), /Q4 · W2 · ≈6h/);
  assert.match(cell({ ...t, est: 7, wave: null }, 'pg'), /Q4 · W\? · ≈7h/);
});
test('U6 missing points are not zero', () => assert.equal(cell(row('nq', { pts: null }), 'pg'), '<span class=\"lr-mu\">— pts</span>'));
test('U7 unsupported models keep names and letter circles', () => {
  assert.equal(cell(row('now', { agent: { model: 'muse', name: 'Muse' } }), 'ag'), '<span class="ax-mono" aria-hidden="true">M</span>Muse');
  assert.equal(cell(row('now', { agent: { model: null, name: null } }), 'ag'), '<span class="ax-mono" aria-hidden="true">?</span>Model unknown');
  assert.equal(cell(row('now', { agent: null }), 'ag'), '<span class=\"lr-mu\">—</span>');
});
test('U8 payload strings cannot create markup or styles', () => {
  const text = '<img src=x onerror="x">\'&';
  const out = html({ now: [row('now', { id: text, title: text, num: text, agent: { model: 'muse', name: text } })] }, { ...P.sources, queue: { state: 'unavailable', reason: text } });
  assert.ok(!out.includes(text)); assert.ok(!out.includes('<img')); assert.match(out, /&lt;img/); assert.match(out, /&#39;/);
  const d = data({ now: [row('now')] }); d.epics = { ...P.epics, [row('now').epic]: { label: text, hue: Infinity, icon: 'missing' } };
  assert.ok(!listHTML(d, state, {}, P, P.now).includes('Infinity'));
});
test('U9 missing metadata uses Unsorted without a feature diamond', () => {
  const out = html({ nq: [row('nq', { epic: 'gone', feature: 'gone' })] });
  assert.match(out, /lr-ep un/); assert.match(out, /Unsorted/); assert.ok(!out.includes('class="lr-f"'));
});
test('U10 section heads expose unavailable causes and read ages', () => {
  assert.ok(!html({}).includes('data-sec="plan"'));
  const source = { state: 'unavailable', reason: 'timeout', observed_at: P.now - 360000 };
  const out = html({}, { ...P.sources, queue: source, open_tickets: { ...source, reason: 'queue_unavailable' }, history: undefined });
  assert.match(out, /unavailable · timed out · read 6 min ago \(14:14\)/);
  assert.match(out, /unavailable · queue_unavailable · read 6 min ago/);
  assert.match(out, /unavailable · unknown cause · no successful read recorded/);
  assert.match(html({ plan: [row('plan')] }, { ...P.sources, queue: source }), /1 in build-queue order · unavailable, showing the read 6 min ago/);
  assert.match(html({}, { ...P.sources, queue: { ...source, state: 'disabled', reason: 'configured off' } }), /disabled · configured off/);
  assert.match(html({}, { ...P.sources, open_tickets: { ...source, state: 'incomplete', reason: 'incomplete' } }), /incomplete · the read was partial · read 6 min ago/);
  assert.match(html({}, { ...P.sources, open_tickets: { state: 'unavailable', reason: 'open_tickets_loading', observed_at: null } }), /the open-ticket listing is in progress/);
  assert.match(html({ hist: [row('hist')] }, { ...P.sources, history: { state: 'stale', observed_at: null } }), /stale, no successful read recorded/);
});
test('retrying agents are counted separately from running and timeout cause is readable', () => {
  const retrying = row('now', { status: 'queued', agent: { state: 'retrying', model: null, name: null } });
  const out = html({ now: [row('now'), retrying] }, { ...P.sources, open_tickets: { state: 'unavailable', reason: 'open_tickets_timeout', observed_at: null } });
  assert.match(out, /1 running · 1 retrying/);
  assert.match(out, /the open-ticket listing timed out/);
});
test('live list header accounts for every row state', () => {
  const rows = [
    row('now', { agent: { state: 'active' } }), row('now', { id: 'retry', agent: { state: 'retrying' } }),
    row('now', { id: 'error', agent: { state: 'error' } }), row('now', { id: 'command', agent: { state: 'command' } }),
    row('now', { id: 'paused', agent: { state: 'paused' } }), row('now', { id: 'unknown', agent: { state: null } })
  ];
  assert.match(html({ now: rows }), /1 running · 1 retrying · 2 stuck · 1 paused · 1 state unknown/);
});
test('U11 long sections render every row and healthy empty sections stay hidden', () => {
  const out = html({ nq: Array.from({ length: 600 }, (_, i) => row('nq', { id: String(i) })) });
  assert.equal((out.match(/class="lr nq"/g) || []).length, 600); assert.match(out, /600 open/);
  assert.equal((html({}).match(/role="row"/g) || []).length, 1);
});
test('U12 history newest first (future regression guard matching design)', () => {
  const out = html({ hist: [row('hist', { id: 'a', end: 100 }), row('hist', { id: 'b', end: 300 }), row('hist', { id: 'c', end: 200 })] });
  assert.deepEqual([...out.matchAll(/data-id="([abc])"/g)].map(m => m[1]), ['b', 'c', 'a']);
});
test('builders use passed filter state independently of global S', () => {
  const d = data({ nq: [row('nq')] }), own = { ...state, f: { ...state.f, epic: ['gone'] } };
  assert.ok(!listHTML(d, own, {}, P, P.now).includes('class="lr nq"'));
});

test('unsupported tracker retains its known cause and age; unknown tags remain unknown', () => {
  const src = { state: 'unsupported', reason: 'tracker_unsupported', observed_at: P.now - 60000 };
  assert.match(html({}, { ...P.sources, open_tickets: src }), /unavailable · this tracker has no open-ticket index · read 1 min ago/);
  assert.match(html({}, { ...P.sources, open_tickets: { ...src, state: 'bogus' } }), /unavailable · unknown cause · no successful read recorded/);
});
test('loading history button stays disabled across list renders', () => {
  assert.match(html({}, P.sources, { more: true, state: 'loading' }), /id="lr-more" disabled aria-busy="true"/);
  assert.ok(!html({}, P.sources, { more: true, state: 'idle' }).includes('aria-busy'));
});
