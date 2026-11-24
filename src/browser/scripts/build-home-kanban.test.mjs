import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { kanbanColumns, kanbanSize, toggleColumn, DONE_STEP } from '../../priv/static/build-home/kanban.js';
import { resetState, S } from '../../priv/static/build-home/state.js';

const P = JSON.parse(readFileSync(new URL('../../test/fixtures/build_home/live.json', import.meta.url)));
resetState();
const base = structuredClone(S);
const row = (sec, patch = {}) => ({ ...P.sections[sec][0], ...patch });
const data = sections => ({ lanes: P.lanes, features: P.features, children: {}, now: [], plan: [], nq: [], hist: [], ...sections });
const state = patch => ({ ...structuredClone(base), ...patch });
const keys = cols => cols.map(c => c.key);

test('the board opens on Kanban with To do and In progress showing', () => {
  assert.equal(base.view, 'kanban');
  assert.deepEqual(keys(kanbanColumns(data({}), base)), ['plan', 'now']);
});

test('columns run left to right in board order whichever are shown', () => {
  const all = state({ kCols: { nq: true, plan: true, now: true, hist: true } });
  assert.deepEqual(kanbanColumns(data({}), all).map(c => c.label), ['Backlog', 'To do', 'In progress', 'Done']);
});

test('each column holds its own section, and To do keeps build-queue order', () => {
  const q1 = row('plan', { id: 'q1', qpos: 1 }), q2 = row('plan', { id: 'q2', qpos: 2 }), now = row('now', { id: 'n1' });
  const cols = kanbanColumns(data({ plan: [q1, q2], now: [now] }), base);
  assert.deepEqual(cols.map(c => [c.key, c.tickets.map(t => t.id)]), [['plan', ['q1', 'q2']], ['now', ['n1']]]);
});

test('Done lists newest first and holds back past each step', () => {
  const hist = Array.from({ length: DONE_STEP + 5 }, (_, i) => row('hist', { id: 'h' + i, end: P.now - i * 60000, start: P.now - i * 60000 - 1 }));
  const [done] = kanbanColumns(data({ hist: [...hist].reverse() }), state({ kCols: { nq: false, plan: false, now: false, hist: true } }));
  assert.equal(done.count, DONE_STEP + 5);
  assert.equal(done.tickets.length, DONE_STEP);
  assert.equal(done.tickets[0].id, 'h0');
  assert.equal(done.more, 5);
});

test('the last visible column cannot be hidden, so the board is never empty', () => {
  const s = state({ kCols: { nq: false, plan: true, now: false, hist: false } });
  assert.equal(toggleColumn(s, 'plan'), false);
  assert.deepEqual(s.kCols, { nq: false, plan: true, now: false, hist: false });
  assert.equal(toggleColumn(s, 'hist'), true);
  assert.equal(s.kCols.hist, true);
});

test('cards default to small on a narrow board and medium on a wide one; a choice sticks', () => {
  assert.equal(kanbanSize(base, 390), 'line');
  assert.equal(kanbanSize(base, 1280), 'full');
  assert.equal(kanbanSize(state({ kSize: 'full' }), 390), 'full');
});
