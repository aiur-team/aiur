import { isUnfiled, refText, queueText, srcLine } from '../unfiled.js';
import { estLabel } from '../estimate.js';
import { ctx, fx, onReset } from '../state.js';
import { $, esc } from '../dom.js';
import { I } from '../icons.js';
import { nowMs } from '../clock.js';
import { MS, onModalClose, registerBody } from './frame.js';

let view = null;
let timelineView = null;
const adds = new Map();
const numeric = id => /^[1-9][0-9]{0,9}$/.test(id);
const cue = (text, icon = I.hourglass, bad = false) => '<p class="bm-cue' + (bad ? ' bad' : '') + '">' + icon + esc(text) + '</p>';
const reasons = {
  auth: 'authentication required', permission: 'permission denied', rate_limited: 'rate limited',
  timeout: 'timed out', transport: 'connection failed', not_found: 'issue not found',
  schema: 'could not be read', validation: 'could not be read', not_fresh: 'not refreshed',
  evicted: 'no longer cached', configuration: 'configuration unavailable', capacity: 'reader at capacity',
  provider_identity_mismatch: 'identity mismatch', nonfetchable_repository: 'repository unavailable',
};
const reasonText = reason => Object.hasOwn(reasons, reason) ? reasons[reason] : 'unknown';
const fmtDate = ms => new Date(ms).toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
const fmtTime = ms => { const d = new Date(ms); return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0'); };
function staleText(doc) {
  const now = nowMs(), observed = doc.observed_at;
  if (!Number.isFinite(observed) || now === null) return 'Issue body as of unknown time (age unknown) · ' + reasonText(doc.reason);
  const age = Math.max(0, now - observed), minutes = Math.floor(age / 60_000);
  const ago = minutes < 1 ? Math.floor(age / 1000) + 's' : minutes < 60 ? minutes + 'm' : minutes < 1440 ? Math.floor(minutes / 60) + 'h' : Math.floor(minutes / 1440) + 'd';
  return 'Issue body as of ' + fmtTime(observed) + ' (' + ago + ' ago) · ' + reasonText(doc.reason);
}
function bodyHTML(doc) {
  switch (doc?.state) {
    case 'available': return doc.body_html || '';
    case 'empty': return '<p class="bm-sum" style="color:var(--muted)">No description.</p>';
    case 'stale': return (doc.body_html || '') + cue(staleText(doc));
    case 'unavailable': return cue('Issue body unavailable · ' + reasonText(doc.reason) + (doc.retry_after ? ' · retry in ' + doc.retry_after + 's' : ''), I.warn, true);
    case 'identity_unknown': return cue('Issue body not loaded here · open it on GitHub', I.github);
    default: return cue('Loading the issue body…');
  }
}
const timelineKinds = { emit: 'Event emitted', consume: 'Event consumed', command: 'Command', note: 'Note' };
const fmtMoment = ms => new Date(ms).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
function timelineLink(url) {
  try {
    const parsed = new URL(url);
    return parsed.protocol === 'https:' && !parsed.username && !parsed.password ? esc(parsed.href) : '';
  } catch { return ''; }
}
export function timelineHTML(timeline) {
  if (!timeline || timeline.status === 'loading') return cue('Loading ticket timeline…');
  const items = timeline.items || [];
  if (!items.length) return cue(timeline.status === 'unavailable' ? 'Timeline is unavailable · retry when the ticket history service is available' : 'No recorded events for this ticket yet', timeline.status === 'unavailable' ? I.warn : I.docs, timeline.status === 'unavailable');
  const start = items[0]?.at ?? 0, end = items.at(-1)?.at ?? start + 1, span = Math.max(1, end - start);
  const actors = ['Executor', 'CI', 'Aiur agent', 'Aiur daemon'];
  const gaps = items.slice(1).flatMap((item, index) => {
    const previous = items[index]; const duration = item.at - previous.at;
    return duration >= 30 * 60_000 ? [{ from: previous.at, to: item.at, duration }] : [];
  });
  return '<section class="bm-timeline" aria-label="Ticket timeline">' +
    (timeline.status === 'unavailable' ? cue('History refresh failed · showing the last cached events', I.warn, true) : '') +
    (timeline.truncated ? cue('Earlier timeline events are unavailable in the retained event history', I.warn) : '') +
    '<div class="bm-timerange"><time>' + esc(fmtMoment(start)) + '</time><time>' + esc(fmtMoment(end)) + '</time></div>' +
    '<div class="bm-timebar" aria-label="Real-time ticket progress">' + (timeline.phases || []).map(phase => '<i class="bm-timephase" style="left:' + ((phase.start - start) / span * 100) + '%;width:' + (phase.finish ? ((phase.finish - phase.start) / span * 100) : ((end - phase.start) / span * 100)) + '%" title="' + esc(phase.label) + '"></i>').join('') + gaps.map(g => '<i class="bm-timegap" style="left:' + ((g.from - start) / span * 100) + '%;width:' + ((g.to - g.from) / span * 100) + '%" title="No recorded activity · ' + esc(Math.round(g.duration / 60_000) + ' min') + '"></i>').join('') +
    items.map(item => '<i class="bm-timepin kind-' + esc(item.kind) + '" style="left:' + ((item.at - start) / span * 100) + '%" title="' + esc(item.label) + '"></i>').join('') + '</div>' +
    (gaps.length ? '<ul class="bm-timegaps" aria-label="Quiet periods">' + gaps.map(g => '<li>No recorded activity · ' + esc(Math.round(g.duration / 60_000) + ' min') + ' (' + esc(fmtMoment(g.from)) + '–' + esc(fmtMoment(g.to)) + ')</li>').join('') + '</ul>' : '') +
    '<div class="bm-timelanes">' + actors.map(actor => '<section class="bm-timelane"><h3>' + esc(actor) + '</h3><ol class="bm-timeitems">' + items.filter(item => item.actor === actor).map(item => '<li class="bm-timeitem kind-' + esc(item.kind) + ' status-' + esc(item.status || 'normal') + '"><time datetime="' + new Date(item.at).toISOString() + '">' + esc(fmtMoment(item.at)) + '</time><span><small>' + esc(timelineKinds[item.kind] || 'Note') + (item.status ? ' · ' + esc(item.status.replaceAll('_', ' ')) : '') + '</small><b>' + esc(item.label) + '</b>' + (item.run_url && timelineLink(item.run_url) ? '<a href="' + timelineLink(item.run_url) + '" target="_blank" rel="noopener noreferrer">Open CI run</a>' : '') + (item.topic ? '<code>' + esc(item.topic) + '</code>' : '') + '</span></li>').join('') + '</ol></section>').join('') + '</div>' +
    '<ol class="bm-timeprogress" aria-label="Reported progress">' + (timeline.progress || []).map(item => '<li><time>' + esc(fmtMoment(item.at)) + '</time><b>' + esc(item.percent == null ? 'Unknown' : item.percent + '%') + '</b></li>').join('') + '</ol></section>';
}
function cues(t) {
  const c = t.cue || {}, parts = [];
  if (c.held) parts.push(cue(c.held, I.lock));
  if (c.failed) parts.push(cue('Prerequisite #' + c.failed.by + ' failed — this and ' + Math.max(0, (c.failed.blocks?.length || 1) - 1) + ' more are blocked', I.warn, true));
  else if (c.wait) parts.push(cue('Waiting on #' + c.wait));
  if (c.unknown) parts.push(cue('Prerequisite state unknown'));
  if (t.override?.reason) parts.push(cue(t.override.reason, I.pencil));
  return parts.join('');
}
function dependencies(ids, D) {
  return ids.map(id => {
    const t = Object.hasOwn(D.byId, id) ? D.byId[id] : null;
    const e = t && D.epics?.[t.epic || 'unsorted'];
    return '<button type="button" class="bm-dep" data-goto="' + esc(id) + '">' +
      (Number.isFinite(e?.hue) ? '<span style="--h:' + e.hue + '"></span>' : '') +
      esc(t ? refText(t) : /^[0-9]+$/.test(id) ? '#' + id : '—') + '<em>' + esc(t?.title ?? 'not loaded') + '</em></button>';
  }).join('');
}
function addHTML(t, D) {
  const source = D.sources?.queue;
  if (t.sec !== 'nq' || !ctx.snap?.writable || source?.state === 'disabled') return '';
  const state = adds.get(t.id), unknown = !['ok', 'stale', 'unavailable'].includes(source?.state);
  let reason = source?.state === 'unavailable' ? 'Build queue unavailable · ' + (source.reason || 'unknown') : unknown ? 'Build queue state unknown' : source.reason || '';
  if (state?.pending) reason = 'Adding to queue';
  if (state?.ok) reason = state.reason === 'already_queued' ? 'Already in queue ' + state.queue : 'Added · waiting for the queue';
  const disabled = state?.pending || state?.ok || unknown || source?.state === 'unavailable';
  const id = 'bm-qadd-reason';
  let html = '<span class="bm-qadd" title="' + esc(reason) + '"><button type="button" class="btn secondary sm" data-a="queue-add" aria-describedby="' + id + '"' +
    (disabled ? ' disabled' : '') + (state?.pending ? ' aria-busy="true"' : '') + '>' + I.up + ' Add to queue</button><span class="sr-only" id="' + id + '">' + esc(reason) + '</span></span>';
  if (state?.reason === 'outcome_unknown') html += cue('Add to queue · outcome unknown — the board updates if it was added');
  else if (state && !state.pending && !state.ok) {
    const refusal = { closed: 'the issue is closed', store_unavailable: 'the queue store is unavailable', unsupported_tracker: 'this tracker has no build queue', refused: 'the queue refused it' };
    html += cue('Could not add to queue · ' + (refusal[state.reason] || refusal.refused), I.warn, true);
  }
  return html;
}
export function renderDoc(body, t, D, doc, opts = {}) {
  const scroll = body.querySelector('.bm-doc')?.scrollTop || 0;
  const active = document.activeElement;
  const focused = body.contains(active) ? active.closest('[data-goto], [data-a], [data-tab], .bm-body a') : null;
  const focus = focused ? { goto: focused.dataset.goto, action: focused.dataset.a, tab: focused.dataset.tab, href: focused.getAttribute('href') } : null;
  const created = doc?.created ?? t.created;
  const source = isUnfiled(t) ? I.docs + esc(srcLine(t)) : I.github + esc(refText(t)) + (created == null ? '' : ' · opened ' + esc(fmtDate(created)) + (doc?.author ? ' by @' + esc(doc.author) : ''));
  const fact = (name, value) => '<div><small>' + name + '</small><b>' + esc(value) + '</b></div>';
  const tab = view?.tab || 'description';
  body.innerHTML = '<div class="bm-tabs" role="tablist" aria-label="Ticket detail"><button type="button" role="tab" id="bm-tab-description" aria-controls="bm-panel-description" tabindex="' + (tab === 'description' ? '0' : '-1') + '" data-tab="description" aria-selected="' + (tab === 'description') + '">Description</button><button type="button" role="tab" id="bm-tab-timeline" aria-controls="bm-panel-timeline" tabindex="' + (tab === 'timeline' ? '0' : '-1') + '" data-tab="timeline" aria-selected="' + (tab === 'timeline') + '">Timeline</button></div><div class="bm-doc"><article class="bm-art"><div class="bm-src">' + source + '</div><div class="bm-body" role="tabpanel" id="bm-panel-' + tab + '" aria-labelledby="bm-tab-' + tab + '">' + (tab === 'timeline' ? timelineHTML(doc?.timeline) : (isUnfiled(t) ? '' : bodyHTML(doc))) + '</div></article><aside class="bm-side"><div class="bm-facts">' +
    fact('Queue', t.sec === 'plan' && !isUnfiled(t) ? queueText(t) : '—') + (t.sec === 'plan' ? fact('Wave', t.wave == null ? '—' : 'W' + t.wave) : '') +
    fact('Estimate', estLabel(t)) + fact('Complexity', t.cx == null ? '—' : t.cx + '/5') + '</div>' +
    ((t.deps || []).length ? '<div class="bm-dg"><small>Depends on</small>' + dependencies(t.deps, D) + '</div>' : '') +
    ((D.children?.[t.id] || []).length ? '<div class="bm-dg"><small>Unblocks</small>' + dependencies(D.children[t.id], D) + '</div>' : '') + addHTML(t, D) + '</aside></div>';
  if (opts.note) {
    const note = typeof opts.note === 'string' ? document.createElement('p') : opts.note;
    if (typeof opts.note === 'string') { note.className = 'bm-cue'; note.textContent = opts.note; }
    body.querySelector('.bm-src').after(note);
  }
  const content = body.querySelector('.bm-body'), first = content.firstElementChild;
  if (first?.tagName === 'P' && !first.classList.contains('bm-cue')) { first.classList.add('bm-sum'); first.insertAdjacentHTML('afterend', cues(t)); }
  else content.insertAdjacentHTML('afterbegin', cues(t));
  content.querySelectorAll('a').forEach(a => { a.target = '_blank'; a.rel = 'noopener noreferrer'; });
  if (focus) {
    const replacement = Array.from(body.querySelectorAll('[data-goto], [data-a], [data-tab], .bm-body a')).find(el =>
      focus.href != null ? el.getAttribute('href') === focus.href : focus.goto != null ? el.dataset.goto === focus.goto : focus.tab != null ? el.dataset.tab === focus.tab : el.dataset.a === focus.action);
    if (replacement && !replacement.disabled) replacement.focus({ preventScroll: true });
  }
  body.querySelector('.bm-doc').scrollTop = scroll;
  body.querySelector('[data-a="queue-add"]')?.addEventListener('click', () => add(t.id));
  body.querySelectorAll('[data-tab]').forEach(button => {
    button.addEventListener('click', () => { if (view) view.tab = button.dataset.tab; repaint(); });
    button.addEventListener('keydown', event => {
      if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
      event.preventDefault();
      const tabs = [...body.querySelectorAll('[role="tab"]')];
      const index = tabs.indexOf(button);
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1 : (index + (event.key === 'ArrowRight' ? 1 : tabs.length - 1)) % tabs.length;
      tabs[next].focus();
      tabs[next].click();
    });
  });
}
function repaint() {
  if (view && MS.t?.id === view.id && $('#tk-body')) renderDoc($('#tk-body'), MS.t, ctx.D, view.doc, view.opts);
}
export function applyDoc(doc) {
  if (doc?.v !== 1 || doc.kind !== 'doc' || MS.t?.id !== doc.id) return;
  if (doc.id === timelineView?.id) { timelineView.update(doc.timeline); return; }
  if (doc.id !== view?.id) return;
  view.doc = { ...view.doc, ...doc }; repaint();
}
export function requestTimeline(t, update) {
  const current = timelineView = { id: t.id, update };
  if (!numeric(t.id) || ctx.socket !== 'up') { update({ status: 'unavailable', items: [] }); return; }
  ctx.push('ticket-doc', { id: t.id }).then(doc => {
    if (timelineView === current) applyDoc(doc);
  }, () => { if (timelineView === current) update({ status: 'unavailable', items: [] }); });
}
export function requestDoc(t) {
  if (!numeric(t.id) || ctx.socket !== 'up') return;
  const current = view, req = MS.req;
  ctx.push('ticket-doc', { id: t.id }).then(doc => {
    if (view === current && req === MS.req) applyDoc(doc);
  }, () => { if (view === current && req === MS.req) applyDoc({ v: 1, kind: 'doc', id: t.id, state: 'unavailable', reason: 'unknown' }); });
}
async function add(id) {
  if (adds.get(id)?.pending || adds.get(id)?.ok) return;
  const pending = { pending: true };
  adds.set(id, pending); repaint();
  const life = ctx.life;
  let reply;
  try { reply = await ctx.push('queue-add', { id }); }
  catch { reply = { v: 1, kind: 'queue-add-result', id, ok: false, reason: 'outcome_unknown' }; }
  if (ctx.life !== life || life.disposed || adds.get(id) !== pending) return;
  if (reply?.kind === 'error') {
    if (reply.reason === 'read_only') ctx.snap.writable = false;
    adds.set(id, { ok: false, reason: 'refused' }); repaint();
  } else if (reply?.kind === 'queue-add-result') applyQueueAdd(reply);
}
export function applyQueueAdd(msg) {
  if (msg?.v !== 1 || msg.kind !== 'queue-add-result' || !adds.has(msg.id)) return;
  // Once a board row leaves nq, a late add result cannot re-lock a later re-add.
  const row = ctx.D?.byId[msg.id] || (MS.t?.id === msg.id ? MS.t : null);
  if (row && row.sec !== 'nq') adds.delete(msg.id);
  else adds.set(msg.id, msg);
  repaint();
}
export function syncDoc(msg) {
  let ticketQueueChanged = false;
  for (const row of msg.upsert || []) {
    if (row.sec !== 'nq' && adds.delete(row.id) && row.id === view?.id) ticketQueueChanged = true;
  }
  for (const id of msg.remove || []) {
    if (adds.delete(id) && id === view?.id) ticketQueueChanged = true;
  }
  const related = new Set(Array.from($('#tk-body')?.querySelectorAll('[data-goto]') || [], element => element.dataset.goto));
  const relatedChanged = msg.upsert?.some(row => related.has(row.id) || row.deps?.includes(view?.id)) ||
    msg.remove?.some(id => related.has(id));
  const ticketChanged = msg.upsert?.some(row => row.id === view?.id) || msg.remove?.includes(view?.id);
  if (ticketQueueChanged || ticketChanged || relatedChanged || Object.keys(msg.set || {}).length) repaint();
}
export function reconnectDoc() {
  for (const [id, state] of adds) if (state.pending) adds.set(id, { ok: false, reason: 'outcome_unknown' });
  repaint(); if (view && MS.t?.id === view.id) requestDoc(MS.t);
}
registerBody('doc', (t, body, opts = {}) => {
  view = { id: t.id, opts, doc: null, tab: 'description' };
  renderDoc(body, t, ctx.D, null, opts); requestDoc(t);
});
const modalSync = fx.modalSync;
fx.modalSync = msg => { modalSync(msg); syncDoc(msg); };
onModalClose(() => {
  timelineView = null;
  const hadDoc = view && numeric(view.id);
  view = null;
  if (hadDoc && ctx.socket === 'up' && ctx.push) ctx.push('ticket-doc-close', {}).catch(() => {});
});
onReset(() => { view = null; adds.clear(); });
