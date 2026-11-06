import {
  BUILD_ORDER_CONTRACT,
  BUILD_ORDER_VERSION,
  EDGE_STATES,
  GATE_STATUSES,
  SOURCE_STATUSES,
  isEdgeType,
} from './contract.js';

/**
 * Read a published `build-order.v1` document.
 *
 * Accepts a JSON string, an already-parsed object, or a response body from a
 * fetch. Returns `{ ok: true, document }`, or `{ ok: false, error }` with
 * `{ code, message, path }`. The document keeps the contract's own field names,
 * so the only thing between a published graph and a renderer is this check.
 *
 * Validation covers what a renderer reads: the contract marker and version, the
 * required top-level records, ticket identity and titles, gate identity, typed
 * edges whose endpoints exist, waves, the critical path and every progress
 * record. A violation is a structured error naming the path, never a half-drawn
 * view. Unknown values are *not* violations: `status: "unknown"` and null counts
 * are the contract's way of saying "not observed", and they parse fine.
 */
export function parseBuildOrder(input) {
  const read = readJson(input);
  if (!read.ok) return read;

  const raw = read.value;
  if (!isRecord(raw)) return fail('not_an_object', 'The build-order document must be a JSON object.', []);
  if (raw.contract !== BUILD_ORDER_CONTRACT) {
    return fail('unsupported_contract', `Expected contract "${BUILD_ORDER_CONTRACT}", received ${describe(raw.contract)}.`, ['contract']);
  }
  if (raw.contract_version !== BUILD_ORDER_VERSION) {
    return fail('unsupported_version', `Expected contract_version ${BUILD_ORDER_VERSION}, received ${describe(raw.contract_version)}.`, ['contract_version']);
  }

  for (const field of ['build_order_id', 'title', 'generated_at']) {
    if (typeof raw[field] !== 'string' || raw[field].trim() === '') {
      return fail('invalid_field', `The document needs a ${field} string.`, [field]);
    }
  }

  const tickets = readTickets(raw.tickets);
  if (!tickets.ok) return tickets;

  const gates = readGates(raw.gates);
  if (!gates.ok) return gates;

  const epics = readScopes(raw.epics, 'epics', ['key', 'title']);
  if (!epics.ok) return epics;
  const features = readScopes(raw.features, 'features', ['key', 'title']);
  if (!features.ok) return features;
  const lanes = readScopes(raw.lanes, 'lanes', ['key', 'title', 'order']);
  if (!lanes.ok) return lanes;

  const ticketIds = new Set(tickets.value.map((ticket) => ticket.id));
  const gateKeys = new Set(gates.value.map((gate) => gate.key));

  const edges = readEdges(raw.edges, ticketIds, gateKeys);
  if (!edges.ok) return edges;

  const waves = readWaves(raw.waves, ticketIds);
  if (!waves.ok) return waves;

  const criticalPath = readCriticalPath(raw.critical_path, ticketIds);
  if (!criticalPath.ok) return criticalPath;

  const sources = readSources(raw.sources);
  if (!sources.ok) return sources;

  const progress = readProgress(raw.progress, ['progress']);
  if (!progress.ok) return progress;

  const root = readRoot(raw.root);
  if (!root.ok) return root;

  const critical = new Set(criticalPath.value.status === 'known' ? criticalPath.value.tickets : []);
  const waveByTicket = new Map();
  for (const wave of waves.value) {
    for (const id of wave.tickets) if (!waveByTicket.has(id)) waveByTicket.set(id, wave.index);
  }

  for (const ticket of tickets.value) {
    ticket.edges = edges.value.filter((edge) => edge.from === ticket.id || edge.to === ticket.id);
    ticket.critical = critical.has(ticket.id);
    if (ticket.wave === null && waveByTicket.has(ticket.id)) ticket.wave = waveByTicket.get(ticket.id);
  }

  const status = documentStatus(raw, sources.value, progress.value);

  return {
    ok: true,
    document: {
      contract: BUILD_ORDER_CONTRACT,
      contract_version: BUILD_ORDER_VERSION,
      build_order_id: raw.build_order_id,
      title: raw.title.trim(),
      repository: stringOrNull(raw.repository),
      root: root.value,
      generated_at: raw.generated_at,
      sources: sources.value,
      progress: progress.value,
      epics: epics.value,
      features: features.value,
      lanes: lanes.value,
      tickets: tickets.value,
      edges: edges.value,
      gates: gates.value,
      waves: waves.value,
      critical_path: criticalPath.value,
      status: status.status,
      statusReason: status.reason,
      byId: new Map(tickets.value.map((ticket) => [ticket.id, ticket])),
      gatesByKey: new Map(gates.value.map((gate) => [gate.key, gate])),
    },
  };
}

