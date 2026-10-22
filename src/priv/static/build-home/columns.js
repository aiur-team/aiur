import { S, ctx, fx, LH, gutW } from './state.js';
import { esc } from './dom.js';
import { dayKey } from './util.js';
import { I } from './icons.js';
import { place } from './render.js';

let leaveSeq = 0;

export function visibleCols() {
  if (S.flow) return Array.from({ length: S.K }, (_, i) => "s" + i);
  if (S.feature && ctx.D.features[S.feature]) return featureCols();
  /* history: columns change per whole visible day, not per card; forward (now + planned + not queued) is one fixed set */
  const st = ctx.vp.scrollTop, chh = ctx.vp.clientHeight, vis = new Set();
  const hs = ctx.L.secs.hist, htop = ctx.secs.hist.el.offsetTop, a = st - htop + LH, b = st - htop + chh;
  if (!ctx.L._dayCols) { ctx.L._dayCols = {}; hs.items.forEach((it) => { if (!it.t.end) return; const d = dayKey(it.t.end); (ctx.L._dayCols[d] = ctx.L._dayCols[d] || new Set()).add(it.key); }); }
  hs.items.forEach((it) => { if (it.t.end && it.y + it.h > a && it.y < b) ctx.L._dayCols[dayKey(it.t.end)].forEach((k) => vis.add(k)); });
  if (st + chh > htop + hs.h + 40) {
    for (const sec of ['plan', 'nq']) ctx.L.secs[sec].items.forEach(it => vis.add(it.key));
  }
  return ctx.D.order.filter((k) => vis.has(k));
}
function featureCols() {
  const F = S.feature, items = ['hist', 'plan', 'nq'].flatMap(sec => ctx.L.secs[sec].items), set = new Set();
  const featureItems = items.filter(it => belongsToFeature(it.t, F));
  featureItems.forEach(it => set.add(it.key));
  if (S.fmode === 'compact') {
    const featureIds = new Set(featureItems.map(it => it.t.id));
    items.filter(it => it.t.deps.some(id => featureIds.has(id))).forEach(it => set.add(it.key));
  }
  return ctx.D.order.filter(k => set.has(k));
}
function belongsToFeature(t, feature) {
  return t.feature === feature || t.also.includes(feature) || S.fmode === 'compact' && t.deps.some(id => {
    const dep = ctx.D.byId[id]; return dep && (dep.feature === feature || dep.also.includes(feature));
  });
}
export function applyCols(next, immediate) {
  ctx.cols = next;
  const w = ctx.vp.clientWidth, g = gutW();
  const maxW = 520, gap = S.flow ? 10 : 16;
  const n = ctx.cols.length, avail = w - g - 14;
  let cw = Math.min(S.flow ? 1e9 : maxW, (avail - gap * (n - 1)) / n);
  ctx.lanesEl.style.setProperty("--g", gap + "px");
  ctx.colMap = {}; ctx.cols.forEach((k, i) => ctx.colMap[k] = { x: g + i * (cw + gap), w: cw });
  ctx.colMap.g = { x: g, w: avail };
  { const BK = (ctx.L && ctx.L.band.BK) || 1, bg = 16, bw = Math.min(380, (avail - bg * (BK - 1)) / BK); ctx.bandMap = {}; for (let i = 0; i < BK; i++) ctx.bandMap["b" + i] = { x: g + i * (bw + bg), w: bw }; }
  ctx.content.style.width = w + "px";
  if (S.flow) { ctx.laneEls.forEach((el) => el.remove()); ctx.laneEls.clear(); ctx.guideEls.forEach((el) => el.remove()); ctx.guideEls.clear(); ctx.lanesEl.querySelector(".bd-lane-g").textContent = "Colour = epic"; ctx.R.forEach((el) => place(el, el._it)); ctx.L.band.items.forEach((it) => place(it.el, it)); ctx.svg.classList.add("hide"); fx.drawEdgesSoon(immediate ? 30 : 380); return; }
  ctx.lanesEl.querySelector(".bd-lane-g").textContent = S.view === "gantt" ? "Time" : "Order";
  syncKeyed(ctx.laneEls, ctx.lanesEl, "bd-lane", (k, el) => {
    const e = ctx.D.epics[k], locked = S.feature && ctx.D.features[S.feature] && ctx.D.features[S.feature].epics.includes(k);
    el.className = "bd-lane" + (e.temp ? " temp" : "") + (e.unsorted ? " unsorted" : "") + (locked ? " lock" : "");
    el.style.setProperty("--h", e.hue);
    el.title = e.temp ? e.label + " — short-lived feature epic" : e.label;
    el.innerHTML = I[e.icon] + "<span>" + esc(e.label) + "</span><em>" + (locked ? I.lock : (Number.isInteger(ctx.D.counts?.[k]) ? ctx.D.counts[k] : "—")) + "</em>";
    if (!locked && !Number.isInteger(ctx.D.counts?.[k])) el.querySelector("em").title = "Ticket count unavailable";
  }, (el, k) => { const c = ctx.colMap[k]; el.style.left = c.x + "px"; el.style.width = c.w + "px"; el.classList.toggle("first", ctx.cols[0] === k); });
  syncKeyed(ctx.guideEls, ctx.guidesEl, "bd-guide", () => {}, (el, k) => { const c = ctx.colMap[k]; el.style.left = (c.x - gap / 2) + "px"; el.style.width = (c.w + gap) + "px"; });
  ctx.R.forEach((el) => place(el, el._it));
  ctx.L.band.items.forEach((it) => place(it.el, it));
  ctx.svg.classList.remove("hide");
  ctx.lanesEl.querySelector('.bd-lane-g').textContent = ctx.cols.length ? (S.view === 'gantt' ? 'Time' : 'Order') : 'No visible tickets';
  fx.drawEdgesSoon(immediate ? 0 : 420);
}
function syncKeyed(map, host, cls, fill, pos) {
  const want = new Set(ctx.cols);
  map.forEach((el, k) => { if (!want.has(k) && !el.classList.contains("leave")) { el.classList.add("leave"); ctx.life.later("col-leave:" + (++leaveSeq), 300, () => { if (el.classList.contains("leave")) { el.remove(); if (map.get(k) === el) map.delete(k); } }); } });
  ctx.cols.forEach((k) => {
    let el = map.get(k);
    if (el && el.classList.contains("leave")) { el.classList.remove("leave"); }
    if (!el) { el = document.createElement("div"); fill(k, el); el.classList.add(cls, "enter"); host.appendChild(el); map.set(k, el); pos(el, k); el.getBoundingClientRect(); el.classList.remove("enter"); }
    else { const lv = el.classList.contains("leave"); fill(k, el); el.classList.add(cls); if (lv) el.classList.add("leave"); pos(el, k); }
  });
}

export function scheduleCols(force) {
  const next = visibleCols();
  if (next.join('|') !== ctx.cols.join('|'))
    ctx.life.later('cols', force ? 0 : 220, () => { applyCols(visibleCols()); fx.update(); });
}
Object.assign(fx, { visibleCols, applyCols, scheduleCols });
