import { ctx } from '../state.js';
import { rowState, modelInfo } from '../agents.js';
import { esc } from '../dom.js';
import { I, MI } from '../icons.js';

export const bodyKind = t => t.agent && t.start != null ? 'conversation' : 'doc';
const number = t => Number.isFinite(t.num) ? '#' + t.num : '—';
const close = () => '<button class="bm-ib bm-x" id="bd-tk-close" type="button" aria-label="Close">' + I.x + '</button>';
const title = t => '<h3 id="bm-title" tabindex="-1" data-dialog-heading><span class="bm-num"' +
  (Number.isFinite(t.num) ? '' : ' title="Not filed yet"') + '>' + number(t) + '</span>' + esc(t.title) + '</h3>';
const lookup = (map, key) => map && Object.hasOwn(map, key) ? map[key] : null;

function status(t) {
  if (t.sec === 'now') { const ag = rowState(t); return { label: ag.label, tone: ag.cls || 'idle' }; }
  if (t.sec === 'hist') {
    const states = { done: ['Merged', 'done'], failed: ['Failed', 'stuck'], not_planned: ['Not planned', 'idle'], closed: ['Closed', 'idle'] };
    const [label, tone] = lookup(states, t.status) || ['State unknown', 'idle']; return { label, tone };
  }
  if (t.sec === 'plan') return { label: t.num == null ? 'Planned · not filed' : 'Queued · Q' + (Number.isFinite(t.qpos) ? t.qpos : '?') , tone: 'idle' };
  return { label: t.sec === 'nq' ? 'Not queued' : 'State unknown', tone: 'idle' };
}
function agent(t) {
  if (!t.agent) return '';
  const m = modelInfo(t.agent.model), name = t.agent.name || m.name;
  const live = t.sec === 'now' && ['active', 'paused'].includes(t.agent.state), paused = t.agent.state === 'paused';
  return '<div class="bm-agent" title="' + esc(name + (t.agent.effort == null ? '' : ' · ' + t.agent.effort + ' effort')) + '">' +
    (m.logo ? '<img src="' + esc(m.logo.src) + '" alt="">' : '<span class="ax-mono" aria-hidden="true">' + esc(m.mono) + '</span>') +
    '<span>' + esc(name) + '</span>' +
    (live ? '<button class="bm-ib" type="button" data-a="pause" disabled title="' + (paused ? 'Resume agent' : 'Pause agent') + '">' + (paused ? MI.play : MI.pause) + '</button>' : '') +
    (bodyKind(t) === 'conversation' ? '<button class="bm-ib" type="button" data-a="chat" disabled title="Open in Conversations">' + MI.expand + '</button>' : '') + '</div>';
}
function repositoryURL() {
  try { const url = new URL(ctx.D?.repo?.url); return ['https:', 'http:'].includes(url.protocol) ? url.href : null; }
  catch { return null; }
}
function links(t) {
  const repo = repositoryURL(), filed = Number.isFinite(t.num);
  const issue = !filed ? '<span class="bm-ib" data-a="none" aria-disabled="true">' + I.docs + '</span>' : repo ?
    '<a class="bm-ib" href="' + esc(repo + 'issues/' + t.num) + '" target="_blank" rel="noopener" title="Issue #' + t.num + '" aria-label="Issue #' + t.num + ' on GitHub">' + I.github + '</a>' : '';
  const pr = repo && t.pr && Number.isFinite(t.pr.num) && ['open', 'merged', 'closed'].includes(t.pr.state) ?
    '<a class="bm-pr ' + t.pr.state + '" href="' + esc(repo + 'pull/' + t.pr.num) + '" target="_blank" rel="noopener" title="Pull request · ' + t.pr.state + '">' + I.pr + '#' + t.pr.num + '</a>' : '';
  return '<div class="bm-links">' + issue + pr + '<button class="bm-ib" type="button" data-a="link" title="Copy link" aria-label="Copy link">' + I.link + '</button></div>';
}
export function headerHTML(t) {
  const e = lookup(ctx.D?.epics, t.epic || 'unsorted') || lookup(ctx.D?.epics, 'unsorted'), f = lookup(ctx.D?.features, t.feature), st = status(t);
  const known = Number.isFinite(t.pct) && t.pct >= 0 && t.pct <= 100;
  return '<div class="bm-h"><span class="bm-ep"' + (Number.isFinite(e?.hue) ? ' style="--h:' + e.hue + '"' : '') + ' title="' + esc(e?.label || 'Unsorted') + '">' + (lookup(I, e?.icon) || '') + '</span>' +
    '<div class="bm-tt">' + title(t) + '<div class="bm-meta"><span class="bm-st ' + st.tone + '"' +
    (t.sec === 'plan' && t.num != null && !Number.isFinite(t.qpos) ? ' title="Queue position unknown"' : '') +
    (t.sec === 'now' && known ? ' style="--ph:' + Math.round(42 + t.pct * 1.03) + '"' : '') + '><i></i>' + st.label +
    (t.sec === 'now' ? ' · <b id="bm-pct"' + (known ? '' : ' data-unknown="pct" title="Progress unknown"') + '>' + (known ? t.pct : '?') + '%</b>' : '') + '</span><span>' + esc(e?.label || 'Unsorted') + '</span>' +
    (t.feature ? '<span' + (f ? '' : ' title="Feature not in the loaded catalog"') + '>◆ ' + esc(f?.label || t.feature) + '</span>' : '') +
    '<span' + (Number.isFinite(t.pts) ? '' : ' data-unknown="pts"') + '>' + (Number.isFinite(t.pts) ? t.pts : '?') + ' pts</span></div></div>' +
    '<div class="bm-act">' + agent(t) + links(t) + close() + '</div></div>';
}
export function errorHTML(id, state, reason) {
  const words = { unavailable: 'source unavailable', invalid_params: 'invalid ticket id', client_timeout: 'timed out', disconnected: 'connection lost' };
  return '<div class="bm-h"><div class="bm-tt">' + title({ num: Number(id), title: state === 'not_found' ? 'Ticket not found' : 'Ticket unavailable' }) +
    (state === 'unavailable' ? '<div class="bm-meta">' + (lookup(words, reason) || 'unknown cause') + '</div>' : '') + '</div><div class="bm-act">' + close() + '</div></div>';
}
