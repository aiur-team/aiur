import { S, ctx, fx, onReset } from './state.js';
import { histDays } from './layout.js';
import { mergeEarlier } from './store.js';
import { takeAnchor, restoreAnchor } from './render-anchor.js';

export const H = {};
let inflight = null, serial = 0;
export function resetHistory() {
  serial++; inflight = null;
  Object.assign(H, { state: 'idle', retryArmed: true, epoch: null, more: false, total: null });
}
export function setPaging(state) {
  H.state = state;
  if (ctx.root) ctx.root.dataset.bdPaging = state;
}
export function syncHistory() {
  if (H.epoch !== ctx.proto.epoch) { serial++; inflight = null; H.retryArmed = true; setPaging('idle'); }
  H.epoch = ctx.proto.epoch;
  S.histFrom = ctx.snap.history.from ?? 0;
  H.more = ctx.snap.history.more;
  H.total = ctx.snap.history.total;
  setPaging(H.state);
}
export function loadEarlier(days = 1) {
  if (inflight) return inflight;
  const root = ctx.root, life = ctx.life;
  if (!H.more || !root?.isConnected || life.disposed || (H.state === 'error' && !H.retryArmed)) return Promise.resolve(false);
  const before = S.histFrom, epoch = ctx.proto.epoch, token = ++serial;
  const current = () => token === serial && ctx.root === root && root.isConnected && !life.disposed;
  setPaging('loading');
  const fail = () => {
    if (current()) { H.retryArmed = false; setPaging('error'); fx.renderHeads(); }
    return false;
  };
  // Defer the push so even a synchronous exception uses the same error path.
  inflight = Promise.resolve().then(() => ctx.push('load-earlier', days > 1 ? { before, days } : { before })).then(reply => {
    if (!current()) return false;
    if (epoch !== ctx.proto.epoch || reply?.epoch && reply.epoch !== epoch) { setPaging('idle'); return false; }
    if (!reply || reply.kind !== 'earlier' || !Number.isFinite(reply.history?.from) || reply.history.from >= before) return fail();
    const anchor = takeAnchor();
    if (mergeEarlier(reply).error) return fail();
    fx.relayout({ live: true }); restoreAnchor(anchor);
    setPaging('idle');
    return true;
  }).catch(fail).finally(() => {
    if (token !== serial) return;
    inflight = null;
    // Clear single-flight before update: filtered days can trigger the next page.
    if (current() && H.state === 'idle') fx.update();
  });
  return inflight;
}
export async function ensureDays(n) {
  while (histDays(ctx.D.hist).length < n && H.more && await loadEarlier(Math.min(31, n - histDays(ctx.D.hist).length)));
}
export async function ensureFrom(ms, keep = () => true) {
  while (S.histFrom > ms && H.more && keep() && await loadEarlier());
}
onReset(resetHistory);
