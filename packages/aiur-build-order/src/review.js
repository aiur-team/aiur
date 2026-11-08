import { EDGE_LABELS, EDGE_NOTES, EDGE_TYPES } from './contract.js';
import { countText, escapeHtml, orDash, percentText, safeUrl, stampText, truncate } from './html.js';
import { parseBuildOrder } from './parse.js';

/**
 * Render the review page for a parsed `build-order.v1` document as static HTML.
 *
 * Every number comes from the document: waves from `waves`, the ordering from
 * `critical_path`, bars and counts from `progress`, relations from the typed
 * edges. An unknown document renders an explicit banner and dashes, never a
 * zero-percent bar or an empty list that reads as "nothing to do".
 */
export function renderReview(input) {
  const document = asDocument(input);
  const title = document.root?.title ?? document.title;

  return `<article class="aiur-bo aiur-bo--review" data-status="${document.status}" data-contract="${escapeHtml(document.contract)}">
${header(document, title)}
${staleBanner(document)}
${summary(document)}
${epicsSection(document)}
${lanesSection(document)}
${wavesSection(document)}
${criticalSection(document)}
${gatesSection(document)}
${ticketsSection(document)}
${legend()}
</article>`;
}

function header(document, title) {
  const scope = document.repository ?? 'no repository';
  const root = document.root
    ? `<span data-section="root">Root ${escapeHtml(ticketLabel(document.root))} ${escapeHtml(truncate(document.root.title ?? '', 80))}</span>`
    : '<span data-section="root">Whole catalog</span>';
  return `<header class="aiur-bo-header">
<p class="aiur-bo-kicker">Build order review</p>
<h2 class="aiur-bo-title">${escapeHtml(title)}</h2>
<p class="aiur-bo-meta"><span>${escapeHtml(document.build_order_id)}</span><span>${escapeHtml(scope)}</span>${root}<span>${countText(document.tickets.length)} tickets</span><span>as of ${escapeHtml(stampText(document.generated_at))}</span></p>
</header>`;
}

function staleBanner(document) {
  if (document.status === 'known') return '';
  const reasons = [];
  if (document.statusReason) reasons.push(document.statusReason);
  for (const source of Object.values(document.sources)) {
    if (source.status !== 'known' && source.reason) reasons.push(`${source.name}: ${source.reason}`);
  }
  const detail = reasons.length > 0 ? reasons.join(' ') : 'The publishing source did not report a reason.';
  const heading = document.status === 'unknown' ? 'Build order is unknown' : 'Build order is stale';
  return `<div class="aiur-bo-banner" role="status" data-section="status-banner" data-status="${document.status}">
<p class="aiur-bo-banner-head">${heading}</p>
<p class="aiur-bo-banner-body">${escapeHtml(detail)} Counts and bars below are unknown, not zero.</p>
</div>`;
}

function summary(document) {
  const progress = document.progress;
  const known = progress.status === 'known' && Number.isFinite(progress.percent);
  const critical = document.critical_path;
  const hours = critical.status === 'known' && Number.isFinite(critical.hours) ? `${critical.hours}h` : '—';
  return `<section class="aiur-bo-summary" data-section="progress">
<div class="aiur-bo-bar" role="img" aria-label="${escapeHtml(barLabel(progress))}"${known ? ` data-percent="${progress.percent}"` : ' data-unknown="true"'}>${known ? `<span style="--bo-pct:${progress.percent}%"></span>` : '<span class="aiur-bo-bar-unknown"></span>'}</div>
<ul class="aiur-bo-counts">
<li><b>${known ? percentText(progress.percent) : '—'}</b><span>complete</span></li>
<li><b>${orDash(progress.done)}</b><span>done</span></li>
<li><b>${orDash(progress.open)}</b><span>open</span></li>
<li><b>${orDash(progress.failed)}</b><span>failed</span></li>
<li><b>${orDash(progress.total)}</b><span>total</span></li>
<li><b>${escapeHtml(hours)}</b><span>critical path</span></li>
</ul>
${progress.status === 'known' ? '' : `<p class="aiur-bo-note" data-section="progress-note">Progress unavailable: ${escapeHtml(progress.reason ?? 'the publishing source did not report it.')}</p>`}
</section>`;
}

function barLabel(progress) {
  if (progress.status !== 'known' || !Number.isFinite(progress.percent)) return 'Progress unknown';
  return `${progress.percent}% complete, ${progress.done ?? '—'} done of ${progress.total ?? '—'}`;
}

function epicsSection(document) {
  if (document.epics.length === 0) return '';
  const rows = document.epics
    .map((epic) => {
      const members = document.features.filter((feature) => feature.epic === epic.key);
      const nested = members.length > 0
        ? `<ul class="aiur-bo-feature-list">
${members.map((feature) => featureRow(document, feature)).join('\n')}
</ul>`
        : '';
      return `<li class="aiur-bo-epic" data-epic="${escapeHtml(epic.key)}" data-status="${epic.progress.status}">
<div class="aiur-bo-card" data-status="${epic.progress.status}">
<span class="aiur-bo-card-label">${escapeHtml(truncate(epic.title, 64))}</span>
${barMarkup(epic.progress, 'card')}
<span class="aiur-bo-card-count">${countLabel(epic.progress)}</span>
</div>
${nested}
</li>`;
    })
    .join('\n');
  return `<section class="aiur-bo-cards" data-section="epics">
<h3>Epics</h3>
<ul class="aiur-bo-card-list">
${rows}
</ul>
</section>`;
}

