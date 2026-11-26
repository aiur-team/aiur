import assert from 'node:assert/strict';
import test from 'node:test';
import {
  buildOrder,
  buildOrderGolden,
  buildOrderSchema,
  buildOrderUnavailable,
  validateBuildOrder,
} from '../scripts/validate.mjs';

const clone = (value) => structuredClone(value);
const EDGE_KINDS = ['depends_on', 'serializes_with', 'suggested_after', 'contains', 'gates'];

test('golden build order fixtures validate against build-order.v1', () => {
  assert.equal(validateBuildOrder(buildOrder), true);
  assert.equal(validateBuildOrder(buildOrderUnavailable), true);
  assert.equal(validateBuildOrder(buildOrderGolden), true);
});

test('the daemon-published golden document keeps every edge endpoint local', () => {
  const nodes = new Set([
    ...buildOrderGolden.tickets.map((ticket) => ticket.id),
    ...buildOrderGolden.gates.map((gate) => gate.key),
  ]);
  for (const edge of buildOrderGolden.edges) {
    assert.ok(nodes.has(edge.from), `unknown edge source ${edge.from}`);
    assert.ok(nodes.has(edge.to), `unknown edge target ${edge.to}`);
    assert.ok(['pack', 'tracker', 'inferred', 'unknown'].includes(edge.source));
  }

  const kinds = new Set(buildOrderGolden.edges.map((edge) => edge.kind));
  for (const kind of EDGE_KINDS) assert.ok(kinds.has(kind), `golden document has no ${kind} edge`);

  for (const source of ['pack', 'tracker', 'progress']) {
    assert.ok(['known', 'stale', 'unknown'].includes(buildOrderGolden.sources[source].status));
  }
});

for (const key of [
  'contract',
  'contract_version',
  'build_order_id',
  'title',
  'repository',
  'root',
  'generated_at',
  'sources',
  'epics',
  'features',
  'lanes',
  'tickets',
  'edges',
  'gates',
  'waves',
  'critical_path',
  'progress',
]) {
  test(`missing ${key} is invalid`, () => {
    const missing = clone(buildOrder);
    delete missing[key];
    assert.equal(validateBuildOrder(missing), false);
  });
}

test('contract marker and version are pinned', () => {
  const wrongContract = clone(buildOrder);
  wrongContract.contract = 'aiur.ticket';
  assert.equal(validateBuildOrder(wrongContract), false);

  const wrongVersion = clone(buildOrder);
  wrongVersion.contract_version = 2;
  assert.equal(validateBuildOrder(wrongVersion), false);
});

test('additive fields stay valid for forward compatible consumers', () => {
  const additive = clone(buildOrder);
  additive.future_section = { anything: true };
  additive.tickets[0].future_field = 'later';
  assert.equal(validateBuildOrder(additive), true);
});

test('every typed edge kind has a fixture example', () => {
  const kinds = new Set(buildOrder.edges.map((edge) => edge.kind));
  for (const kind of EDGE_KINDS) assert.ok(kinds.has(kind), `no fixture edge of kind ${kind}`);
});

test('an invented edge kind is rejected', () => {
  const invalid = clone(buildOrder);
  invalid.edges[0].kind = 'blocks';
  assert.equal(validateBuildOrder(invalid), false);
});

test('edge kinds outside depends_on carry an open state', () => {
  const depended = buildOrder.edges.filter((edge) => edge.kind === 'depends_on');
  assert.ok(depended.length > 0);
  for (const edge of depended) {
    assert.ok(['cleared', 'blocking', 'terminal_unsatisfied', 'unknown'].includes(edge.state));
  }
  for (const edge of buildOrder.edges.filter((edge) => edge.kind !== 'depends_on')) {
    assert.equal(edge.state, null);
  }
});

