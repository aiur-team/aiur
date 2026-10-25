import { colKey } from './layout.js';
import { agentState, progress } from './now-state.js';
import { fmtD } from './util.js';

export const NW = 196, NH = 50, GX = 14, GY = 44, GW = 12, MIN = 0.8;

export function chainOf(D, id) {
  const set = new Set([id]);
  if (!D.byId[id]) return set;
  walk(id, x => D.byId[x].deps || [], set, D);
  walk(id, x => D.children[x] || [], set, D);
  return set;
}

// Frames preserve the design's recursive depth-first insertion order.
function walk(start, next, set, D) {
  const stack = [[start, 0]];
  while (stack.length) {
    const frame = stack[stack.length - 1], nodes = next(frame[0]);
    if (frame[1] >= nodes.length) { stack.pop(); continue; }
    const child = nodes[frame[1]++];
    if (!set.has(child) && D.byId[child]) { set.add(child); stack.push([child, 0]); }
  }
}

export function chainGaps(D, set) {
  const unloaded = new Set();
  let missing = 0;
  for (const id of set) {
    const t = D.byId[id];
    if (!t) continue;
    for (const other of [...(t.deps || []), ...(D.children[id] || [])]) {
      if (!D.byId[other]) unloaded.add(other);
    }
    if (t.deps_missing === null) missing = null;
    else if (missing !== null) missing += t.deps_missing ?? 0;
  }
  return { unloaded: unloaded.size, missing };
}

export function fitFrom(D, id) {
  let oldest = Infinity;
  for (const member of chainOf(D, id)) {
    const t = D.byId[member];
    if (t?.sec === 'hist' && Number.isFinite(t.end)) oldest = Math.min(oldest, t.end);
  }
  if (!Number.isFinite(oldest)) return null;
  const d = new Date(oldest); d.setHours(0, 0, 0, 0);
  return d.getTime();
}

function depths(D, ids, set) {
  const depth = Object.create(null);
  for (const id of ids) {
    if (depth[id] != null) continue;
    depth[id] = 0;
    const stack = [{ id, index: 0, max: 0 }];
    while (stack.length) {
      const frame = stack[stack.length - 1], deps = D.byId[frame.id].deps || [];
      if (frame.index === deps.length) {
        depth[frame.id] = frame.max;
        stack.pop();
        if (stack.length) {
          const parent = stack[stack.length - 1];
          parent.max = Math.max(parent.max, frame.max + 1);
        }
        continue;
      }
      const p = deps[frame.index++];
      if (p === frame.id || !set.has(p)) continue;
      if (depth[p] != null) frame.max = Math.max(frame.max, depth[p] + 1);
      else { depth[p] = 0; stack.push({ id: p, index: 0, max: 0 }); }
    }
  }
  return depth;
}

export function treeLayout(D, id, aw, ah) {
  const set = chainOf(D, id), ids = [...set].filter(x => D.byId[x]);
  const depth = depths(D, ids, set), rows = [];
  for (const x of ids) (rows[depth[x]] ||= []).push(x);
  const oi = x => D.order.indexOf(colKey(D.byId[x]));
  const numKey = x => D.byId[x].num ?? Infinity;
  rows.forEach(r => r.sort((a, b) => oi(a) - oi(b) || numKey(a) - numKey(b) || (a < b ? -1 : 1)));
  const per = Math.max(2, Math.floor((aw / MIN + GX) / (NW + GX))), vrows = [];
  rows.forEach(r => { for (let i = 0; i < r.length; i += per) vrows.push({ ids: r.slice(i, i + per), cont: i > 0 }); });
  const widest = vrows.reduce((n, r) => Math.max(n, r.ids.length), 0);
  const natW = widest ? widest * (NW + GX) - GX : 0, pos = Object.create(null);
  let y = 0;
  vrows.forEach((r, ri) => {
    if (ri) y += r.cont ? GW : GY;
    const rw = r.ids.length * (NW + GX) - GX, x0 = (natW - rw) / 2;
    r.ids.forEach((x, i) => { pos[x] = { x: x0 + i * (NW + GX), y }; });
    y += NH;
  });
  const natH = y, sc = Math.max(MIN, Math.min(1, aw / natW, ah / natH)), edges = [];
  for (const x of ids) for (const p of D.byId[x].deps || []) {
    if (p === x || !set.has(p)) continue;
    const a = pos[p], b = pos[x];
    const x1 = a.x + NW / 2, y1 = a.y + NH, x2 = b.x + NW / 2, y2 = b.y - 4, dy = Math.max(16, (y2 - y1) / 2);
    edges.push({ id: x, dep: p, x1, y1, x2, y2, dy,
      path: `M${x1} ${y1} C${x1} ${y1 + dy} ${x2} ${y2 - dy} ${x2} ${y2}`,
      arrow: `M${x2 - 4} ${y2 - 6} L${x2} ${y2 + 1} L${x2 + 4} ${y2 - 6}z` });
  }
  return { ids, rows, depth, levels: rows.filter(r => r.length).length, pos, natW, natH, sc, per, edges };
}

export function treeStatus(t, queueText = row => row.qpos == null ? 'Q?' : 'Q' + row.qpos) {
  if (t.sec === 'hist') {
    if (t.status === 'failed') return 'Failed';
    if (t.status === 'not_planned') return 'Not planned';
    if (t.status === 'closed') return 'Closed';
    return Number.isFinite(t.end) ? 'Merged ' + fmtD(t.end) : 'Merged · date unknown';
  }
  if (t.sec === 'now') return agentState(t.agent?.state).label + ' · ' + progress(t.pct).text;
  if (t.sec === 'plan') return queueText(t) + ' · ' + (t.wave == null ? 'W?' : 'W' + t.wave);
  return 'Not queued';
}