function featureRow(document, feature) {
  const count = document.tickets.filter((ticket) => ticket.feature === feature.key).length;
  return `<li class="aiur-bo-card" data-feature="${escapeHtml(feature.key)}" data-status="${feature.progress.status}">
<span class="aiur-bo-card-label">${escapeHtml(truncate(feature.title, 64))} <span class="aiur-bo-count">${countText(count)}</span></span>
${barMarkup(feature.progress, 'card')}
<span class="aiur-bo-card-count">${countLabel(feature.progress)}</span>
</li>`;
}

function lanesSection(document) {
  if (document.lanes.length === 0) return '';
  const rows = document.lanes
    .map((lane) => {
      const count = document.tickets.filter((ticket) => ticket.lane === lane.key).length;
      return `<li class="aiur-bo-card" data-lane="${escapeHtml(lane.key)}" data-status="${lane.progress.status}">
<span class="aiur-bo-card-label">${escapeHtml(truncate(lane.title, 48))} <span class="aiur-bo-count">${countText(count)}</span></span>
${barMarkup(lane.progress, 'card')}
<span class="aiur-bo-card-count">${countLabel(lane.progress)}</span>
</li>`;
    })
    .join('\n');
  return `<section class="aiur-bo-cards" data-section="lanes">
<h3>Lanes</h3>
<ul class="aiur-bo-card-list">
${rows}
</ul>
</section>`;
}

function barMarkup(progress, modifier) {
  const known = progress.status === 'known' && Number.isFinite(progress.percent);
  return `<span class="aiur-bo-bar aiur-bo-bar--${modifier}"${known ? ` data-percent="${progress.percent}"` : ' data-unknown="true"'} role="img" aria-label="${escapeHtml(barLabel(progress))}">${known ? `<span style="--bo-pct:${progress.percent}%"></span>` : '<span class="aiur-bo-bar-unknown"></span>'}</span>`;
}

function countLabel(progress) {
  if (progress.status !== 'known') return `— · ${progress.reason ?? 'unknown'}`;
  return `${percentText(progress.percent)} · ${orDash(progress.done)}/${orDash(progress.total)}`;
}

function wavesSection(document) {
  if (document.waves.length === 0) {
    return `<section class="aiur-bo-waves" data-section="waves" data-status="unknown">
<h3>Waves</h3>
<p class="aiur-bo-note">The document does not publish waves.</p>
</section>`;
  }
  const rows = document.waves
    .map((wave) => {
      const members = wave.tickets.map((id) => document.byId.get(id)).filter(Boolean);
      const list = members.length > 0
        ? members.map((ticket) => `<li>${ticketLink(ticket)} <span class="aiur-bo-state">${escapeHtml(ticket.status)}</span></li>`).join('\n')
        : '<li class="aiur-bo-note">No tickets published for this wave.</li>';
      return `<li class="aiur-bo-wave" data-wave="${wave.index}">
<h4><span class="aiur-bo-wave-title">Wave ${wave.index}</span> <span class="aiur-bo-count">${countText(members.length)} tickets</span></h4>
<ul>
${list}
</ul>
</li>`;
    })
    .join('\n');
  return `<section class="aiur-bo-waves" data-section="waves">
<h3>Waves <span class="aiur-bo-count">${document.waves.length}</span></h3>
<ol class="aiur-bo-wave-list">
${rows}
</ol>
</section>`;
}

function criticalSection(document) {
  const path = document.critical_path;
  if (path.status !== 'known' || path.tickets.length === 0) {
    return `<section class="aiur-bo-critical" data-section="critical-path" data-status="unknown">
<h3>Critical path</h3>
<p class="aiur-bo-note">${escapeHtml(path.reason ?? 'The document does not publish a critical path.')}</p>
</section>`;
  }
  const hours = Number.isFinite(path.hours) ? ` <span class="aiur-bo-count">${path.hours}h</span>` : '';
  const steps = path.tickets
    .map((id) => {
      const ticket = document.byId.get(id);
      return `<li data-ticket="${escapeHtml(id)}">${ticket ? ticketLink(ticket) : `${escapeHtml(id)} <span class="aiur-bo-note">not published</span>`}</li>`;
    })
    .join('\n');
  return `<section class="aiur-bo-critical" data-section="critical-path" data-status="known">
<h3>Critical path${hours}</h3>
<ol class="aiur-bo-critical-list">
${steps}
</ol>
</section>`;
}

