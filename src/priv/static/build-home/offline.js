import { ctx, fx, onReset } from './state.js';
import { nowMs, setNow } from './clock.js';
import { $, esc } from './dom.js';
import { I } from './icons.js';

const fresh = () => ({ downAt: null, downSeenAt: null, linkDown: false, retry: null, ticking: false, snap: null });
let st = fresh();
onReset(() => { st = fresh(); ctx.offline = { isLive, daemonView }; });

export function fmtAge(ms) {
  const minutes = Math.floor(Math.max(0, ms) / 60_000);
  if (minutes < 1) return 'less than 1 min ago';
  if (minutes < 60) return `${minutes} min ago`;
  if (minutes < 48 * 60) return `${Math.floor(minutes / 60)} h ago`;
  return `${Math.floor(minutes / 1440)} days ago`;
}
const fmtT = t => new Date(t).toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
const fmtWD = t => new Date(t).toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' }).replace(',', '');
export function fmtWhen(t, now) {
  return (new Date(t).toDateString() === new Date(now).toDateString() ? '' : fmtWD(t) + ' ') + fmtT(t);
}
export const isLive = () => ctx.socket === 'up' && !st.linkDown && ctx.snap?.daemon?.state === 'live';

function banner(headline, heartbeat) {
  const now = nowMs();
  const detail = Number.isFinite(heartbeat) && now !== null
    ? ` · last heartbeat ${fmtAge(now - heartbeat)} (${fmtWhen(heartbeat, now)}).`
    : ' · no heartbeat recorded.';
  return { headline, detail: detail + ' Showing cached state — agent states and usage may be stale.' };
}
const HOLD = /hold|held|budget|rate_limit/;
const since = at => Number.isFinite(at) && nowMs() !== null ? Math.max(0, nowMs() - at) : null;
const brief = ms => ms < 60_000 ? '<1m' : ms < 3_600_000 ? `${Math.floor(ms / 60_000)}m`
  : ms < 172_800_000 ? `${Math.floor(ms / 3_600_000)}h` : `${Math.floor(ms / 86_400_000)}d`;
// The visible label stays phone-short (`short`); the title carries the full sentence.
// A GitHub-backed source held by the shared budget is a field gap, not a daemon fault (#4770).
function heldNote(short) {
  const held = Object.entries(ctx.snap?.sources ?? {}).find(([, src]) => src?.state !== 'ok' && HOLD.test(String(src?.reason)));
  if (!held) return '';
  const ms = since(held[1].observed_at);
  if (short) return ` · ${held[0]} held${ms === null ? '' : ' ' + brief(ms)}`;
  return ` · ${held[0]} held by GitHub, ${ms === null ? 'no read recorded' : 'read ' + fmtAge(ms)}`;
}
// An open socket proves the daemon answers even while its fleet snapshot is unread.
function unreadText(daemon, short) {
  const ms = since(daemon?.heartbeat_at);
  if (short) return 'Daemon up · unread' + (ms === null ? '' : ', last good ' + brief(ms));
  return 'Daemon up · fleet snapshot unread, ' + (ms === null ? 'no good reading yet' : 'last good ' + fmtAge(ms));
}
// The mount's last daemon reading stands in until the first snapshot; a never-observed one stays unknown (#4915).
export function seedDaemon(raw) {
  let hint;
  try { hint = JSON.parse(raw || 'null'); } catch { return; }
  const daemon = hint?.daemon;
  if (!daemon || (daemon.state === 'unknown' && !Number.isFinite(daemon.heartbeat_at))) return;
  ctx.mountDaemon = daemon;
  if (nowMs() === null && Number.isFinite(hint.now)) setNow(hint.now);
}
function readAge(at, short) {
  const ms = since(at);
  return ms === null ? '' : short ? ` · ${brief(ms)} ago` : `, read ${fmtAge(ms)}`;
}
export function daemonView() {
  const hint = ctx.snap ? null : ctx.mountDaemon ?? null;
  const daemon = hint ?? ctx.snap?.daemon;
  // A mount hint is only a cached reading. Once it is old, don't let its former
  // live state keep the footer green while the page has no fresh snapshot.
  const hintAge = hint && Number.isFinite(hint.observed_at) && nowMs() !== null
    ? Math.max(0, nowMs() - hint.observed_at) : null;
  const hintStale = Boolean(hint && (hintAge === null || hintAge >= 30_000));
  const live = daemon?.state === 'live' && !hintStale;
  const headline = st.linkDown ? 'Daemon unreachable'
    : hintStale || daemon?.state === 'stale' ? 'Daemon stale'
      : daemon?.state === 'offline' ? 'Daemon offline' : null;
  const reachable = !headline && !live && Boolean(ctx.snap || hint) && ctx.socket === 'up';
  const text = short => (headline || (live ? 'Daemon live' + heldNote(short)
    : reachable ? unreadText(daemon, short) + heldNote(short) : 'Daemon status unknown'))
    + (hint ? readAge(hint.observed_at, short) : '');
  return {
    stale: Boolean(headline), dotOff: Boolean(headline) || !(live || reachable),
    dotText: text(true), dotTitle: text(false),
    banner: headline ? banner(headline, st.linkDown ? st.downAt : daemon.heartbeat_at) : null,
    socketDown: st.linkDown,
  };
}
function updateLink() {
  if (ctx.socket === 'up') {
    if (st.downSeenAt !== null) st.retry = null;
    st.downAt = st.downSeenAt = null; st.linkDown = false;
    return;
  }
  const delay = window.liveSocket?.disconnectedTimeout ?? 500;
  if (st.downSeenAt === null) {
    st.downSeenAt = performance.now(); st.downAt = nowMs();
    ctx.life.later('offline-link', delay, renderOffline);
  }
  st.linkDown = performance.now() - st.downSeenAt >= delay;
}
function reconnect() {
  if (st.retry) return;
  st.retry = st.linkDown ? 'socket' : 'resync';
  ctx.life.later('offline-retry', 10_000, () => { st.retry = null; renderOffline(); });
  renderOffline();
  if (!st.linkDown) { ctx.resync(); return; }
  const socket = window.liveSocket.getSocket();
  if (!socket.isConnected()) socket.teardown(() => socket.connect());
}
export function renderOffline() {
  const wasDown = st.linkDown;
  updateLink();
  // Store replaces the snapshot on each applied message; timers retain its identity.
  if (st.snap !== ctx.snap) { st.retry = null; st.snap = ctx.snap; }
  const view = daemonView(), host = $('#bd-offline', ctx.root);
  ctx.root?.classList.toggle('stale', view.stale);
  if (host) paintBanner(host, view.banner);
  if (!st.ticking && view.banner) {
    st.ticking = true; ctx.life.every(30_000, () => { if (daemonView().banner) renderOffline(); });
  }
  if (wasDown !== st.linkDown) fx.renderStatus?.();
  fx.refreshBandClock?.();
}
function paintBanner(host, info) {
  host.innerHTML = info ? `<div class="bd-offline" role="status">${I.warn}<div><b>${esc(info.headline)}</b>${esc(info.detail)}</div><button class="btn secondary sm" type="button" id="bd-retry"${st.retry ? ' disabled' : ''}>${st.retry ? 'Reconnecting…' : 'Reconnect'}</button></div>` : '';
  $('#bd-retry', host)?.addEventListener('click', reconnect);
}
Object.assign(fx, { renderOffline, daemonView });
