import test from 'node:test';
import { mapRawToPayload } from './build-home-fixture-map.mjs';
import assert from 'node:assert/strict';
import { mkdtempSync, cpSync, readFileSync, writeFileSync, appendFileSync, readdirSync, rmSync, symlinkSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { buildAll, loadBuildJs, encode, decode, API_ROWS } from './export-build-home-fixtures.mjs';

const out = fileURLToPath(new URL('../../test/fixtures/build_home/', import.meta.url));
const designDir = join(out, 'design-source');
const script = fileURLToPath(new URL('./export-build-home-fixtures.mjs', import.meta.url));
const files = buildAll();
const fixture = k => decode(files[`${k}.json`]);
const source = readFileSync(join(designDir, 'assets/build.js'), 'utf8');
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
    assert.ok(source.includes(`tag: "${row.tag}", pct: ${row.pct}, bar: bar([${row.pct}]), reset: "${row.reset}", win: "${row.win}"`));
    assert.ok(source.includes(`head: "${row.head}", rows: [["${row.rows[0][0]}", "${row.rows[0][1]}"]]`));
  }
});
test('GitHub is one icon row with the design core and GraphQL lines, without Search', () => {
  const { apis } = fixture('live').usage;
  assert.equal(apis.length, 1);
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
  for (const f of readdirSync(a)) assert.equal(readFileSync(join(a, f), 'utf8'), readFileSync(join(b, f), 'utf8'));
});
test('trailing slash design paths preserve exported files and checks', t => {
  assert.deepEqual(buildAll({ designDir: `${designDir}/` }), buildAll({ designDir }));
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
