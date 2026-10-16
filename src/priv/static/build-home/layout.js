import { sectionState, emptyMark } from './states.js';
import { nowMs } from './clock.js';
import { LH, SEC } from './state.js';
import { esc } from './dom.js';
import { WD, fmtD, fmtRange, dayKey } from './util.js';
import { I } from './icons.js';

export const colKey = t => t.epic || "unsorted";
export const CH = { full: 9.4 * 13, line: 2.5 * 13, mini: Math.max(24, 2.3 * 13) };
const days = new WeakMap(), warned = new WeakSet();
export function histDays(hist) {
  if (!days.has(hist)) days.set(hist, [...new Set(hist.filter(t => Number.isFinite(t.end)).map(t => {
    const d = new Date(t.end); d.setHours(0, 0, 0, 0); return d.getTime();
  }))].sort((a, b) => a - b));
  return days.get(hist);
}
export function measureFlow(D, dims) {
  const avail = dims.vpW - dims.gut - 14;
  const nEst = Math.max(4, new Set([...D.now, ...D.plan].map(colKey)).size);
  return { flow: avail / nEst < 62, K: Math.max(2, Math.floor(avail / 140)) };
}
export function computeLayout(D, S, dims, sources, ext = {}) {
  if (S.view === "gantt" && !ext.gantt) throw new Error("gantt layout not installed");
  const epicOk = t => !S.f.epic.length || S.f.epic.includes(colKey(t));
  const NOWL = D.now.filter(epicOk), PLANL = D.plan.filter(epicOk), NQL = D.nq.filter(epicOk);
  const span = S.span || 1, fs = 13, flow = S.flow, K = S.K, vh = Math.max(300, (dims.vpH == null ? 700 : dims.vpH) - LH - 40);
  let gap = 14;
  const pphG = span <= 1 ? 18 : Math.max(0.45, vh / (span * 11));
  const baseDet = "full";
  let det = baseDet;
  let ch = CH[det], pitch = ch + gap;
  const compact = !!ext.compact;
  const entries = ext.entries ?? (list => list.map(t => ({ t })));
  const gapLabel = ext.gapLabel ?? (g => "+" + g.n + " unrelated" + (g.a ? " · " + fmtRange(g.a, g.b) : ""));
  const histList = D.hist.filter((t) => Number.isFinite(t.end) && t.end >= (S.histFrom || 0) && epicOk(t)).sort((a, b) => a.end - b.end);
  if (span > 1 && S.view !== "gantt") {
    const ds = histDays(D.hist), from = ds.length ? ds[Math.max(0, ds.length - span)] : 0;
    let n = 0, cur = null;
    entries(histList.filter((t) => t.end >= from)).forEach((e) => { if (e.gap) { n++; cur = null; return; } const k = flow ? null : colKey(e.t); if (!cur || (flow ? cur.size >= K : cur.has(k))) { n++; cur = new Set(); } cur.add(flow ? cur.size : k); });
    const target = vh / Math.max(1, n);
    gap = Math.max(2, Math.min(14, target * 0.18));
    ch = Math.min(CH[baseDet], Math.max(5, target - gap));
    const TI = ["bar", "mini", "line", "full"], bi = ch >= CH.full ? 3 : ch >= CH.line ? 2 : ch >= 22 ? 1 : 0;
    det = TI[Math.min(bi, TI.indexOf(baseDet))];
    pitch = ch + gap;
  }
  function rows(ents, y, items, marks, labels, sec, timeLabels) {
    let cur = null, lastDay = null;
    const flush = () => {
      if (!cur || !cur.size) { cur = null; return; }
      let first = null;
      cur.forEach((e, k) => { items.push({ t: e.t, ghost: e.ghost, key: k, y, h: ch, sec }); if (!first || e.t.end < first.end) first = e.t; });
      if (timeLabels && first.end) {
        const dk = dayKey(first.end);
        if (dk !== lastDay) { labels.push({ y, day: fmtD(first.end), t: WD[new Date(first.end).getDay()], line: lastDay != null }); lastDay = dk; }
      }
      y += pitch; cur = null;
    };
    ents.forEach((e) => {
      if (e.gap) { flush(); marks.push({ kind: "gap", y, h: 26, label: gapLabel(e.gap) }); y += 26 + gap; return; }
      if (flow) { if (cur && cur.size >= K) flush(); if (!cur) cur = new Map(); cur.set("s" + cur.size, e); return; }
      const k = colKey(e.t);
      if (cur && cur.has(k)) flush();
      if (!cur) cur = new Map();
      cur.set(k, e);
    });
    flush();
    return y;
  }
  const out = { det, base: baseDet, fs, ch, pitch, gap, secs: {} };
  const P = { sources }, H = ext.history ?? {}, mctx = { nqCount: NQL.length, index: sources?.index, now: nowMs() };
  /* history */
  const hs = { items: [], marks: [], labels: [], h: 0, unplaced: D.hist.filter(t => !Number.isFinite(t.end)).map(t => t.id) };
  if (hs.unplaced.length && !warned.has(D.hist)) {
    warned.add(D.hist);
    console.warn("History rows without finite end:", hs.unplaced);
  }
  const gctx = y => ({ span, pph: pphG, flow, K, compact, gapLabel, colKey, CH, gap, det, nowRows: NOWL, hs, y });
  const hst = sectionState(P, D, H, 'hist', histList);
  if (hst.show !== 'rows') { hs.marks.push(emptyMark('hist', hst, mctx)); hs.h = SEC + 104; }
  else if (S.view === "gantt") ext.gantt.hist(entries(histList), gctx(SEC + 4));
  else hs.h = rows(entries(histList), SEC + 4, hs.items, hs.marks, hs.labels, "hist", true) + gap;
  out.secs.hist = hs;
  // J:486–496 Now band: C9-T08 bandLayout
  out.band = { items: [], h: 0, BK: 1 };
  /* planned */
  const ps = { items: [], marks: [], labels: [], h: 0 };
  const pst = sectionState(P, D, H, 'plan', PLANL);
  if (pst.show !== 'rows') { ps.marks.push(emptyMark('plan', pst, mctx)); ps.h = SEC + 104; }
  else {
    let y = SEC + 4, cum = 0, unknown = false;
    const waveKey = t => Number.isInteger(t.wave) && t.wave >= 1 ? t.wave : null;
    [...new Set(PLANL.map(waveKey))].sort((a, b) => a === null ? 1 : b === null ? -1 : a - b).forEach((w) => {
      const list = PLANL.filter((t) => waveKey(t) === w); if (!list.length) return;
      const ents = entries(list);
      if (compact && !ents.some((e) => e.t)) { ps.marks.push({ kind: "gap", y, h: 26, label: (w === null ? "W?" : "W" + w) + " · " + gapLabel(ents[0].gap) }); y += 26 + gap; return; }
      y += gap * 0.6;
      ps.labels.push({ y, day: (w === null ? "W?" : "W" + w), t: list.length + (w === null ? " · wave unknown" : w === 1 ? " · ready" : ""), tk: true, line: w === null || w > 1, wave: true });
      if (S.view === "gantt") {
        const result = ext.gantt.plan(ents, { ...gctx(y), cum, unknown });
        ps.items.push(...result.items); ps.labels.push(result.label);
        unknown ||= result.unknown;
        cum += (result.end - y) / pphG;
        y = result.end + gap * 0.5;
      } else y = rows(ents, y, ps.items, ps.marks, ps.labels, "plan", false);
    });
    ps.h = y + gap;
  }
  out.secs.plan = ps;
  /* not queued */
  const ns = { items: [], marks: [], labels: [], h: 0 };
  ns.h = rows(entries(NQL), SEC + 4, ns.items, ns.marks, ns.labels, "nq", false) + gap;
  const nst = sectionState(P, D, H, 'nq', NQL);
  if (['unavailable', 'incomplete', 'disabled'].includes(nst.show)) {
    ns.marks.push(emptyMark('nq', nst, mctx)); ns.h = SEC + 104;
  }
  out.secs.nq = ns;
  return out;
}

