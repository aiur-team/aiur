import { activeFeature } from './features.js';
import { rowOk } from './filters.js';
// Port of design build.js:1152–1181, with explicit unknowns and delegated input.
import { S, ctx, fx } from './state.js';
import { esc } from './dom.js';
import { nowMs } from './clock.js';
import { fmtD, fmtH } from './util.js';
import { estLabel } from './estimate.js';
import { I } from './icons.js';
import { writeURL } from './url.js';
import { LOGOS } from './logos.js';
import { agentState, progress, modelLabel } from './now-state.js';
import { colKey, match } from './match.js';
import { H, loadEarlier } from './history.js';
import { sectionState, headNote, reasonText, ageText } from './states.js';
import { timed } from './perf.js';
export const renderList = timed('renderList', renderListImpl);

const HIST = { failed: ['failed', 'Failed'], done: ['merged', 'Merged'], not_planned: ['np', 'Not planned'], closed: ['closed', 'Closed'] };
export function stClass(t) {
  if (t.sec === 'hist') return Object.hasOwn(HIST, t.status) ? HIST[t.status][0] : 'unknown';
  if (t.sec === 'now') return agentState(t.agent?.state).cls ?? 'unknown';
  if (t.sec === 'plan') return t.cue?.held ? 'held' : t.cue?.failed || t.cue?.blockedChain ? 'blocked' : 'queued';
  return 'open';
}
export function stText(t) {
  if (t.sec === 'hist') return Object.hasOwn(HIST, t.status) ? HIST[t.status][1] : 'State unknown';
  if (t.sec === 'now') {
    const stateLabel = agentState(t.agent?.state).label;
    return t.agent?.pause === 'usage_limit_exhausted' && Number.isFinite(t.agent?.resume_at)
      ? stateLabel + ' (resumes at ' + new Date(t.agent.resume_at).toISOString().slice(11, 16) + ' UTC)'
      : stateLabel;
  }
  if (t.sec === 'plan') return t.cue?.held ? 'Held' : t.cue?.failed || t.cue?.blockedChain ? 'Blocked' : t.cue?.wait ? 'Waiting on #' + t.cue.wait : 'Queued';
  return 'Not queued';
}
const muted = text => '<span class="lr-mu">' + esc(text) + '</span>';
const number = x => Number.isFinite(x) ? x : '—';
const hue = (key, value) => Number.isFinite(value) ? ' style="' + key + ':' + value + '"' : '';
function progCell(t) {
  if (t.sec === 'now') {
    const p = progress(t.pct);
    return p.known ? '<span class="lr-pg" style="' + esc(p.style) + '"><span class="bd-bar"><i style="width:' + t.pct + '%"></i></span><b>' + esc(p.text) + '</b></span>' : muted('—');
  }
  if (t.sec === 'hist') return muted((Number.isFinite(t.end) ? fmtD(t.end) : '—') + ' · ' +
    (Number.isFinite(t.start) && Number.isFinite(t.end) && t.end >= t.start ? fmtH((t.end - t.start) / 36e5) : '—'));
  if (t.sec === 'plan') {
    return muted('Q' + number(t.qpos) + ' · W' + (Number.isFinite(t.wave) ? t.wave : '?') + ' · ' + estLabel(t));
  }
  return muted(number(t.pts) + ' pts');
}
function agentCell(t) {
  const a = t.agent;
  if (!a) return muted('—');
  const logo = LOGOS[a.model], name = modelLabel(a) ?? 'Model unknown';
  return (logo ? '<img src="' + esc(logo.src) + '" alt="">' : '<span class="ax-mono" aria-hidden="true">' + esc(a.name?.[0]?.toUpperCase() || '?') + '</span>') + esc(name);
}
function rowHTML(t, D, state) {
  const key = colKey(t), e = (Object.hasOwn(D.epics, key) ? D.epics[key] : D.epics.unsorted) ?? { label: 'Unsorted', unsorted: true };
  const f = Object.hasOwn(D.features, t.feature) ? D.features[t.feature] : null;
  const dim = activeFeature(D, state) && state.fmode === 'focus' && t.feature !== state.feature && !t.also.includes(state.feature);
  const ups = t.deps.length, dn = (D.children[t.id] || []).length, deps = ups + ' dependencies · unblocks ' + dn;
  const cell = (cls, html, attrs = '') => '<span class="' + cls + '" role="cell"' + attrs + '>' + html + '</span>';
  return '<div class="lr ' + esc(t.sec) + (dim ? ' dim' : '') + '" role="row" tabindex="0" data-id="' + esc(t.id) + '"' + hue('--h', e.hue) +
    ' aria-label="' + esc('#' + t.num + ' ' + t.title + ', ' + stText(t)) + '">' +
    cell('c-id', '<span class="lr-ep' + (e.unsorted ? ' un' : '') + '" aria-hidden="true">' + (Object.hasOwn(I, e.icon) ? I[e.icon] : '') + '</span>#' + esc(t.num)) +
    cell('c-tt', esc(t.title) + (f ? '<i class="lr-f"' + hue('--ft', f.hue) + ' title="' + esc(f.label) + '" role="img" aria-label="' + esc('Feature: ' + f.label) + '"></i>' : '')) +
    cell('c-ep', esc(e.label)) + cell('c-st', '<span class="lst st-' + stClass(t) + '"><u aria-hidden="true"></u>' + esc(stText(t)) + '</span>') +
    cell('c-ag', agentCell(t)) + cell('c-pg', progCell(t)) + cell('c-dp', (ups ? '↑' + ups : '') + (dn ? ' ↓' + dn : ''), ' title="' + esc(deps) + '" aria-label="' + esc(deps) + '"') + '</div>';
}
function secHead(sec, label, sub, rows, extra, D, state, history, P, now) {
  // Open-ticket availability already includes queue health; index is only the index reader's health.
  const open = P.sources?.open_tickets;
  const index = open?.state === 'unsupported' ? { ...open, state: 'unavailable' } : open;
  const payload = sec === 'nq' ? { ...P, sources: { ...P.sources, index } } : P;
  const st = sectionState(payload, D, history, sec, rows), note = headNote(sec, st, now);
  if (!rows.length && !extra && st.src.state === 'ok') return '';
  if (!rows.length && ['unavailable', 'incomplete', 'disabled'].includes(st.src.state)) {
    sub = note + ' · ' + reasonText(st.src.reason) + (st.src.state === 'disabled' ? '' : ' · ' + ageText(st.src, now));
  } else if (note) sub += ' · ' + note;
  if (sec === 'hist' && history.state === 'error') sub += ' · earlier days could not load';
  return '<div class="lh" role="row" data-sec="' + sec + '"' + (st.src.state !== 'ok' ? ' data-st="' + esc(st.src.state) + '"' : '') +
    '><b role="cell">' + label + '</b><em role="cell">' + esc(sub) + '</em></div>' + rows.map(t => rowHTML(t, D, state)).join('') + extra;
}
export function listHTML(D, state, history, P, now) {
  if (state.list === 'features') return featureListHTML(D, state, now);
  const keep = t => rowOk(state, t) && match(t, state), rows = Object.fromEntries(['now', 'plan', 'nq'].map(sec => [sec, D[sec].filter(keep)]));
  rows.hist = D.hist.filter(t => t.end >= (state.histFrom || 0) && keep(t)).sort((a, b) => b.end - a.end);
  const labels = { now: '<i class="lh-live" aria-hidden="true"></i>Live', plan: 'Planned', nq: 'Not queued', hist: 'History' };
  const nowCounts = { running: 0, retrying: 0, stuck: 0, paused: 0, unknown: 0 };
  for (const ticket of rows.now) {
    const key = ticket.agent?.state === 'active' ? 'running'
      : ticket.agent?.state === 'retrying' ? 'retrying'
        : ['error', 'retries', 'command'].includes(ticket.agent?.state) ? 'stuck'
          : ['paused', 'parked', 'usage_limited', 'paused-usage-limit', 'paused-decision', 'paused-agent', 'ci_wait', 'merge-queued', 'blocked', 'handed-off'].includes(ticket.agent?.state) ? 'paused'
            : ['ci-red', 'body-fix'].includes(ticket.agent?.state) ? 'stuck' : 'unknown';
    nowCounts[key]++;
  }
  const nowSummary = Object.entries(nowCounts).filter(([key, count]) => key === 'running' || count > 0)
    .map(([key, count]) => count + ' ' + (key === 'unknown' ? 'state unknown' : key)).join(' · ');
  const subs = { now: nowSummary, plan: rows.plan.length + ' in build-queue order', nq: rows.nq.length + ' open', hist: rows.hist.length + ' loaded · newest first' };
  const more = history.more ? '<div role="row"><div role="cell"><button type="button" class="lr-more" id="lr-more"' + (history.state === 'loading' ? ' disabled aria-busy="true"' : '') + '>Load earlier day</button></div></div>' : '';
  return '<div class="bd-list" role="table" aria-label="Build tickets" tabindex="-1"><div class="lr lr-h" role="row">' +
    ['id', 'tt', 'ep', 'st', 'ag', 'pg', 'dp'].map((key, i) => '<span class="c-' + key + '" role="columnheader">' + ['Ticket', 'Title', 'Epic', 'State', 'Agent', 'Progress', 'Deps'][i] + '</span>').join('') + '</div>' +
    ['now', 'plan', 'nq', 'hist'].map(sec => secHead(sec, labels[sec], subs[sec], rows[sec], sec === 'hist' ? more : '', D, state, history, P, now)).join('') + '</div>';
}
const knownSum = (values, key) => values.every(x => Number.isFinite(x[key])) ? values.reduce((sum, x) => sum + x[key], 0) : null;
function featureListHTML(D, state, now) {
  const values = Object.entries(D.features).flatMap(([slug, feature]) => {
    const epics = (feature.epics || []).map(key => ({ key, epic: D.epics[key], progress: D.feature_progress?.features?.[key] })).filter(x => x.epic);
    if (!epics.length) return [{ key: slug, feature, epic: { label: feature.label, feature: slug }, lanes: [], progress: null }];
    const sum = key => knownSum(epics.map(x => x.progress || {}), key);
    const closed = sum('closed'), open = sum('open'), ci = sum('ci_wait'), total = sum('total'), unpublished = sum('unpublished');
    const waves = [...new Set(epics.map(x => x.progress?.wave).filter(x => typeof x === 'string' && x.length))];
    const wave = waves.length === 1 ? waves[0] : null;
    const codes = [...new Set(epics.map(x => x.progress?.code).filter(x => typeof x === 'string' && x.length))];
    return [{ key: slug, feature, epic: { label: feature.label, feature: slug }, lanes: epics, progress: { feature: slug, closed, open, ci_wait: ci, total, unpublished, wave, reason: epics.some(x => x.progress?.reason) ? epics.find(x => x.progress?.reason)?.reason : null, icon: epics.find(x => x.progress?.icon)?.progress?.icon, summary: epics.find(x => x.progress?.summary)?.progress?.summary, code: codes.length === 1 ? codes[0] : null, root_number: epics.find(x => x.progress?.root_number)?.progress?.root_number, root_title: epics.find(x => x.progress?.root_title)?.progress?.root_title, start_date: epics.find(x => x.progress?.start_date)?.progress?.start_date } }];
  });
  const globallyUnknown = D.feature_progress?.reason;
  const aggregate = key => globallyUnknown ? null : knownSum(values.filter(x => x.progress).map(x => x.progress), key);
  const closed = aggregate('closed'), open = aggregate('open'), unpublished = aggregate('unpublished');
  const total = aggregate('total'), ci = aggregate('ci_wait');
  const opened = Number.isFinite(open) && Number.isFinite(ci) ? open + ci : null;
  const pct = Number.isFinite(total) && total > 0 && Number.isFinite(closed) ? Math.floor(closed * 100 / total) : null;
  const observed = D.feature_progress?.observed_at, age = Number.isFinite(observed) ? Math.max(0, now - observed) : null;
  const ageLabel = age == null ? 'age unknown' : age < 60_000 ? 'just now' : age < 3_600_000 ? Math.floor(age / 60_000) + 'm ago' : Math.floor(age / 3_600_000) + 'h ago';
  const pctText = pct == null ? '—' : pct + '%';
  const summary = Number.isFinite(closed) && Number.isFinite(total) ? `${closed} / ${total} tickets closed across all features` : '— tickets closed across all features';
  const totalReasons = globallyUnknown ? [globallyUnknown] : [Number.isFinite(closed) ? null : 'states unavailable', Number.isFinite(ci) ? null : 'CI state unknown', Number.isFinite(unpublished) ? null : 'planned count unavailable'].filter(Boolean);
  const totalsLine = `${summary} · ${Number.isFinite(unpublished) ? unpublished : '—'} planned tickets not published yet · ${Number.isFinite(ci) ? ci : '—'} waiting on CI${totalReasons.length ? ` · ${totalReasons.join(' · ')}` : ''}`;
  const bar = (c, o, u, reason, cls = '') => {
    const denominator = Number.isFinite(c) && Number.isFinite(o) && Number.isFinite(u) ? c + o + u : 0;
    const width = n => denominator > 0 ? Math.max(0, n / denominator * 100) : 0;
    return `<div class="fp-bar ${cls}${reason ? ' unknown' : ''}" role="img" aria-label="${esc(reason || `${c} closed, ${o} published open, ${u} planned not published`)}">${reason ? '<i class="fp-unknown"></i>' : `<i class="fp-closed" style="width:${width(c)}%"></i><i class="fp-open" style="width:${width(o)}%"></i><i class="fp-unpublished" style="width:${width(u)}%"></i>`}</div>`;
  };
  const groupKey = x => typeof x.progress?.wave === 'string' && x.progress.wave.length ? x.progress.wave : `feature:${x.key}`;
  const grouped = new Map();
  for (const item of values) { const key = groupKey(item); (grouped.get(key) || grouped.set(key, []).get(key)).push(item); }
  const waveOrder = value => { const match = /^(\d+)(.*)$/.exec(value); return match ? [Number(match[1]), match[2]] : [Infinity, value]; };
  const groups = [...grouped.entries()].sort(([a], [b]) => {
    if (a === 'unknown') return 1;
    if (b === 'unknown') return -1;
    const [an, as] = waveOrder(a), [bn, bs] = waveOrder(b);
    return an - bn || as.localeCompare(bs);
  });
  const rows = groups.map(([wave, items]) => `<section class="fp-wave"><h2>${wave.startsWith('feature:') ? `Feature: ${esc(items[0].feature.label)}` : `Wave ${esc(wave)}`}</h2>${items.map(({key, feature, epic, lanes, progress: p}) => {
    const membershipKnown = lanes.length > 0 && lanes.every(x => Number.isFinite(x.progress?.total));
    const reason = membershipKnown ? null : (p?.reason || 'planned count unavailable'), c = p?.closed, o = p?.open, u = p?.unpublished, t = p?.total;
    const rowPct = Number.isFinite(c) && Number.isFinite(t) && t > 0 ? Math.floor(c * 100 / t) + '%' : '—';
    const iconName = p?.icon || 'squares', icon = Object.hasOwn(I, iconName) ? I[iconName] : I.squares;
    const published = Number.isFinite(c) && Number.isFinite(o) && Number.isFinite(p?.ci_wait) ? c + o + p.ci_wait : null;
    const note = p && !reason ? published === 0 && Number.isFinite(t) && t > 0
      ? `not published yet — 0 of ${t} planned tickets on GitHub`
      : [u > 0 ? `${u} of ${t} not published yet` : null, p.ci_wait > 0 ? `${p.ci_wait} waiting on CI` : null].filter(Boolean).join(' · ')
      : reason || 'not published yet — 0 of planned tickets on GitHub';
    const summary = p?.summary ? `<small class="fp-summary">${esc(p.summary)}</small>` : '';
    const code = p?.code ? `<small class="fp-code">${esc(p.code)}</small>` : '';
    const laneText = lanes.map(x => `${esc(x.epic.label)}: ${Number.isFinite(x.progress?.closed) ? x.progress.closed : '—'} / ${Number.isFinite(x.progress?.total) ? x.progress.total : '—'}`).join(' · ');
    return `<button type="button" class="fp-row" data-feature="${esc(p?.feature || epic.feature)}" aria-label="Focus ${esc(feature.label)} feature"><span class="fp-icon" role="img" aria-label="${esc(feature.label)}">${icon}</span><span class="fp-name"><b>${esc(feature.label)}</b>${code}${summary}<small class="fp-summary">${laneText}</small></span>${bar(c, Number.isFinite(o) && Number.isFinite(p?.ci_wait) ? o + p.ci_wait : null, u, reason || (!Number.isFinite(p?.ci_wait) ? 'CI state unknown' : null), 'fp-meter')}<span class="fp-numbers"><b>${esc(rowPct)}</b><small>${Number.isFinite(c) ? c : '—'} / ${Number.isFinite(t) ? t : '—'}</small></span><span class="fp-note">${esc(note)}</span></button>`;
  }).join('')}</section>`).join('');
  const legend = '<div class="fp-legend"><span><i class="closed"></i>Closed</span><span><i class="open"></i>Published, open</span><span><i class="unpublished"></i>Planned, not published</span></div>';
  const version = D.feature_progress?.plan_version || 'plan version unavailable';
  const first = values.map(x => x.progress).find(Boolean) || {};
  const rootTitle = first.root_title || 'Feature progress';
  const rootDetails = [first.root_number ? `root #${first.root_number}` : 'root unknown', first.start_date || 'start date unknown', `data as of ${Number.isFinite(observed) ? new Date(observed).toLocaleString() : '—'} · ${ageLabel}`].join(' · ');
  return `<article class="fp-card"><header class="fp-head"><div><h1>${esc(rootTitle)}</h1><p>${esc(rootDetails)}</p></div><div class="fp-overall"><b>${pctText}</b><span>${esc(totalsLine)}</span></div>${bar(closed, opened, unpublished, Number.isFinite(closed) && Number.isFinite(opened) && Number.isFinite(unpublished) ? null : 'Progress unavailable', 'fp-total')}${legend}</header><div class="fp-groups">${rows || '<p>No features available</p>'}</div><footer>Progress is closed / all tickets in the feature, rounded down; closed includes done, failed, and not-planned tickets. Planned counts from ${esc(version)}. ${Number.isFinite(D.feature_progress?.extras) ? D.feature_progress.extras : '—'} published tickets outside the plan are included in totals.</footer></article>`;
}
function renderListImpl() {
  const vp = ctx.vp, rows = () => [...vp.querySelectorAll('.lr[data-id]')], previous = rows();
  if (S.list === 'features') {
    ctx.L = null; ctx.content = null; ctx.R.clear(); ctx.cols = [];
    vp.innerHTML = listHTML(ctx.D, S, H, ctx.snap, nowMs());
    bindOnce(vp); return;
  }
  const focused = document.activeElement?.closest?.('.lr[data-id]'), index = previous.indexOf(focused);
  const moreFocused = document.activeElement?.id === 'lr-more' && vp.contains(document.activeElement);
  const top = vp.getBoundingClientRect().top;
  const anchor = previous.find(el => el.getBoundingClientRect().top >= top);
  const offset = anchor ? anchor.getBoundingClientRect().top - top : null, scroll = vp.scrollTop;
  ctx.L = null; ctx.content = null; ctx.R.clear(); ctx.cols = [];
  if (S.list === 'epics') {
    vp.innerHTML = '<div class="bd-list-placeholder">Epics view is not available yet</div>';
    vp.scrollTop = 0; bindOnce(vp); return;
  }
  vp.innerHTML = listHTML(ctx.D, S, H, ctx.snap, nowMs());
  const all = rows(), next = anchor && all.find(el => el.dataset.id === anchor.dataset.id);
  vp.scrollTop = next ? vp.scrollTop + next.getBoundingClientRect().top - top - offset : scroll;
  if (index >= 0) (all.find(el => el.dataset.id === focused.dataset.id) || all[Math.min(index, all.length - 1)] || vp.querySelector('.bd-list')).focus({ preventScroll: true });
  if (moreFocused) (vp.querySelector('#lr-more') || all.at(-1) || vp.querySelector('.bd-list')).focus({ preventScroll: true });
  bindOnce(vp);
}
function bindOnce(vp) {
  if (ctx.listVp === vp) return;
  ctx.listVp = vp;
  const open = row => { const t = ctx.D.byId[row.dataset.id]; if (t) fx.openModal(t, { origin: row }); };
  ctx.life.on(vp, 'click', e => {
    if (S.view !== 'list') return;
    const btn = e.target.closest('#lr-more');
    if (btn) { earlier(btn); return; }
    const row = e.target.closest('.lr[data-id]'); if (row) open(row);
    const feature = e.target.closest('.fp-row'); if (feature) focusFeature(feature.dataset.feature);
  });
  ctx.life.on(vp, 'keydown', e => {
    if (S.view !== 'list' || e.key !== 'Enter' || (e.target.matches('button') && !e.target.matches('.fp-row'))) return;
    const row = e.target.closest('.lr[data-id]'); if (row) { e.preventDefault(); open(row); }
    const feature = e.target.closest('.fp-row'); if (feature) { e.preventDefault(); focusFeature(feature.dataset.feature); }
  });
}
function focusFeature(key) {
  S.view = 'graph'; S.list = 'tickets'; S.feature = key; S.fmode = 'focus';
  writeURL(); fx.renderTools(); fx.viewport(); fx.relayout();
}
async function earlier(btn) {
  if (H.state === 'loading') return;
  const focused = document.activeElement === btn, life = ctx.life, vp = ctx.vp;
  H.retryArmed = true; btn.disabled = true; btn.setAttribute('aria-busy', 'true');
  await loadEarlier();
  if (ctx.life !== life || life.disposed || ctx.vp !== vp || S.view !== 'list') return;
  renderList();
  if (focused && document.activeElement === document.body) {
    (vp.querySelector('#lr-more') || [...vp.querySelectorAll('.lr[data-id]')].at(-1) || vp.querySelector('.bd-list'))?.focus({ preventScroll: true });
  }
}
Object.assign(fx, { renderList });
