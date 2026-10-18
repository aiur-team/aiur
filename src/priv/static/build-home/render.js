import { S, ctx, fx, gutW, LH, onReset, renderChrome } from './state.js';
import { syncStates } from './states.js';
import { $ } from './dom.js';
import { I } from './icons.js';
import { dotSize } from './span.js';
import { writeURL } from './url.js';
import { computeLayout, measureFlow, crowded, laneMax, fwdLanes, histDays, makeMark, placeMark, makeLabel } from './layout.js';
import { H, syncHistory, loadEarlier, ensureDays, ensureFrom } from './history.js';
import { takeAnchor, restoreAnchor } from './render-anchor.js';
import { renderHeads } from './render-heads.js';
export { takeAnchor, restoreAnchor } from './render-anchor.js';
export { headHTML } from './render-heads.js';

let pendingLive;
onReset(() => { pendingLive = { changed: new Set(), removed: new Set(), dirty: false }; });

export function viewport() {
    ctx.vp.innerHTML =
      '<div class="bd-content" id="bd-content">' +
        '<div class="bd-lanes" id="bd-lanes"><span class="bd-lane-g">' + (S.view === "gantt" ? "Time" : "Order") + "</span></div>" +
        '<div class="bd-guides" id="bd-guides"></div>' +
        '<svg class="bd-edges" id="bd-edges" aria-hidden="true"></svg>' +
        '<section class="bd-sec" id="bd-sec-hist"><div class="bd-sech"></div><div class="bd-layer"></div></section>' +
        '<div class="bd-now" id="bd-now"><div class="bd-now-h"></div><div class="bd-layer"></div></div>' +
        '<section class="bd-sec" id="bd-sec-plan"><div class="bd-sech"></div><div class="bd-layer"></div></section>' +
        '<section class="bd-sec" id="bd-sec-nq"><div class="bd-sech"></div><div class="bd-layer"></div></section>' +
      "</div>";
    ctx.content = $("#bd-content", ctx.root); ctx.lanesEl = $("#bd-lanes", ctx.root); ctx.guidesEl = $("#bd-guides", ctx.root); ctx.svg = $("#bd-edges", ctx.root); ctx.bandEl = $("#bd-now", ctx.root);
    ["hist", "plan", "nq"].forEach((s) => { const el = $("#bd-sec-" + s, ctx.root); ctx.secs[s] = { el, layer: $(".bd-layer", el), head: $(".bd-sech", el) }; });
    ctx.R.clear(); ctx.RL.clear(); ctx.laneEls.clear(); ctx.guideEls.clear(); ctx.cols = []; ctx.colMap = {};
    ctx.life.on(ctx.content, "mouseover", e => fx.onHover(e));
    ctx.life.on(ctx.content, "mouseleave", () => { if (!ctx.lockId) ctx.life.later("hover", 200, () => { if (!ctx.lockId) fx.setHover(null); }); });
    ctx.lockId = null;
    ctx.lt = document.createElement("div"); ctx.lt.className = "bd-lt";
    ctx.lt.innerHTML = '<button type="button" data-lt="lock" title="Lock this dependency tree">' + I.lock + '</button><button type="button" data-lt="fit" title="Zoom out to fit this tree">' + I.fit + '</button><button type="button" data-lt="tree" title="View the whole tree">' + I.eye + "</button>";
    ctx.content.appendChild(ctx.lt);
    ctx.life.on(ctx.content, "click", (e) => {
      const eh = e.target.closest(".bd-eh");
      if (eh) { e.stopPropagation(); fx.lockTree(eh.dataset.e); return; }
      const b = e.target.closest("[data-lt]");
      if (b) { e.stopPropagation(); if (b.dataset.lt === "lock") { if (ctx.lockId) fx.unlock(); else if (ctx.hoverId) { ctx.lockId = ctx.hoverId; ctx.lt.classList.add("locked"); } } else if (ctx.lockId) { if (b.dataset.lt === "fit") fx.fitTree(ctx.lockId); else fx.openTree(ctx.lockId); } return; }
      if (e.target.closest("[data-min]")) { S.liveMin = !S.liveMin; writeURL(); relayout(); return; }
      const sd = e.target.closest("[data-sid]"); if (sd) { fx.openModal(ctx.D.byId[sd.dataset.sid]); return; }
      const st = e.target.closest("[data-ast]"); if (st) { const v = st.dataset.ast.split(","), same = S.f.astate.join(",") === v.join(","); S.f.astate = same ? [] : v; if (S.liveMin && !same) { S.liveMin = false; writeURL(); relayout(); } fx.filtersChanged(); return; }
      const c = e.target.closest(".bd-card");
      if (ctx.lockId) { if (c && fx.chainOf(ctx.lockId).has(c.dataset.id)) fx.openModal(ctx.D.byId[c.dataset.id], { origin: c }); return; }
      if (c) fx.openModal(ctx.D.byId[c.dataset.id], { origin: c });
    });
  }

