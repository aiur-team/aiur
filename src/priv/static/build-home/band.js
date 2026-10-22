import { S, ctx, fx } from './state.js';
import { nowMs, stampMs } from './clock.js';
import { $, esc } from './dom.js';
import { I } from './icons.js';
import { fmtT } from './util.js';
import { writeURL } from './url.js';
import './band-scroll.js';
export { SNAP_T, guardTarget, settleTarget } from './band-scroll.js';

const groups = [['ok', 'nr', 'active', 'running'], ['queued', 'nt', 'retrying', 'retrying'], ['bad', 'ns', 'error,retries,command', 'stuck'], ['idle', 'ni', 'paused,parked', 'paused']];
const AGENTS_STALE_MAX_AGE_MS = 120_000;
export function bandCounts(rows) {
  const result = { nr: 0, nt: 0, ns: 0, ni: 0, nu: 0 };
  for (const t of rows) {
    const state = t.agent?.state, group = groups.find(g => g[2].split(',').includes(state));
    result[group ? group[1] : 'nu']++;
  }
  return result;
}
export function bandClock({ now, stamp, daemon, agents, socketDown }) {
  if (!Number.isFinite(now)) return { text: '—', title: 'Time unknown' };
  const cached = (at, title) => ({ text: 'cached ' + (Number.isFinite(at) ? fmtT(at) : '—'), title });
  if (socketDown) return cached(stamp, Number.isFinite(stamp) ? 'Last received state' : 'Last received time unknown');
  if (['offline', 'stale'].includes(daemon?.state)) return cached(daemon.heartbeat_at, Number.isFinite(daemon.heartbeat_at) ? 'Last daemon heartbeat' : 'Last heartbeat unknown');
  if (daemon?.state !== 'live') return { text: '—', title: 'Daemon state unknown' };
  if (agents?.state === 'stale') return cached(agents.observed_at, 'Last agent observation');
  return { text: fmtT(now), title: 'Live time' };
}
export function bandEta(D) {
  // C7-T03 replaces the placeholder with capacity-aware etaLabel; never use the demo's /4.
  const known = ['ok', 'stale'].includes(D.sources?.queue?.state);
  return { text: (known ? D.plan.length + D.now.length : '—') + ' to go · ETA —', title: 'ETA not available yet' };
}
export function bandEmptyText(D, now = nowMs()) {
  const source = D.sources?.agents;
  const age = Number.isFinite(now) && Number.isFinite(source?.observed_at) ? now - source.observed_at : null;
  if (!bandAgentsUsable(D, now)) return 'Agent states unavailable';
  return D.now.length ? null : ['stale', 'unavailable'].includes(source?.state) ? 'Agent states stale · last seen ' + fmtT(source.observed_at) : 'No agents are working right now.';
}
export function bandAgentsUsable(D, now = nowMs()) {
  const source = D.sources?.agents;
  if (source?.state === 'ok') return true;
  const age = Number.isFinite(now) && Number.isFinite(source?.observed_at) ? now - source.observed_at : null;
  const retained = source?.state === 'stale' || (source?.state === 'unavailable' && D.now.length > 0);
  return retained && age !== null && age >= 0 && age <= AGENTS_STALE_MAX_AGE_MS;
}
export function bandAgentsFreshness(D, now = nowMs()) {
  const source = D.sources?.agents;
  const age = Number.isFinite(now) && Number.isFinite(source?.observed_at) ? now - source.observed_at : null;
  if (!bandAgentsUsable(D, now) || source?.state === 'ok' || age === null) return null;
  const minutes = Math.floor(age / 60_000);
  const ageLabel = minutes === 0 ? 'under 1m ago' : `${minutes}m ago`;
  return { text: `Stale · ${ageLabel}`, title: `Last agent observation ${fmtT(source.observed_at)}; ${ageLabel}` };
}
function paintClock() {
  if (!ctx.life || ctx.life.disposed) return;
  const el = ctx.bandEl?.querySelector('time');
  if (!el) return;
  const clock = bandClock({ now: nowMs(), stamp: stampMs(), daemon: ctx.snap?.daemon,
    agents: ctx.D?.sources?.agents, socketDown: fx.daemonView().socketDown || ctx.socket === 'down' });
  el.textContent = clock.text; el.title = clock.title;
  const now = nowMs();
  ctx.life.later('band-clock', Number.isFinite(now) ? 60000 - now % 60000 : 60000, paintClock);
}
export function syncAst() {
  const value = S.f.astate.join(',');
  ctx.root.querySelectorAll('.bd-now-h [data-ast]').forEach(el => {
    const on = !!value && value === el.dataset.ast;
    el.classList.toggle('on', on); el.setAttribute('aria-pressed', String(on));
  });
}
function header(counts, available) {
  const { nr, nt, ns, ni, nu } = counts, eta = bandEta(ctx.D);
  const buttons = available ? groups.filter(g => counts[g[1]]) : [];
  const freshness = bandAgentsFreshness(ctx.D, nowMs());
  return '<b><i></i>Live</b><time></time><span class="bd-now-st">' +
    buttons.map(([cls, key, ast, word]) => `<button type="button" class="${cls}" data-ast="${ast}"><i></i>${counts[key]} ${word}</button>`).join('') + '</span>' +
    (freshness ? `<span class="bd-now-freshness" role="status" title="${esc(freshness.title)}">${esc(freshness.text)}</span>` : '') +
    (available && S.liveMin && ctx.D.now.length ? '<span class="bd-now-sum" role="group" aria-label="' + nr + ' running' + (nt ? ', ' + nt + ' retrying' : '') + ', ' + ns + ' stuck, ' + ni + ' paused' + (nu ? ', ' + nu + ' state unknown' : '') + '">' +
      buttons.map(([cls, key, ast, word]) => `<button type="button" class="${cls}" data-ast="${ast}" style="flex:${counts[key]}" title="${counts[key]} ${word}" aria-label="${counts[key]} ${word}"></button>`).join('') + '</span>' : '') +
    '<button type="button" class="bd-now-min" data-min title="' + (S.liveMin ? 'Expand live' : 'Minimize live') + '" aria-expanded="' + !S.liveMin + '" aria-controls="bd-now">' + (S.liveMin ? I.chev : I.chevU) + '</button>' +
    '<span class="bd-now-eta" title="' + eta.title + '">' + eta.text + '</span>';
}
export function renderBand() {
  if (!ctx.bandEl || !ctx.D || !ctx.L) return;
  const now = nowMs(), available = bandAgentsUsable(ctx.D, now);
  const focused = document.activeElement, owned = ctx.bandEl.querySelector('.bd-now-h')?.contains(focused);
  const selector = owned ? focused.matches('[data-min]') ? '[data-min]' : focused.dataset.ast ?
    (S.liveMin ? '.bd-now-sum' : '.bd-now-st') + ' [data-ast="' + focused.dataset.ast + '"]' : null : null;
  $('.bd-now-h', ctx.bandEl).innerHTML = header(bandCounts(ctx.D.now), available);
  fx.syncAst(); paintClock();
  if (selector) (ctx.bandEl.querySelector(selector) || ctx.bandEl.querySelector('[data-min]')).focus({ preventScroll: true });
  const bl = $('.bd-layer', ctx.bandEl), empty = bandEmptyText(ctx.D, now);
  bl.innerHTML = empty ? '<div class="bd-now-empty">' + esc(empty) + '</div>' : '';
  ctx.bandEl.classList.toggle('min', S.liveMin);
  (available ? ctx.L.band.items : []).forEach(it => {
    const el = fx.makeCard(it); el.classList.add('noanim'); bl.appendChild(el); it.el = el;
  });
}
export function onBandClick(e) {
  if (e.target.closest('[data-min]')) {
    S.liveMin = !S.liveMin; writeURL(); fx.relayout(); return true;
  }
  const st = e.target.closest('[data-ast]');
  if (!st) return false;
  const v = st.dataset.ast.split(','), same = S.f.astate.join(',') === v.join(',');
  S.f.astate = same ? [] : v;
  if (S.liveMin && !same) { S.liveMin = false; writeURL(); fx.relayout(); }
  fx.filtersChanged(); return true;
}
Object.assign(fx, { renderBand, onBandClick, refreshBandClock: paintClock });
// shortcut: C10-T02 replaces these interim URL/button effects with filter dimming.
fx.syncAst ??= syncAst;
fx.filtersChanged ??= () => { writeURL(); fx.syncAst(); };
