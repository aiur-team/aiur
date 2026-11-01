import { S, ctx, fx, onReset, LH, rmOn } from './state.js';

// #7446: the live band scrolls with the content; nothing snaps it to an edge.

let scrolling = false, animSeq = 0, jumping = false;
onReset(() => {
  scrolling = false; animSeq++; jumping = false;
  ctx.snapping = false; ctx.isScrolling = () => scrolling;
});
export function markScrolling() {
  if (!scrolling) {
    scrolling = true; ctx.content?.classList.add('scrolling');
    if (ctx.hoverId && !ctx.lockId) fx.setHover(null);
  }
  ctx.life.later('band-settle', 200, () => {
    scrolling = false; ctx.content?.classList.remove('scrolling'); fx.flushLive();
  });
}
export function scrollVP(y, smooth) {
  const seq = ++animSeq, vp = ctx.vp;
  y = Math.max(0, Math.min(y, vp.scrollHeight - vp.clientHeight));
  if (!smooth || rmOn()) { if (jumping) jumping = ctx.snapping = false; vp.scrollTop = y; return; }
  const y0 = vp.scrollTop, t0 = performance.now(), dur = 420;
  // A smooth jump defers live passes until it lands, so a relayout cannot move its target.
  jumping = ctx.snapping = true;
  const step = now => {
    if (seq !== animSeq) return;
    const k = Math.min(1, (now - t0) / dur), e = 1 - Math.pow(1 - k, 3);
    vp.scrollTop = y0 + (y - y0) * e;
    // A native scroll callback can arrive after this frame; keep sticky edges current.
    fx.drawEdges(false);
    if (k < 1) ctx.life.frame('scrollVP:' + seq, step);
    else { jumping = ctx.snapping = false; fx.flushLive(); }
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
  if (!ctx.bandEl) return;
  const nb = ctx.root.querySelector('#bd-nowbtn');
  const r = ctx.bandEl.getBoundingClientRect(), v = ctx.vp.getBoundingClientRect();
  // #5614: the order header drops its shadow only while Live is docked under it.
  ctx.vp.classList.toggle('live-top', Math.abs(r.top - (v.top + LH)) < 6);
  nb?.classList.toggle('at', r.top > v.top + LH + 30 && r.bottom < v.bottom - 30);
}
Object.assign(fx, { markScrolling, scrollVP, jumpNow, syncNowBtn });