/** A structured error a caller can show without guessing. */
export function buildOrderError(code, message, path = []) {
  return { ok: false, error: { code, message, path } };
}

function fail(code, message, path) {
  return buildOrderError(code, message, path);
}

function readJson(input) {
  if (typeof input !== 'string') return { ok: true, value: input };
  try {
    return { ok: true, value: JSON.parse(input) };
  } catch (error) {
    return fail('not_json', `The build-order body is not valid JSON: ${error.message}`, []);
  }
}

function readTickets(raw) {
  if (!Array.isArray(raw)) return fail('invalid_field', 'The document needs a tickets array.', ['tickets']);
  const tickets = [];
  const seen = new Set();
  for (const [index, entry] of raw.entries()) {
    const at = ['tickets', index];
    if (!isRecord(entry)) return fail('invalid_ticket', 'Each ticket must be an object.', at);
    const id = stringOrNull(entry.id);
    if (id === null) return fail('invalid_ticket', 'Each ticket needs a non-empty string id.', [...at, 'id']);
    if (seen.has(id)) return fail('invalid_ticket', `Ticket ${id} appears more than once.`, [...at, 'id']);
    if (typeof entry.title !== 'string' || entry.title.trim() === '') {
      return fail('invalid_ticket', `Ticket ${id} needs a title.`, [...at, 'title']);
    }
    seen.add(id);
    tickets.push({
      id,
      number: integerOrNull(entry.number),
      title: entry.title.trim(),
      url: stringOrNull(entry.url),
      kind: stringOrNull(entry.kind) ?? 'unknown',
      provenance: stringOrNull(entry.provenance) ?? 'unknown',
      epic: stringOrNull(entry.epic),
      feature: stringOrNull(entry.feature),
      lane: stringOrNull(entry.lane),
      phase: integerOrNull(entry.phase),
      wave: integerOrNull(entry.wave),
      complexity: integerOrNull(entry.complexity),
      points: numberOrNull(entry.points),
      estimate_hours: numberOrNull(entry.estimate_hours),
      status: stringOrNull(entry.status) ?? 'unknown',
      progress_percent: percentOrNull(entry.progress_percent),
      started_at: stringOrNull(entry.started_at),
      ended_at: stringOrNull(entry.ended_at),
      edges: [],
      critical: false,
    });
  }
  return { ok: true, value: tickets };
}

function readGates(raw) {
  if (!Array.isArray(raw)) return fail('invalid_field', 'The document needs a gates array.', ['gates']);
  const gates = [];
  const seen = new Set();
  for (const [index, entry] of raw.entries()) {
    const at = ['gates', index];
    if (!isRecord(entry)) return fail('invalid_field', 'Each gate must be an object.', at);
    const key = stringOrNull(entry.key);
    if (key === null) return fail('invalid_field', 'Each gate needs a non-empty string key.', [...at, 'key']);
    if (seen.has(key)) return fail('invalid_field', `Gate ${key} appears more than once.`, [...at, 'key']);
    seen.add(key);
    gates.push({
      key,
      title: stringOrNull(entry.title) ?? key,
      owner: stringOrNull(entry.owner),
      resolution_criteria: stringOrNull(entry.resolution_criteria),
      status: GATE_STATUSES.includes(entry.status) ? entry.status : 'unknown',
    });
  }
  return { ok: true, value: gates };
}

function readScopes(raw, field, required) {
  if (!Array.isArray(raw)) return fail('invalid_field', `The document needs a ${field} array.`, [field]);
  const scopes = [];
  const seen = new Set();
  for (const [index, entry] of raw.entries()) {
    const at = [field, index];
    if (!isRecord(entry)) return fail('invalid_field', `Each entry in ${field} must be an object.`, at);
    const key = stringOrNull(entry.key);
    if (key === null) return fail('invalid_field', `Each entry in ${field} needs a non-empty string key.`, [...at, 'key']);
    if (seen.has(key)) return fail('invalid_field', `${field} publishes ${key} more than once.`, [...at, 'key']);
    seen.add(key);
    if (required.includes('title') && (typeof entry.title !== 'string' || entry.title.trim() === '')) {
      return fail('invalid_field', `${field} entry ${key} needs a title.`, [...at, 'title']);
    }
    const progress = readProgress(entry.progress, [...at, 'progress']);
    if (!progress.ok) return progress;
    scopes.push({
      key,
      title: entry.title.trim(),
      label: stringOrNull(entry.label) ?? key,
      url: stringOrNull(entry.url),
      icon: stringOrNull(entry.icon),
      hue: numberOrNull(entry.hue),
      epic: stringOrNull(entry.epic),
      order: integerOrNull(entry.order),
      features: Array.isArray(entry.features) ? entry.features.filter((value) => typeof value === 'string') : [],
      progress: progress.value,
    });
  }
  return { ok: true, value: scopes };
}

