import assert from 'node:assert/strict';
import test from 'node:test';
import { EDGE_TYPES, renderGraph } from '../src/index.js';
import { documentWith, fixture } from './helpers.mjs';

const reference = () => renderGraph(fixture('build-order.v1.json'));

test('the graph is one SVG holding a node per ticket and one per gate', () => {
  const svg = reference();
  const document = fixture('build-order.v1.json');

  assert.match(svg, /^<svg class="aiur-bo-graph" data-status="known"/);
  assert.match(svg, /role="img"/);
  assert.match(svg, /<title id="[^"]+">/);
  for (const ticket of document.tickets) assert.match(svg, new RegExp(`data-ticket="${ticket.id}"`));
  assert.equal((svg.match(/class="aiur-bo-graph-node"/g) ?? []).length, document.tickets.length);
  for (const gate of document.gates) assert.match(svg, new RegExp(`data-gate="${gate.key}"`));
  assert.match(svg, /GATE-001 · open/);
});

test('waves are columns and lanes are rows, straight from the document', () => {
  const svg = reference();
  const document = fixture('build-order.v1.json');

  for (const wave of document.waves) assert.match(svg, new RegExp(`data-wave="${wave.index}"`));
  for (const lane of document.lanes) assert.match(svg, new RegExp(`data-lane="${lane.key}"`));
  assert.match(svg, /data-section="lanes"/);
});

test('every typed edge draws its own group, style class and state', () => {
  const svg = reference();
  const document = fixture('build-order.v1.json');

  for (const kind of EDGE_TYPES) {
    assert.match(svg, new RegExp(`class="aiur-bo-edge aiur-bo-edge--${kind}"`), `no path for ${kind}`);
    assert.match(svg, new RegExp(`class="aiur-bo-legend-item" data-edge-kind="${kind}"`), `no legend entry for ${kind}`);
  }
  assert.equal((svg.match(/class="aiur-bo-graph-edge"/g) ?? []).length, document.edges.length);
  assert.match(svg, /data-edge-kind="depends_on" data-from="BO-005" data-to="BO-004" data-edge-state="terminal_unsatisfied"/);
  assert.match(svg, /data-edge-kind="gates" data-from="BO-004" data-to="GATE-001"/);
});

test('the critical path and progress reach the nodes', () => {
  const svg = reference();
  const document = fixture('build-order.v1.json');
  const criticalNodes = document.tickets.filter((ticket) => document.critical_path.tickets.includes(ticket.id));

  assert.equal((svg.match(/data-critical="true"/g) ?? []).length, criticalNodes.length);
  const progress = document.progress;
  assert.match(svg, new RegExp(`class="aiur-bo-graph-summary"[^>]*>${progress.percent}% · ${progress.done}/${progress.total} done`));
  assert.match(svg, /41h critical path/);
});

test('an unknown document draws a banner and no percent anywhere', () => {
  const svg = renderGraph(fixture('build-order-unavailable.v1.json'));

  assert.match(svg, /^<svg class="aiur-bo-graph" data-status="unknown"/);
  assert.match(svg, /class="aiur-bo-graph-banner" data-section="status-banner" data-status="unknown"/);
  assert.match(svg, /Build order is unknown/);
  assert.doesNotMatch(svg, />\d+%</);
  assert.doesNotMatch(svg, /\d+%/);
  assert.match(svg, /progress unknown/);
  assert.match(svg, />—</);
  // The two tickets the document still knows about stay on the canvas.
  assert.match(svg, /data-ticket="BO-001"/);
  assert.match(svg, /data-ticket="BO-002"/);
});

test('a document with no waves still lays its tickets out', () => {
  const svg = renderGraph(documentWith({ waves: [], critical_path: { status: 'unknown', tickets: [], hours: null, reason: null } }));
  assert.match(svg, /data-wave="unscheduled"/);
  assert.equal((svg.match(/class="aiur-bo-graph-node"/g) ?? []).length, fixture('build-order.v1.json').tickets.length);
});

test('an unusable document throws instead of drawing an empty canvas', () => {
  assert.throws(() => renderGraph('{ not json'), (error) => error.code === 'not_json');
  assert.throws(
    () => renderGraph(fixture('build-order-invalid.v1.json')),
    (error) => error.code === 'invalid_edge',
  );
});

test('the viewBox is sized to the content it drew', () => {
  const svg = reference();
  const [, width, height] = svg.match(/viewBox="0 0 (\d+(?:\.\d+)?) (\d+(?:\.\d+)?)"/) ?? [];
  assert.ok(Number(width) > 400, `width ${width}`);
  assert.ok(Number(height) > 200, `height ${height}`);
});
