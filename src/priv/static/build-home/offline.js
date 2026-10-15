import { ctx, fx, onReset } from './state.js';
import { nowMs } from './clock.js';
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
export function daemonView() {
  const daemon = ctx.snap?.daemon;
  const headline = st.linkDown ? 'Daemon unreachable'
    : daemon?.state === 'offline' ? 'Daemon offline' : daemon?.state === 'stale' ? 'Daemon stale' : null;
  return {
    stale: Boolean(headline), dotOff: Boolean(headline) || daemon?.state !== 'live',
    dotText: headline || (daemon?.state === 'live' ? 'Daemon live' : 'Daemon status unknown'),
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
}
function paintBanner(host, info) {
  host.innerHTML = info ? `<div class="bd-offline" role="status">${I.warn}<div><b>${esc(info.headline)}</b>${esc(info.detail)}</div><button class="btn secondary sm" type="button" id="bd-retry"${st.retry ? ' disabled' : ''}>${st.retry ? 'Reconnecting…' : 'Reconnect'}</button></div>` : '';
  $('#bd-retry', host)?.addEventListener('click', reconnect);
}
Object.assign(fx, { renderOffline, daemonView });
