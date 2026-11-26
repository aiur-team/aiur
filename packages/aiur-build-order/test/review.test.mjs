import assert from 'node:assert/strict';
import test from 'node:test';
import { EDGE_TYPES, renderReview } from '../src/index.js';
import { documentWith, fixture } from './helpers.mjs';

const reference = () => renderReview(fixture('build-order.v1.json'));

test('the review renders every ticket, epic, feature and lane in the document', () => {
  const html = reference();
  const document = fixture('build-order.v1.json');

  for (const ticket of document.tickets) assert.match(html, new RegExp(`data-ticket="${ticket.id}"`));
  for (const epic of document.epics) assert.match(html, new RegExp(`data-epic="${epic.key}"`));
  for (const feature of document.features) assert.match(html, new RegExp(`data-feature="${feature.key}"`));
  for (const lane of document.lanes) assert.match(html, new RegExp(`data-lane="${lane.key}"`));
  for (const gate of document.gates) assert.match(html, new RegExp(`data-gate="${gate.key}"`));
  assert.match(html, /<article class="aiur-bo aiur-bo--review" data-status="known"/);
});

test('the review draws one chip and one legend entry for every typed edge', () => {
  const html = reference();

  for (const kind of EDGE_TYPES) {
    assert.match(html, new RegExp(`data-edge-kind="${kind}" data-direction="(in|out)"`), `no chip for ${kind}`);
    assert.match(html, new RegExp(`class="aiur-bo-legend-item" data-edge-kind="${kind}"`), `no legend entry for ${kind}`);
  }
  assert.equal((html.match(/class="aiur-bo-legend-item"/g) ?? []).length, EDGE_TYPES.length);
});

test('a failed dependency is visible as a state on its chip', () => {
  const html = reference();
  assert.match(html, /class="aiur-bo-edge aiur-bo-edge--depends_on" data-edge-kind="depends_on" data-direction="[a-z]+" data-edge-state="terminal_unsatisfied"/);
  assert.match(html, /gated by Approve the review page component/);
});

test('waves, the critical path and progress come from the document', () => {
  const html = reference();
  const document = fixture('build-order.v1.json');

  for (const wave of document.waves) assert.match(html, new RegExp(`data-wave="${wave.index}"`));
  assert.match(html, /data-section="critical-path" data-status="known"/);
  assert.equal((html.match(/data-section="critical-path"[\s\S]*?<\/section>/) ?? [''])[0].match(/<li data-ticket/g)?.length, document.critical_path.tickets.length);
  assert.match(html, /data-percent="16"/);
  assert.match(html, /41h/);
});

test('an unknown document shows an explicit banner and never a zero bar', () => {
  const html = renderReview(fixture('build-order-unavailable.v1.json'));

  assert.match(html, /data-section="status-banner" data-status="unknown"/);
  assert.match(html, /Counts and bars below are unknown, not zero\./);
  assert.match(html, /data-unknown="true"/);
  assert.doesNotMatch(html, /data-percent=/);
  assert.doesNotMatch(html, />\s*0%\s*</);
  assert.doesNotMatch(html, />0% complete/);
  // The tickets the document still knows about stay visible.
  assert.match(html, /data-ticket="BO-001"/);
  assert.match(html, /data-ticket="BO-002"/);
  assert.match(html, /data-section="critical-path" data-status="unknown"/);
});

test('an empty catalog still explains itself instead of rendering nothing', () => {
  const html = renderReview(documentWith({ tickets: [], edges: [], gates: [], waves: [], critical_path: { status: 'unknown', tickets: [], hours: null, reason: 'no root selected' } }));
  assert.match(html, /data-section="tickets" data-status="known"/);
  assert.match(html, /No tickets are published in this document\./);
  assert.match(html, /no root selected/);
});

test('an unusable document throws an error carrying the parser code and path', () => {
  assert.throws(
    () => renderReview('{ not json'),
    (error) => error.code === 'not_json' && Array.isArray(error.path),
  );
  assert.throws(
    () => renderReview(fixture('build-order-invalid.v1.json')),
    (error) => error.code === 'invalid_edge' && error.path.join('.') === 'edges.0.to',
  );
});

test('the renderer escapes text instead of trusting the document', () => {
  const hostile = renderReview(documentWith({
    tickets: [{
      id: 'BO-001',
      number: 1,
      title: '<script>alert(1)</script>',
      url: 'javascript:alert(2)',
      kind: 'executable',
      provenance: 'planned',
      epic: null,
      feature: null,
      lane: null,
      phase: null,
      wave: null,
      complexity: null,
      points: null,
      estimate_hours: null,
      status: 'open',
      progress_percent: 0,
      started_at: null,
      ended_at: null,
    }],
    edges: [],
    gates: [],
    waves: [],
    epics: [],
    features: [],
    lanes: [],
    critical_path: { status: 'unknown', tickets: [], hours: null, reason: null },
  }));
  assert.doesNotMatch(hostile, /<script>alert\(1\)<\/script>/);
  assert.match(hostile, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
  assert.doesNotMatch(hostile, /href="javascript:/);
});
