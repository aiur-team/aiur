import { S, ctx, fx, onReset } from './state.js';
import { $, $$, esc } from './dom.js';
import { writeURL } from './url.js';
import { I } from './icons.js';
import { KANBAN_COLUMNS, KANBAN_DEFAULT_COLUMNS, kanbanSize, toggleColumn } from './kanban.js';

const VIEWS = [['kanban', 'Kanban'], ['graph', 'Timeline'], ['gantt', 'Gantt'], ['list', 'List'], ['build-order', 'Build order', 'layers']];
const LISTS = [['tickets', 'Tickets', 'ticket'], ['features', 'Features', 'feature'], ['lanes', 'Lanes', 'layers']];
const FSORTS = [['goal', 'Goal order'], ['pct', 'Most done'], ['left', 'Most left']];
let lastKey = null, bound = false;
onReset(() => { lastKey = null; bound = false; });

function viewButton([view, label, icon]) {
  const on = S.view === view;
  return `<button type="button" data-v="${view}" class="${on ? 'on' : ''}" title="${label}" role="tab" aria-selected="${on}" aria-label="${label}" tabindex="${on ? 0 : -1}">${I[icon ?? view]}<span>${label}</span></button>`;
}
function listButton([list, label, icon]) {
  const on = S.list === list;
  return `<button type="button" data-list="${list}" class="${on ? 'on' : ''}" title="${label}" role="tab" aria-selected="${on}" aria-label="${label}" tabindex="${on ? 0 : -1}">${I[icon]}<span>${label}</span></button>`;
}
function bindOnce(host, right) {
  if (bound) return;
  bound = true;
  ctx.life.on(right, 'click', e => {
    if (e.target.closest('#bd-nowbtn')) { fx.jumpNow(false); return; }
    const col = e.target.closest('[data-kcol]');
    if (col) { if (toggleColumn(S, col.dataset.kcol)) { renderControls(); if (!S.loading) fx.renderKanban(); } return; }
    const size = e.target.closest('[data-ksize]');
    if (size && S.kSize !== size.dataset.ksize) { S.kSize = size.dataset.ksize; renderControls(); if (!S.loading) fx.renderKanban(); }
  });
  ctx.life.on(right, 'change', e => {
    if (!e.target.matches('[data-fsort]')) return;
    S.fsort = e.target.value; writeURL(); fx.renderList();
  });
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
  const span = S.view === 'graph' || S.view === 'gantt' ? fx.spanToolsHTML() : '';
  const kanban = S.view === 'kanban' ? kanbanToolsHTML() : '';
  const key = S.view + '|' + S.list + '|' + S.span + '|' + span + '|' + kanban;
  ctx.root.classList.toggle('feature-list', S.view === 'list' && S.list === 'features');
  ctx.root.classList.toggle('list-view', S.view === 'list');
  ctx.root.classList.toggle('kanban-view', S.view === 'kanban');
  if (lastKey === key) return;
  const active = left.contains(document.activeElement) ? document.activeElement.closest('[data-v], [data-list]') : null;
  const focused = active?.dataset.v ? ['v', active.dataset.v] : active?.dataset.list ? ['list', active.dataset.list] : null;
  lastKey = key;
  left.innerHTML = '<div class="bd-seg vw" role="tablist" aria-label="View">' + VIEWS.map(viewButton).join('') + '</div>' +
    (S.view === 'list' ? '<span class="bd-list-label">List shows</span><div class="bd-seg bd-list-shows" role="tablist" aria-label="List shows">' + LISTS.map(listButton).join('') + '</div>' : '');
  right.innerHTML = '<button class="bd-live" type="button" id="bd-nowbtn" title="Jump to live"><i></i>Live</button>' +
    (S.view === 'list' && S.list === 'features' ? `<label class="fp-sort">Sort <select data-fsort>${FSORTS.map(([key, label]) => `<option value="${key}"${(S.fsort || 'goal') === key ? ' selected' : ''}>${label}</option>`).join('')}</select></label>` : '') + kanban + span;
  if (span) fx.wireSpanTools(right);
  if (focused) $(`[data-${focused[0]}="${focused[1]}"]`, left)?.focus();
}
export function renderStatus() {
  const host = $('#bd-status', ctx.root);
  if (!host) return;
  const daemon = fx.daemonView();
  const key = S.view === 'graph' || S.view === 'gantt' ? '<span class="bd-key"><span class="bd-leg"><span class="bd-leg-l"></span>Cleared</span>' +
    '<span class="bd-leg"><span class="bd-leg-l d"></span>Pending</span>' +
    (S.view === 'gantt' ? '<span class="bd-leg"><span class="bd-leg-h"></span>Planned estimate</span>' : '') + '</span>' : '';
  host.innerHTML = `<span class="bd-daemon${daemon.dotOff ? ' off' : ''}" title="${esc(daemon.dotTitle ?? daemon.dotText)}"><i></i>${esc(daemon.dotText)}</span>` + key;
}
function kanbanToolsHTML() {
  const cols = S.kCols ?? KANBAN_DEFAULT_COLUMNS, size = kanbanSize(S, ctx.root.clientWidth);
  return '<div class="bd-seg kb-cols" role="group" aria-label="Columns">' +
    KANBAN_COLUMNS.map(([key, label]) => `<button type="button" data-kcol="${key}" class="${cols[key] ? 'on' : ''}" aria-pressed="${!!cols[key]}" title="${cols[key] ? 'Hide' : 'Show'} ${label}">${label}</button>`).join('') + '</div>' +
    '<div class="bd-seg" role="group" aria-label="Card size">' +
    [['line', 'S', 'Small cards'], ['full', 'M', 'Medium cards']].map(([key, label, title]) => `<button type="button" data-ksize="${key}" class="${size === key ? 'on' : ''}" aria-pressed="${size === key}" title="${title}">${label}</button>`).join('') + '</div>';
}
export function renderTools() { renderControls(); renderStatus(); }
export function setView(view) {
  if (!VIEWS.some(([value]) => value === view) || S.view === view) return;
  const focusedId = document.activeElement?.closest?.('[data-id]')?.dataset.id ?? null;
  S.view = view; writeURL(); renderTools();
  if (S.loading) return;
  fx.viewport(); fx.relayout(); fx.jumpNow(true);
  if (focusedId) {
    const target = [...ctx.vp.querySelectorAll('[data-id]')].find(element => element.dataset.id === focusedId);
    (target || ctx.vp).focus({ preventScroll: true });
  }
}
export function setList(list) {
  if (!LISTS.some(([value]) => value === list) || S.list === list) return;
  S.list = list; writeURL(); renderTools();
  if (!S.loading && S.view === 'list') fx.renderList();
}
Object.assign(fx, { renderTools, renderStatus, setView, setList });
