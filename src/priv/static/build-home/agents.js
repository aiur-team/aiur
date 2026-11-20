import { LOGOS } from './logos.js';
import { esc } from './dom.js';
import { agentState, modelLabel } from './now-state.js';
import { fmtT } from './util.js';
import { nowMs } from './clock.js';
import { ctx, onReset } from './state.js';
let holdTick = false;
onReset(() => { holdTick = false; });

export function rowState(t) {
  const state = t.sec === 'now' ? agentState(t.agent?.state) : null;
  return nativeHold(t) ? { ...state, label: state.label + ' · ' + holdAge(nativeHold(t)?.since) } : state;
}
export function nativeHold(t) {
  return t.sec === 'now' && t.agent?.state === 'native_question' ? t.agent.native_hold : null;
}
function holdAge(since) {
  const now = nowMs();
  return Number.isFinite(since) && Number.isFinite(now) ? 'for ' + Math.floor(Math.max(0, now - since) / 60000) + ' min' : 'duration unavailable';
}
export function holdLinkHTML(t) {
  const hold = nativeHold(t);
  if (hold && !holdTick && ctx.life) {
    ctx.life.every(60000, () => document.querySelectorAll('.bd-hold').forEach(el => {
      const since = el.dataset.since === '' ? null : Number(el.dataset.since);
      el.textContent = agentState('native_question').label + ' · ' + holdAge(since);
    }));
    holdTick = true;
  }
  return hold ? '<a data-since="' + esc(hold.since ?? '') + '" class="bd-hold" href="/commands/' + encodeURIComponent(hold.decision_id) + '">' + esc(rowState(t).label) + '</a>' : '';
}
export function modelInfo(key) {
  const k = typeof key === 'string' && key !== '' ? key : null;
  return {
    name: k ? modelLabel({ model: k, name: null }) || k : 'Model unknown',
    logo: k && Object.hasOwn(LOGOS, k) ? LOGOS[k] : null,
    mono: k ? k.charAt(0).toUpperCase() : '?',
  };
}
function who(t) {
  const m = modelInfo(t.agent?.model);
  return { m, name: modelLabel(t.agent) || m.name };
}
export function agentClasses(t, det) {
  const ag = rowState(t);
  return { ag: ag?.cls ? 'ag-' + ag.cls : null, hasAg: !!t.agent && det === 'full' };
}
export function glowHTML(t) {
  return rowState(t)?.cls ? '<span class="bd-glow"></span>' : '';
}
export function logoHTML(t, det) {
  if (!t.agent || det !== 'full') return '';
  const { m, name } = who(t), ag = rowState(t);
  const title = esc(name + (ag ? ' · ' + ag.label : ''));
  const inner = m.logo ? '<img src="' + esc(m.logo.src) + '" alt="">' : '<span class="ax-mono">' + esc(m.mono) + '</span>';
  return '<span class="bd-ag' + (m.logo?.fill ? ' fill' : '') + '" title="' + title + '" aria-hidden="true">' + inner + '</span>';
}
export function lineLogoHTML(t) {
  const { m, name } = who(t);
  return m.logo ? '<img class="bd-lg" src="' + esc(m.logo.src) + '" alt="" aria-hidden="true" title="' + esc(name) + '">' :
    '<span class="bd-lg ax-mono" aria-hidden="true" title="' + esc(name) + '">' + esc(m.mono) + '</span>';
}
export function agentText(t, D) {
  const ag = rowState(t);
  if (!t.agent && !ag) return null;
  const head = t.agent ? 'Agent ' + who(t).name : 'Agent';
  return ag ? head + ': ' + (ag.cls ? ag.label : 'state unknown') + staleSuffix(D) : head;
}
export function srHTML(t, D) {
  const text = agentText(t, D);
  return text ? '<span class="sr-only">' + esc(text) + '</span>' : '';
}
function staleSuffix(D) {
  const d = D.daemon || {}, a = D.sources?.agents || {};
  const at = ms => Number.isFinite(ms) ? ', as of ' + fmtT(ms) : ', state age unknown';
  if (d.state === 'offline' || d.state === 'stale') return at(d.heartbeat_at);
  if (d.state !== 'live') return ', state age unknown';
  return a.state !== 'ok' ? at(a.observed_at) : '';
}
