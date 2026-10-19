// Port of design build.js:1152–1181, with explicit unknowns and delegated input.
import { S, ctx, fx } from './state.js';
import { esc } from './dom.js';
import { nowMs } from './clock.js';
import { fmtD, fmtH } from './util.js';
import { I } from './icons.js';
import { LOGOS } from './logos.js';
import { agentState, progress, modelLabel } from './now-state.js';
import { colKey, match } from './match.js';
import { H, loadEarlier } from './history.js';
import { sectionState, headNote, reasonText, ageText } from './states.js';

const HIST = { failed: ['failed', 'Failed'], done: ['merged', 'Merged'], not_planned: ['np', 'Not planned'], closed: ['closed', 'Closed'] };
export function stClass(t) {
  if (t.sec === 'hist') return Object.hasOwn(HIST, t.status) ? HIST[t.status][0] : 'unknown';
  if (t.sec === 'now') return agentState(t.agent?.state).cls ?? 'unknown';
  if (t.sec === 'plan') return t.cue?.held ? 'held' : t.cue?.failed || t.cue?.blockedChain ? 'blocked' : 'queued';
  return 'open';
}
export function stText(t) {
  if (t.sec === 'hist') return Object.hasOwn(HIST, t.status) ? HIST[t.status][1] : 'State unknown';
  if (t.sec === 'now') return agentState(t.agent?.state).label;
  if (t.sec === 'plan') return t.cue?.held ? 'Held' : t.cue?.failed || t.cue?.blockedChain ? 'Blocked' : t.cue?.wait ? 'Waiting on #' + t.cue.wait : 'Queued';
  return 'Not queued';
}
const muted = text => '<span class="lr-mu">' + esc(text) + '</span>';
const number = x => Number.isFinite(x) ? x : '—';
const hue = (key, value) => Number.isFinite(value) ? ' style="' + key + ':' + value + '"' : '';
function progCell(t) {
  if (t.sec === 'now') {
    const p = progress(t.pct);
    return p.known ? '<span class="lr-pg" style="' + esc(p.style) + '"><span class="bd-bar"><i style="width:' + t.pct + '%"></i></span><b>' + esc(p.text) + '</b></span>' : muted('—');
  }
  if (t.sec === 'hist') return muted((Number.isFinite(t.end) ? fmtD(t.end) : '—') + ' · ' +
    (Number.isFinite(t.start) && Number.isFinite(t.end) && t.end >= t.start ? fmtH((t.end - t.start) / 36e5) : '—'));
  if (t.sec === 'plan') {
    const hours = Number.isFinite(t.override?.hours) ? t.override.hours : t.est;
    return muted('Q' + number(t.qpos) + ' · W' + (Number.isFinite(t.wave) ? t.wave : '?') + ' · ' + (Number.isFinite(hours) ? '≈' + hours + 'h' : '—'));
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
  const dim = state.feature && state.fmode === 'focus' && t.feature !== state.feature && !t.also.includes(state.feature);
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
  const keep = t => match(t, state), rows = Object.fromEntries(['now', 'plan', 'nq'].map(sec => [sec, D[sec].filter(keep)]));
  rows.hist = D.hist.filter(t => t.end >= (state.histFrom || 0) && keep(t)).sort((a, b) => b.end - a.end);
  const labels = { now: '<i class="lh-live" aria-hidden="true"></i>Live', plan: 'Planned', nq: 'Not queued', hist: 'History' };
  const nowCounts = { running: 0, retrying: 0, stuck: 0, paused: 0, unknown: 0 };
  for (const ticket of rows.now) {
    const key = ticket.agent?.state === 'active' ? 'running'
      : ticket.agent?.state === 'retrying' ? 'retrying'
        : ['error', 'retries', 'command'].includes(ticket.agent?.state) ? 'stuck'
          : ['paused', 'parked'].includes(ticket.agent?.state) ? 'paused' : 'unknown';
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
export function renderList() {
  const vp = ctx.vp, rows = () => [...vp.querySelectorAll('.lr[data-id]')], previous = rows();
  const focused = document.activeElement?.closest?.('.lr[data-id]'), index = previous.indexOf(focused);
  const moreFocused = document.activeElement?.id === 'lr-more' && vp.contains(document.activeElement);
  const top = vp.getBoundingClientRect().top;
  const anchor = previous.find(el => el.getBoundingClientRect().top >= top);
  const offset = anchor ? anchor.getBoundingClientRect().top - top : null, scroll = vp.scrollTop;
  ctx.L = null; ctx.content = null; ctx.R.clear(); ctx.cols = [];
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
  const open = id => { const t = ctx.D.byId[id]; if (t) fx.openModal(t); };
  ctx.life.on(vp, 'click', e => {
    if (S.view !== 'list') return;
    const btn = e.target.closest('#lr-more');
    if (btn) { earlier(btn); return; }
    const row = e.target.closest('.lr[data-id]'); if (row) open(row.dataset.id);
  });
  ctx.life.on(vp, 'keydown', e => {
    if (S.view !== 'list' || e.key !== 'Enter' || e.target.matches('button')) return;
    const row = e.target.closest('.lr[data-id]'); if (row) { e.preventDefault(); open(row.dataset.id); }
  });
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