function noanim(el) {
  el.classList.add('noanim');
  ctx.life.frame(el, () => ctx.life.frame(el, () => el.classList.remove('noanim')));
}
function focusId() { return document.activeElement?.closest('.bd-card')?.dataset.id ?? null; }
function restoreFocus(id) {
  if (!id) return;
  const card = [...ctx.R.values()].find(el => el.dataset.id === id);
  (card || ctx.vp).focus({ preventScroll: true });
}
export function relayout({ live = false } = {}) {
  if (S.loading) return fx.renderLoading();
  syncStates();
  const reconnect = H.epoch !== null && H.epoch !== ctx.proto.epoch;
  const anchor = reconnect ? takeAnchor() : null, oldFrom = S.histFrom, focused = focusId();
  syncHistory();
  if (S.view === 'list') return fx.renderList();
  if (!ctx.content) viewport();
  const dims = { vpW: ctx.vp.clientWidth, vpH: ctx.vp.clientHeight, gut: gutW() };
  Object.assign(S, measureFlow(ctx.D, dims));
  if (ctx.lockId && (!live || !ctx.D.byId[ctx.lockId])) fx.unlock();
  if (!live || ctx.treeId && !ctx.D.byId[ctx.treeId]) fx.closeTree();
  const previousDetail = ctx.L?.det;
  ctx.L = computeLayout(ctx.D, S, dims, ctx.snap.sources, { history: H });
  // The design counts only live and planned lanes; also flow when the packed day columns would still be slivers (#4769).
  if (!S.flow && !S.feature && crowded(dims, laneMax(ctx.L, fwdLanes(ctx.D, S), dims.vpH - LH))) { S.flow = true; ctx.L = computeLayout(ctx.D, S, dims, ctx.snap.sources, { history: H }); }
  ctx.content.classList.toggle('flow', S.flow);
  const detailChanged = previousDetail !== ctx.L.det;
  ctx.svg.setAttribute('height', 0);
  ctx.vp.style.setProperty('--dot', dotSize(S.span));
  for (const [uid, el] of ctx.R) {
    const id = el.dataset.id;
    if (!live || detailChanged || pendingLive.changed.has(id) || pendingLive.removed.has(id)) { el.remove(); ctx.R.delete(uid); }
    else noanim(el);
  }
  for (const [uid, el] of ctx.RL) {
    if (!live || !uid.includes(':m')) { el.remove(); ctx.RL.delete(uid); }
  }
  renderHeads();
  for (const sec of ['hist', 'plan', 'nq']) ctx.secs[sec].el.style.height = ctx.L.secs[sec].h + 'px';
  ctx.bandEl.style.height = ctx.L.band.h + 'px'; fx.renderBand();
  ctx.content.style.setProperty('--fs', ctx.L.fs + 'px');
  fx.applyCols(fx.visibleCols(), true);
  ctx.a11y.focusId = focused;
  update(true); restoreFocus(focused);
  if (reconnect) {
    restoreAnchor(anchor); update();
    if (oldFrom < S.histFrom) {
      const life = ctx.life, epoch = ctx.proto.epoch;
      ensureFrom(oldFrom, () => ctx.life === life && !life.disposed && ctx.proto.epoch === epoch).then(() => {
        if (ctx.life !== life || life.disposed || ctx.proto.epoch !== epoch) return;
        restoreAnchor(anchor); ctx.a11y.focusId = focused; update(); restoreFocus(focused);
      });
    }
  }
  if (S.span > 1 && histDays(ctx.D.hist).length < S.span && H.more) ensureDays(S.span);
}
export const colFor = it => it.sec === 'now' ? ctx.bandMap[it.key] : ctx.colMap[it.key];
export function place(el, it) {
  const c = colFor(it);
  el.style.top = it.y + 'px'; el.style.height = it.h + 'px';
  if (!c) { el.style.opacity = '0'; el.style.pointerEvents = 'none'; if (!el.style.left) el.style.left = '0px'; return; }
  const lanes = it.lanes || 1, lw = c.w / lanes;
  el.style.left = (c.x + (it.lane || 0) * lw) + 'px';
  let ww = lw - (lanes > 1 ? 4 : 0);
  if ((el.classList.contains('mini') || el.classList.contains('bar')) && !S.flow) ww = Math.min(ww, 70);
  el.style.width = ww + 'px'; el.style.opacity = ''; el.style.pointerEvents = '';
}
function renderSection(s, keep, keepL, focused) {
  const sec = ctx.secs[s], lay = ctx.L.secs[s], st = ctx.vp.scrollTop;
  const A = st - sec.el.offsetTop - 700, B = st - sec.el.offsetTop + ctx.vp.clientHeight + 700;
  const overlaps = (y, h = 0) => y + h >= A && y <= B;
  for (const it of lay.items) {
    if (!overlaps(it.y, it.h) && it.t.id !== focused) continue;
    const uid = s + ':' + it.t.id; keep.add(uid);
    let el = ctx.R.get(uid);
    if (!el) { el = fx.makeCard(it); noanim(el); sec.layer.appendChild(el); ctx.R.set(uid, el); }
    el._it = it; place(el, it);
  }
  lay.marks.forEach((m, i) => {
    if (!overlaps(m.y, m.h)) return;
    const uid = s + ':m' + i; keepL.add(uid);
    let el = ctx.RL.get(uid);
    if (!el) { el = makeMark(m); sec.layer.appendChild(el); ctx.RL.set(uid, el); }
    el.className = 'bd-mk ' + m.kind;
    const text = makeMark(m).innerHTML;
    if (el.dataset.txt !== text) { el.innerHTML = text; el.dataset.txt = text; }
    placeMark(el, m, ctx.content.offsetWidth, gutW());
  });
  lay.labels.forEach((lb, i) => {
    if (!overlaps(lb.y)) return;
    const uid = s + ':l' + i; keepL.add(uid);
    if (ctx.RL.has(uid)) return;
    const [el, ln] = makeLabel(lb); sec.layer.appendChild(el); ctx.RL.set(uid, el);
    if (ln) { sec.layer.appendChild(ln); ctx.RL.set(uid + 'd', ln); }
  });
}
export function update(force) {
  if (!ctx.L || !ctx.content || S.loading || S.view === 'list') return;
  fx.scheduleCols(force);
  const keep = new Set(), keepL = new Set();
  const focused = focusId() ?? ctx.a11y.focusId;
  ctx.a11y.focusId = focused;
  for (const s of ['hist', 'plan', 'nq']) renderSection(s, keep, keepL, focused);
  ctx.R.forEach((el, uid) => { if (!keep.has(uid)) { el.remove(); ctx.R.delete(uid); } });
  ctx.RL.forEach((el, uid) => {
    if (!keepL.has(uid.endsWith('d') ? uid.slice(0, -1) : uid)) { el.remove(); ctx.RL.delete(uid); }
  });
  const nb = $('#bd-nowbtn', ctx.root);
  if (nb) { const r = ctx.bandEl.getBoundingClientRect(), v = ctx.vp.getBoundingClientRect(); nb.classList.toggle('at', r.top > v.top + LH + 30 && r.bottom < v.bottom - 30); }
  fx.drawEdges(false);
  if (ctx.vp.scrollTop >= 260) H.retryArmed = true;
  if (S.ready && H.state !== 'loading' && ctx.vp.scrollTop < 260 && H.more && H.retryArmed) loadEarlier();
  if (!focusId()) ctx.a11y.focusId = null;
}
function deferred() {
  return H.state === 'loading' || ctx.snapping || ctx.content?.classList.contains('scrolling') || ctx.root.querySelector('.bd-sb.drag');
}
export function onDataChanged(msg) {
  if (Object.keys(msg.set ?? {}).length) renderChrome(); else fx.renderOffline();
  msg.upsert.forEach(row => pendingLive.changed.add(row.id));
  msg.remove.forEach(id => pendingLive.removed.add(id));
  pendingLive.dirty = true;
  if (!deferred()) ctx.life.frame('live', flushLive);
}
export function requestLivePass() {
  pendingLive.dirty = true;
  ctx.life.frame('live', flushLive);
}
export function flushLive() {
  if (!pendingLive.dirty || deferred()) return;
  const anchor = takeAnchor();
  relayout({ live: true }); restoreAnchor(anchor); update();
  pendingLive.changed.clear(); pendingLive.removed.clear(); pendingLive.dirty = false;
  performance.mark('build-home-live-pass');
}
Object.assign(fx, { viewport, relayout, update, dataChanged: onDataChanged, flushLive, requestLivePass, renderHeads });
