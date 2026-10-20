// Vertical time geometry ported from the signed-off build design.
import { SEC } from './state.js';
import { fmtD, fmtWD, fmtT, fmtRange, dayKey } from './util.js';
const H = 3600000;

export function ganttHist(ents, ctx) {
  const { span, pph, now, nowRows, flow, colKey, CH, compact, hs: o } = ctx;
  const hMin = span <= 2 ? CH.mini : 4;
  const startOf = t => t.start == null ? t.end - hMin / pph * H : Math.min(t.start, t.end);
  const BRK = span <= 1 ? 30 : Math.max(4, Math.round(30 / Math.sqrt(span))), ivs = [];
  ents.forEach((e) => { if (e.t && e.t.end != null) ivs.push([startOf(e.t), e.t.end]); });
  nowRows.forEach((t) => { if (t.start != null) ivs.push([Math.min(t.start, now), now]); });
  ivs.sort((a, b) => a[0] - b[0]);
  const merged = [];
  ivs.forEach((iv) => { const l = merged[merged.length - 1]; if (l && iv[0] <= l[1]) l[1] = Math.max(l[1], iv[1]); else merged.push(iv.slice()); });
  const segs = []; let y = SEC + 12, cur = merged.length ? merged[0][0] : now;
  const lin = (a, b) => { if (b <= a) return; const h = (b - a) / H * pph; segs.push({ t0: a, t1: b, y0: y, y1: y + h }); y += h; };
  const brk = (a, b) => { segs.push({ t0: a, t1: b, y0: y, y1: y + BRK, br: true }); y += BRK; };
  merged.forEach((m) => { if (m[0] - cur > 3 * H) brk(cur, m[0]); else lin(cur, m[0]); lin(Math.max(cur, m[0]), m[1]); cur = Math.max(cur, m[1]); });
  if (now - cur > 3 * H) brk(cur, now); else lin(cur, now);
  const tY = (t) => {
    let lo = 0, hi = segs.length - 1;
    while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (segs[mid].t0 <= t) lo = mid; else hi = mid - 1; }
    const s = segs[lo]; if (!s) return y;
    return s.y0 + Math.min(1, Math.max(0, (t - s.t0) / ((s.t1 - s.t0) || 1))) * (s.y1 - s.y0);
  };
  ents.forEach((e) => {
    if (!e.t || e.t.end == null) return;
    const a = tY(startOf(e.t)), b = tY(e.t.end), unknown = e.t.start == null;
    o.items.push({ t: e.t, ghost: e.ghost, key: flow ? "g" : colKey(e.t), y: a,
      h: unknown ? hMin : Math.max(b - a - 1, hMin), sec: "hist", ...(unknown ? { startUnknown: true } : {}) });
  });
  assignLanes(o.items);
  const gaps = ents.filter((e) => e.gap).map((e) => e.gap);
  let prevB = -Infinity;
  segs.forEach((s) => {
    if (!s.br) return;
    const hrs = (s.t1 - s.t0) / H;
    let label = hrs >= 20 ? "Idle · " + fmtWD(s.t0) + " " + fmtT(s.t0) + " → " + fmtWD(s.t1) + " " + fmtT(s.t1) + " · " + Math.round(hrs) + "h" : "";
    if (compact) { const gs = gaps.filter((g) => g.b > prevB && g.b <= s.t1); const n = gs.reduce((a, g) => a + g.n, 0); if (n) label = "+" + n + " unrelated · " + fmtRange(gs[0].a, gs[gs.length - 1].b) + (label ? " · " + label : ""); }
    prevB = s.t1;
    o.marks.push({ kind: "brk", y: s.y0, h: BRK, label });
  });
  const step = [1, 2, 3, 6, 12, 24].find((s) => s * pph >= 30) || 24;
  let lastDay = null;
  segs.forEach((s) => {
    if (s.br) return;
    const d = new Date(s.t0); d.setMinutes(0, 0, 0);
    if (d.getTime() < s.t0) d.setHours(d.getHours() + 1);
    for (let k = 0; k < 400 && d.getTime() <= s.t1; k++) {
      if (d.getHours() % step === 0) {
        const t = d.getTime(), dk = dayKey(t);
        if (dk !== lastDay) { o.labels.push({ y: tY(t), day: flow ? fmtD(t) : fmtWD(t), t: fmtT(t), line: lastDay != null }); lastDay = dk; }
        else o.labels.push({ y: tY(t), t: fmtT(t), tick: true });
      }
      d.setHours(d.getHours() + 1);
    }
  });
  o.h = y + 10;
  return { segs, tY };
}
export function assignLanes(items) {
  const by = Object.create(null);
  items.forEach((it) => (by[it.key] = by[it.key] || []).push(it));
  Object.values(by).forEach((list) => {
    list.sort((a, b) => a.y - b.y);
    let cl = [], end = -1, lanes = [];
    const fin = () => cl.forEach((it) => it.lanes = lanes.length);
    list.forEach((it) => {
      if (it.y >= end) { fin(); cl = []; lanes = []; }
      let li = lanes.findIndex((e) => e <= it.y); if (li < 0) { li = lanes.length; lanes.push(0); }
      lanes[li] = it.y + it.h + 2; it.lane = li; cl.push(it); end = Math.max(end, it.y + it.h + 2);
    });
    fin();
  });
}
// Interim estimate accessor; C7-T03 replaces this with the shared estHours.
export const estOf = t => Number.isFinite(t.override?.hours) ? t.override.hours : Number.isFinite(t.est) ? t.est : null;
export function bandGanttHeight(t, { pph, CH }) {
  const est = estOf(t);
  return est === null ? CH.line : Math.max(Math.min(14 * pph, est * pph), CH.line + Math.min(48, est * 3.2));
}
export function planGantt(ents, ctx) {
  const { y: start, pph, flow, K, colKey, CH, gap, span, det, cum } = ctx;
  const cur = Object.create(null), items = [];
  let end = start, unknown = !!ctx.unknown;
  ents.forEach(e => {
    if (e.gap) return;
    let k;
    if (flow) {
      k = "s0";
      for (let i = 1; i < K; i++) {
        const kk = "s" + i;
        if ((cur[kk] != null ? cur[kk] : start) < (cur[k] != null ? cur[k] : start)) k = kk;
      }
    } else k = colKey(e.t);
    const yy = cur[k] != null ? cur[k] : start, hrs = estOf(e.t);
    const h = Math.max((hrs ?? 0) * pph, span > 2 ? 4 : det === "mini" ? CH.mini : CH.line);
    items.push({ t: e.t, ghost: e.ghost, key: k, y: yy, h, sec: "plan", gantt: true,
      ...(hrs === null ? { estUnknown: true } : {}) });
    unknown ||= hrs === null;
    cur[k] = yy + h + gap * 0.5; end = Math.max(end, cur[k]);
  });
  return { items, end, label: { y: start + 30, t: "≈ " + (ctx.unknown ? "≥" : "") + "+" + Math.round(cum) + "h" }, unknown };
}
export const ganttExt = { hist: ganttHist, plan: planGantt, bandHeight: (t, { pphG, CH }) => bandGanttHeight(t, { pph: pphG, CH }) };
