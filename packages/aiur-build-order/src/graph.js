import { EDGE_LABELS, EDGE_TYPES } from './contract.js';
import { escapeHtml, orDash, percentText, truncate } from './html.js';
import { parseBuildOrder } from './parse.js';

const NODE_W = 176;
const NODE_H = 54;
const GATE_W = 132;
const GATE_H = 34;
const COL_GAP = 36;
const STACK_GAP = 12;
const ROW_GAP = 26;
const PAD = 24;
const LABEL_W = 112;
const HEADER_H = 26;
const BANNER_H = 62;
const LEGEND_ROW = 22;

/**
 * Render the dependency graph for a parsed `build-order.v1` document as SVG.
 *
 * Columns are the published `waves` and rows are the published `lanes`, so the
 * layout needs no engine: the document already says where each ticket belongs.
 * Every typed edge draws its own line style and head, and gates — which the
 * `gates` edges point at — are drawn in their own row. An unknown document
 * draws an explicit banner and the tickets it still knows about.
 */
export function renderGraph(input) {
  const document = asDocument(input);
  const uid = `aiur-bo-graph-${slug(document.build_order_id)}`;
  const stale = document.status !== 'known';
  const top = PAD + (stale ? BANNER_H : 0);
  const layout = layoutGraph(document, top);
  const legendTop = layout.height + 16;
  const height = legendTop + EDGE_TYPES.length * LEGEND_ROW + PAD;
  const waves = document.waves.length;
  const critical = document.critical_path.tickets.length;
  const summary = summaryText(document);

  return `<svg class="aiur-bo-graph" data-status="${document.status}" data-contract="${escapeHtml(document.contract)}" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${layout.width} ${height}" width="${layout.width}" height="${height}" role="img" aria-labelledby="${uid}-title" aria-describedby="${uid}-desc">
<title id="${uid}-title">${escapeHtml(document.title)} build order graph</title>
<desc id="${uid}-desc">${escapeHtml(`${document.tickets.length} tickets across ${waves} waves; ${critical} on the critical path; ${summary}.`)}</desc>
${summaryMarkup(summary, layout.width, top)}
${stale ? staleBanner(document, layout.width) : ''}
${waveHeaders(layout)}
${laneLabels(layout)}
<g class="aiur-bo-graph-edges" data-section="edges">
${layout.edges}
</g>
<g class="aiur-bo-graph-nodes" data-section="nodes">
${layout.nodes}
</g>
<g class="aiur-bo-graph-gates" data-section="gates">
${layout.gates}
</g>
<g class="aiur-bo-legend is-graph-legend" data-section="legend" transform="translate(${PAD} ${legendTop})">
${graphLegend()}
</g>
</svg>`;
}

/**
 * The document's own progress line: the percent, the counts, and the critical
 * path's hours. Unknown renders the same dashes the review does.
 */
function summaryText(document) {
  const progress = document.progress;
  const known = progress.status === 'known' && Number.isFinite(progress.percent);
  const percent = known ? percentText(progress.percent) : 'progress unknown';
  const counts = `${orDash(progress.done)}/${orDash(progress.total)} done`;
  const hours = document.critical_path.status === 'known' && Number.isFinite(document.critical_path.hours)
    ? `${document.critical_path.hours}h critical path`
    : 'critical path unknown';
  return `${percent} · ${counts} · ${hours}`;
}

function summaryMarkup(summary, width, top) {
  return `<text class="aiur-bo-graph-summary" x="${round(width - PAD)}" y="${round(top - 10)}" text-anchor="end">${escapeHtml(summary)}</text>`;
}

function staleBanner(document, layoutWidth) {
  const reason = document.statusReason ?? 'The publishing source did not report a reason.';
  const width = Math.max(240, Math.min(640, layoutWidth - PAD * 2));
  const heading = document.status === 'unknown' ? 'Build order is unknown' : 'Build order is stale';
  return `<g class="aiur-bo-graph-banner" data-section="status-banner" data-status="${document.status}">
<rect class="aiur-bo-banner-box" x="${PAD}" y="${PAD}" width="${round(width)}" height="${BANNER_H - 16}" rx="10"/>
<text class="aiur-bo-banner-text" x="${PAD + 16}" y="${PAD + 26}">${escapeHtml(heading)}</text>
<text class="aiur-bo-banner-text is-body" x="${PAD + 16}" y="${PAD + 44}">${escapeHtml(truncate(reason, 88))}</text>
</g>`;
}