function readEdges(raw, ticketIds, gateKeys) {
  if (!Array.isArray(raw)) return fail('invalid_field', 'The document needs an edges array.', ['edges']);
  const edges = [];
  for (const [index, entry] of raw.entries()) {
    const at = ['edges', index];
    if (!isRecord(entry)) return fail('invalid_edge', 'Each edge must be an object.', at);
    if (!isEdgeType(entry.kind)) {
      return fail('invalid_edge', `Unknown edge kind ${describe(entry.kind)}; expected one of depends_on, serializes_with, suggested_after, contains, gates.`, [...at, 'kind']);
    }
    const from = stringOrNull(entry.from);
    const to = stringOrNull(entry.to);
    if (from === null) return fail('invalid_edge', 'Each edge needs a non-empty from id.', [...at, 'from']);
    if (to === null) return fail('invalid_edge', 'Each edge needs a non-empty to id.', [...at, 'to']);
    const endpoint = (value) => (ticketIds.has(value) ? 'ticket' : gateKeys.has(value) ? 'gate' : null);
    const fromKind = endpoint(from);
    const toKind = endpoint(to);
    if (fromKind === null) return fail('invalid_edge', `Edge ${from} -> ${to} starts at ${from}, which is not a ticket id or gate key in this document.`, [...at, 'from']);
    if (toKind === null) return fail('invalid_edge', `Edge ${from} -> ${to} ends at ${to}, which is not a ticket id or gate key in this document.`, [...at, 'to']);
    if (entry.kind === 'gates') {
      if (fromKind !== 'ticket' || toKind !== 'gate') {
        return fail('invalid_edge', 'A gates edge runs from a ticket to a gate key.', at);
      }
    } else if (fromKind !== 'ticket' || toKind !== 'ticket') {
      return fail('invalid_edge', `A ${entry.kind} edge runs from ticket to ticket.`, at);
    }
    const state = stringOrNull(entry.state);
    if (state !== null && !EDGE_STATES.includes(state)) {
      return fail('invalid_edge', `Unknown edge state ${describe(state)}; expected one of ${EDGE_STATES.join(', ')}.`, [...at, 'state']);
    }
    edges.push({
      kind: entry.kind,
      from,
      to,
      state,
      source: ['pack', 'tracker', 'inferred', 'unknown'].includes(entry.source) ? entry.source : 'unknown',
      fromKind,
      toKind,
    });
  }
  return { ok: true, value: edges };
}

function readWaves(raw, ticketIds) {
  if (!Array.isArray(raw)) return fail('invalid_field', 'The document needs a waves array.', ['waves']);
  const waves = [];
  for (const [index, entry] of raw.entries()) {
    const at = ['waves', index];
    if (!isRecord(entry)) return fail('invalid_field', 'Each wave must be an object.', at);
    if (!Number.isInteger(entry.index) || entry.index < 0) {
      return fail('invalid_field', 'Each wave needs a non-negative integer index.', [...at, 'index']);
    }
    if (!Array.isArray(entry.tickets)) return fail('invalid_field', 'Each wave needs a tickets array.', [...at, 'tickets']);
    const members = [];
    for (const [position, id] of entry.tickets.entries()) {
      const ticketId = stringOrNull(id);
      if (ticketId === null || !ticketIds.has(ticketId)) {
        return fail('invalid_field', `Wave ${entry.index} lists ${describe(id)}, which is not a ticket id in this document.`, [...at, 'tickets', position]);
      }
      if (!members.includes(ticketId)) members.push(ticketId);
    }
    waves.push({
      index: entry.index,
      label: `Wave ${entry.index}`,
      tickets: members,
      starts_at: stringOrNull(entry.starts_at),
      ends_at: stringOrNull(entry.ends_at),
    });
  }
  waves.sort((left, right) => left.index - right.index);
  return { ok: true, value: waves };
}

