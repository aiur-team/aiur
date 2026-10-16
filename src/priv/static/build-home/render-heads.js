import { S, ctx } from './state.js';
import { H } from './history.js';
import { fmtD } from './util.js';

export function headHTML(D, history, sources, from, state = 'idle') {
  const hc = history.more ? history.total : D.hist.length, shown = D.hist.filter(x => x.end >= from).length;
  const total = Number.isInteger(hc) ? hc.toLocaleString() : null;
  const available = ['ok', 'stale', 'incomplete'].includes(sources?.history?.state);
  const starts = D.hist.map(row => row.start).filter(Number.isFinite);
  const first = starts.length ? Math.min(...starts) : null;
  let label;
  if (!available && !D.hist.length) label = 'unavailable';
  else if (history.more) label = 'since ' + fmtD(from) + (state === 'error' ? ' — earlier days could not load · scroll up to retry' : ' — scroll up to load earlier days');
  else if (!D.hist.length) label = 'empty';
  else label = 'all ' + D.hist.length.toLocaleString() + (Number.isFinite(first) ? ' from ' + fmtD(first) : '');
  const count = !D.hist.length ? '' : '<em style="margin-left:auto;padding-right:14px">' + shown.toLocaleString() + (total === null ? ' loaded · total unknown' : ' of ' + total + ' loaded') + '</em>';
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