function waveHeaders(layout) {
  if (layout.columns.length === 0) return '';
  const items = layout.columns
    .map((column) => `<text class="aiur-bo-graph-wave-label" x="${column.x}" y="${layout.top}" data-wave="${escapeHtml(String(column.index))}">${escapeHtml(truncate(column.label, 22))}</text>`)
    .join('\n');
  return `<g class="aiur-bo-graph-waves" data-section="waves">
${items}
</g>`;
}

function laneLabels(layout) {
  if (layout.rows.length === 0) return '';
  const items = layout.rows
    .map((row) => `<text class="aiur-bo-graph-lane-label" x="${PAD}" y="${round(row.y + row.height / 2 + 4)}" data-lane="${escapeHtml(row.key ?? '')}">${escapeHtml(truncate(row.label, 16))}</text>`)
    .join('\n');
  return `<g class="aiur-bo-graph-lanes" data-section="lanes">
${items}
</g>`;
}

function graphLegend() {
  return EDGE_TYPES.map((kind, index) => {
    const y = index * LEGEND_ROW + LEGEND_ROW / 2;
    return `<g class="aiur-bo-legend-item" data-edge-kind="${kind}" transform="translate(0 ${y})">
<line class="aiur-bo-edge aiur-bo-edge--${kind}" x1="0" y1="0" x2="30" y2="0"/>
<text class="aiur-bo-legend-text" x="40" y="4">${escapeHtml(EDGE_LABELS[kind])}</text>
</g>`;
  }).join('\n');
}

function layoutGraph(document, top) {
  const columns = columnPlan(document);
  const rows = rowPlan(document);

  const cells = new Map();
  const fallbackColumn = columns[columns.length - 1];
  const fallbackRow = rows.find((row) => row.kind === 'lane') ?? rows[0];
  for (const ticket of document.tickets) {
    const column = columns.find((entry) => entry.index !== 'unscheduled' && entry.ids.includes(ticket.id)) ?? fallbackColumn;
    const row = rows.find((entry) => entry.kind === 'lane' && entry.key === ticket.lane) ?? rows.find((entry) => entry.kind === 'unlaned') ?? fallbackRow;
    if (!column || !row) continue;
    const key = `${column.index}|${row.key}`;
    if (!cells.has(key)) cells.set(key, []);
    cells.get(key).push(ticket);
  }

  let cursor = top + HEADER_H;
  const rowTops = new Map();
  for (const row of rows) {
    const stack = Math.max(...columns.map((column) => cells.get(`${column.index}|${row.key}`)?.length ?? 0), 1);
    rowTops.set(row.key, cursor);
    row.y = cursor;
    row.height = row.kind === 'gates' ? GATE_H + STACK_GAP : stack * NODE_H + (stack - 1) * STACK_GAP;
    cursor += row.height + ROW_GAP;
  }

  const position = new Map();
  for (const row of rows) {
    if (row.kind === 'gates') continue;
    for (const column of columns) {
      const stack = cells.get(`${column.index}|${row.key}`) ?? [];
      stack.forEach((ticket, index) => {
        position.set(ticket.id, {
          x: column.x,
          y: rowTops.get(row.key) + index * (NODE_H + STACK_GAP),
          width: NODE_W,
          height: NODE_H,
        });
      });
    }
  }

  const gatePosition = placeGates(document, position, rows);

  const width = columns.length > 0
    ? PAD + LABEL_W + columns.length * NODE_W + (columns.length - 1) * COL_GAP + PAD
    : PAD * 2 + NODE_W;
  const height = Math.max(cursor - ROW_GAP, top + NODE_H);

  const edges = document.edges
    .map((edge) => edgeMarkup(edge, position, gatePosition))
    .filter(Boolean)
    .join('\n');

  const nodes = document.tickets
    .map((ticket) => nodeMarkup(document, ticket, position.get(ticket.id)))
    .filter(Boolean)
    .join('\n');

  const gates = document.gates
    .map((gate, index) => gateMarkup(gate, gatePosition.get(gate.key), index))
    .filter(Boolean)
    .join('\n');

  return { width, columns, rows, edges, nodes, gates, height, top };
}