function readCriticalPath(raw, ticketIds) {
  if (!isRecord(raw)) return fail('invalid_field', 'The document needs a critical_path object.', ['critical_path']);
  const status = raw.status === 'known' ? 'known' : 'unknown';
  const tickets = [];
  if (status === 'known') {
    if (!Array.isArray(raw.tickets)) return fail('invalid_field', 'A known critical_path needs a tickets array.', ['critical_path', 'tickets']);
    for (const [index, id] of raw.tickets.entries()) {
      const ticketId = stringOrNull(id);
      if (ticketId === null || !ticketIds.has(ticketId)) {
        return fail('invalid_field', `critical_path lists ${describe(id)}, which is not a ticket id in this document.`, ['critical_path', 'tickets', index]);
      }
      if (!tickets.includes(ticketId)) tickets.push(ticketId);
    }
  }
  return {
    ok: true,
    value: { status, tickets, hours: numberOrNull(raw.hours), reason: stringOrNull(raw.reason) },
  };
}

function readSources(raw) {
  if (!isRecord(raw)) return fail('invalid_field', 'The document needs a sources object.', ['sources']);
  const sources = {};
  for (const name of ['pack', 'tracker', 'progress']) {
    const entry = raw[name];
    if (!isRecord(entry)) return fail('invalid_field', `sources needs a ${name} record.`, ['sources', name]);
    sources[name] = {
      name,
      status: SOURCE_STATUSES.includes(entry.status) ? entry.status : 'unknown',
      observed_at: stringOrNull(entry.observed_at),
      reason: stringOrNull(entry.reason),
    };
  }
  return { ok: true, value: sources };
}

function readProgress(raw, path) {
  if (!isRecord(raw)) return fail('invalid_field', 'Progress needs an object with a status.', path);
  return {
    ok: true,
    value: {
      status: SOURCE_STATUSES.includes(raw.status) ? raw.status : 'unknown',
      total: integerOrNull(raw.total),
      done: integerOrNull(raw.done),
      open: integerOrNull(raw.open),
      failed: integerOrNull(raw.failed),
      percent: percentOrNull(raw.percent),
      by_status: isRecord(raw.by_status) ? { ...raw.by_status } : null,
      observed_at: stringOrNull(raw.observed_at),
      reason: stringOrNull(raw.reason),
    },
  };
}

function readRoot(raw) {
  if (raw === null || raw === undefined) return { ok: true, value: null };
  if (!isRecord(raw)) return fail('invalid_field', 'root must be an object or null.', ['root']);
  return {
    ok: true,
    value: {
      id: stringOrNull(raw.id),
      title: stringOrNull(raw.title),
      number: integerOrNull(raw.number),
      url: stringOrNull(raw.url),
      epic: stringOrNull(raw.epic),
      plan_version: integerOrNull(raw.plan_version),
      researched_at_commit: stringOrNull(raw.researched_at_commit),
    },
  };
}

/**
 * The document's own unknown state.
 *
 * `build-order.v1` publishes availability per source (and repeats it on
 * progress), so no single boolean exists on the wire. A document is unknown
 * when any published source is unknown, stale when one is stale, and a
 * top-level `status` — which a producer may add — wins when it is worse.
 * Either way the renderers draw a banner instead of an empty or zero view.
 */
function documentStatus(raw, sources, progress) {
  const rank = { known: 0, stale: 1, unknown: 2 };
  let status = 'known';
  let reason = null;
  const consider = (candidate, detail) => {
    const value = SOURCE_STATUSES.includes(candidate) ? candidate : 'unknown';
    if (rank[value] > rank[status]) {
      status = value;
      reason = detail ?? null;
    } else if (rank[value] === rank[status] && reason === null && value !== 'known') {
      reason = detail ?? null;
    }
  };
  if (raw.status !== undefined) consider(raw.status, stringOrNull(raw.reason));
  for (const source of Object.values(sources)) consider(source.status, source.reason ? `${source.name}: ${source.reason}` : null);
  consider(progress.status, progress.reason);
  return { status, reason };
}

function stringOrNull(value) {
  if (typeof value !== 'string') return null;
  const text = value.trim();
  return text === '' ? null : text;
}

function integerOrNull(value) {
  return Number.isInteger(value) ? value : null;
}

function numberOrNull(value) {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

function percentOrNull(value) {
  const number = numberOrNull(value);
  if (number === null || number < 0 || number > 100) return null;
  return number;
}

function isRecord(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function describe(value) {
  if (value === undefined) return 'nothing';
  if (value === null) return 'null';
  return JSON.stringify(value);
}
