import { S, ctx, fx, onReset } from './state.js';
import { esc } from './dom.js';
import { timed } from './perf.js';
export const drawEdges = timed('drawEdges', drawEdgesImpl);

let edgeSig = '', edgeUntil = 0;
onReset(() => { edgeSig = ''; edgeUntil = 0; });

// "unknown" and anything unrecognised stay the base faint line; never green, never dashed.
export function edgeClass(t, did, ghost = false) {
  if (ghost) return 'gh';
  const st = t.dep_states && typeof t.dep_states === 'object' ? t.dep_states[did] : undefined;
  if (st === 'cleared') return 'ok';
  if (st === 'terminal_unsatisfied' || (t.cue && (t.cue.failed || t.cue.blockedChain))) return 'bad';
  return st === 'blocking' ? 'bl' : '';
}
export function edgeEmphasis(chain, id, did, dim) {
  if (chain) return chain.has(id) && chain.has(did) ? ' hl' : ' fade';
  return dim ? ' fade' : '';
}
// a, b, cr are rects (left/right/top/bottom/width/height); b is the dependent.
export function edgeGeometry(a, b, cr) {
  if (a.bottom <= b.top + 6) {
    const x1 = a.left + a.width / 2 - cr.left, y1 = a.bottom - cr.top;
    const x2 = b.left + b.width / 2 - cr.left, y2 = b.top - cr.top - 3;
    const dy = Math.max(18, (y2 - y1) / 2);
    return {
      path: `M${x1} ${y1} C${x1} ${y1 + dy} ${x2} ${y2 - dy} ${x2} ${y2}`,
      arrow: `M${x2 - 4} ${y2 - 6} L${x2} ${y2 + 1} L${x2 + 4} ${y2 - 6}z`,
    };
  }
  const right = a.right <= b.left;
  const x1 = (right ? a.right : a.left) - cr.left, y1 = a.top + a.height / 2 - cr.top;
  const x2 = (right ? b.left - 3 : b.right + 3) - cr.left, y2 = b.top + Math.min(18, b.height / 2) - cr.top;
  const dx = Math.max(20, Math.abs(x2 - x1) / 2) * (right ? 1 : -1);
  return {
    path: `M${x1} ${y1} C${x1 + dx} ${y1} ${x2 - dx} ${y2} ${x2} ${y2}`,
    arrow: right
      ? `M${x2 - 6} ${y2 - 4} L${x2 + 1} ${y2} L${x2 - 6} ${y2 + 4}z`
      : `M${x2 + 6} ${y2 - 4} L${x2 - 1} ${y2} L${x2 + 6} ${y2 + 4}z`,
  };
}

export function drawEdgesSoon(ms) {
  const was = edgeUntil > performance.now();
  edgeUntil = performance.now() + (ms || 0);
  if (was) return;
  const loop = () => {
    if (!ctx.content?.isConnected) return;
    const moving = ctx.content.getAnimations({ subtree: true }).some(a =>
      ['left', 'width'].includes(a.transitionProperty) && a.playState === 'running' && a.effect.target.matches('.bd-card'));
    const done = performance.now() >= edgeUntil && !moving;
    if (done && (ctx.hoverId || ctx.treeId) && fx.reapply) fx.reapply();
    else drawEdges(true);
    if (!done) ctx.life.frame('edges', loop);
  };
  ctx.life.frame('edges', loop);
}

function drawEdgesImpl(force) {
  const { content, svg, bandEl, D, L } = ctx;
  if (!content || !svg || !L || !D || !content.isConnected) return;
  const cr = content.getBoundingClientRect();
  const vis = new Map(), rects = new Map();
  ctx.R.forEach(el => { if (el.style.opacity !== '0') vis.set(el.dataset.id, el); });
  L.band.items.forEach(it => { if (it.el && it.el.style.opacity !== '0') vis.set(it.t.id, it.el); });
  const rectOf = (id) => { let r = rects.get(id); if (!r) rects.set(id, r = vis.get(id).getBoundingClientRect()); return r; };
  const hid = ctx.hoverId ?? null;
  const sig = [...vis.keys()].join(',') + '|' + ctx.cols.join(',') + '|' + hid + '|' +
    (bandEl ? Math.round(bandEl.getBoundingClientRect().top - cr.top) : '') + '|' + content.scrollWidth + '|' + ctx.proto?.generation;
  if (!force && sig === edgeSig) return;
  edgeSig = sig;
  svg.setAttribute('height', 0); svg.setAttribute('width', content.scrollWidth); svg.setAttribute('height', content.scrollHeight);
  const chain = hid ? fx.chainOf(hid) : null;
  let out = '', liveOut = '';
  vis.forEach((el, id) => {
    const t = D.byId[id];
    if (!t || !Array.isArray(t.deps)) return;
    for (const did of new Set(t.deps)) {
      const de = vis.get(did), d = D.byId[did];
      if (did === id || !de || !d) continue;
      const { path, arrow } = edgeGeometry(rectOf(did), rectOf(id), cr);
      const cls = edgeClass(t, did, el.classList.contains('ghost') || de.classList.contains('ghost'));
      const c = cls + edgeEmphasis(chain, id, did, el.classList.contains('dim') || de.classList.contains('dim'));
      const lines = `<path class="bd-e ${c}" d="${path}"/><path class="bd-ea ${c}" d="${arrow}"/>`;
      if (t.sec === 'now' || d.sec === 'now') liveOut += lines;
      out += `<path class="bd-eh" data-e="${esc(id)}" d="${path}"/>` + lines;
    }
  });
  svg.innerHTML = out;
  svg.classList.toggle('gantt', S.view === 'gantt' && !hid);
  svg.classList.toggle('hov', !!hid);
  if (!bandEl) return;
  let ls = bandEl.querySelector('.bd-now-e');
  if (!ls) {
    ls = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    ls.setAttribute('class', 'bd-now-e bd-edges');
    ls.setAttribute('aria-hidden', 'true');
    bandEl.insertBefore(ls, bandEl.firstChild);
  }
  const br = bandEl.getBoundingClientRect();
  ls.setAttribute('width', br.width); ls.setAttribute('height', br.height);
  ls.innerHTML = `<g transform="translate(${cr.left - br.left},${cr.top - br.top})">${liveOut}</g>`;
}

Object.assign(fx, { drawEdges, drawEdgesSoon });