function columnPlan(document) {
  const columns = document.waves.map((wave) => ({ index: wave.index, label: wave.label, ids: wave.tickets, x: 0 }));
  const assigned = new Set(columns.flatMap((column) => column.ids));
  const rest = document.tickets.filter((ticket) => !assigned.has(ticket.id)).map((ticket) => ticket.id);
  if (rest.length > 0) {
    columns.push({ index: 'unscheduled', label: document.waves.length > 0 ? 'Unscheduled' : 'Tickets', ids: rest, x: 0 });
  }
  columns.forEach((column, index) => {
    column.x = PAD + LABEL_W + index * (NODE_W + COL_GAP);
  });
  return columns;
}

function rowPlan(document) {
  const lanes = [...document.lanes].sort((left, right) => (left.order ?? Number.MAX_SAFE_INTEGER) - (right.order ?? Number.MAX_SAFE_INTEGER));
  const rows = lanes.map((lane) => ({ key: lane.key, label: lane.title, kind: 'lane', y: 0, height: NODE_H }));
  const used = new Set(rows.map((row) => row.key));
  for (const lane of [...new Set(document.tickets.map((ticket) => ticket.lane).filter((key) => key && !used.has(key)))]) {
    rows.push({ key: lane, label: lane, kind: 'lane', y: 0, height: NODE_H });
  }
  if (document.tickets.some((ticket) => !ticket.lane || !rows.some((row) => row.key === ticket.lane))) {
    rows.push({ key: '__unlaned', label: 'No lane', kind: 'unlaned', y: 0, height: NODE_H });
  }
  if (document.gates.length > 0) rows.push({ key: '__gates', label: 'Gates', kind: 'gates', y: 0, height: GATE_H });
  if (rows.length === 0) rows.push({ key: '__unlaned', label: 'No lane', kind: 'unlaned', y: 0, height: NODE_H });
  return rows;
}

/** Gates sit in the gates row, in the column of the ticket that gates them. */
function placeGates(document, position, rows) {
  const row = rows.find((entry) => entry.kind === 'gates');
  const placed = new Map();
  if (!row) return placed;
  const used = new Map();
  for (const gate of document.gates) {
    const source = document.edges.find((edge) => edge.kind === 'gates' && edge.to === gate.key && position.has(edge.from));
    const column = source ? position.get(source.from).x : PAD + LABEL_W;
    const count = used.get(column) ?? 0;
    used.set(column, count + 1);
    placed.set(gate.key, { x: column, y: row.y + count * (GATE_H + 6), width: GATE_W, height: GATE_H });
  }
  return placed;
}

function edgeMarkup(edge, position, gatePosition) {
  const from = edge.fromKind === 'ticket' ? position.get(edge.from) : gatePosition.get(edge.from);
  const to = edge.toKind === 'ticket' ? position.get(edge.to) : gatePosition.get(edge.to);
  if (!from || !to) return '';
  const fromCenter = { x: from.x + from.width / 2, y: from.y + from.height / 2 };
  const toCenter = { x: to.x + to.width / 2, y: to.y + to.height / 2 };
  const forward = toCenter.x >= fromCenter.x;
  const x1 = forward ? from.x + from.width : from.x;
  const y1 = fromCenter.y;
  const x2 = forward ? to.x - 1 : to.x + to.width + 1;
  const y2 = toCenter.y;
  const bend = Math.max(28, Math.abs(x2 - x1) / 2) * (forward ? 1 : -1);
  const path = `M${round(x1)} ${round(y1)} C${round(x1 + bend)} ${round(y1)} ${round(x2 - bend)} ${round(y2)} ${round(x2)} ${round(y2)}`;
  const direction = forward ? 1 : -1;
  const state = edge.state ? ` data-edge-state="${escapeHtml(edge.state)}"` : '';
  return `<g class="aiur-bo-graph-edge" data-edge-kind="${edge.kind}" data-from="${escapeHtml(edge.from)}" data-to="${escapeHtml(edge.to)}"${state} data-edge-source="${escapeHtml(edge.source)}">
<path class="aiur-bo-edge aiur-bo-edge--${edge.kind}" d="${path}"/>
${edgeHead(edge.kind, x2, y2, direction)}
</g>`;
}

