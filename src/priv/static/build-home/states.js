import { ctx, fx, onReset, SEC } from './state.js';
import { nowMs } from './clock.js';
import { fmtAge, fmtWhen } from './offline.js';

const keys = { hist: 'history', plan: 'queue', nq: 'index', now: 'agents' };
const sourceKeys = ['agents', 'features', 'history', 'index', 'queue'];
const valid = ['ok', 'stale', 'incomplete', 'unavailable', 'disabled'];
const source = (P, key) => valid.includes(P?.sources?.[key]?.state) ? P.sources[key]
  : { state: 'unavailable', observed_at: null, reason: 'unknown' };
let ticking = false;
onReset(() => { ticking = false; });

export function sectionState(P, D, H, sec, filtered) {
  const src = source(P, keys[sec]), loaded = D[sec].length;
  const stale = ['stale', 'incomplete'].includes(src.state) || loaded > 0 && ['unavailable', 'disabled'].includes(src.state);
  let show;
  if (!loaded && ['disabled', 'unavailable', 'incomplete'].includes(src.state)) show = src.state;
  else if (loaded && !filtered.length) show = 'filtered';
  else if (sec === 'hist' && !loaded && (H.more === true || H.total > 0)) show = 'window';
  else show = loaded ? 'rows' : 'empty';
  return { show, stale, src };
}
export function reasonText(tag) {
  const words = { not_wired: 'not connected', timeout: 'timed out', crashed: 'the reader crashed',
    snapshot_unpublished: 'the daemon is starting', orchestrator_unavailable: 'the orchestrator is down',
    incomplete: 'the read was partial', open_tickets_loading: 'the open-ticket listing is in progress',
    open_tickets_unavailable: 'the open-ticket listing is unavailable', open_tickets_timeout: 'the open-ticket listing timed out', backfill_running: 'the history backfill is still running',
    structurally_invalid: 'the stored data is malformed', tracker_unsupported: 'this tracker has no open-ticket index' };
  if (typeof tag !== 'string' || ['unknown', 'unavailable'].includes(tag)) return 'unknown cause';
  return Object.hasOwn(words, tag) ? words[tag] : tag.slice(0, 80);
}
export function ageText(src, now) {
  return Number.isFinite(src.observed_at) && Number.isFinite(now)
    ? `read ${fmtAge(now - src.observed_at)} (${fmtWhen(src.observed_at, now)})` : 'no successful read recorded';
}
// A sentence, never "Last no successful read recorded" (#4916).
const lastText = (src, now) => Number.isFinite(src.observed_at) && Number.isFinite(now) ? 'Last ' + ageText(src, now) : 'No successful read recorded';
export function emptyMark(sec, st, mctx) {
  const { src, show } = st, last = lastText(src, mctx.now), why = reasonText(src.reason);
  const names = { hist: ['History', 'The build history', 'nothing has merged'], plan: ['Queue', 'The build queue', 'the queue is empty'], nq: ['Open tickets', 'The open-ticket index'] };
  const [name, subject, disclaimer] = names[sec];
  let label, sub;
  if (show === 'disabled') {
    label = { hist: 'History disabled', plan: 'Build queue disabled', nq: 'Open-ticket index disabled' }[sec]; sub = why + '.';
  } else if (['unavailable', 'incomplete'].includes(show)) {
    label = name + ' ' + show;
    sub = `${subject} ${show === 'incomplete' ? 'was only partly read' : 'could not be read'} (${why}). ${last}.` + (disclaimer ? ` This does not mean ${disclaimer}.` : '');
  } else if (show === 'filtered') {
    label = sec === 'hist' ? 'No history in the selected epics' : 'No planned tickets in the selected epics';
    sub = 'Clear the epic filter to see ' + (sec === 'hist' ? 'the loaded history.' : 'the build queue.');
  } else if (show === 'window') {
    label = 'No history in the loaded days'; sub = 'Scroll up to load earlier days.';
  } else if (sec === 'hist') {
    label = 'No history yet'; sub = 'A new repo — nothing has merged. The first tickets are running in the Now band below.';
  } else {
    label = 'Nothing planned'; sub = ['ok', 'stale'].includes(mctx.index?.state)
      ? `The build queue is empty. ${mctx.nqCount} open tickets are not queued — promote some to keep agents busy.`
      : 'The build queue is empty. The open-ticket index is unavailable, so the number not queued is unknown.';
  }
  if (show === 'empty' && src.state === 'stale') sub += ` ${last}; this may be out of date.`;
  const mark = { kind: 'empty', y: SEC, h: 96, label, sub };
  return src.state === 'ok' && show === 'empty' ? mark
    : { ...mark, source: keys[sec], state: src.state, observed_at: src.observed_at };
}
export function headNote(_sec, st, now) {
  if (['unavailable', 'incomplete', 'disabled'].includes(st.show)) return st.show;
  const age = ageText(st.src, now);
  if (st.src.state === 'stale') return `stale, ${age}`;
  if (st.src.state === 'incomplete') return `partial, ${age}`;
  if (['unavailable', 'disabled'].includes(st.src.state)) return `${st.src.state}, showing the ${age}`;
  return '';
}
export function syncStates() {
  const nonOk = () => sourceKeys.map(key => [key, source(ctx.snap, key).state]).filter(([, state]) => state !== 'ok');
  ctx.bdStates = nonOk().map(([key, state]) => `${key}:${state}`).join(' ');
  ctx.root.dataset.bdStates = ctx.bdStates;
  if (!ticking && ctx.bdStates) {
    ticking = true;
    ctx.life.every(30_000, () => { if (nonOk().length) fx.requestLivePass(); });
  }
}
export function renderLoading() {
  if (ctx.snap) return;
  ctx.content = null;
  if (ctx.vp.querySelector('.bd-skel') && ctx.vp.querySelector('.bd-spin')) return;
  ctx.vp.innerHTML = '<div class="bd-lanes"><div class="bd-skel-lanes"><i class="bd-skel-i"></i><i></i><i></i><i></i></div></div>' +
    '<div class="bd-skel">' + '<i></i>'.repeat(16) + '</div><div class="bd-loading" role="status"><span class="bd-spin"></span>Loading build timeline…</div>';
  ctx.vp.querySelectorAll('.bd-skel-lanes i').forEach(el => { el.style.background = 'var(--surface-3)'; });
}
export function renderUnavailable(reason) {
  const loading = ctx.root?.querySelector('.bd-loading');
  if (!loading) return;
  const words = { not_wired: 'no data source', timeout: 'build index read timed out', crashed: 'source crashed',
    version: 'page out of date, reload', invalid: 'invalid data', invalid_data: 'build data failed validation',
    index_not_running: 'build index is not running', read_failed: 'build index read failed',
    epic_config_unavailable: 'Build Order settings could not be read' };
  if (reason === 'settings_loading') {
    loading.textContent = 'Loading build settings…';
    loading.setAttribute('role', 'status');
    return;
  }
  const cause = Object.hasOwn(words, reason) ? words[reason] : `unknown cause (${String(reason).slice(0, 80)})`;
  loading.textContent = `Build timeline unavailable · ${cause}`;
  loading.setAttribute('role', 'status');
  ctx.vp.querySelectorAll('.bd-skel i').forEach(el => { el.style.animation = 'none'; });
}
Object.assign(fx, { renderLoading, renderUnavailable });
