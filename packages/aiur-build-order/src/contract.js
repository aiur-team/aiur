// The published contract this package reads. One document in, both renderers out.
// Field names here are the wire names of `build-order.v1`; nothing is renamed,
// so a reader of `packages/aiur-contracts/schemas/build-order.v1.schema.json`
// can follow the code below without a translation table.

export const BUILD_ORDER_CONTRACT = 'aiur.build_order';
export const BUILD_ORDER_VERSION = 1;
export const ELEMENT_NAME = 'aiur-build-order';

// Every typed edge the contract publishes, with the words the legend uses.
export const EDGE_TYPES = Object.freeze([
  'depends_on',
  'serializes_with',
  'suggested_after',
  'contains',
  'gates',
]);

export const EDGE_LABELS = Object.freeze({
  depends_on: 'Depends on',
  serializes_with: 'Serializes with',
  suggested_after: 'Suggested after',
  contains: 'Contains',
  gates: 'Gated by',
});

export const EDGE_NOTES = Object.freeze({
  depends_on: 'A blocking prerequisite a ticket cannot start before.',
  serializes_with: 'Two tickets that must not run at the same time.',
  suggested_after: 'Advisory ordering only; nothing is blocked.',
  contains: 'The parent collects the member ticket.',
  gates: 'An outside gate, such as a release or an acceptance.',
});

/** `depends_on` states the contract publishes. The other kinds carry `null`. */
export const EDGE_STATES = Object.freeze(['cleared', 'blocking', 'terminal_unsatisfied', 'unknown']);

export const SOURCE_STATUSES = Object.freeze(['known', 'stale', 'unknown']);

export const TICKET_STATUSES = Object.freeze([
  'planned',
  'queued',
  'running',
  'open',
  'closed',
  'done',
  'failed',
  'not_planned',
  'unknown',
]);

export const GATE_STATUSES = Object.freeze(['open', 'approved', 'rejected', 'unknown']);

export const isEdgeType = (value) => EDGE_TYPES.includes(value);
