#!/usr/bin/env node
// `pack:check`: the tarball this package would publish installs and renders on
// its own, in a directory that has nothing else in it.
//
// The consumer is deliberately bare — no `aiur-style`, no bundler, no daemon —
// because that is the claim the package makes: a plain page can parse the
// document and render both views from it.
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));

// Declared before the pack/install block so the consumer can be written as soon
// as the tarball is installed. A `const` read before its declaration throws
// instead of yielding `undefined`, so the order here is load-bearing.
const consumerSource = `
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import {
  BUILD_ORDER_CONTRACT,
  ELEMENT_NAME,
  parseBuildOrder,
  renderGraph,
  renderReview,
} from 'aiur-build-order';

const require = createRequire(import.meta.url);
const manifest = require('aiur-build-order/package.json');
const reference = JSON.parse(readFileSync(${JSON.stringify(`${root}fixtures/build-order.v1.json`)}, 'utf8'));
const unavailable = JSON.parse(readFileSync(${JSON.stringify(`${root}fixtures/build-order-unavailable.v1.json`)}, 'utf8'));

if (Object.keys(manifest.dependencies ?? {}).length !== 0) throw new Error('the tarball has a runtime dependency');
if (manifest.peerDependencies['aiur-style'] === undefined) throw new Error('aiur-style is not a declared peer');
if (BUILD_ORDER_CONTRACT !== 'aiur.build_order' || ELEMENT_NAME !== 'aiur-build-order') throw new Error('wrong contract constants');

const parsed = parseBuildOrder(reference);
if (!parsed.ok) throw new Error(parsed.error.message);
if (parsed.document.tickets.length !== 6) throw new Error('the document lost tickets');

const review = renderReview(reference);
for (const needle of ['data-ticket="BO-004"', 'data-edge-kind="depends_on"', 'data-edge-state="terminal_unsatisfied"', 'aiur-bo-legend-item']) {
  if (!review.includes(needle)) throw new Error('the review is missing ' + needle);
}

const graph = renderGraph(reference);
if (!graph.startsWith('<svg')) throw new Error('the graph is not an SVG');
if (!graph.includes('data-gate="GATE-001"')) throw new Error('the graph lost its gate');

const unknown = renderReview(unavailable);
if (!unknown.includes('data-section="status-banner" data-status="unknown"')) throw new Error('the unknown banner is missing');
if (unknown.includes('data-percent=')) throw new Error('an unknown document rendered a known bar');

const broken = parseBuildOrder('{ not json');
if (broken.ok || broken.error.code !== 'not_json') throw new Error('a broken document did not return a structured error');

const stylesheet = readFileSync(require.resolve('aiur-build-order/aiur-build-order.css'), 'utf8');
if (!stylesheet.includes('var(--aiur-')) throw new Error('the stylesheet does not read aiur-style tokens');

process.stdout.write('rendered review ' + review.length + ' bytes, graph ' + graph.length + ' bytes');
`;

const consumer = mkdtempSync(join(tmpdir(), 'aiur-build-order-consumer-'));

try {
  const packed = run('npm', ['pack', '--json', '--pack-destination', consumer], root);
  const [{ filename, files }] = JSON.parse(packed.stdout);
  assertFiles(files.map((file) => file.path));

  writeFileSync(join(consumer, 'package.json'), JSON.stringify({ name: 'aiur-build-order-consumer', private: true, type: 'module' }), 'utf8');
  run('npm', ['install', '--ignore-scripts', '--no-audit', '--no-fund', join(consumer, filename)], consumer);

  writeFileSync(join(consumer, 'consumer.mjs'), consumerSource, 'utf8');
  const output = run(process.execPath, ['consumer.mjs'], consumer).stdout.trim();
  process.stdout.write(`${output}\npack:check ok: ${filename} renders in an isolated consumer\n`);
} catch (error) {
  process.stderr.write(`pack:check failed: ${error.message}\n`);
  process.exitCode = 1;
} finally {
  rmSync(consumer, { recursive: true, force: true });
}

function assertFiles(paths) {
  const required = ['dist/index.js', 'dist/index.d.ts', 'dist/aiur-build-order.css', 'README.md', 'package.json'];
  const missing = required.filter((path) => !paths.includes(path));
  if (missing.length > 0) throw new Error(`the tarball is missing: ${missing.join(', ')}`);
}

function run(command, args, cwd) {
  const result = spawnSync(command, args, { cwd, encoding: 'utf8' });
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(' ')} exited ${result.status ?? 'without a status'}\n${result.stdout}${result.stderr}`);
  }
  return result;
}
