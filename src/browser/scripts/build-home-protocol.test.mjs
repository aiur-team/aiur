import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { loadBuildJs } from './export-build-home-fixtures.mjs';
// Static assets are ES modules served by the endpoint, outside a Node package.
const source = readFileSync(new URL('../../priv/static/build-home/protocol.js', import.meta.url), 'utf8');
const { decide, intake, esc } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const dir = new URL('../../test/fixtures/build_home/', import.meta.url);
const fixture = kind => JSON.parse(readFileSync(new URL(`${kind}.json`, dir), 'utf8'));
const state = { epoch: 'E', generation: 3 };
const msg = (kind, epoch = 'E', generation = 4) => ({ v: 1, kind, epoch, generation });

for (const [name, state_, message, expected] of [
  ['version mismatch', null, { ...msg('snapshot'), v: 2 }, 'reload'],
  ['error', state, { v: 1, kind: 'error', reason: 'unavailable' }, 'ignore'],
  ['diff before snapshot', null, msg('diff'), 'ignore'],
  ['first snapshot', null, msg('snapshot'), 'apply'],
  ['new epoch snapshot', state, msg('snapshot', 'F', 0), 'apply'],
  ['stale snapshot', state, msg('snapshot', 'E', 2), 'ignore'],
  ['duplicate snapshot', state, msg('snapshot', 'E', 3), 'ignore'],
  ['new snapshot', state, msg('snapshot'), 'apply'],
  ['next diff', state, msg('diff'), 'apply'],
  ['duplicate diff', state, msg('diff', 'E', 3), 'ignore'],
  ['old diff', state, msg('diff', 'E', 2), 'ignore'],
  ['gap', state, msg('diff', 'E', 5), 'resync'],
  ['different epoch diff', state, msg('diff', 'F', 1), 'resync'],
  ['single flight', { ...state, resyncing: true }, msg('diff', 'E', 5), 'ignore'],
  ['same epoch page', state, msg('earlier', 'E', 1), 'apply'],
  ['old epoch page', state, msg('earlier', 'F'), 'ignore'],
]) test(`decide: ${name}`, () => assert.equal(decide(state_, message), expected));

const { dataFor } = loadBuildJs({ designDir: fileURLToPath(new URL('design-source/', dir)), expose: ['dataFor'] });
for (const kind of ['live', 'dense', 'newrepo', 'noqueue']) {
  test(`round trip ${kind}: all loaded pages recover design data`, () => {
    const raw = structuredClone(dataFor(kind));
    const snapshot = fixture(kind);
    // Assemble the initial active-day window followed by all earlier day pages.
    const day = new Intl.DateTimeFormat('en-CA', { timeZone: snapshot.history.tz, year: 'numeric', month: '2-digit', day: '2-digit' });
    // Portable grouping: Map.groupBy needs Node 21+, newer than the harness runtime.
    const pages = new Map();
    for (const row of snapshot.sections.hist) {
      const key = day.format(row.end);
      if (!pages.has(key)) pages.set(key, []);
      pages.get(key).push(row);
    }
    const days = [...pages.keys()].sort().reverse();
    const initialDays = kind === 'dense' ? 1 : 2;
    snapshot.sections.hist = days.slice(0, initialDays).flatMap(key => pages.get(key));
    for (const key of days.slice(initialDays)) snapshot.sections.hist.push(...pages.get(key));
    const actual = intake(snapshot);
    assert.deepEqual(actual.epics, raw.epics);
    const features = Object.fromEntries(Object.entries(raw.features).map(([key, f]) => [key, { ...f, from: f.from == null ? null : Math.trunc(f.from), to: f.to === Infinity ? Infinity : Math.trunc(f.to) }]));
    assert.deepEqual(actual.features, features);
    assert.deepEqual(actual.order, raw.order);
    for (const [key, count] of Object.entries(raw.counts)) assert.equal(actual.counts[key], count);
    for (const key of raw.order) assert.equal(actual.counts[key], raw.counts[key] ?? 0);
    assert.equal(actual.all.length, raw.all.length);
    for (const sec of ['hist', 'now', 'plan', 'nq']) {
      assert.deepEqual(actual[sec].map(r => r.num), raw[sec].map(r => r.num));
      for (const [i, row] of raw[sec].entries()) {
        const mapped = actual[sec][i];
        for (const [key, value] of Object.entries(row)) {
          if (['id', 'deps', 'cue', 'start', 'end', 'created', 'override'].includes(key)) continue;
          assert.deepEqual(mapped[key], value, `${kind} ${row.id}.${key}`);
        }
        for (const [key, value] of Object.entries(row.override ?? {})) assert.deepEqual(mapped.override[key], value);
        assert.equal(mapped.id, String(row.num));
        assert.deepEqual(mapped.deps, row.deps.map(d => d.replace('AIUR-', '')));
        for (const key of ['start', 'end', 'created']) assert.equal(mapped[key], row[key] == null ? null : Math.trunc(row[key]));
        for (const [key, value] of Object.entries(row.cue ?? {})) if (key !== 'promoted') assert.deepEqual(mapped.cue[key], value);
        if (row.cue?.promoted) assert.equal(mapped.cue.promoted, snapshot.now - 6 * 60000);
        assert.equal(actual.byId[mapped.id], mapped);
      }
    }
    assert.deepEqual(actual.children, Object.fromEntries(Object.entries(raw.children).map(([key, ids]) => [key.replace('AIUR-', ''), ids.map(id => id.replace('AIUR-', ''))])));
  });
}

test('intake sorts by ord then num without mutating the snapshot', () => {
  const snapshot = fixture('live');
  const [a, b] = snapshot.sections.now;
  snapshot.sections.now = [{ ...b, ord: 1 }, { ...a, ord: 1 }];
  const original = structuredClone(snapshot);
  assert.deepEqual(intake(snapshot).now.map(r => r.num), [a.num, b.num].sort((x, y) => x - y));
  assert.deepEqual(snapshot, original);
});

test('hostile text stays raw until escaping, including apostrophes', () => {
  const snapshot = fixture('hostile').snapshot;
  const title = intake(snapshot).now[0].title;
  assert.equal(title, `<img src=x onerror="window.__xss=1">'"&`);
  assert.equal(esc(title), '&lt;img src=x onerror=&quot;window.__xss=1&quot;&gt;&#39;&quot;&amp;');
});
