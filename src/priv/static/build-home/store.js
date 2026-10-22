import { ctx } from './state.js';
import { intake } from './protocol.js';
import { setNow } from './clock.js';

function commit(snap, clock = true) {
  const D = { ...intake(snap), sources: snap.sources, capacity: snap.capacity, repo: snap.repo };
  ctx.snap = snap; ctx.D = D;
  ctx.proto.epoch = snap.epoch; ctx.proto.generation = snap.generation;
  if (clock) setNow(snap.now);
  return { ok: true };
}
export function acceptSnapshot(msg) {
  if (!Number.isFinite(msg.now)) return { error: 'invalid' };
  try { return commit(structuredClone(msg)); }
  catch { return { error: 'invalid' }; }
}
export function applyDiff(msg) {
  if (!Number.isFinite(msg.now)) return { error: 'invalid' };
  try {
    const copy = structuredClone(ctx.snap);
    const ids = new Set([...msg.remove, ...msg.upsert.map(row => {
      if (!row.id || !Object.hasOwn(copy.sections, row.sec)) throw new Error('invalid row');
      return row.id;
    })]);
    for (const key of Object.keys(copy.sections)) copy.sections[key] = copy.sections[key].filter(row => !ids.has(row.id));
    for (const row of msg.upsert) copy.sections[row.sec].push(structuredClone(row));
    Object.assign(copy, structuredClone(msg.set), { generation: msg.generation, now: msg.now });
    return commit(copy);
  } catch { return { error: 'invalid' }; }
}
export function mergeEarlier(msg) {
  if (msg.epoch !== ctx.proto.epoch) return { error: 'epoch' };
  try {
    const copy = structuredClone(ctx.snap), ids = new Set(ctx.D.all.map(row => row.id));
    for (const row of msg.rows) {
      if (!row.id || !Object.hasOwn(copy.sections, row.sec)) throw new Error('invalid row');
      if (!ids.has(row.id)) { copy.sections[row.sec].push(structuredClone(row)); ids.add(row.id); }
    }
    copy.history = structuredClone(msg.history);
    return commit(copy, false);
  } catch { return { error: 'invalid' }; }
}