function edgeHead(kind, x, y, direction) {
  const back = 9 * direction;
  if (kind === 'contains') return '';
  if (kind === 'suggested_after') return `<circle class="aiur-bo-edge-head aiur-bo-edge--${kind}" cx="${round(x - back)}" cy="${round(y)}" r="3.5"/>`;
  if (kind === 'gates') {
    return `<rect class="aiur-bo-edge-head aiur-bo-edge--${kind}" x="${round(x - 8 * direction - 4)}" y="${round(y - 4)}" width="8" height="8"/>`;
  }
  return `<path class="aiur-bo-edge-head aiur-bo-edge--${kind}" d="M${round(x - back)} ${round(y - 5)} L${round(x)} ${round(y)} L${round(x - back)} ${round(y + 5)} z"/>`;
}

function nodeMarkup(document, ticket, box) {
  if (!box) return '';
  const percent = document.status === 'known' && Number.isFinite(ticket.progress_percent) ? ticket.progress_percent : null;
  const label = ticket.number === null ? ticket.id : `#${ticket.number}`;
  return `<g class="aiur-bo-graph-node" data-ticket="${escapeHtml(ticket.id)}" data-status="${escapeHtml(ticket.status)}"${ticket.critical ? ' data-critical="true"' : ''} transform="translate(${round(box.x)} ${round(box.y)})">
<rect class="aiur-bo-node-box" width="${NODE_W}" height="${NODE_H}" rx="9"/>
<text class="aiur-bo-node-id" x="12" y="19">${escapeHtml(label)} <tspan class="aiur-bo-node-kind">${escapeHtml(ticket.kind)}</tspan></text>
<text class="aiur-bo-node-title" x="12" y="35">${escapeHtml(truncate(ticket.title, 30))}</text>
<text class="aiur-bo-node-meta" x="12" y="47">${escapeHtml(orDash(ticket.lane))} · w${escapeHtml(orDash(ticket.wave))}</text>
<text class="aiur-bo-node-percent" x="${NODE_W - 12}" y="19" text-anchor="end">${escapeHtml(percent === null ? '—' : percentText(percent))}</text>
</g>`;
}

function gateMarkup(gate, box, index) {
  if (!box) return '';
  return `<g class="aiur-bo-graph-gate" data-gate="${escapeHtml(gate.key)}" data-status="${escapeHtml(gate.status)}" transform="translate(${round(box.x)} ${round(box.y)})">
<rect class="aiur-bo-gate-box" width="${GATE_W}" height="${GATE_H}" rx="17"/>
<text class="aiur-bo-gate-label" x="12" y="15">${escapeHtml(gate.key)} · ${escapeHtml(gate.status)}</text>
<text class="aiur-bo-gate-title" x="12" y="27">${escapeHtml(truncate(gate.title, 20 + (index % 2)))}</text>
</g>`;
}

function slug(value) {
  return String(value ?? 'build-order').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'build-order';
}

function round(value) {
  return Math.round(value * 100) / 100;
}

function asDocument(input) {
  if (input && Array.isArray(input.edges) && input.byId instanceof Map) return input;
  const parsed = parseBuildOrder(input);
  if (parsed.ok) return parsed.document;
  const error = new Error(parsed.error.message);
  error.code = parsed.error.code;
  error.path = parsed.error.path;
  throw error;
}
