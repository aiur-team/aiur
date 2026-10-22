import { S, ctx, fx, onReset, LH, rmOn } from './state.js';
import { H } from './history.js';

export const SNAP_T = 36;
let scrolling = false, lastSnapST = 0, animSeq = 0;
onReset(() => {
  scrolling = false; lastSnapST = 0; animSeq++;
  ctx.snapping = false; ctx.isScrolling = () => scrolling;
});
export function guardTarget({ dir, y, topY, botY }) {
  if (botY <= topY + SNAP_T * 2) return null;
  if (dir < 0 && y > topY + SNAP_T && y < botY) return 'bottom';
  if (dir > 0 && y < botY - SNAP_T && y > topY) return 'top';
  return null;
}
export function settleTarget({ y, topY, botY }) {
  if (y <= topY + 2 || y >= botY - 2 || botY <= topY) return null;
  return y - topY < botY - y ? 'top' : 'bottom';
}
const unavailable = () => ctx.snapping || !ctx.L || !ctx.content || S.view === 'list' || S.loading || H.state === 'loading';
function position() {
  const nat = ctx.secs.hist.el.offsetTop + ctx.L.secs.hist.h;
  return { nat, y: nat - ctx.vp.scrollTop, topY: LH, botY: ctx.vp.clientHeight - ctx.L.band.h };
}
function snap(target, nat, delay, guard = false) {
  if (!target) return;
  ctx.snapping = true;
  scrollVP(target === 'top' ? nat - LH : nat + ctx.L.band.h - ctx.vp.clientHeight, true);
  ctx.life.later('band-lock', delay, () => {
    ctx.snapping = false;
    if (guard) lastSnapST = ctx.vp.scrollTop;
    fx.flushLive();
  });
}
export function liveGuard() {
  if (unavailable()) { lastSnapST = ctx.vp ? ctx.vp.scrollTop : 0; return; }
  if (ctx.root.querySelector('.bd-sb.drag')) return;
  const st = ctx.vp.scrollTop, dir = st - lastSnapST; lastSnapST = st;
  const p = position();
  snap(guardTarget({ ...p, dir }), p.nat, 460, true);
}
export function snapLive() {
  // J:593's rmOn() === "x" never skips snapping; reduced motion jumps instantly.
  if (unavailable() || ctx.root.querySelector('.bd-sb.drag')) return;
  const p = position();
  snap(settleTarget(p), p.nat, 480);
}
export function markScrolling() {
  if (!scrolling) {
    scrolling = true; ctx.content?.classList.add('scrolling');
    if (ctx.hoverId && !ctx.lockId) fx.setHover(null);
  }
  ctx.life.later('band-settle', 200, () => {
    scrolling = false; ctx.content?.classList.remove('scrolling'); snapLive(); fx.flushLive();
  });
}
export function scrollVP(y, smooth) {
  const seq = ++animSeq, vp = ctx.vp;
  y = Math.max(0, Math.min(y, vp.scrollHeight - vp.clientHeight));
  if (!smooth || rmOn()) { vp.scrollTop = y; return; }
  const y0 = vp.scrollTop, t0 = performance.now(), dur = 420;
  const step = now => {
    if (seq !== animSeq) return;
    const k = Math.min(1, (now - t0) / dur), e = 1 - Math.pow(1 - k, 3);
    vp.scrollTop = y0 + (y - y0) * e;
    // A native scroll callback can arrive after this frame; keep sticky edges current.
    fx.drawEdges(false);
    if (k < 1) ctx.life.frame('scrollVP:' + seq, step);
  };
  ctx.life.frame('scrollVP:' + seq, step);
}
export function jumpNow(instant) {
  if (S.view === 'list') { scrollVP(0, !instant); return; }
  if (!ctx.secs.hist || !ctx.L) return;
  scrollVP(ctx.secs.hist.el.offsetTop + ctx.L.secs.hist.h - LH, !instant);
  if (instant) fx.update();
}
export function syncNowBtn() {
  const nb = ctx.root.querySelector('#bd-nowbtn');
  if (!nb || !ctx.bandEl) return;
  const r = ctx.bandEl.getBoundingClientRect(), v = ctx.vp.getBoundingClientRect();
  nb.classList.toggle('at', r.top > v.top + LH + 30 && r.bottom < v.bottom - 30);
}
Object.assign(fx, { liveGuard, snapLive, markScrolling, scrollVP, jumpNow, syncNowBtn });
