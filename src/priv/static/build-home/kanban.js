/**
 * The Kanban view: the build as a left-to-right board.
 *
 * Columns are the sections the payload already carries, in board order:
 * Backlog (open, not queued), To do (the build queue, in queue order),
 * In progress (running) and Done (closed, newest first). Cards are the
 * timeline's own cards (`makeCard`) at the small (`line`) or medium (`full`)
 * tier, so a ticket looks the same here as on the timeline.
 *
 * To do and In progress show by default; Backlog and Done are toggled from the
 * toolbar. Done shows the loaded history in steps of `DONE_STEP`.
 */
import { S, ctx, fx } from './state.js';
import { esc } from './dom.js';
import { rowOk } from './filters.js';
import { match } from './match.js';
import { makeCard } from './cards.js';
import { timed } from './perf.js';

export const KANBAN_COLUMNS = [['nq', 'Backlog'], ['plan', 'To do'], ['now', 'In progress'], ['hist', 'Done']];
export const KANBAN_DEFAULT_COLUMNS = Object.freeze({ nq: false, plan: true, now: true, hist: false });
export const DONE_STEP = 40;
// Below this board width the small card leaves room for two to three columns.
const SMALL_BELOW = 700;

export const renderKanban = timed('renderKanban', renderKanbanImpl);

/** The visible columns for one state: which tickets, in board order, and how many Done holds back. */
export function kanbanColumns(D, state) {
  const keep = t => rowOk(state, t) && match(t, state);
  const visible = state.kCols ?? KANBAN_DEFAULT_COLUMNS;
  const shown = state.kDone || DONE_STEP;
  return KANBAN_COLUMNS.filter(([key]) => visible[key]).map(([key, label]) => {
    const all = key === 'hist'
      ? D.hist.filter(t => t.end >= (state.histFrom || 0) && keep(t)).sort((a, b) => b.end - a.end)
      : D[key].filter(keep);
    const tickets = key === 'hist' ? all.slice(0, shown) : all;
    return { key, label, count: all.length, tickets, more: Math.min(all.length - tickets.length, DONE_STEP) };
  });
}

/** The card tier: the operator's choice, else small on a narrow board and medium otherwise. */
export function kanbanSize(state, width) {
  return state.kSize || (width < SMALL_BELOW ? 'line' : 'full');
}

/** Toggles one column; the last visible column stays, so the board is never empty. */
export function toggleColumn(state, key) {
  const cols = { ...(state.kCols ?? KANBAN_DEFAULT_COLUMNS) };
  if (cols[key] && Object.values(cols).filter(Boolean).length === 1) return false;
  cols[key] = !cols[key];
  state.kCols = cols;
  return true;
}

function renderKanbanImpl() {
  const vp = ctx.vp;
  const focused = document.activeElement?.closest?.('.kb .bd-card')?.dataset.id ?? null;
  const scroll = vp.querySelector('.kb')?.scrollLeft ?? 0;
  ctx.L = null; ctx.content = null; ctx.R.clear(); ctx.cols = [];
  const det = kanbanSize(S, ctx.root.clientWidth);
  const board = document.createElement('div');
  board.className = 'kb';
  board.setAttribute('role', 'region');
  board.setAttribute('aria-label', 'Kanban board');
  for (const col of kanbanColumns(ctx.D, S)) {
    const sec = document.createElement('section');
    sec.className = 'kb-col';
    sec.dataset.col = col.key;
    sec.setAttribute('aria-label', col.label + ', ' + col.count + (col.count === 1 ? ' ticket' : ' tickets'));
    sec.innerHTML = '<h3 class="kb-h">' + (col.key === 'now' ? '<i class="lh-live" aria-hidden="true"></i>' : '') +
      esc(col.label) + '<em>' + col.count.toLocaleString() + '</em></h3>';
    for (const t of col.tickets) {
      const card = makeCard({ t, sec: t.sec, kb: true, det });
      card.tabIndex = 0;
      sec.appendChild(card);
    }
    if (!col.count) sec.insertAdjacentHTML('beforeend', '<div class="kb-empty">No tickets</div>');
    if (col.more > 0) sec.insertAdjacentHTML('beforeend', '<button type="button" class="lr-more kb-more">Show ' + col.more + ' more</button>');
    board.appendChild(sec);
  }
  vp.replaceChildren(board);
  board.scrollLeft = scroll;
  if (focused) board.querySelector('.bd-card[data-id="' + CSS.escape(focused) + '"]')?.focus({ preventScroll: true });
  bindOnce(vp);
}

function bindOnce(vp) {
  if (ctx.kanbanVp === vp) return;
  ctx.kanbanVp = vp;
  const open = card => { const t = ctx.D.byId[card.dataset.id]; if (t) fx.openModal(t, { origin: card }); };
  ctx.life.on(vp, 'click', e => {
    if (S.view !== 'kanban') return;
    if (e.target.closest('.kb-more')) { S.kDone = (S.kDone || DONE_STEP) + DONE_STEP; renderKanban(); return; }
    if (e.target.closest('.bd-hold')) return;
    const card = e.target.closest('.kb .bd-card[data-id]');
    if (card) open(card);
  });
  ctx.life.on(vp, 'keydown', e => {
    if (S.view !== 'kanban' || (e.key !== 'Enter' && e.key !== ' ') || e.target.matches('button')) return;
    const card = e.target.closest('.kb .bd-card[data-id]');
    if (card) { e.preventDefault(); open(card); }
  });
}

Object.assign(fx, { renderKanban });
