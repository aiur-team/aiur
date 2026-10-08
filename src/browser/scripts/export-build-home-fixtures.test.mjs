import test from 'node:test';
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
  for (const k of manifest.datasets) assert.equal(fixture(k).meta.now, manifest.now);
});
test('open-ended feature keeps Infinity', () => {
  assert.equal(JSON.parse(files['live.json']).data.features.pag.to, 'Infinity');
  assert.equal(fixture('live').data.features.pag.to, Infinity);
  assert.doesNotMatch(files['live.json'], /"to":null/);
});
test('export is lossless', () => {
  const { dataFor } = loadBuildJs({ designDir, expose: ['dataFor'] });
  for (const k of ['live', 'dense', 'newrepo', 'noqueue', 'offline']) {
    const { kind, all, byId, ...raw } = structuredClone(dataFor(k));
    assert.deepEqual(fixture(k).data, raw);
  }
});
test('absent stays absent', () => {
  const { hist, plan, nq } = fixture('live').data;
  assert.equal(plan.length + nq.length, 76);
  for (const row of [...plan, ...nq]) assert.equal(Object.hasOwn(row, 'start'), false);
  for (const row of hist) {
    assert.equal(Object.hasOwn(row, 'est'), false);
    assert.equal(row.agent.state, null);
  }
});
test('dataset census', () => {
  const expected = { live: [332, 248, 8, 54, 22, 2, 'AIUR-595'],
    dense: [1384, 1300, 8, 54, 22, 12, 'AIUR-1286'],
    newrepo: [64, 0, 4, 54, 6, 2, null], noqueue: [278, 248, 8, 0, 22, 2, 'AIUR-595'] };
  for (const [k, counts] of Object.entries(expected)) {
    const d = fixture(k).data;
    assert.deepEqual([d.hist.length + d.now.length + d.plan.length + d.nq.length,
      d.hist.length, d.now.length, d.plan.length, d.nq.length, Object.keys(d.features).length, d.failedId], counts);
  }
});
test('offline is live plus a daemon block', () => {
  assert.deepEqual(fixture('offline').data, fixture('live').data);
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
  writeFileSync(join(dir, 'dense.json'), files['dense.json'].replace('dense', 'xxxxx'));
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
