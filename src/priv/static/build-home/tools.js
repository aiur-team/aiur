import { S, ctx, fx, onReset } from './state.js';
import { $, $$, esc } from './dom.js';
import { writeURL } from './url.js';
import { I } from './icons.js';

const VIEWS = [['graph', 'Timeline'], ['gantt', 'Gantt'], ['list', 'List']];
let lastKey = null, bound = false;
onReset(() => { lastKey = null; bound = false; });

function viewButton([view, label]) {
  const on = S.view === view;
  return `<button type="button" data-v="${view}" class="${on ? 'on' : ''}" title="${label}" role="tab" aria-selected="${on}" aria-label="${label}" tabindex="${on ? 0 : -1}">${I[view]}<span>${label}</span></button>`;
}
function bindOnce(host, right) {
  if (bound) return;
  bound = true;
  ctx.life.on(right, 'click', e => { if (e.target.closest('#bd-nowbtn')) fx.jumpNow(false); });
  ctx.life.on(host, 'click', e => {
    const button = e.target.closest('[data-v]');
    if (button) setView(button.dataset.v);
  });
  ctx.life.on(host, 'keydown', e => {
    const tabs = $$('[data-v]', host), index = tabs.indexOf(e.target.closest('[data-v]'));
    if (index < 0) return;
    const next = { ArrowRight: (index + 1) % tabs.length, ArrowLeft: (index + tabs.length - 1) % tabs.length,
      Home: 0, End: tabs.length - 1 }[e.key];
    if (next === undefined) return;
    e.preventDefault(); tabs[next].focus();
  });
}
function renderControls() {
  const left = $('#bd-tools-l', ctx.root), right = $('#bd-tools', ctx.root);
  if (!left || !right) return;
  bindOnce(left, right);
  const span = S.view === 'list' ? '' : fx.spanToolsHTML();
  const key = S.view + '|' + S.span + '|' + span;
  if (lastKey === key) return;
  const focused = left.contains(document.activeElement) ? document.activeElement.closest('[data-v]')?.dataset.v : null;
  lastKey = key;
  left.innerHTML = '<div class="bd-seg vw" role="tablist" aria-label="View">' + VIEWS.map(viewButton).join('') + '</div>';
  right.innerHTML = '<button class="bd-live" type="button" id="bd-nowbtn" title="Jump to live"><i></i>Live</button>' + span;
  if (span) fx.wireSpanTools(right);
  if (focused) $(`[data-v="${focused}"]`, left).focus();
}
export function renderStatus() {
  const host = $('#bd-status', ctx.root);
  if (!host) return;
  const daemon = fx.daemonView();
  const key = S.view === 'list' ? '' : '<span class="bd-key"><span class="bd-leg"><span class="bd-leg-l"></span>Cleared</span>' +
    '<span class="bd-leg"><span class="bd-leg-l d"></span>Pending</span>' +
    (S.view === 'gantt' ? '<span class="bd-leg"><span class="bd-leg-h"></span>Planned estimate</span>' : '') + '</span>';
  host.innerHTML = `<span class="bd-daemon${daemon.dotOff ? ' off' : ''}" title="${esc(daemon.dotTitle ?? daemon.dotText)}"><i></i>${esc(daemon.dotText)}</span>` + key;
}
export function renderTools() { renderControls(); renderStatus(); }
export function setView(view) {
  if (!VIEWS.some(([value]) => value === view) || S.view === view) return;
  S.view = view; writeURL(); renderTools();
  if (S.loading) return;
  fx.viewport(); fx.relayout(); fx.jumpNow(true);
}
Object.assign(fx, { renderTools, renderStatus, setView });
