import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, renameSync, mkdirSync, existsSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve, join, relative } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import vm from 'node:vm';
import { mapRawToPayload } from './build-home-fixture-map.mjs';

const TZ = 'America/Los_Angeles';
const ETAG = '1791431544512943';
const ANCHOR = '  window.AiurBuild = {';
const DEFAULT_OUT = fileURLToPath(new URL('../../test/fixtures/build_home/', import.meta.url));
const DATASETS = ['live', 'dense', 'newrepo', 'noqueue', 'offline'];
const designFiles = dir => {
  const entries = readdirSync(dir, { recursive: true, withFileTypes: true });
  assert.ok(!entries.some(e => e.isSymbolicLink()), 'design source contains a symlink');
  return entries.filter(e => e.isFile()).map(e => relative(dir, join(e.parentPath, e.name))).sort();
};
// build.js:1031–1036: API usage is literal render data, unlike PSETS.
export const API_ROWS = [
  { tag: 'core', pct: 5, reset: '37m', win: '1h', head: 'GitHub core · resets in 37m', rows: [['Requests left', '4,736 of 5,000']] },
  { tag: 'gql', pct: 0, reset: '20m', win: '1h', head: 'GitHub GraphQL · resets in 20m', rows: [['Points left', '4,998 of 5,000']] },
  { tag: 'credits', pct: 0, reset: '22d', win: '30d', head: 'Search · renews in 22d', rows: [['Credits left', '90.0K']] },
];
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');

export function loadBuildJs({ designDir, expose, context = {} }) {
  const src = readFileSync(join(designDir, 'assets/build.js'), 'utf8');
  const count = src.split(ANCHOR).length - 1;
  assert.equal(count, 1, `build.js anchor '${ANCHOR}' found ${count} times`);
  for (const name of expose) assert.match(name, /^[A-Za-z_$][\w$]*$/, `invalid expose name: ${name}`);
  const patched = src.replace(ANCHOR, `  window.__E8 = { ${expose.join(', ')} };\n${ANCHOR}`);
  const ctx = { window: {}, document: {}, location: { search: '' }, history: {}, ...context };
  vm.runInContext(patched, vm.createContext(ctx), { filename: 'build.js', timeout: 10000 });
  return ctx.window.__E8;
}

function walk(value, visit, path = '') {
  visit(value, path);
  if (value && typeof value === 'object') {
    for (const [key, child] of Object.entries(value)) walk(child, visit, path ? `${path}.${key}` : key);
  }
}

export function encode(value) {
  walk(value, (v, path) => {
    if (typeof v === 'number' && !Number.isFinite(v) && v !== Infinity) throw new Error(`${path}: ${v}`);
    if (v === 'Infinity') throw new Error(`${path}: string "Infinity" would decode as a number`);
  });
  return JSON.stringify(value, (_key, v) => v === Infinity ? 'Infinity' : v) + '\n';
}

export function decode(text) {
  return JSON.parse(text, (_key, v) => v === 'Infinity' ? Infinity : v);
}

function raw(d) {
  const ids = rows => Array.from(rows, row => row.id);
  assert.deepEqual(ids(d.all), ids([...d.hist, ...d.now, ...d.plan, ...d.nq]));
  const { kind, all, byId, ...data } = d;
  return data;
}

