import { S, SPANS } from './state.js';
import { setSpan } from './span.js';

// Touch gestures on the board (#7686). One finger is left alone so the page scrolls natively
// (the board is not a touch scroller; see home/20-touch.css). Two fingers pan the board and
// a pinch steps the same day-span zoom the +/- control sets.
const dist = t => Math.hypot(t[0].clientX - t[1].clientX, t[0].clientY - t[1].clientY);
const nearestSpan = want => SPANS.reduce((a, b) => Math.abs(Math.log(b / want)) < Math.abs(Math.log(a / want)) ? b : a);

export function wireTouch(vp, life) {
  let g = null;
  const rebase = t => {
    g = { d: dist(t), x: (t[0].clientX + t[1].clientX) / 2, y: (t[0].clientY + t[1].clientY) / 2, top: vp.scrollTop, left: vp.scrollLeft, span: S.span };
  };
  life.on(vp, 'touchstart', e => {
    if (e.touches.length !== 2) { g = null; return; }
    if (e.cancelable) e.preventDefault();
    rebase(e.touches);
  }, { passive: false });
  life.on(vp, 'touchmove', e => {
    if (!g || e.touches.length !== 2) return;
    if (e.cancelable) e.preventDefault();
    const t = e.touches;
    vp.scrollTop = g.top - ((t[0].clientY + t[1].clientY) / 2 - g.y);
    vp.scrollLeft = g.left - ((t[0].clientX + t[1].clientX) / 2 - g.x);
    // Pinch out = more percent = fewer days in view.
    const next = nearestSpan(g.span * g.d / Math.max(1, dist(t)));
    if (next === S.span) return;
    setSpan(next);
    rebase(t);
  }, { passive: false });
  for (const type of ['touchend', 'touchcancel']) life.on(vp, type, e => { if (e.touches.length !== 2) g = null; });
}