test('epic, feature and lane are distinct node fields', () => {
  for (const ticket of buildOrder.tickets) {
    for (const field of ['epic', 'feature', 'lane']) assert.ok(field in ticket);
  }
  const laneKeys = new Set(buildOrder.lanes.map((lane) => lane.key));
  const featureKeys = new Set(buildOrder.features.map((feature) => feature.key));
  const epicKeys = new Set(buildOrder.epics.map((epic) => epic.key));
  for (const ticket of buildOrder.tickets) {
    assert.ok(laneKeys.has(ticket.lane), `unknown lane ${ticket.lane}`);
    assert.ok(featureKeys.has(ticket.feature), `unknown feature ${ticket.feature}`);
    assert.ok(epicKeys.has(ticket.epic), `unknown epic ${ticket.epic}`);
  }
  for (const feature of buildOrder.features) assert.ok(epicKeys.has(feature.epic));
  for (const epic of buildOrder.epics) {
    for (const feature of epic.features) assert.ok(featureKeys.has(feature));
  }
});

test('every edge endpoint names a ticket id or a gate key', () => {
  const known = new Set([
    ...buildOrder.tickets.map((ticket) => ticket.id),
    ...buildOrder.gates.map((gate) => gate.key),
  ]);
  for (const edge of buildOrder.edges) {
    for (const endpoint of [edge.from, edge.to]) {
      assert.ok(known.has(endpoint), `edge endpoint ${endpoint} is not a node or gate in this document`);
    }
  }
});

test('waves cover every ticket exactly once', () => {
  const waved = buildOrder.waves.flatMap((wave) => wave.tickets).sort();
  const tickets = buildOrder.tickets.map((ticket) => ticket.id).sort();
  assert.deepEqual(waved, tickets);
});

test('critical path is wired through dependency edges', () => {
  const dependsOn = new Set(
    buildOrder.edges
      .filter((edge) => edge.kind === 'depends_on')
      .map((edge) => `${edge.from}<-${edge.to}`),
  );
  const path = buildOrder.critical_path.tickets;
  assert.ok(path.length > 1);
  for (const [index, ticket] of path.slice(1).entries()) {
    assert.ok(dependsOn.has(`${ticket}<-${path[index]}`), `${ticket} does not depend on ${path[index]}`);
  }
});

test('an unavailable tracker publishes unknown state instead of an empty graph', () => {
  assert.equal(buildOrderUnavailable.sources.tracker.status, 'unknown');
  assert.equal(buildOrderUnavailable.sources.tracker.reason, 'tracker_unavailable');
  assert.equal(buildOrderUnavailable.progress.status, 'unknown');
  assert.equal(buildOrderUnavailable.critical_path.status, 'unknown');
  assert.ok(buildOrderUnavailable.tickets.length > 0);
  for (const ticket of buildOrderUnavailable.tickets) {
    assert.equal(ticket.status, 'unknown');
    assert.equal(ticket.number, null);
  }
});

test('counts stay nullable so a consumer reads status before totals', () => {
  const knownWithoutCounts = clone(buildOrderUnavailable);
  knownWithoutCounts.progress = { status: 'known' };
  assert.equal(validateBuildOrder(knownWithoutCounts), true);
  const unknownWithoutReason = clone(buildOrderUnavailable);
  delete unknownWithoutReason.sources.tracker.reason;
  assert.equal(validateBuildOrder(unknownWithoutReason), true);
});

test('progress percent stays inside 0-100', () => {
  const invalid = clone(buildOrder);
  invalid.progress.percent = 101;
  assert.equal(validateBuildOrder(invalid), false);
  const negative = clone(buildOrder);
  negative.tickets[0].progress_percent = -1;
  assert.equal(validateBuildOrder(negative), false);
});

test('ticket kind and provenance enums reject invented values', () => {
  const invalidKind = clone(buildOrder);
  invalidKind.tickets[0].kind = 'spike';
  assert.equal(validateBuildOrder(invalidKind), false);
  const invalidProvenance = clone(buildOrder);
  invalidProvenance.tickets[0].provenance = 'guessed';
  assert.equal(validateBuildOrder(invalidProvenance), false);
});

test('the schema declares the draft 2020-12 dialect and a stable id', () => {
  assert.equal(buildOrderSchema.$schema, 'https://json-schema.org/draft/2020-12/schema');
  assert.equal(buildOrderSchema.$id, 'https://aiur.team/schemas/build-order.v1.schema.json');
});
