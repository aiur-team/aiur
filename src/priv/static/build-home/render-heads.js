import { S, ctx } from './state.js';
import { H } from './history.js';
import { fmtD } from './util.js';

export function headHTML(D, history, sources, from, state = 'idle') {
  const hc = history.total, shown = D.hist.filter(x => x.end >= from).length;
  const total = Number.isInteger(hc) ? hc.toLocaleString() : null;
  const available = ['ok', 'stale', 'incomplete'].includes(sources?.history?.state);
  const first = D.hist[0]?.start;
  let label;
  if (!available && !D.hist.length) label = 'unavailable';
  else if (history.more) label = 'since ' + fmtD(from) + (state === 'error' ? ' — earlier days could not load · scroll up to retry' : ' — scroll up to load earlier days');
  else if (hc === 0) label = 'empty';
  else label = 'all ' + (total ?? '—') + (Number.isFinite(first) ? ' from ' + fmtD(first) : '');
  const count = hc === 0 && available ? '' : '<em style="margin-left:auto;padding-right:14px">' + shown.toLocaleString() + (total === null ? ' loaded · total unknown' : ' of ' + total + ' loaded') + '</em>';
  return {
    hist: 'History <em>' + label + '</em>' + count,
    plan: 'Planned <em>' + (D.plan.length ? D.plan.length + ' in build-queue order · dependency waves' : 'queue empty') + '</em>',
    nq: 'Not queued <em>' + D.nq.length + ' open · not in the queue</em>',
  };
}
export function renderHeads() {
  if (!ctx.D || !ctx.secs.hist) return;
  const heads = headHTML(ctx.D, H, ctx.snap.sources, S.histFrom, H.state);
  for (const sec of Object.keys(heads)) ctx.secs[sec].head.innerHTML = heads[sec];
}