function gatesSection(document) {
  if (document.gates.length === 0) return '';
  const rows = document.gates
    .map((gate) => `<li class="aiur-bo-gate" data-gate="${escapeHtml(gate.key)}" data-status="${gate.status}">
<h4>${escapeHtml(gate.title)} <span class="aiur-bo-count">${escapeHtml(gate.key)} · ${escapeHtml(gate.status)}</span></h4>
${gate.owner ? `<p class="aiur-bo-note">Owner: ${escapeHtml(gate.owner)}</p>` : ''}
${gate.resolution_criteria ? `<p class="aiur-bo-gate-criteria">${escapeHtml(gate.resolution_criteria)}</p>` : ''}
</li>`)
    .join('\n');
  return `<section class="aiur-bo-gates" data-section="gates">
<h3>Gates <span class="aiur-bo-count">${document.gates.length}</span></h3>
<ul class="aiur-bo-gate-list">
${rows}
</ul>
</section>`;
}

function ticketsSection(document) {
  if (document.tickets.length === 0) {
    return `<section class="aiur-bo-tickets" data-section="tickets" data-status="${document.status}">
<h3>Tickets</h3>
<p class="aiur-bo-note">No tickets are published in this document.</p>
</section>`;
  }
  const rows = document.tickets.map((ticket) => ticketRow(document, ticket)).join('\n');
  return `<section class="aiur-bo-tickets" data-section="tickets">
<h3>Tickets <span class="aiur-bo-count">${document.tickets.length}</span></h3>
<div class="aiur-bo-table-wrap">
<table class="aiur-bo-table">
<thead><tr><th scope="col">Ticket</th><th scope="col">Title</th><th scope="col">Epic</th><th scope="col">Feature</th><th scope="col">Lane</th><th scope="col">Wave</th><th scope="col">Kind</th><th scope="col">Status</th><th scope="col">Progress</th><th scope="col">Relations</th></tr></thead>
<tbody>
${rows}
</tbody>
</table>
</div>
</section>`;
}

function ticketRow(document, ticket) {
  const relations = ticket.edges.map((edge) => edgeChip(document, edge, ticket.id)).join(' ');
  return `<tr data-ticket="${escapeHtml(ticket.id)}"${ticket.critical ? ' data-critical="true"' : ''}>
<td>${escapeHtml(ticketLabel(ticket))}</td>
<td>${ticketLink(ticket)}</td>
<td>${escapeHtml(orDash(ticket.epic))}</td>
<td>${escapeHtml(orDash(ticket.feature))}</td>
<td>${escapeHtml(orDash(ticket.lane))}</td>
<td>${escapeHtml(orDash(ticket.wave))}</td>
<td>${escapeHtml(ticket.kind)}</td>
<td><span class="aiur-bo-state" data-status="${escapeHtml(ticket.status)}">${escapeHtml(ticket.status)}</span></td>
<td>${Number.isFinite(ticket.progress_percent) && document.progress.status === 'known' ? escapeHtml(percentText(ticket.progress_percent)) : '—'}</td>
<td>${relations || '<span class="aiur-bo-note">none</span>'}</td>
</tr>`;
}

function ticketLabel(ticket) {
  return ticket.number === null || ticket.number === undefined ? String(ticket.id) : `#${ticket.number}`;
}

function ticketLink(ticket) {
  const label = `<span class="aiur-bo-ticket-id">${escapeHtml(ticketLabel(ticket))}</span> ${escapeHtml(truncate(ticket.title, 80))}`;
  const href = safeUrl(ticket.url);
  if (href === null) return `<span class="aiur-bo-ticket-name">${label}</span>`;
  return `<a class="aiur-bo-ticket-link" href="${escapeHtml(href)}">${label}</a>`;
}

function edgeChip(document, edge, id) {
  const outgoing = edge.from === id;
  const other = outgoing ? edge.to : edge.from;
  const gate = edge.toKind === 'gate' ? document.gatesByKey.get(edge.to) : null;
  const target = gate ? escapeHtml(truncate(gate.title, 40)) : escapeHtml(other);
  const words = {
    depends_on: outgoing ? 'needs' : 'blocks',
    serializes_with: 'serialized with',
    suggested_after: outgoing ? 'after' : 'before',
    contains: outgoing ? 'contains' : 'part of',
    gates: outgoing ? 'gated by' : 'gates',
  };
  const state = edge.state && edge.kind === 'depends_on' ? ` data-edge-state="${escapeHtml(edge.state)}"` : '';
  return `<span class="aiur-bo-edge aiur-bo-edge--${edge.kind}" data-edge-kind="${edge.kind}" data-direction="${outgoing ? 'out' : 'in'}"${state}>${escapeHtml(words[edge.kind])} ${target}</span>`;
}

function legend() {
  const items = EDGE_TYPES.map((kind) => `<li class="aiur-bo-legend-item" data-edge-kind="${kind}"><span class="aiur-bo-legend-swatch aiur-bo-edge--${kind}" aria-hidden="true"></span><b>${escapeHtml(EDGE_LABELS[kind])}</b><span>${escapeHtml(EDGE_NOTES[kind])}</span></li>`).join('\n');
  return `<footer class="aiur-bo-legend" data-section="legend">
<h3>Relations</h3>
<ul class="aiur-bo-legend-list">
${items}
</ul>
</footer>`;
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
