import { S, ctx, fx, onReset } from './state.js';
import { $, $$, esc } from './dom.js';
import { writeURL } from './url.js';
import { I } from './icons.js';

const VIEWS = [['graph', 'Timeline'], ['gantt', 'Gantt'], ['list', 'List']];
const LISTS = [['tickets', 'Tickets', 'ticket'], ['features', 'Features', 'feature'], ['epics', 'Epics', 'layers']];
let lastKey = null, bound = false;
onReset(() => { lastKey = null; bound = false; });

function viewButton([view, label]) {
  const on = S.view === view;
  return `<button type="button" data-v="${view}" class="${on ? 'on' : ''}" title="${label}" role="tab" aria-selected="${on}" aria-label="${label}" tabindex="${on ? 0 : -1}">${I[view]}<span>${label}</span></button>`;
}
function listButton([list, label, icon]) {
  const on = S.list === list;
  return `<button type="button" data-list="${list}" class="${on ? 'on' : ''}" title="${label}" role="tab" aria-selected="${on}" aria-label="${label}" tabindex="${on ? 0 : -1}">${I[icon]}<span>${label}</span></button>`;
}
function bindOnce(host, right) {
  if (bound) return;
  bound = true;
  ctx.life.on(right, 'click', e => { if (e.target.closest('#bd-nowbtn')) fx.jumpNow(false); });
  ctx.life.on(host, 'click', e => {
    const button = e.target.closest('[data-v]');
    if (button) setView(button.dataset.v);
    else {
      const list = e.target.closest('[data-list]');
      if (list) setList(list.dataset.list);
    }
  });
  ctx.life.on(host, 'keydown', e => {
    const button = e.target.closest('[data-v], [data-list]');
    const tabs = button ? $$(`[data-${button.hasAttribute('data-list') ? 'list' : 'v'}]`, button.parentElement) : [];
    const index = tabs.indexOf(button);
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
  const key = S.view + '|' + S.list + '|' + S.span + '|' + span;
  if (lastKey === key) return;
  const active = left.contains(document.activeElement) ? document.activeElement.closest('[data-v], [data-list]') : null;
  const focused = active?.dataset.v ? ['v', active.dataset.v] : active?.dataset.list ? ['list', active.dataset.list] : null;
  lastKey = key;
  left.innerHTML = '<div class="bd-seg vw" role="tablist" aria-label="View">' + VIEWS.map(viewButton).join('') + '</div>' +
    (S.view === 'list' ? '<span class="bd-list-label">List shows</span><div class="bd-seg bd-list-shows" role="tablist" aria-label="List shows">' + LISTS.map(listButton).join('') + '</div>' : '');
  right.innerHTML = '<button class="bd-live" type="button" id="bd-nowbtn" title="Jump to live"><i></i>Live</button>' + span;
  if (span) fx.wireSpanTools(right);
  if (focused) $(`[data-${focused[0]}="${focused[1]}"]`, left)?.focus();
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
export function setList(list) {
  if (!LISTS.some(([value]) => value === list) || S.list === list) return;
  S.list = list; writeURL(); renderTools();
  if (!S.loading && S.view === 'list') fx.renderList();
}
Object.assign(fx, { renderTools, renderStatus, setView, setList });
