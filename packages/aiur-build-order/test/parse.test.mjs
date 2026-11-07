import assert from 'node:assert/strict';
import test from 'node:test';
import { parseBuildOrder } from '../src/index.js';
import { documentWith, fixture, fixtureText, ticketWith } from './helpers.mjs';

test('parses the reference fixture into one document', () => {
  const result = parseBuildOrder(fixture('build-order.v1.json'));
  assert.equal(result.ok, true);
  const document = result.document;

  assert.equal(document.contract, 'aiur.build_order');
  assert.equal(document.contract_version, 1);
  assert.equal(document.status, 'known');
  assert.equal(document.build_order_id, 'aiur-team/aiur:build-order-package');
  assert.equal(document.repository, 'aiur-team/aiur');
  assert.equal(document.root.number, 7490);
  assert.equal(document.tickets.length, 6);
  assert.deepEqual(document.waves.map((wave) => wave.index), [1, 2, 3, 4]);
  assert.deepEqual(document.critical_path.tickets, ['BO-001', 'BO-002', 'BO-004', 'BO-005']);
  assert.equal(document.critical_path.hours, 41);
  assert.equal(document.progress.percent, 16);
  assert.equal(document.progress.total, 6);
  const published = fixture('build-order.v1.json').tickets.find((ticket) => ticket.id === 'BO-004');
  assert.equal(document.byId.get('BO-004').title, published.title);
  assert.equal(document.byId.get('BO-004').epic, published.epic);
  assert.equal(document.byId.get('BO-004').lane, published.lane);
});

test('accepts the JSON text a fetch returns', () => {
  const fromText = parseBuildOrder(fixtureText('build-order.v1.json'));
  const fromObject = parseBuildOrder(fixture('build-order.v1.json'));
  assert.equal(fromText.ok, true);
  assert.deepEqual(fromText.document.tickets, fromObject.document.tickets);
});

test('publishes every typed edge with its kind, state and source', () => {
  const document = parseBuildOrder(fixture('build-order.v1.json')).document;
  const kinds = new Set(document.edges.map((edge) => edge.kind));
  assert.deepEqual([...kinds].sort(), ['contains', 'depends_on', 'gates', 'serializes_with', 'suggested_after']);
  assert.deepEqual([...new Set(document.edges.map((edge) => edge.source))].sort(), ['pack', 'tracker']);
  assert.deepEqual(
    [...new Set(document.edges.filter((edge) => edge.kind === 'depends_on').map((edge) => edge.state))].sort(),
    ['blocking', 'cleared', 'terminal_unsatisfied'],
  );
  const gated = document.edges.find((edge) => edge.kind === 'gates');
  assert.equal(gated.to, 'GATE-001');
  assert.equal(gated.toKind, 'gate');
  assert.equal(document.gatesByKey.get('GATE-001').status, 'open');
  assert.equal(document.byId.get('BO-004').edges.length, 7);
});

test('an unknown document keeps its known tickets and publishes no percent', () => {
  const result = parseBuildOrder(fixture('build-order-unavailable.v1.json'));
  assert.equal(result.ok, true);
  const document = result.document;
  assert.equal(document.status, 'unknown');
  assert.equal(document.progress.status, 'unknown');
  assert.equal(document.progress.percent, null);
  assert.equal(document.tickets.length, 2);
  assert.equal(document.tickets[0].progress_percent, null);
  assert.equal(document.critical_path.status, 'unknown');
  assert.equal(document.sources.tracker.status, 'unknown');
  assert.match(document.statusReason, /tracker/);
});

test('marks the critical path and attaches each ticket wave', () => {
  const document = parseBuildOrder(fixture('build-order.v1.json')).document;
  assert.deepEqual(
    document.tickets.filter((ticket) => ticket.critical).map((ticket) => ticket.id),
    ['BO-001', 'BO-002', 'BO-004', 'BO-005'],
  );
  const unscheduled = fixture('build-order.v1.json').tickets.find((ticket) => ticket.id === 'BO-006');
  assert.equal(document.byId.get('BO-006').wave, unscheduled.wave);
});

test('rejects a document whose edges point at a ticket it does not publish', () => {
  const result = parseBuildOrder(fixture('build-order-invalid.v1.json'));
  assert.equal(result.ok, false);
  assert.equal(result.error.code, 'invalid_edge');
  assert.deepEqual(result.error.path, ['edges', 0, 'to']);
  assert.match(result.error.message, /BO-404/);
});

