// Isolated source probes. Requires Node 24; no browser, packages, daemon or network.
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdtemp, mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { stripTypeScriptTypes } from 'node:module';
import { createHash } from 'node:crypto';
import vm from 'node:vm';

const snapshot = process.argv[2];
assert(snapshot, 'Usage: node website_review_probe.mjs SNAPSHOT');
const sources = {};
async function source(relative) {
  const text = await readFile(path.join(snapshot, relative), 'utf8');
  sources[relative] = createHash('sha256').update(text).digest('hex');
  return text;
}
const dashboard = await source('website/src/dashboard.ts');
const sim = await source('website/src/simData.ts');
const checks = await source('website/scripts/assert-sim.ts');
const golden = await source('website/scripts/dashboard-golden.json');
const capture = await source('website/scripts/capture-dashboard.mjs');
const main = await source('website/src/main.ts');
const temporary = await mkdtemp(path.join(tmpdir(), 'aiur-website-research-'));
const result = { source_sha256: sources, node: process.version };
try {
  await mkdir(path.join(temporary, 'src'));
  await mkdir(path.join(temporary, 'scripts'));
  // Extension rewriting is solely to make the existing TS imports resolvable
  // by native Node; stripTypeScriptTypes removes types, not runtime logic.
  const javascript = text => stripTypeScriptTypes(text).replace(
    /from "(\.\.?\/[^".]+)"/g, 'from "$1.mjs"');
  await writeFile(path.join(temporary, 'src/simData.mjs'), javascript(sim));
  await writeFile(path.join(temporary, 'scripts/assert-sim.mjs'), javascript(checks));
  await writeFile(path.join(temporary, 'scripts/dashboard-golden.json'), golden);
  const harness = `
import { startDashboard } from './src/dashboard.mjs';
globalThis.window = { matchMedia: () => ({ matches: true }), setTimeout };
globalThis.document = {};
globalThis.ResizeObserver = class { observe() {} };
const screen = { innerHTML: '', getBoundingClientRect: () => ({width: 900, height: 600}), querySelector: () => null };
startDashboard(screen);
console.log(JSON.stringify({ hasPostedUserText: screen.innerHTML.includes('lets brainstorm options') }));
`;
  await writeFile(path.join(temporary, 'render.mjs'), harness);
  result.reduced_motion = {};
  assert.equal(dashboard.split('baseMs + 22_000').length, 2, 'Exactly one freeze constant');
  for (const [name, text] of [
    ['baseline', dashboard], ['freeze_at_zero_mutation', dashboard.replace('baseMs + 22_000', 'baseMs + 0')],
  ]) {
    await writeFile(path.join(temporary, 'src/dashboard.mjs'), javascript(text));
    const run = filename => spawnSync(process.execPath, [filename], {
      cwd: temporary, encoding: 'utf8', timeout: 10_000,
    });
    const suite = run('scripts/assert-sim.mjs');
    const render = run('render.mjs');
    assert.equal(suite.status, 0, suite.stderr + suite.stdout);
    assert.equal(render.status, 0, render.stderr);
    result.reduced_motion[name] = {
      suite_exit: suite.status, suite_stdout: suite.stdout.trim(),
      render: JSON.parse(render.stdout),
    };
  }
  assert.equal(result.reduced_motion.baseline.render.hasPostedUserText, true);
  assert.equal(result.reduced_motion.freeze_at_zero_mutation.render.hasPostedUserText, false);

  const readiness = capture.slice(capture.indexOf('async function waitUntilReady('),
    capture.indexOf('\nasync function assertSyntheticPage('));
  assert(readiness.startsWith('async function waitUntilReady('));
  let clock = 0;
  let releaseFetch;
  let fetchOptions;
  const context = vm.createContext({
    Date: { now: () => clock }, baseURL: 'http://127.0.0.1:1', authorizationHeader: 'synthetic',
    fetch: (_url, options) => {
      fetchOptions = options;
      return new Promise(resolve => { releaseFetch = resolve; });
    },
    setTimeout: () => { throw new Error('Unexpected retry'); },
  });
  const wait = vm.runInContext(readiness + '\nwaitUntilReady', context);
  let settled = false;
  const pending = wait({exitCode: null}).then(() => { settled = true; });
  clock = 31_000;
  await new Promise(resolve => setImmediate(resolve));
  result.readiness = {
    fake_elapsed_ms: clock, settled_while_fetch_pending: settled,
    fetch_has_abort_signal: Object.hasOwn(fetchOptions, 'signal'),
  };
  assert.equal(settled, false);
  releaseFetch({ok: true, text: async () => 'dec-example-blocking EX-143'});
  await pending;
  result.readiness.accepted_response_after_deadline = settled;

  const copySource = main.slice(main.indexOf('async function copyText('),
    main.indexOf('\ncopyBtn?.addEventListener('));
  let fallbackCalls = 0;
  const copyContext = vm.createContext({
    navigator: {clipboard: {writeText: async () => { throw new Error('denied'); }}},
    document: {
      createElement: () => ({style: {}, setAttribute() {}, select() {}, remove() {}}),
      body: {appendChild() {}}, execCommand: () => { fallbackCalls++; return false; },
    },
  });
  const copy = vm.runInContext(stripTypeScriptTypes(copySource) + '\ncopyText', copyContext);
  await copy('synthetic command');
  result.clipboard = {primary: 'rejected', fallback_return: false, fallback_calls: fallbackCalls,
    copy_function: 'resolved despite both clipboard paths failing'};
  assert.equal(fallbackCalls, 1);
  result.limits = 'Synthetic source-level probes only. The reduced-motion harness checks generated HTML with a minimal DOM, not layout or a browser. Readiness uses a fake clock and fetch promise, not a live stalled fixture. Clipboard uses API doubles. No production files modified and no live Aiur or shared release executed.';
  console.log(JSON.stringify(result, null, 2));
} finally {
  await rm(temporary, {recursive: true, force: true});
}