export function buildAll({ designDir = join(DEFAULT_OUT, 'design-source') } = {}) {
  const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  if (zone !== TZ) throw new Error(`export needs TZ=${TZ}, got ${zone}`);
  const { dataFor, NOW, PSETS } = loadBuildJs({ designDir, expose: ['dataFor', 'NOW', 'PSETS'] });
  assert.equal(NOW, 1791408000000, `NOW moved: ${new Date(NOW).toISOString()}`);
  const files = {};
  for (const dataset of DATASETS) {
    files[`${dataset}.json`] = encode(mapRawToPayload({
      meta: { dataset, now: NOW, tz: TZ, design_etag: ETAG },
      data: raw(dataFor(dataset === 'offline' ? 'live' : dataset)),
      usage: { models: PSETS[4], apis: API_ROWS },
      daemon: { state: dataset === 'offline' ? 'offline' : 'live',
        heartbeat_at: dataset === 'offline' ? NOW - 360000 : NOW, observed_at: NOW },
    }));
  }
  const hostile = JSON.parse(files['live.json']);
  hostile.sections.now[0].title = `<img src=x onerror="window.__xss=1">'"&`;
  Object.values(hostile.epics)[0].label = '<b>x</b>';
  Object.values(hostile.features)[0].label = '<b>x</b>';
  hostile.sections.plan[0].cue.held = '" onmouseover="window.__xss=1';
  hostile.sections.plan[0].override = { hours: 1, reason: '" onmouseover="window.__xss=1', by: 'fixture', at: NOW };
  files['hostile.json'] = encode({ snapshot: hostile, invalid_title_base64: Buffer.from([65, 255, 66]).toString('base64') });
  files['usage-sets.json'] = encode(PSETS);
  const offsets = new Set();
  for (const text of Object.values(files)) walk(decode(text), v => {
    if (Number.isFinite(v) && v >= 1.7e12 && v <= 1.9e12) offsets.add(-new Date(v).getTimezoneOffset());
  });
  files['manifest.json'] = encode({
    schema: 'build-home-payload/1', ids: Object.fromEntries(DATASETS.flatMap(k => Object.values(JSON.parse(files[`${k}.json`]).sections).flat().map(r => [`AIUR-${r.num}`, r.id]))), now: NOW, now_iso: '2026-10-07T14:20:00-07:00', tz: TZ,
    design_etag: ETAG, datasets: DATASETS,
    design_sha256: Object.fromEntries(designFiles(designDir).map(f => [f, sha256(readFileSync(join(designDir, f)))])),
    fixture_sha256: Object.fromEntries(Object.entries(files).map(([f, text]) => [f, sha256(text)])),
    utc_offsets_min: [...offsets].sort((a, b) => a - b), node: process.version,
  });
  return files;
}

function checkFiles(files, out) {
  const oldManifest = join(out, 'manifest.json');
  const old = existsSync(oldManifest) ? JSON.parse(readFileSync(oldManifest, 'utf8')) : {};
  const manifest = JSON.parse(files['manifest.json']);
  const errors = [];
  for (const f of new Set([...Object.keys(old.design_sha256 ?? {}), ...Object.keys(manifest.design_sha256)])) {
    if (old.design_sha256?.[f] !== manifest.design_sha256[f]) {
      errors.push(`design file ${f} changed (sha ${manifest.design_sha256[f]}) — run npm run fixtures:build-home`);
    }
  }
  // The recorded Node version describes the export, not the machine checking it.
  manifest.node = old.node;
  files['manifest.json'] = encode(manifest);
  for (const [f, text] of Object.entries(files)) {
    if (f === 'manifest.json' && errors.length) continue;
    const path = join(out, f);
    if (!existsSync(path) || readFileSync(path, 'utf8') !== text) {
      errors.push(`fixture ${f} is stale — run npm run fixtures:build-home`);
    }
  }
  if (errors.length) throw new Error(errors.join('\n'));
}

function main(args) {
  let out = DEFAULT_OUT, designDir, check = false;
  while (args.length) {
    const flag = args.shift();
    if (flag === '--check') check = true;
    else if ((flag === '--out' || flag === '--design') && args[0] && !args[0].startsWith('--')) {
      const value = resolve(args.shift());
      if (flag === '--out') out = value;
      else designDir = value;
    } else throw new Error(`unknown or incomplete flag: ${flag}`);
  }
  const files = buildAll({ designDir: designDir ?? join(out, 'design-source') });
  if (check) return checkFiles(files, out);
  mkdirSync(out, { recursive: true });
  for (const [f, text] of Object.entries(files)) {
    writeFileSync(join(out, `${f}.tmp`), text);
    renameSync(join(out, `${f}.tmp`), join(out, f));
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try { main(process.argv.slice(2)); }
  catch (error) { console.error(error.message); process.exitCode = 2; }
}
