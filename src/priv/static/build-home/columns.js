import { S, ctx, fx, LH, gutW } from './state.js';
import { esc } from './dom.js';
import { colKey } from './match.js';
import { dayKey } from './util.js';
import { I } from './icons.js';
import { place } from './render.js';

const epicOk = t => !S.f.epic.length || S.f.epic.includes(colKey(t));
let leaveSeq = 0;

export function visibleCols() {
  if (S.flow) return Array.from({ length: S.K }, (_, i) => "s" + i);
  if (S.feature && ctx.D.features[S.feature]) {
    const F = S.feature, set = new Set(ctx.D.features[F].epics);
    ctx.D.all.forEach((t) => { if (t.feature === F || t.also.includes(F)) { set.add(colKey(t)); if (S.fmode === "compact") t.deps.forEach((d) => ctx.D.byId[d] && set.add(colKey(ctx.D.byId[d]))); } });
    return ctx.D.order.filter((k) => set.has(k));
  }
  /* history: columns change per whole visible day, not per card; forward (now + planned + not queued) is one fixed set */
  const st = ctx.vp.scrollTop, chh = ctx.vp.clientHeight, vis = new Set();
  const hs = ctx.L.secs.hist, htop = ctx.secs.hist.el.offsetTop, a = st - htop + LH, b = st - htop + chh;
  if (!ctx.L._dayCols) { ctx.L._dayCols = {}; hs.items.forEach((it) => { if (!it.t.end) return; const d = dayKey(it.t.end); (ctx.L._dayCols[d] = ctx.L._dayCols[d] || new Set()).add(it.key); }); }
  hs.items.forEach((it) => { if (it.t.end && it.y + it.h > a && it.y < b) ctx.L._dayCols[dayKey(it.t.end)].forEach((k) => vis.add(k)); });
  if (st + chh > htop + hs.h + 40) { if (!ctx.D._fwd) ctx.D._fwd = new Set([...ctx.D.plan, ...ctx.D.nq].filter(epicOk).map(colKey)); ctx.D._fwd.forEach((k) => vis.add(k)); }
  if (S.feature && ctx.D.features[S.feature]) ctx.D.features[S.feature].epics.forEach((k) => vis.add(k));
  if (S.f.epic.length) S.f.epic.forEach((k) => { if (vis.size === 0) vis.add(k); });
  return ctx.D.order.filter((k) => vis.has(k));
}
export function applyCols(next, immediate) {
  if (!next.length) next = ctx.cols.length ? ctx.cols : ctx.D.order.filter(k => ctx.D.epics[k]?.general);
  if (!next.length) next = ["unsorted"];
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
  if (next.length && next.join('|') !== ctx.cols.join('|'))
    ctx.life.later('cols', force ? 0 : 220, () => { applyCols(visibleCols()); fx.update(); });
}
Object.assign(fx, { visibleCols, applyCols, scheduleCols });
