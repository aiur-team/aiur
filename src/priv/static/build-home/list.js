import { activeFeature } from './features.js';
import { rowOk } from './filters.js';
// Port of design build.js:1152–1181, with explicit unknowns and delegated input.
import { S, ctx, fx } from './state.js';
import { esc } from './dom.js';
import { nowMs } from './clock.js';
import { fmtD, fmtH } from './util.js';
import { estLabel } from './estimate.js';
import { I } from './icons.js';
import { LOGOS } from './logos.js';
import { agentState, progress, modelLabel } from './now-state.js';
import { colKey, match } from './match.js';
import { H, loadEarlier } from './history.js';
import { sectionState, headNote, reasonText, ageText } from './states.js';
import { writeURL } from './url.js';
import { timed } from './perf.js';
export const renderList = timed('renderList', renderListImpl);

const HIST = { failed: ['failed', 'Failed'], done: ['merged', 'Merged'], not_planned: ['np', 'Not planned'], closed: ['closed', 'Closed'] };
export function stClass(t) {
  if (t.sec === 'hist') return Object.hasOwn(HIST, t.status) ? HIST[t.status][0] : 'unknown';
  if (t.sec === 'now') return agentState(t.agent?.state).cls ?? 'unknown';
  if (t.sec === 'plan') return t.cue?.held ? 'held' : t.cue?.failed || t.cue?.blockedChain ? 'blocked' : 'queued';
  return 'open';
}
export function stText(t) {
  if (t.sec === 'hist') return Object.hasOwn(HIST, t.status) ? HIST[t.status][1] : 'State unknown';
  if (t.sec === 'now') {
    const stateLabel = agentState(t.agent?.state).label;
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
function epicsHTML(D, P, now) {
  const epics = Object.entries(D.epics).filter(([key, epic]) => key !== 'unsorted' && !epic.feature);
  const progress = P.epic_progress || {}, meta = P.epic_progress_meta || {};
  const hasMembers = epics.some(([key]) => {
    const value = progress[key];
    return !value || value.total == null || value.total > 0;
  });
  if (!epics.length || !hasMembers) {
    return '<div class="bd-ep-empty"><b>No epics configured. Define build_order.general_epics to group tickets by area</b> <a href="/docs/reference/configuration-build-order#general-epics">Configuration reference</a></div>';
  }
  const rows = epics.map(([key, epic]) => {
    const value = progress[key], unknown = !value || value.open == null || value.total == null || value.closed == null;
    return { key, epic, value, unknown, open: unknown ? null : value.open };
  }).sort((a, b) => a.unknown !== b.unknown ? (a.unknown ? 1 : -1) : a.unknown ? a.epic.label.localeCompare(b.epic.label) : b.open - a.open || a.epic.label.localeCompare(b.epic.label));
  const knownTotal = rows.some(row => row.unknown) ? '—' : rows.reduce((sum, row) => sum + row.open, 0);
  const content = rows.map(({ key, epic, value, unknown }) => {
    const pct = unknown ? null : value.total === 0 ? 0 : Math.floor(value.closed * 100 / value.total);
    const icon = Object.hasOwn(I, epic.icon) ? I[epic.icon] : '';
    const reason = unknown ? reasonText(value?.reason || 'Progress unavailable') : '';
    return '<div class="ep-row" role="row" tabindex="0" data-epic="' + esc(key) + '" aria-label="' + esc(epic.label + ', ' + (unknown ? 'progress unknown: ' + reason : value.open + ' remaining')) + '">' +
      '<span class="ep-icon" role="cell"' + hue('--h', epic.hue) + ' aria-hidden="true">' + icon + '</span>' +
      '<span class="ep-name" role="cell"><b>' + esc(epic.label) + '</b><small>' + esc(key) + '</small></span>' +
      '<span class="ep-meter" role="cell" aria-label="' + esc(unknown ? 'Progress unknown: ' + reason : value.closed + ' closed of ' + value.total + ', ' + pct + '%') + '"><i aria-hidden="true"' + (unknown ? '' : ' style="--pct:' + pct + '%"') + '></i></span>' +
      '<span class="ep-count" role="cell">' + (unknown ? '<b>—</b><small>' + esc(reason) + '</small>' : '<b>' + value.open + '</b><small>' + value.open + ' / ' + value.total + ' · ' + pct + '%</small>') + '</span></div>';
  }).join('');
  const age = !Number.isFinite(meta.observed_at) ? 'age unknown' : ageText({ observed_at: meta.observed_at }, now);
  return '<div class="epic-list"><header><b>' + knownTotal + ' tickets remaining across ' + rows.length + ' epics</b><small>Data as of ' + esc(age) + '</small><small>Sorted by remaining tickets, most first; ties by name</small></header><div class="ep-rows" role="table" aria-label="Epic progress">' + content + '</div><footer>' +
    'A ticket can count under more than one epic, so column totals can exceed the ticket count. Planned pack tickets without area labels are excluded. ' +
    (meta.unmatched == null ? '— tickets match no epic (' + esc(reasonText(meta.reason || 'Labels incomplete')) + ')' : meta.unmatched + ' tickets match no epic') + '</footer></div>';
}
function progCell(t) {
  if (t.sec === 'now') {
    const p = progress(t.pct);
    return p.known ? '<span class="lr-pg" style="' + esc(p.style) + '"><span class="bd-bar"><i style="width:' + t.pct + '%"></i></span><b>' + esc(p.text) + '</b></span>' : muted('—');
  }
  if (t.sec === 'hist') return muted((Number.isFinite(t.end) ? fmtD(t.end) : '—') + ' · ' +
    (Number.isFinite(t.start) && Number.isFinite(t.end) && t.end >= t.start ? fmtH((t.end - t.start) / 36e5) : '—'));
  if (t.sec === 'plan') {
    return muted('Q' + number(t.qpos) + ' · W' + (Number.isFinite(t.wave) ? t.wave : '?') + ' · ' + estLabel(t));
  }
  return muted(number(t.pts) + ' pts');
}
function agentCell(t) {
  const a = t.agent;
  if (!a) return muted('—');
  const logo = LOGOS[a.model], name = modelLabel(a) ?? 'Model unknown';
  return (logo ? '<img src="' + esc(logo.src) + '" alt="">' : '<span class="ax-mono" aria-hidden="true">' + esc(a.name?.[0]?.toUpperCase() || '?') + '</span>') + esc(name);
}
function rowHTML(t, D, state) {
  const key = colKey(t), e = (Object.hasOwn(D.epics, key) ? D.epics[key] : D.epics.unsorted) ?? { label: 'Unsorted', unsorted: true };
  const f = Object.hasOwn(D.features, t.feature) ? D.features[t.feature] : null;
  const dim = activeFeature(D, state) && state.fmode === 'focus' && t.feature !== state.feature && !t.also.includes(state.feature);
  const ups = t.deps.length, dn = (D.children[t.id] || []).length, deps = ups + ' dependencies · unblocks ' + dn;
  const cell = (cls, html, attrs = '') => '<span class="' + cls + '" role="cell"' + attrs + '>' + html + '</span>';
  return '<div class="lr ' + esc(t.sec) + (dim ? ' dim' : '') + '" role="row" tabindex="0" data-id="' + esc(t.id) + '"' + hue('--h', e.hue) +
    ' aria-label="' + esc('#' + t.num + ' ' + t.title + ', ' + stText(t)) + '">' +
    cell('c-id', '<span class="lr-ep' + (e.unsorted ? ' un' : '') + '" aria-hidden="true">' + (Object.hasOwn(I, e.icon) ? I[e.icon] : '') + '</span>#' + esc(t.num)) +
    cell('c-tt', esc(t.title) + (f ? '<i class="lr-f"' + hue('--ft', f.hue) + ' title="' + esc(f.label) + '" role="img" aria-label="' + esc('Feature: ' + f.label) + '"></i>' : '')) +
    cell('c-ep', esc(e.label)) + cell('c-st', '<span class="lst st-' + stClass(t) + '"><u aria-hidden="true"></u>' + esc(stText(t)) + '</span>') +
    cell('c-ag', agentCell(t)) + cell('c-pg', progCell(t)) + cell('c-dp', (ups ? '↑' + ups : '') + (dn ? ' ↓' + dn : ''), ' title="' + esc(deps) + '" aria-label="' + esc(deps) + '"') + '</div>';
}
function secHead(sec, label, sub, rows, extra, D, state, history, P, now) {
  // Open-ticket availability already includes queue health; index is only the index reader's health.
  const open = P.sources?.open_tickets;
  const index = open?.state === 'unsupported' ? { ...open, state: 'unavailable' } : open;
  const payload = sec === 'nq' ? { ...P, sources: { ...P.sources, index } } : P;
  const st = sectionState(payload, D, history, sec, rows), note = headNote(sec, st, now);
  if (!rows.length && !extra && st.src.state === 'ok') return '';
  if (!rows.length && ['unavailable', 'incomplete', 'disabled'].includes(st.src.state)) {
    sub = note + ' · ' + reasonText(st.src.reason) + (st.src.state === 'disabled' ? '' : ' · ' + ageText(st.src, now));
  } else if (note) sub += ' · ' + note;
  if (sec === 'hist' && history.state === 'error') sub += ' · earlier days could not load';
  return '<div class="lh" role="row" data-sec="' + sec + '"' + (st.src.state !== 'ok' ? ' data-st="' + esc(st.src.state) + '"' : '') +
    '><b role="cell">' + label + '</b><em role="cell">' + esc(sub) + '</em></div>' + rows.map(t => rowHTML(t, D, state)).join('') + extra;
}
export function listHTML(D, state, history, P, now) {
  const keep = t => rowOk(state, t) && match(t, state), rows = Object.fromEntries(['now', 'plan', 'nq'].map(sec => [sec, D[sec].filter(keep)]));
  rows.hist = D.hist.filter(t => t.end >= (state.histFrom || 0) && keep(t)).sort((a, b) => b.end - a.end);
  const labels = { now: '<i class="lh-live" aria-hidden="true"></i>Live', plan: 'Planned', nq: 'Not queued', hist: 'History' };
  const nowCounts = { running: 0, retrying: 0, stuck: 0, paused: 0, unknown: 0 };
  for (const ticket of rows.now) {
    const key = ticket.agent?.state === 'active' ? 'running'
      : ticket.agent?.state === 'retrying' ? 'retrying'
        : ['error', 'retries', 'command'].includes(ticket.agent?.state) ? 'stuck'
          : ['paused', 'parked', 'usage_limited', 'paused-usage-limit', 'paused-decision', 'paused-agent', 'ci_wait', 'merge-queued', 'blocked', 'handed-off'].includes(ticket.agent?.state) ? 'paused'
            : ['ci-red', 'body-fix'].includes(ticket.agent?.state) ? 'stuck' : 'unknown';
    nowCounts[key]++;
  }
  const nowSummary = Object.entries(nowCounts).filter(([key, count]) => key === 'running' || count > 0)
    .map(([key, count]) => count + ' ' + (key === 'unknown' ? 'state unknown' : key)).join(' · ');
  const subs = { now: nowSummary, plan: rows.plan.length + ' in build-queue order', nq: rows.nq.length + ' open', hist: rows.hist.length + ' loaded · newest first' };
  const more = history.more ? '<div role="row"><div role="cell"><button type="button" class="lr-more" id="lr-more"' + (history.state === 'loading' ? ' disabled aria-busy="true"' : '') + '>Load earlier day</button></div></div>' : '';
  return '<div class="bd-list" role="table" aria-label="Build tickets" tabindex="-1"><div class="lr lr-h" role="row">' +
    ['id', 'tt', 'ep', 'st', 'ag', 'pg', 'dp'].map((key, i) => '<span class="c-' + key + '" role="columnheader">' + ['Ticket', 'Title', 'Epic', 'State', 'Agent', 'Progress', 'Deps'][i] + '</span>').join('') + '</div>' +
    ['now', 'plan', 'nq', 'hist'].map(sec => secHead(sec, labels[sec], subs[sec], rows[sec], sec === 'hist' ? more : '', D, state, history, P, now)).join('') + '</div>';
}
function renderListImpl() {
  const vp = ctx.vp, rows = () => [...vp.querySelectorAll('.lr[data-id]')], previous = rows();
  const focused = document.activeElement?.closest?.('.lr[data-id]'), index = previous.indexOf(focused);
  const moreFocused = document.activeElement?.id === 'lr-more' && vp.contains(document.activeElement);
  const top = vp.getBoundingClientRect().top;
  const anchor = previous.find(el => el.getBoundingClientRect().top >= top);
  const offset = anchor ? anchor.getBoundingClientRect().top - top : null, scroll = vp.scrollTop;
  ctx.L = null; ctx.content = null; ctx.R.clear(); ctx.cols = [];
  if (S.list !== 'tickets') {
    vp.innerHTML = S.list === 'epics' ? epicsHTML(ctx.D, ctx.snap, nowMs()) : '<div class="bd-list-placeholder">Features view is not available yet</div>';
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
    const epic = e.target.closest('.ep-row[data-epic]'); if (epic) { chooseEpic(epic.dataset.epic); return; }
    const row = e.target.closest('.lr[data-id]'); if (row) open(row);
  });
  ctx.life.on(vp, 'keydown', e => {
    if (S.view !== 'list' || e.key !== 'Enter' || e.target.matches('button')) return;
    const epic = e.target.closest('.ep-row[data-epic]'); if (epic) { e.preventDefault(); chooseEpic(epic.dataset.epic); return; }
    const row = e.target.closest('.lr[data-id]'); if (row) { e.preventDefault(); open(row); }
  });
}
function chooseEpic(key) {
  S.f.epic = [key]; S.list = 'tickets'; writeURL(); fx.renderTools(); fx.renderList();
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