export function makeMark(m) {
  const el = document.createElement("div"); el.className = "bd-mk " + m.kind;
  el.innerHTML = m.kind === "empty" ? "<b>" + esc(m.label) + "</b><p>" + esc(m.sub) + "</p>" : m.label ? "<span>" + esc(m.label) + (m.sub ? ' <em style="font-style:normal;color:var(--faint)">· ' + esc(m.sub) + "</em>" : "") + "</span>" : "";
  return el;
}
export function placeMark(el, m, contentW, gut) {
  el.style.top = m.y + "px"; el.style.height = m.h + "px"; el.style.left = (m.kind === "wave" ? 12 : gut) + "px"; el.style.width = (contentW - (m.kind === "wave" ? 12 : gut) - 12) + "px";
}
export function makeLabel(lb) {
  const el = document.createElement("div"); el.className = "bd-lbl" + (lb.tick ? " tick" : "") + (lb.wave ? " wave" : ""); el.style.top = lb.y + "px";
  el.innerHTML = (lb.day ? "<b>" + esc(lb.day) + "</b>" : "") + "<span>" + (lb.tk ? I.ticket : "") + esc(lb.t) + "</span>";
  let ln = null;
  if (lb.line) { ln = document.createElement("div"); ln.className = "bd-dl"; ln.style.top = (lb.y - 6) + "px"; }
  return [el, ln];
}