test('rejects an unknown contract and an unknown version separately', () => {
  const wrongContract = parseBuildOrder(documentWith({ contract: 'aiur.other' }));
  assert.equal(wrongContract.error.code, 'unsupported_contract');
  assert.deepEqual(wrongContract.error.path, ['contract']);

  const wrongVersion = parseBuildOrder(documentWith({ contract_version: 2 }));
  assert.equal(wrongVersion.error.code, 'unsupported_version');
  assert.deepEqual(wrongVersion.error.path, ['contract_version']);
});

test('rejects unparseable JSON, non-objects, and a missing required record', () => {
  assert.equal(parseBuildOrder('{ not json').error.code, 'not_json');
  assert.equal(parseBuildOrder('[]').error.code, 'not_an_object');
  assert.equal(parseBuildOrder(null).error.code, 'not_an_object');

  const noTickets = parseBuildOrder(documentWith({ tickets: undefined }));
  assert.equal(noTickets.error.code, 'invalid_field');
  assert.deepEqual(noTickets.error.path, ['tickets']);

  const noProgress = parseBuildOrder(documentWith({ progress: null }));
  assert.equal(noProgress.error.code, 'invalid_field');
  assert.deepEqual(noProgress.error.path, ['progress']);
});

test('rejects a ticket without an id, a title, or with a duplicate id', () => {
  const noId = parseBuildOrder(ticketWith({ id: '   ' }));
  assert.equal(noId.error.code, 'invalid_ticket');
  assert.deepEqual(noId.error.path, ['tickets', 0, 'id']);

  const noTitle = parseBuildOrder(ticketWith({ title: '  ' }));
  assert.equal(noTitle.error.code, 'invalid_ticket');
  assert.deepEqual(noTitle.error.path, ['tickets', 0, 'title']);

  const duplicate = parseBuildOrder({
    ...fixture('build-order.v1.json'),
    tickets: [
      { id: 'BO-001', title: 'a' },
      { id: 'BO-001', title: 'b' },
    ],
    edges: [],
    waves: [],
    critical_path: { status: 'unknown', tickets: [], hours: null, reason: null },
  });
  assert.equal(duplicate.error.code, 'invalid_ticket');
  assert.match(duplicate.error.message, /more than once/);
});

test('rejects an unknown edge kind, a missing end and an unknown state', () => {
  const base = fixture('build-order.v1.json');
  const unknownKind = parseBuildOrder({ ...base, edges: [{ from: 'BO-001', to: 'BO-002', kind: 'blocks', state: null, source: 'pack' }] });
  assert.equal(unknownKind.error.code, 'invalid_edge');
  assert.deepEqual(unknownKind.error.path, ['edges', 0, 'kind']);

  const missingEnd = parseBuildOrder({ ...base, edges: [{ from: 'BO-001', kind: 'depends_on', state: 'blocking', source: 'pack' }] });
  assert.equal(missingEnd.error.code, 'invalid_edge');
  assert.deepEqual(missingEnd.error.path, ['edges', 0, 'to']);

  const unknownState = parseBuildOrder({ ...base, edges: [{ from: 'BO-002', to: 'BO-001', kind: 'depends_on', state: 'pending', source: 'pack' }] });
  assert.equal(unknownState.error.code, 'invalid_edge');
  assert.deepEqual(unknownState.error.path, ['edges', 0, 'state']);

  const gateToTicket = parseBuildOrder({ ...base, edges: [{ from: 'GATE-001', to: 'BO-001', kind: 'gates', state: null, source: 'pack' }] });
  assert.equal(gateToTicket.error.code, 'invalid_edge');
  assert.deepEqual(gateToTicket.error.path, ['edges', 0]);
});

test('rejects a wave or critical path that names a ticket the document does not publish', () => {
  const base = fixture('build-order.v1.json');
  const wave = parseBuildOrder({ ...base, waves: [{ index: 1, tickets: ['BO-999'], starts_at: null, ends_at: null }] });
  assert.equal(wave.error.code, 'invalid_field');
  assert.deepEqual(wave.error.path, ['waves', 0, 'tickets', 0]);

  const critical = parseBuildOrder({ ...base, critical_path: { status: 'known', tickets: ['BO-999'], hours: 1, reason: null } });
  assert.equal(critical.error.code, 'invalid_field');
  assert.deepEqual(critical.error.path, ['critical_path', 'tickets', 0]);
});

test('an absent root is allowed and an absent top-level status is not required', () => {
  const result = parseBuildOrder(documentWith({ root: null }));
  assert.equal(result.ok, true);
  assert.equal(result.document.root, null);
  assert.equal(result.document.status, 'known');
});
