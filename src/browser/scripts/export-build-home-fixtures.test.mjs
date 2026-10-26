import test from 'node:test';
import { mapRawToPayload } from './build-home-fixture-map.mjs';
import assert from 'node:assert/strict';
import { mkdtempSync, cpSync, readFileSync, writeFileSync, appendFileSync, readdirSync, rmSync, symlinkSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { buildAll, loadBuildJs, encode, decode, API_ROWS } from './export-build-home-fixtures.mjs';
import { exportTicketDocs } from './build-home-ticket-docs.mjs';

const out = fileURLToPath(new URL('../../test/fixtures/build_home/', import.meta.url));
const designDir = join(out, 'design-source');
const script = fileURLToPath(new URL('./export-build-home-fixtures.mjs', import.meta.url));
const files = buildAll();
const fixture = k => decode(files[`${k}.json`]);
const source = readFileSync(join(designDir, 'assets/build.js'), 'utf8');

test('doc fixtures cover each design ticket and preserve seeded literal body and author', () => {
  for (const dataset of ['live', 'dense', 'newrepo', 'noqueue', 'offline', 'now0', 'now24']) {
    const docs = decode(files[`docs-${dataset}.json`]);
    const rows = Object.values(fixture(dataset).sections).flat();
    assert.deepEqual(Object.keys(docs).sort(), rows.map(row => row.id).sort());
    assert.ok(rows.every(row => ['maya', 'devon', 'priya', 'sam'].includes(docs[row.id].author)));
  }
  assert.deepEqual(decode(files['docs-live.json'])['351'], {
    body_md: 'Implement cache GitHub API responses. Operators lose context when the daemon restarts mid-run, and this is one of the last gaps.\n\n#### Scope\n\n- Touch only the infra module and its tests\n- Feature-flag anything user-visible\n- Reuse the existing retry and cursor helpers\n\n#### Done when\n\n- No new lint or type errors\n- p95 latency unchanged on the 10k-event fixture\n- Docs updated where behaviour changed',
    author: 'sam',
  });
});

test('doc exporter refuses Markdown that changes the design literal text', () => {
  for (const text of ['`code`', '*emphasis*', '[link]', '# heading', '> quote', '- list', '1. list']) {
    for (const field of ['sum', 'scope', 'done']) {
      const row = { id: 'AIUR-1', sum: 'summary', scope: ['scope'], done: ['done'], author: 'sam' };
      row[field] = field === 'sum' ? text : [text];
      assert.throws(() => exportTicketDocs([row]), /Markdown-active fixture text/);
    }
  }
});
function temp(t) {
  const dir = mkdtempSync(join(tmpdir(), 'build-home-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}
function run(args, zone = 'America/Los_Angeles') {
  return spawnSync(process.execPath, [script, ...args], { env: { ...process.env, TZ: zone }, encoding: 'utf8' });
}
function exportTo(t) {
  const dir = temp(t);
  assert.equal(run(['--out', dir, '--design', designDir]).status, 0);
  return dir;
}

test('refuses a zone other than America/Los_Angeles', t => {
  const dir = temp(t);
  for (const flag of [[], ['--check']]) {
    const result = run(['--out', dir, '--design', designDir, ...flag], 'UTC');
    assert.equal(result.status, 2);
    assert.match(result.stderr, /export needs TZ=America\/Los_Angeles, got UTC/);
    assert.deepEqual(readdirSync(dir), []);
  }
});
test('NOW is 2026-10-07 14:20 Pacific', () => {
  const manifest = JSON.parse(files['manifest.json']);
  assert.equal(manifest.now, 1791408000000);
  assert.equal(manifest.now_iso, '2026-10-07T14:20:00-07:00');
  for (const k of manifest.datasets) assert.equal(fixture(k).now, manifest.now);
});
test('open-ended feature becomes null on the wire', () => {
  assert.equal(fixture('live').features.pag.to, null);
});
test('absent values become explicit null', () => {
  const { hist, plan, nq } = fixture('live').sections;
  assert.equal(plan.length + nq.length, 76);
  for (const row of [...plan, ...nq]) assert.equal(row.start, null);
  for (const row of hist) { assert.equal(row.est, null); assert.equal(row.agent.state, null); }
});
test('dataset census', () => {
  const expected = { live: [332, 248, 8, 54, 22], dense: [1384, 1300, 8, 54, 22],
    newrepo: [64, 0, 4, 54, 6], noqueue: [278, 248, 8, 0, 22] };
  for (const [k, counts] of Object.entries(expected)) {
    const d = fixture(k).sections;
    assert.deepEqual([d.hist.length + d.now.length + d.plan.length + d.nq.length,
      d.hist.length, d.now.length, d.plan.length, d.nq.length], counts);
  }
});
test('offline is live plus a daemon block', () => {
  assert.deepEqual(fixture('offline').sections, fixture('live').sections);
  assert.deepEqual(fixture('offline').daemon, { state: 'offline', heartbeat_at: 1791407640000, observed_at: 1791408000000 });
  assert.deepEqual(fixture('live').daemon, { state: 'live', heartbeat_at: 1791408000000, observed_at: 1791408000000 });
});
test('check fails on design drift', t => {
  const dir = temp(t);
  cpSync(designDir, dir, { recursive: true });
  appendFileSync(join(dir, 'assets/build.js'), '\n');
  const result = run(['--check', '--design', dir]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /design file assets\/build.js changed/);
  assert.doesNotMatch(result.stderr, /fixture .* is stale/);
});
test('check fails on a stale fixture', t => {
  const dir = exportTo(t);
  writeFileSync(join(dir, 'dense.json'), files['dense.json'].replace('snapshot', 'xxxxx'));
  const result = run(['--check', '--out', dir, '--design', designDir]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /fixture dense.json is stale/);
});
test('anchor must occur once', t => {
  const dir = temp(t);
  cpSync(designDir, dir, { recursive: true });
  for (const [count, text] of [[0, source.replace('  window.AiurBuild = {', '  window.Other = {')],
    [2, source + '\n//  window.AiurBuild = {']]) {
    writeFileSync(join(dir, 'assets/build.js'), text);
    assert.throws(() => loadBuildJs({ designDir: dir, expose: ['NOW'] }), new RegExp(`anchor .* found ${count} times`));
  }
});
test('API usage literals still in build.js', () => {
  for (const row of API_ROWS) {
    assert.ok(source.includes(`api: true, tag: "${row.tag}", pct: ${row.pct}, bar: bar([${row.pct}], null, true), reset: "${row.reset}", win: "${row.win}"`));
    assert.ok(source.includes(`head: "${row.head}", rows: [["${row.rows[0][0]}", "${row.rows[0][1]}"]]`));
  }
});
test('GitHub is icon row with design core and GraphQL lines alongside Search', () => {
  const { apis } = fixture('live').usage;
  assert.equal(apis.length, 2);
  assert.equal(apis[1].name, 'Search');
  assert.equal(apis[1].icon, 'bars');
  assert.equal(apis[0].name, 'GitHub');
  assert.equal(apis[0].icon, 'github');
  assert.equal(apis[0].session, null);
  assert.equal(apis[0].weekly, null);
  assert.deepEqual(apis[0].lines, API_ROWS.slice(0, 2).map(a => ({ tag: a.tag, acc: [a.pct],
    reset_at: 1791408000000 + Number.parseInt(a.reset, 10) * 60000,
    win: a.win, tip: a.rows, hold_until: null })));
});
test('provider logos use LOGOS keys instead of design asset paths', () => {
  assert.deepEqual(fixture('live').usage.providers.map(p => [p.name, p.logo]),
    [['Claude', 'claude'], ['Codex', 'codex'], ['Kimi', 'kimi'], ['DeepSeek', 'deepseek']]);
  const { dataFor, NOW } = loadBuildJs({ designDir, expose: ['dataFor', 'NOW'] });
  const mapped = mapRawToPayload({ meta: { now: NOW, tz: 'America/Los_Angeles' }, data: dataFor('live'),
    usage: { models: [{ name: 'Unknown', logo: 'assets/unknown.svg' }, { name: 'Claude', logo: 'claude' }],
      apis: API_ROWS }, daemon: fixture('live').daemon });
  assert.deepEqual(mapped.usage.providers.map(p => p.logo), [null, 'claude']);
});
test('usage mapper preserves unknown windows and optional observation fields', () => {
  const { dataFor, NOW } = loadBuildJs({ designDir, expose: ['dataFor', 'NOW'] });
  const lines = [{ tag: 'session', acc: [null], reset_at: null, win: null,
    tip: [['Limits', 'not observed']], hold_until: NOW + 60000 }];
  const provider = { name: 'Unknown', session: { acc: [null], reset: null, win: null },
    lines, icon: null, stale: true, observed_at: NOW - 1000, note: 'Last known' };
  const mapped = mapRawToPayload({ meta: { now: NOW, tz: 'America/Los_Angeles' }, data: dataFor('live'),
    usage: { models: [provider, { name: 'Missing' }], apis: [{ tag: 'core', pct: null }] }, daemon: fixture('live').daemon });
  assert.deepEqual(mapped.usage.providers[0].session, { acc: [null], reset_at: null, win: null });
  assert.deepEqual(mapped.usage.providers[0].lines, lines);
  for (const key of ['icon', 'stale', 'observed_at', 'note']) assert.equal(mapped.usage.providers[0][key], provider[key]);
  assert.deepEqual(mapped.usage.apis[0].lines[0].acc, [null]);
  for (const key of ['lines', 'icon', 'observed_at', 'note']) assert.equal(mapped.usage.providers[1][key], null);
  assert.equal(mapped.usage.providers[1].stale, false);
});
test('encode refuses ambiguous values', () => {
  assert.throws(() => encode({ a: { b: NaN } }), /a.b: NaN/);
  assert.throws(() => encode({ a: -Infinity }), /a: -Infinity/);
  assert.throws(() => encode({ t: 'Infinity' }), /t: string "Infinity"/);
  assert.deepEqual(decode(encode({ to: Infinity })), { to: Infinity });
});
test('loader exposes what it is asked for', () => {
  const { readURL, S } = loadBuildJs({ designDir, expose: ['readURL', 'S'], context: { URLSearchParams, location: { search: '?view=list' } } });
  assert.equal(typeof readURL, 'function');
  assert.equal(typeof S, 'object');
  readURL();
  assert.equal(S.view, 'list');
  assert.throws(() => loadBuildJs({ designDir, expose: ['a; b'] }), /invalid expose name/);
});
test('deterministic', t => {
  const a = exportTo(t), b = exportTo(t);
  for (const f of Object.keys(files)) assert.equal(readFileSync(join(a, f), 'utf8'), readFileSync(join(b, f), 'utf8'));
});
test('trailing slash design paths preserve exported files and checks', t => {
  assert.deepEqual(buildAll({ designDir: `${designDir}/` }), files);
  // Existing CLI normalization is a control; the exported API assertion guards the fix.
  const dir = exportTo(t);
  const before = readFileSync(join(dir, 'manifest.json'), 'utf8');
  assert.equal(run(['--out', dir, '--design', `${designDir}/`, '--check']).status, 0);
  assert.equal(run(['--out', dir, '--design', `${designDir}/`]).status, 0);
  assert.equal(readFileSync(join(dir, 'manifest.json'), 'utf8'), before);
});
test('check rejects changed non-JS design assets', t => {
  const dir = exportTo(t);
  const copy = join(dir, 'design-source');
  cpSync(designDir, copy, { recursive: true });
  assert.equal(run(['--out', dir, '--check']).status, 0);
  appendFileSync(join(copy, 'assets/aiur-logo.png'), 'drift');
  const result = run(['--out', dir, '--check']);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /design file assets\/aiur-logo.png changed/);
});
test('no DST inside the fixtures (future re-import guard)', () => {
  assert.deepEqual(JSON.parse(files['manifest.json']).utc_offsets_min, [-420]);
});

test('export rejects symlink design assets', t => {
  const dir = temp(t);
  cpSync(designDir, dir, { recursive: true });
  symlinkSync(join(dir, 'assets/aiur-logo.png'), join(dir, 'assets/linked-logo.png'));
  const result = run(['--out', join(dir, 'export'), '--design', dir]);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /design source contains a symlink/);
});

test('feature statistics oracle contains real design inputs and results', () => {
  const oracle = decode(files['feature-stats.json']);
  assert.deepEqual(Object.keys(oracle), ['live', 'dense', 'newrepo', 'noqueue']);
  let count = 0;
  for (const [dataset, value] of Object.entries(oracle)) {
    const data = fixture(dataset).sections;
    const rows = [...data.hist, ...data.now, ...data.plan, ...data.nq];
    assert.equal(value.now, fixture(dataset).now);
    for (const [key, { expected, members, also }] of Object.entries(value.features)) {
      count++;
      assert.equal(expected.total, members.length);
      const mapped = fixture(dataset).features[key].stats;
      assert.deepEqual(mapped, { ...expected, done_min: expected.done,
        pct: expected.total ? expected.pct : null, pct_min: expected.total ? expected.pct : null,
        baseline: true, reasons: expected.total ? [] : ['no_weight'] });
      assert.deepEqual(members.map(t => t.num), rows.filter(t => t.feature === key).map(t => t.num));
      assert.ok(members.every(t => Number.isInteger(t.created)));
      assert.deepEqual(also, rows.filter(t => t.also.includes(key)).map(t => t.num));
    }
  }
  assert.equal(count, 18);
  assert.ok(JSON.parse(files['manifest.json']).fixture_sha256['feature-stats.json']);
  assert.equal(oracle.live.features.pag.expected.pct, 61);
});

test('missing design statistics map to explicit unavailable statistics', () => {
  const { dataFor, NOW, PSETS } = loadBuildJs({ designDir, expose: ['dataFor', 'NOW', 'PSETS'] });
  const mapped = mapRawToPayload({ meta: { now: NOW, tz: 'America/Los_Angeles' }, data: dataFor('live'),
    usage: { models: PSETS[4], apis: API_ROWS }, daemon: fixture('live').daemon });
  assert.equal(mapped.features.pag.stats, null);
  assert.ok(Object.values(mapped.features).every(f => Object.hasOwn(f, 'stats') && f.stats === null));
});

test('edge fields preserve design children and classify each blocker', () => {
  const { dataFor } = loadBuildJs({ designDir, expose: ['dataFor'] });
  for (const dataset of ['live', 'dense', 'newrepo', 'noqueue']) {
    const raw = structuredClone(dataFor(dataset));
    const payload = fixture(dataset);
    for (const row of Object.values(payload.sections).flat()) {
      const design = raw.byId[`AIUR-${row.id}`];
      assert.deepEqual(row.children, (raw.children[design.id] ?? []).map(id => id.replace('AIUR-', '')));
      assert.equal(row.deps_missing, 0);
      assert.deepEqual(row.dep_states, Object.fromEntries(design.deps.map(id => [id.replace('AIUR-', ''),
        raw.byId[id].status === 'done' ? 'cleared' : raw.byId[id].status === 'failed' ? 'terminal_unsatisfied' : 'blocking'])));
    }
  }
});

test('odd edges are registered outside the design parity datasets', () => {
  const meta = JSON.parse(files['manifest.json']);
  assert.deepEqual(meta.datasets, ['live', 'dense', 'newrepo', 'noqueue', 'offline']);
  assert.deepEqual(meta.extra_datasets, ['odd-edges', 'now0', 'now24']);
  const history = fixture('odd-edges-history');
  const odd = fixture('odd-edges');
  assert.equal(history.rows.length, 12);
  for (const row of Object.values(odd.sections).flat()) {
    assert.deepEqual({ deps: row.deps, children: row.children, dep_states: row.dep_states, deps_missing: row.deps_missing }, history.expected[row.id]);
  }
  assert.equal(history.expected['12'].dep_states['10'], 'terminal_unsatisfied');
  assert.equal(history.expected['16'].dep_states['10'], 'cleared');
  assert.equal(history.expected['14'].deps_missing, 1);
  assert.equal(history.expected['19'].dep_states['18'], 'unknown');
  assert.deepEqual(history.expected['7'].deps, []);
});

test('the design and full motion matrices exclude synthetic edge fixtures', async () => {
  const { PARITY_MATRIX } = await import('../support/design-parity.mjs');
  const meta = JSON.parse(files['manifest.json']);
  assert.deepEqual([...new Set(PARITY_MATRIX.map(cell => cell.dataset))], meta.datasets);
  assert.equal(PARITY_MATRIX.length, 61);
  const motionGroups = PARITY_MATRIX.filter(cell => !cell.reducedMotion)
    .flatMap(cell => ['no-preference', 'reduce'].map(reducedMotion => ({ ...cell, reducedMotion })));
  assert.equal(motionGroups.length, 120);
  assert.ok(motionGroups.every(cell => !meta.extra_datasets.includes(cell.dataset)));
});

test('conversation injection is fixed and all eligible design conversations are exported', () => {
  assert.throws(() => loadBuildJs({ designDir, expose: [], inject: ['convoFor; globalThis.x = 1'] }), /unknown injection/);
  const { dataFor, convoFor } = loadBuildJs({ designDir, expose: ['dataFor'], inject: ['convoFor'] });
  for (const dataset of ['live', 'dense', 'newrepo', 'noqueue', 'offline']) {
    const kind = dataset === 'offline' ? 'live' : dataset;
    const rows = Array.from(dataFor(kind).all).filter(t => t.agent && t.start != null);
    const conversations = decode(files['conversations/' + dataset + '.json']);
    assert.equal(Object.keys(conversations).length, rows.length);
    const t = rows[0], entries = conversations[t.id.replace('AIUR-', '')];
    assert.equal(entries.length, convoFor(kind, t.id).items.length);
    assert.ok(entries.every((o, n) => o.id === 'd:' + n && Number.isInteger(o.at)));
  }
  const states = decode(files['conversations/states.json']);
  assert.equal(states.paged.entries.length, 600);
  assert.equal(states.unknown_time.entries[0].at, null);
});
