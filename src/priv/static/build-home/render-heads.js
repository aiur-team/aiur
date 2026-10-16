import { S, ctx } from './state.js';
import { H } from './history.js';
import { sectionState, headNote } from './states.js';
import { nowMs } from './clock.js';
import { esc } from './dom.js';
import { fmtD } from './util.js';

export function headHTML(D, history, sources, from, state = 'idle', compact = false) {
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
  const heads = {
    hist: 'History <em>' + label + '</em>' + count,
    plan: 'Planned <em>' + (D.plan.length ? D.plan.length + ' in build-queue order · dependency waves' : 'queue empty') + '</em>',
    nq: 'Not queued <em>' + D.nq.length + ' open · not in the queue</em>',
  };
  for (const sec of Object.keys(heads)) {
    const filtered = D[sec].filter(row => !S.f?.epic?.length || S.f.epic.includes(row.epic || 'unsorted'));
    const st = sectionState({ sources }, D, history, sec, filtered), note = headNote(sec, st, nowMs());
    if (!note) continue;
    const suffix = compact ? '<br>' + esc(note).replace(', showing the ', ', showing<br> the ') : esc(note);
    heads[sec] = heads[sec].replace(/<em>(.*?)<\/em>/, (_match, text) => '<em>' +
      (['unavailable', 'incomplete', 'disabled'].includes(st.show) ? esc(note) : text + ' · ' + suffix) + '</em>');
  }
  return heads;
}
export function renderHeads() {
  if (!ctx.D || !ctx.secs.hist) return;
  const heads = headHTML(ctx.D, H, ctx.snap.sources, S.histFrom, H.state, ctx.root.clientWidth < 640);
  for (const sec of Object.keys(heads)) ctx.secs[sec].head.innerHTML = heads[sec];
}
