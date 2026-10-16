// Port of design build.js:807–877, 1543–1547; unknowns are explicit at the trust boundary.
import { S, ctx, fx, onReset } from './state.js';
import { esc } from './dom.js';
import { nowMs } from './clock.js';
import { fmtD, fmtT, fmtH, dayKey } from './util.js';
import { I } from './icons.js';
import { LOGOS } from './logos.js';
import { agentState, progress, modelLabel } from './now-state.js';
import { colKey, match } from './match.js';
import { place } from './render.js';

const CX = ['❶', '❷', '❸', '❹', '❺'], CXH = [145, 110, 80, 50, 25];
export const finite = (x, lo = 0, hi = Number.MAX_SAFE_INTEGER) => Number.isFinite(x) && x >= lo && x <= hi ? x : null;
const unk = (field, title) => '<span data-unknown="' + field + '" title="' + esc(title) + '">—</span>';
const number = (x, field, title) => finite(x) === null ? unk(field, title) : String(x);
let ageTick = false;
const warned = new Set();
onReset(() => { ageTick = false; warned.clear(); });
export function age(promoted) {
  const now = nowMs(), time = finite(promoted);
  if (now === null || time === null) return unk('promoted', 'Promotion time unknown');
  const minutes = Math.floor(Math.max(0, now - time) / 60000);
  return minutes < 1 ? 'just now' : minutes < 60 ? minutes + 'm ago' : minutes < 1440 ? Math.floor(minutes / 60) + 'h ago' : Math.floor(minutes / 1440) + 'd ago';
}
function promo(time) { return I.up + ' promoted ' + age(time); }
function rendered() { return [...ctx.R.values(), ...(ctx.L?.band.items ?? []).map(it => it.el)].filter(Boolean); }
function tickAges() {
  for (const el of rendered()) {
    const row = ctx.D.byId[el.dataset.id], cue = el.querySelector('.bd-q.promo');
    if (row && cue) cue.innerHTML = promo(row.cue?.promoted);
  }
}
function epic(key) {
  if (Object.hasOwn(ctx.D.epics, key)) return ctx.D.epics[key];
  if (!warned.has(key)) { console.warn('Unknown epic:', key); warned.add(key); }
  return { key: 'unsorted', unsorted: true };
}
function modelOf(agent) {
  if (!agent) return null;
  const key = agent.model, logo = Object.hasOwn(LOGOS, key) ? LOGOS[key] : null;
  const name = modelLabel(agent) || (typeof key === 'string' && key ? key : 'Model unknown');
  return { logo, name, tip: name, mono: name === 'Model unknown' ? '?' : name[0].toUpperCase() };
}
function fullLogo(m, ag) {
  if (!m) return '';
  return '<span class="bd-ag' + (m.logo?.fill ? ' fill' : '') + '" title="' + esc(m.tip + (ag ? ' · ' + ag.label : '')) + '">' +
    (m.logo ? '<img src="' + esc(m.logo.src) + '" alt="' + esc(m.name) + '">' : '<span class="ax-mono">' + esc(m.mono) + '</span>') + '</span>';
}
function lineLogo(m) {
  if (!m) return '';
  return m.logo ? '<img class="bd-lg" src="' + esc(m.logo.src) + '" alt="">' : '<span class="bd-lg ax-mono" aria-hidden="true">' + esc(m.mono) + '</span>';
}
export function cardDetail(it) {
  const L = ctx.L;
  if (!it.gantt && !it.gt && !(S.view === 'gantt' && it.sec === 'hist')) return L.det;
  const fs = L.fs, tiers = ['bar', 'mini', 'line', 'full'];
  let i = it.h >= 8.8 * fs ? 3 : it.h >= 2.1 * fs ? 2 : it.h >= 20 ? 1 : 0;
  if ((it.lanes || 1) >= 3) i = Math.min(i, 1); else if ((it.lanes || 1) >= 2) i = Math.min(i, 2);
  return tiers[Math.min(i, tiers.indexOf(L.base))];
}
function complexity(t) {
  const cx = finite(t.cx, 1, 5), known = cx !== null && Number.isInteger(cx);
  const points = finite(t.pts) === null ? 'points unknown' : t.pts + ' pts';
  return '<span class="bd-cx' + (known ? '" style="--cxh:' + CXH[cx - 1] : ' unk') + '" title="' +
    (known ? 'Complexity ' + cx + '/5' : 'Complexity unknown') + ' · ' + points + '">' + (known ? CX[cx - 1] : '—') + '</span>';
}
function planContent(t, points) {
  const c = t.cue || {}, cues = [];
  if (c.promoted != null) {
    cues.push('<span class="bd-q promo">' + promo(c.promoted) + '</span>');
    if (!ageTick && ctx.life) { ctx.life.every(60000, tickAges); ageTick = true; }
  }
  if (c.held) cues.push('<span class="bd-q held" title="' + esc(c.held) + '">' + I.lock + ' held</span>');
  if (c.wait != null && !c.blockedChain) cues.push('<span class="bd-q">' + I.hourglass + ' waits on #' + number(c.wait, 'wait', 'Prerequisite unknown') + '</span>');
  if (c.blockedChain && !c.failed) cues.push('<span class="bd-q" style="color:var(--block-ink);border-color:var(--block-line)">' + I.warn + ' prereq chain failed</span>');
  if (t.override) cues.push('<span class="bd-q ovr" title="' + esc(t.override.reason) + '">' + I.pencil + ' estimate overridden</span>');
  const blocks = Array.isArray(c.failed?.blocks) ? c.failed.blocks : [];
  const body = c.failed ? '<div class="bd-alert">' + I.warn + '<span>Prereq #' + number(c.failed.by, 'failed.by', 'Prerequisite unknown') + ' failed' +
    (blocks.length ? ' · blocks ' + blocks.map(n => '#' + number(n, 'failed.blocks', 'Blocked ticket unknown')).join(' ') : '') + '</span></div>' :
    cues.length ? '<div class="bd-cues">' + cues.join('') + '</div>' : '';
  const est = finite(t.override?.hours) ?? finite(t.est);
  const label = t.id.startsWith('pack:') && t.num === null ? 'Planned · not filed' : 'Q' + number(t.qpos, 'qpos', 'Queue position unknown') +
    (c.held ? ' · held' : c.failed ? ' · prereq failed' : c.wait ? ' · waiting' : ' · queued');
  return { body, status: '<div class="bd-status"><span>' + label + '</span><span>≈' + (est === null ? unk('est', 'Estimate unknown') : est + 'h') + ' · ' + points + ' pts</span></div>' };
}
function historyContent(t, points) {
  const labels = { done: 'Merged', failed: 'Failed · closed', not_planned: 'Not planned', closed: 'Closed' };
  const label = Object.hasOwn(labels, t.status) ? labels[t.status] : 'State unknown';
  const end = finite(t.end, 0, 8640000000000000), start = finite(t.start, 0, 8640000000000000);
  const hrs = end !== null && start !== null ? (end - start) / 3600000 : null;
  let body = '', value = end === null ? unk('end', 'Close time unknown') : fmtD(end);
  if (S.view === 'gantt') {
    value = hrs === null ? unk('duration', 'Duration unknown') : fmtH(hrs);
    body = '<div class="bd-time">' + (start === null ? unk('start', 'Start time unknown') : fmtD(start) + ' ' + fmtT(start)) + '<br>→ ' +
      (end === null ? unk('end', 'Close time unknown') : (dayKey(start) === dayKey(end) ? '' : fmtD(end) + ' ') + fmtT(end)) +
      '</div><div class="bd-badges"><span class="h">' + value + '</span><span>' + points + ' pts</span></div>';
    return { body, status: '' };
  }
  return { body, status: '<div class="bd-status"><span>' + label + '</span><span>' + value + '</span></div>' };
}
export function makeCard(it) {
  const t = it.t, e = epic(colKey(t)), det = cardDetail(it), ag = t.sec === 'now' ? agentState(t.agent?.state) : null;
  const pg = t.sec === 'now' ? progress(finite(t.pct, 0, 100)) : null, m = modelOf(t.agent);
  const el = document.createElement('div');
  el._it = it; el.dataset.id = t.id; el.tabIndex = -1;
  el.className = 'bd-card ' + det + ' ' + t.sec + (t.status === 'failed' ? ' failed' : '') + (ag?.cls ? ' ag-' + ag.cls : '') +
    (it.ghost ? ' ghost' : '') + (e.unsorted ? ' unsorted' : '') + (it.gantt ? ' gplan' : '') +
    (t.sec === 'plan' && (t.cue?.failed || t.cue?.blockedChain) ? ' blk' : '') + (t.agent && det === 'full' ? ' has-ag' : '') + (t.status === 'not_planned' ? ' np' : '');
  const hue = finite(e.hue, 0, 360);
  if (hue !== null) el.style.setProperty('--h', hue);
  if (e.unsorted) el.style.setProperty('--ec', 'var(--muted)');
  if (pg?.known) { el.style.setProperty('--pct', t.pct + '%'); el.style.setProperty('--ph', Math.round(42 + t.pct * 1.03)); }
  if ((det === 'mini' && it.h > 34) || (det === 'line' && it.h > 3.2 * ctx.L.fs)) el.classList.add('tall');
  const glow = ag?.cls ? '<span class="bd-glow"></span>' : '';
  const unfiled = t.id.startsWith('pack:') && t.num === null;
  const id = unfiled ? '<span title="Not filed yet">—</span>' : '#' + number(t.num, 'num', 'Ticket number unknown');
  const tip = (unfiled ? '—' : '#' + (finite(t.num) ?? '—')) + ' · ' + t.title + (ag ? ' · ' + ag.label : '');
  const bar = pg?.known ? '<span class="bd-bar"><i style="width:' + finite(t.pct, 0, 100) + '%"></i></span>' : '';
  if (det === 'bar') el.innerHTML = glow + '<div class="bd-in" title="' + esc(tip) + '"></div>';
  else if (det === 'line' || det === 'mini') el.innerHTML = glow + '<div class="bd-in" title="' + esc(tip) + '"><span class="bd-dot"></span><span class="bd-id">' + id + '</span>' +
    (det === 'line' ? '<span class="bd-title">' + esc(t.title) + '</span>' + (t.sec === 'now' ? lineLogo(m) + bar : t.status === 'failed' ? '<span class="bd-lx">' + I.warn + '</span>' : '') : '') + '</div>';
  else {
    const top = '<div class="bd-top"><span class="bd-ic">' + I[t.type === 'bug' ? 'bug' : t.type === 'docs' ? 'docs' : t.type === 'chore' ? 'chore' : e.key === 'design' ? 'pen' : 'feature'] +
      '</span><span class="bd-id">' + id + '</span>' + complexity(t) + '</div>';
    const points = number(t.pts, 'pts', 'Points unknown');
    let body = '', status = '';
    if (t.sec === 'hist') ({ body, status } = historyContent(t, points));
    else if (t.sec === 'now') status = '<div class="bd-status"><span>' + ag.label + '</span><span>' + (pg.known ? pg.text : unk('pct', 'Progress unknown')) + '</span></div>' + bar;
    else if (t.sec === 'plan') ({ body, status } = planContent(t, points));
    else status = '<div class="bd-status"><span>Open · not queued</span><span>' + points + ' pts</span></div>';
    el.innerHTML = glow + '<div class="bd-in">' + top + '<div class="bd-title">' + esc(t.title) + '</div>' + body + status + '</div>' + fullLogo(m, ag);
  }
  decorate(el); return el;
}
export function decorate(el) {
  const t = ctx.D.byId[el.dataset.id], F = S.feature;
  if (!t) return;
  const inFeat = F && t.feature === F, also = F && !inFeat && t.also.includes(F), ghost = el.classList.contains('ghost');
  el.classList.toggle('dim', !match(t) || (!!F && S.fmode === 'focus' && !inFeat && !also && !ghost));
  el.classList.toggle('also', !!also); el.classList.toggle('feat-on', !!inFeat);
  const hue = F && Object.hasOwn(ctx.D.features, F) ? finite(ctx.D.features[F].hue, 0, 360) : null;
  if (hue !== null) el.style.setProperty('--fh', hue); else el.style.removeProperty('--fh');
}
export function decorateAll() { rendered().forEach(decorate); fx.drawEdgesSoon(10); }
export function refreshTicket(id) {
  if (!ctx.L) return;
  for (const it of ctx.L.band.items) if (it.t.id === id && ctx.D.byId[id]) {
    it.t = ctx.D.byId[id];
    const el = makeCard(it); el.classList.add('noanim'); place(el, it);
    it.el?.replaceWith(el); it.el = el;
  }
  fx.drawEdgesSoon(30);
}
Object.assign(fx, { makeCard, decorateAll, refreshTicket, tickCardAges: tickAges });
