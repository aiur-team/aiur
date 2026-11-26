import { isUnfiled, refText, refTitle, queueText } from './unfiled.js';
import { activeFeature } from './features.js';
import { rowOk } from './filters.js';
// Port of design build.js:1152–1181, with explicit unknowns and delegated input.
import { S, ctx, fx } from './state.js';
import { esc } from './dom.js';
import { nowMs } from './clock.js';
import { fmtD, fmtH, fmtT } from './util.js';
import { estLabel } from './estimate.js';
import { I } from './icons.js';
import { writeURL } from './url.js';
import { LOGOS } from './logos.js';
import { agentState, progress, modelLabel } from './now-state.js';
import { rowState, holdLinkHTML } from './agents.js';
import { colKey, match } from './match.js';
import { H, loadEarlier } from './history.js';
import { sectionState, headNote, reasonText, ageText } from './states.js';
import { timed } from './perf.js';
export const renderList = timed('renderList', renderListImpl);

const HIST = { failed: ['failed', 'Failed'], done: ['merged', 'Merged'], not_planned: ['np', 'Not planned'], closed: ['closed', 'Closed'] };
export function stClass(t) {
  if (t.sec === 'hist') return Object.hasOwn(HIST, t.status) ? HIST[t.status][0] : 'unknown';
  if (t.sec === 'now') return agentState(t.agent?.state).cls ?? 'unknown';
  if (isUnfiled(t)) return 'open';
  if (t.sec === 'plan') return t.cue?.held ? 'held' : t.cue?.failed || t.cue?.blockedChain ? 'blocked' : 'queued';
  return 'open';
}
export function stText(t) {
  if (isUnfiled(t)) return 'Not filed';
  if (t.sec === 'hist') return Object.hasOwn(HIST, t.status) ? HIST[t.status][1] : 'State unknown';
  if (t.sec === 'now') {
    const stateLabel = rowState(t).label;
    return t.agent?.pause === 'usage_limit_exhausted' && Number.isFinite(t.agent?.resume_at)
      ? stateLabel + ' (resumes at ' + new Date(t.agent.resume_at).toISOString().slice(11, 16) + ' UTC)'
      : stateLabel;
  }
  if (t.sec === 'plan') return t.cue?.held ? 'Held' : t.cue?.failed || t.cue?.blockedChain ? 'Blocked' : t.cue?.wait ? 'Waiting on #' + t.cue.wait : 'Queued';
  return 'Not queued';
}
const muted = text => '<span class="lr-mu">' + esc(text) + '</span>';
const number = x => Number.isFinite(x) ? x : '—';
const hue = (key, value) => Number.isFinite(value) ? ' style="' + key + ':' + value + '"' : '';
function lanesHTML(D, P, now) {
  const lanes = Object.entries(D.lanes).filter(([key, lane]) => key !== 'unsorted' && !lane.feature);
  const progress = P.lane_progress || {}, meta = P.lane_progress_meta || {};
  const hasMembers = lanes.some(([key]) => {
    const value = progress[key];
    return !value || value.total == null || value.total > 0;
  });
  if (!lanes.length || !hasMembers) {
    return '<div class="bd-ep-empty"><b>No lanes configured. Define build_order.lanes to group tickets by area</b> <a href="/docs/reference/configuration-build-order#lanes">Configuration reference</a></div>';
  }
  const rows = lanes.map(([key, lane]) => {
    const value = progress[key], unknown = !value || value.open == null || value.total == null || value.closed == null;
    return { key, lane, value, unknown, open: unknown ? null : value.open };
  }).sort((a, b) => a.unknown !== b.unknown ? (a.unknown ? 1 : -1) : a.unknown ? a.lane.label.localeCompare(b.lane.label) : b.open - a.open || a.lane.label.localeCompare(b.lane.label));
  const knownTotal = rows.some(row => row.unknown) ? '—' : rows.reduce((sum, row) => sum + row.open, 0);
  const content = rows.map(({ key, lane, value, unknown }) => {
    const pct = unknown ? null : value.total === 0 ? 0 : Math.floor(value.closed * 100 / value.total);
    const icon = Object.hasOwn(I, lane.icon) ? I[lane.icon] : '';
    const reason = unknown ? reasonText(value?.reason || 'Progress unavailable') : '';
    // An unknown lane gets an empty track, never a zero fill.
    const meter = unknown ? '<span class="fp-bar" role="img" aria-label="' + esc('Progress unknown: ' + reason) + '"></span>'
      : fpBar(value.closed, value.total, value.total > 0 && value.closed === value.total ? ' done' : '', 'closed');
    return '<div class="lr ln-grid ep-row" role="row" tabindex="0" data-lane="' + esc(key) + '"' + hue('--h', lane.hue) + ' aria-label="' + esc(lane.label + ', ' + (unknown ? 'progress unknown: ' + reason : value.open + ' remaining')) + '">' +
      '<span class="ep-name" role="cell"><span class="lr-ep" aria-hidden="true">' + icon + '</span><b title="' + esc(key) + '">' + esc(lane.label) + '</b></span>' +
      '<span class="ep-meter" role="cell">' + meter + '</span>' +
      '<span class="ep-left" role="cell">' + (unknown ? '—' : value.open) + '</span>' +
      '<span class="ep-count" role="cell">' + (unknown ? '— · ' + esc(reason) : value.closed + ' / ' + value.total + ' · ' + pct + '%') + '</span></div>';
  }).join('');
  const age = !Number.isFinite(meta.observed_at) ? 'age unknown' : ageText({ observed_at: meta.observed_at }, now);
  const caption = knownTotal + ' tickets remaining across ' + rows.length + ' lanes · Data as of ' + age + ' · Sorted by remaining tickets, most first; ties by name. ' +
    'A ticket can count under more than one lane, so column totals can exceed the ticket count. Planned pack tickets without area labels are excluded. ' +
    (meta.unmatched == null ? '— tickets match no lane (' + reasonText(meta.reason || 'Labels incomplete') + ')' : meta.unmatched + ' tickets match no lane');
  return '<div class="bd-list epic-list" role="table" aria-label="Lane progress" tabindex="-1">' +
    headRow('ln-grid', [['ep-name', 'Lane'], ['ep-meter', 'Progress'], ['ep-left', 'Remaining'], ['ep-count', 'Done']]) + content + capRow(caption) + '</div>';
}
// Features and Lanes share the Tickets table: the same card, header row and row class.
const headRow = (cls, cols) => '<div class="lr lr-h ' + cls + '" role="row">' + cols.map(([cls, label]) => '<span class="' + cls + '" role="columnheader">' + label + '</span>').join('') + '</div>';
const capRow = (text, cls = '') => '<div class="lr-cap' + cls + '" role="row"><span role="cell">' + esc(text) + '</span></div>';
const fpBar = (m, t, cls, word = 'merged') => `<span class="fp-bar${cls}" role="img" aria-label="${m} of ${t} ${word}"><i style="width:${t > 0 ? m / t * 100 : 0}%"></i></span>`;
function progCell(t) {
  if (t.sec === 'now') {
    const p = progress(t.pct);
    return p.known ? '<span class="lr-pg" style="' + esc(p.style) + '"><span class="bd-bar"><i style="width:' + t.pct + '%"></i></span><b>' + esc(p.text) + '</b></span>' : muted('—');
  }
  if (t.sec === 'hist') return muted((Number.isFinite(t.end) ? fmtD(t.end) : '—') + ' · ' +
    (Number.isFinite(t.start) && Number.isFinite(t.end) && t.end >= t.start ? fmtH((t.end - t.start) / 36e5) : '—'));
  if (t.sec === 'plan') {
    return muted(queueText(t) + ' · W' + (Number.isFinite(t.wave) ? t.wave : '?') + ' · ' + estLabel(t));
  }
  return muted(number(t.pts) + ' pts');
}
function agentCell(t) {
  const a = t.agent;
  if (!a) return t.cue?.capacity ? muted(t.cue.capacity) : muted('—');
  const logo = LOGOS[a.model], name = modelLabel(a) ?? 'Model unknown';
  return (logo ? '<img src="' + esc(logo.src) + '" alt="">' : '<span class="ax-mono" aria-hidden="true">' + esc(a.name?.[0]?.toUpperCase() || '?') + '</span>') + esc(name) +
    (a.reason ? ' <span class="lr-mu" title="' + esc(a.reason) + '">' + esc(a.reason) + '</span>' : '');
}
function rowHTML(t, D, state) {
  const key = colKey(t), e = (Object.hasOwn(D.lanes, key) ? D.lanes[key] : D.lanes.unsorted) ?? { label: 'Unsorted', unsorted: true };
  const f = Object.hasOwn(D.features, t.feature) ? D.features[t.feature] : null;
  const dim = activeFeature(D, state) && state.fmode === 'focus' && t.feature !== state.feature && !t.also.includes(state.feature);
  const ups = t.deps.length, dn = (D.children[t.id] || []).length, deps = ups + ' dependencies · unblocks ' + dn;
  const cell = (cls, html, attrs = '') => '<span class="' + cls + '" role="cell"' + attrs + '>' + html + '</span>';
  return '<div class="lr ' + esc(t.sec) + (t.sec === 'hist' && t.status === 'done' ? ' completed' : '') + (dim ? ' dim' : '') + '" role="row" tabindex="0" data-id="' + esc(t.id) + '"' + hue('--h', e.hue) +
    ' aria-label="' + esc(refText(t) + ' ' + t.title + ', ' + stText(t)) + '">' +
    cell('c-id', '<span class="lr-ep' + (e.unsorted ? ' un' : '') + '" aria-hidden="true">' + (D.icons?.[e.icon] || e.svg || (Object.hasOwn(I, e.icon) ? I[e.icon] : '')) + '</span><span title="' + esc(refTitle(t)) + '">' + esc(refText(t)) + '</span>') +
    cell('c-tt', esc(t.title) + (f ? '<span class="lr-f"' + hue('--ft', f.hue) + ' title="' + esc(f.summary || f.label) + '" role="img" aria-label="' + esc('Feature: ' + f.label) + '">' + (D.icons?.[f.icon] || f.svg || '') + '</span>' : '')) +
    cell('c-ep', esc(e.label)) + cell('c-st', '<span class="lst st-' + stClass(t) + '"><u aria-hidden="true"></u>' + (holdLinkHTML(t) || esc(stText(t))) + '</span>') +
    cell('c-ag', agentCell(t)) + cell('c-pg', progCell(t)) + cell('c-dp', (ups ? '↑' + ups : '') + (dn ? ' ↓' + dn : ''), ' title="' + esc(deps) + '" aria-label="' + esc(deps) + '"') + '</div>';
}
function secHead(sec, label, sub, rows, extra, D, state, history, P, now) {
  // Open-ticket availability already includes queue health; index is only the index reader's health.
  const open = P.sources?.open_tickets;
  const index = open?.state === 'unsupported' ? { ...open, state: 'unavailable' } : open;
  const payload = sec === 'nq' ? { ...P, sources: { ...P.sources, index } } : P;
  const st = sectionState(payload, D, history, sec, rows), note = headNote(sec, st, now);
  const packs = sec === 'plan' && P.sources?.packs?.state === 'unavailable' ? P.sources.packs : null;
  if (!rows.length && !extra && st.src.state === 'ok' && !packs) return '';
  if (!rows.length && ['unavailable', 'incomplete', 'disabled'].includes(st.src.state)) {
    sub = note + ' · ' + reasonText(st.src.reason) + (st.src.state === 'disabled' ? '' : ' · ' + ageText(st.src, now));
  } else if (note) sub += ' · ' + note;
  if (sec === 'hist' && history.state === 'error') sub += ' · earlier days could not load';
  if (packs) sub += ' · Planning packs unavailable · ' + (packs.reason || 'unknown cause') +
    ' · checked ' + (Number.isFinite(packs.observed_at) ? fmtT(packs.observed_at) : 'unknown');
  return '<div class="lh" role="row" data-sec="' + sec + '"' + (st.src.state !== 'ok' ? ' data-st="' + esc(st.src.state) + '"' : '') +
    '><b role="cell">' + label + '</b><em role="cell">' + esc(sub) + '</em></div>' + rows.map(t => rowHTML(t, D, state)).join('') + extra;
}
export function listHTML(D, state, history, P, now) {
  if (state.list === 'features') return featureListHTML(D, state, now);
  const keep = t => rowOk(state, t) && match(t, state), rows = Object.fromEntries(['now', 'plan', 'nq'].map(sec => [sec, D[sec].filter(keep)]));
  rows.hist = D.hist.filter(t => t.end >= (state.histFrom || 0) && keep(t)).sort((a, b) => b.end - a.end);
  const labels = { now: '<i class="lh-live" aria-hidden="true"></i>Live', plan: 'Planned', nq: 'Not queued', hist: 'History' };
  const nowCounts = { running: 0, retrying: 0, stuck: 0, paused: 0, unknown: 0 };
  for (const ticket of rows.now) {
    const key = ticket.agent?.state === 'active' ? 'running'
      : ticket.agent?.state === 'retrying' ? 'retrying'
        : ['error', 'retries', 'command', 'native_question'].includes(ticket.agent?.state) ? 'stuck'
          : ['paused', 'parked', 'usage_limited', 'paused-usage-limit', 'paused-decision', 'paused-agent', 'ci_wait', 'merge-queued', 'blocked', 'handed-off'].includes(ticket.agent?.state) ? 'paused'
            : ['ci-red', 'body-fix'].includes(ticket.agent?.state) ? 'stuck' : 'unknown';
    nowCounts[key]++;
  }
  const nowSummary = Object.entries(nowCounts).filter(([key, count]) => key === 'running' || count > 0)
    .map(([key, count]) => count + ' ' + (key === 'unknown' ? 'state unknown' : key)).join(' · ');
  const subs = { now: nowSummary, plan: rows.plan.length + ' in build-queue order', nq: rows.nq.length + ' open', hist: rows.hist.length + ' loaded · newest first' };
  const more = history.more ? '<div role="row"><div role="cell"><button type="button" class="lr-more" id="lr-more"' + (history.state === 'loading' ? ' disabled aria-busy="true"' : '') + '>Load earlier day</button></div></div>' : '';
  return '<div class="bd-list" role="table" aria-label="Build tickets" tabindex="-1"><div class="lr lr-h" role="row">' +
    ['id', 'tt', 'ep', 'st', 'ag', 'pg', 'dp'].map((key, i) => '<span class="c-' + key + '" role="columnheader">' + ['Ticket', 'Title', 'Lane', 'State', 'Agent', 'Progress', 'Deps'][i] + '</span>').join('') + '</div>' +
    ['now', 'plan', 'nq', 'hist'].map(sec => {
      const html = secHead(sec, labels[sec], subs[sec], rows[sec], sec === 'hist' ? more : '', D, state, history, P, now);
      // #7758: the Live group is one sticky block so it pins under the column header or to the bottom edge.
      return sec === 'now' && html ? '<div class="lr-live" role="rowgroup">' + html + '</div>' : html;
    }).join('') + '</div>';
}
// One table row per feature: name, rounded bar, merged/total and remaining. Bars come from the
// same block as the feature filter. Sorting lives in the toolbar; the summary is the caption row.
export function featureListHTML(D, state, now) {
  const P = D.feature_progress, bars = P?.bars, known = Array.isArray(bars);
  const sorted = known ? [...bars] : [];
  if (state.fsort === 'pct') sorted.sort((a, b) => b.merged / b.total - a.merged / a.total);
  if (state.fsort === 'left') sorted.sort((a, b) => (b.total - b.merged) - (a.total - a.merged));
  const merged = sorted.reduce((sum, b) => sum + b.merged, 0), total = sorted.reduce((sum, b) => sum + b.total, 0);
  const cells = (name, m, t, cls) => `<span class="fp-name" role="cell" title="${esc(name)}">${esc(name)}</span><span class="fp-pg" role="cell">${fpBar(m, t, cls)}</span><span class="fp-count" role="cell">${m}/${t}</span><span class="fp-left" role="cell">${t - m}</span>`;
  const row = (b, extra = '') => {
    const go = Object.hasOwn(D.features, b.key);
    return `<div class="lr fp-grid fp-row${extra}${go ? ' fp-go' : ''}" role="row" data-feature="${esc(b.key)}"${go ? ` tabindex="0" aria-label="Focus ${esc(b.label)} feature"` : ''}>${cells(b.label, b.merged, b.total, b.merged === b.total ? ' done' : '')}</div>`;
  };
  const date = new Date(now).toLocaleDateString('en-CA');
  const summary = known ? `${merged} of ${total} tickets merged - ${date}` : `Feature progress unavailable - ${date}`;
  const all = known ? `<div class="lr fp-grid fp-row fp-all" role="row">${cells('All features', merged, total, ' all')}</div>` : '';
  const body = known ? featureRowsHTML(sorted, P.epics, state, row, cells) : '';
  return '<div class="bd-list fp-list" role="table" aria-label="Feature progress" tabindex="-1">' +
    headRow('fp-grid', [['fp-name', 'Feature'], ['fp-pg', 'Progress'], ['fp-count', 'Merged'], ['fp-left', 'Remaining']]) +
    (body || capRow('No features with tickets')) + all + capRow(summary, ' fp-sum') + '</div>';
}
// Epics group the rows when the payload carries epic rows: the epic's own merged/total first,
// then its features indented under it in the epic's order. Features no epic lists keep their flat
// order under "No epic" at the end. A payload without epic rows keeps the flat list, so a build
// with no epic records reads exactly as before.
function featureRowsHTML(sorted, epics, state, row, cells) {
  const flat = () => sorted.map(b => row(b)).join('');
  const known = new Map(sorted.map(b => [b.key, b]));
  const inGroup = list => state.fsort === 'goal' ? list : [...list].sort((a, b) => state.fsort === 'pct'
    ? b.merged / b.total - a.merged / a.total
    : (b.total - b.merged) - (a.total - a.merged));
  const claimed = new Set();
  const groups = (Array.isArray(epics) ? epics : []).map(epic => {
    const feats = (epic.features || []).map(key => known.get(key)).filter(Boolean);
    feats.forEach(f => claimed.add(f.key));
    return feats.length ? { epic, feats } : null;
  }).filter(Boolean);
  if (!groups.length) return flat();
  const group = ({ epic, feats }) =>
    `<div class="lr fp-grid fp-row fp-epic-row fp-go" role="row" data-epic="${esc(epic.key)}" tabindex="0" aria-label="Focus ${esc(epic.label)} epic features">${cells(epic.label, epic.merged, epic.total, epic.merged === epic.total ? ' done' : '')}</div>` +
    inGroup(feats).map(f => row(f, ' fp-feat')).join('');
  const rest = sorted.filter(b => !claimed.has(b.key));
  const noEpic = rest.length ? '<div class="lr fp-grid fp-row fp-noepic-row" role="row"><span class="fp-name" role="cell">No epic</span></div>' + inGroup(rest).map(f => row(f, ' fp-feat')).join('') : '';
  return groups.map(group).join('') + noEpic;
}
function renderListImpl() {
  const vp = ctx.vp, rows = () => [...vp.querySelectorAll('.lr[data-id]')], previous = rows();
  if (S.list === 'features') {
    ctx.L = null; ctx.content = null; ctx.R.clear(); ctx.cols = [];
    vp.innerHTML = listHTML(ctx.D, S, H, ctx.snap, nowMs());
    bindOnce(vp); return;
  }
  const focused = document.activeElement?.closest?.('.lr[data-id]'), index = previous.indexOf(focused);
  const moreFocused = document.activeElement?.id === 'lr-more' && vp.contains(document.activeElement);
  const top = vp.getBoundingClientRect().top;
  const anchor = previous.find(el => el.getBoundingClientRect().top >= top);
  const offset = anchor ? anchor.getBoundingClientRect().top - top : null, scroll = vp.scrollTop;
  ctx.L = null; ctx.content = null; ctx.R.clear(); ctx.cols = [];
  if (S.list === 'lanes') {
    vp.innerHTML = lanesHTML(ctx.D, ctx.snap, nowMs());
    vp.scrollTop = 0; bindOnce(vp); return;
  }
  if (S.list !== 'tickets') {
    vp.innerHTML = '<div class="bd-list-placeholder">Features view is not available yet</div>';
    vp.scrollTop = 0; bindOnce(vp); return;
  }
  vp.innerHTML = listHTML(ctx.D, S, H, ctx.snap, nowMs());
  const all = rows(), next = anchor && all.find(el => el.dataset.id === anchor.dataset.id);
  vp.scrollTop = next ? vp.scrollTop + next.getBoundingClientRect().top - top - offset : scroll;
  if (index >= 0) (all.find(el => el.dataset.id === focused.dataset.id) || all[Math.min(index, all.length - 1)] || vp.querySelector('.bd-list')).focus({ preventScroll: true });
  if (moreFocused) (vp.querySelector('#lr-more') || all.at(-1) || vp.querySelector('.bd-list')).focus({ preventScroll: true });
  bindOnce(vp);
}
function bindOnce(vp) {
  if (ctx.listVp === vp) return;
  ctx.listVp = vp;
  const open = row => { const t = ctx.D.byId[row.dataset.id]; if (t) fx.openModal(t, { origin: row }); };
  ctx.life.on(vp, 'click', e => {
    if (S.view !== 'list') return;
    const btn = e.target.closest('#lr-more');
    if (btn) { earlier(btn); return; }
    const lane = e.target.closest('.ep-row[data-lane]'); if (lane) { chooseLane(lane.dataset.lane); return; }
    const group = e.target.closest('.fp-epic-row[data-epic]'); if (group) { focusEpic(group.dataset.epic); return; }
    if (e.target.closest('.bd-hold')) return;
    const row = e.target.closest('.lr[data-id]'); if (row) open(row);
    const feature = e.target.closest('.fp-go'); if (feature) focusFeature(feature.dataset.feature);
  });
  ctx.life.on(vp, 'keydown', e => {
    if (S.view !== 'list' || e.key !== 'Enter' || e.target.matches('button')) return;
    const lane = e.target.closest('.ep-row[data-lane]'); if (lane) { e.preventDefault(); chooseLane(lane.dataset.lane); return; }
    const group = e.target.closest('.fp-epic-row[data-epic]'); if (group) { e.preventDefault(); focusEpic(group.dataset.epic); return; }
    if (e.target.closest('.bd-hold')) return;
    const row = e.target.closest('.lr[data-id]'); if (row) { e.preventDefault(); open(row); }
    const feature = e.target.closest('.fp-go'); if (feature) { e.preventDefault(); focusFeature(feature.dataset.feature); }
  });
}
function chooseLane(key) {
  S.f.lane = [key]; S.list = 'tickets'; writeURL(); fx.renderTools(); fx.renderList();
}
function focusFeature(key) {
  S.view = 'graph'; S.list = 'tickets'; S.feature = key; S.fmode = 'focus'; S.f.feature = [];
  writeURL(); fx.renderTools(); fx.renderFilters(); fx.viewport(); fx.relayout();
}
// An epic row focuses the graph on every feature the epic holds: the feature filter carries the
// epic's features, so the timeline lays out only their tickets. The toolbar shows the count and
// Clear releases it, the same way the lane filter does.
function focusEpic(key) {
  const epics = ctx.D?.feature_progress?.epics;
  const epic = Array.isArray(epics) ? epics.find(candidate => candidate.key === key) : null;
  if (!epic || !Array.isArray(epic.features) || !epic.features.length) return;
  S.view = 'graph'; S.list = 'tickets'; S.feature = null; S.fmode = 'focus'; S.f.feature = [...epic.features];
  writeURL(); fx.renderFeatures(); fx.renderTools(); fx.renderFilters(); fx.viewport(); fx.relayout();
}
async function earlier(btn) {
  if (H.state === 'loading') return;
  const focused = document.activeElement === btn, life = ctx.life, vp = ctx.vp;
  H.retryArmed = true; btn.disabled = true; btn.setAttribute('aria-busy', 'true');
  await loadEarlier();
  if (ctx.life !== life || life.disposed || ctx.vp !== vp || S.view !== 'list') return;
  renderList();
  if (focused && document.activeElement === document.body) {
    (vp.querySelector('#lr-more') || [...vp.querySelectorAll('.lr[data-id]')].at(-1) || vp.querySelector('.bd-list'))?.focus({ preventScroll: true });
  }
}
Object.assign(fx, { renderList });
