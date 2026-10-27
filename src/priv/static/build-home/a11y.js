import { S, ctx, fx, onReset } from './state.js';
import { agentText } from './agents.js';
import { stText } from './list.js';

let announceTimer = null;
let pendingAnnouncements = new Map();

const finite = (value, low = 0, high = Number.MAX_SAFE_INTEGER) => Number.isFinite(value) && value >= low && value <= high;
const cards = () => [...ctx.R.values(), ...(ctx.L?.band.items ?? []).map(item => item.el)].filter(Boolean);
function reference(ticket) {
  if (ticket.id?.startsWith('pack:') && ticket.num === null) return 'Not filed yet';
  return finite(ticket.num, 1) && Number.isInteger(ticket.num) ? '#' + ticket.num : 'ticket reference unknown';
}
function ticketTitle(ticket) {
  const ref = reference(ticket);
  const title = typeof ticket.title === 'string' && ticket.title.trim() ? ticket.title : 'title unknown';
  return ref === 'Not filed yet' ? ref + '. ' + title : ref + ' ' + title;
}
const stateText = (ticket, data) => {
  if (ticket.sec === 'now') return agentText(ticket, data) ?? 'State unknown';
  const state = stText(ticket);
  const agent = agentText(ticket, data);
  return agent ? state + '. ' + agent : state;
};

export function cardLabel(ticket, data, element) {
  const parts = [ticketTitle(ticket), stateText(ticket, data)];
  parts.push(ticket.sec === 'now' ? (finite(ticket.pct, 0, 100) ? ticket.pct + '% done' : 'progress unknown') : 'progress not applicable');
  parts.push(finite(ticket.cx, 1, 5) && Number.isInteger(ticket.cx) ? 'Complexity ' + ticket.cx + ' of 5' : 'complexity unknown');
  const dependencies = Array.isArray(ticket.deps) ? ticket.deps.length + ' dependencies' : 'dependency count unknown';
  const children = Object.hasOwn(data?.children ?? {}, ticket.id) && Array.isArray(data.children[ticket.id])
    ? 'unblocks ' + data.children[ticket.id].length : 'unblock count unknown';
  parts.push(dependencies + ', ' + children);
  if (element?.classList.contains('ghost')) parts.push('outside feature');
  if (element?.classList.contains('also')) parts.push('also affects');
  if (element?.classList.contains('dim')) parts.push('dimmed by filter');
  return parts.filter(Boolean).join('. ') + '.';
}

export function labelCard(element) {
  const ticket = ctx.D?.byId?.[element.dataset.id];
  if (ticket) element.setAttribute('aria-label', cardLabel(ticket, ctx.D, element));
}

export function readingOrder(layout = ctx.L) {
  if (!layout) return [];
  return ['hist', 'now', 'plan', 'nq'].flatMap(section => {
    const items = section === 'now' ? layout.band.items : layout.secs[section].items;
    return [...items].sort((left, right) => left.y - right.y || left.x - right.x).map(item => ({ ...item, section }));
  });
}

function itemTop(item) {
  const host = item.section === 'now' ? ctx.bandEl : ctx.secs[item.section]?.el;
  return (host?.offsetTop ?? 0) + item.y;
}

function elementFor(id) {
  return cards().find(card => card.dataset.id === id);
}

function focusItem(item) {
  let card = elementFor(item.t.id);
  if (!card) {
    ctx.vp.scrollTop = Math.max(0, itemTop(item) - ctx.vp.clientHeight / 3);
    fx.update(true);
    card = elementFor(item.t.id);
  }
  if (!card) return;
  ctx.a11y.roving = item.t.id;
  ctx.a11y.focusId = item.t.id;
  syncRoving();
  card.focus({ preventScroll: true });
}

function visibleOrder(order) {
  const top = ctx.vp.scrollTop;
  return order.find(item => itemTop(item) >= top) ?? order[0] ?? null;
}

export function syncRoving() {
  if (!ctx.a11y || !ctx.L || S.view === 'list') return;
  const order = readingOrder();
  const ids = new Set(order.map(item => item.t.id));
  const focused = document.activeElement?.closest?.('.bd-card')?.dataset.id ?? null;
  if (focused && ids.has(focused)) {
    ctx.a11y.focusId = focused;
    ctx.a11y.roving = focused;
  } else {
    ctx.a11y.roving = visibleOrder(order)?.t.id ?? null;
  }
  for (const card of cards()) card.tabIndex = card.dataset.id === ctx.a11y.roving ? 0 : -1;
}

function moveCard(key) {
  const order = readingOrder();
  if (!order.length) return;
  const current = document.activeElement?.closest?.('.bd-card')?.dataset.id ?? ctx.a11y.roving;
  const index = Math.max(0, order.findIndex(item => item.t.id === current));
  const target = key === 'Home' ? order[0] : key === 'End' ? order.at(-1) : order[Math.max(0, Math.min(order.length - 1, index + (['ArrowRight', 'ArrowDown'].includes(key) ? 1 : -1)))];
  focusItem(target);
}

function openCard(card) {
  const ticket = ctx.D?.byId?.[card.dataset.id];
  if (!ticket) return;
  if (ctx.lockId && !fx.chainOf(ctx.lockId).has(ticket.id)) return;
  fx.openModal(ticket, { origin: card });
}

export function onCardKeydown(event) {
  const card = event.target.closest?.('.bd-card');
  if (!card) return;
  if (['ArrowRight', 'ArrowDown', 'ArrowLeft', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
    event.preventDefault();
    moveCard(event.key);
    const focused = document.activeElement?.closest?.('.bd-card');
    if (S.trees && !ctx.lockId && focused && !focused.closest('.bd-now')) {
      ctx.a11y.focusHoverId = focused.dataset.id;
      fx.setHover(focused.dataset.id, focused);
    }
    return;
  }
  if (event.key === 'Enter') { event.preventDefault(); openCard(card); return; }
  if (event.key !== ' ') return;
  event.preventDefault();
  if (!S.trees) { openCard(card); return; }
  if (ctx.lockId) fx.unlock(); else fx.lockTree(card.dataset.id);
}

export function onCardFocusIn(event) {
  const card = event.target.closest?.('.bd-card');
  if (!card) return;
  ctx.a11y.focusId = ctx.a11y.roving = card.dataset.id;
  syncRoving();
  if (S.trees && !ctx.lockId && card.matches(':focus-visible') && !card.closest('.bd-now')) {
    ctx.a11y.focusHoverId = card.dataset.id;
    fx.setHover(card.dataset.id, card);
  }
}

export function onCardFocusOut(event) {
  const card = event.target.closest?.('.bd-card');
  if (!card || event.relatedTarget?.closest?.('.bd-card')) return;
  ctx.a11y.focusId = null;
  if (ctx.a11y.focusHoverId === card.dataset.id) {
    ctx.a11y.focusHoverId = null;
    if (!ctx.lockId) fx.setHover(null);
  }
}

function displayAnnouncements() {
  announceTimer = null;
  const region = ctx.root?.querySelector('#bd-state-live');
  const values = [...pendingAnnouncements.values()];
  pendingAnnouncements = new Map();
  if (!region || !values.length) return;
  const text = values.slice(0, 3).join('; ') + (values.length > 3 ? '; and ' + (values.length - 3) + ' more' : '');
  if (region.textContent === text) {
    region.textContent = '';
    requestAnimationFrame(() => { if (region.isConnected) region.textContent = text; });
  } else region.textContent = text;
}

export function announceState(notes) {
  for (const [id, text] of notes ?? []) pendingAnnouncements.set(id, text);
  if (pendingAnnouncements.size && !announceTimer) announceTimer = setTimeout(displayAnnouncements, 160);
}

export function noteDiff(previous, next, message) {
  const notes = [];
  for (const update of message.upsert ?? []) {
    const before = previous?.byId?.[update.id], after = next?.byId?.[update.id];
    if (!after || (before?.sec !== 'now' && after.sec !== 'now')) continue;
    const changed = before?.sec !== after.sec || before?.agent?.state !== after.agent?.state;
    if (!changed) continue;
    notes.push([after.id, reference(after) + ': ' + (after.sec === 'now' ? (agentText(after, next) ?? 'state unknown').replace(/^Agent .*?: /, '') : stText(after))]);
  }
  return notes;
}

export function wireA11y() {
  const { vp, root, life } = ctx;
  vp.setAttribute('role', 'region'); vp.setAttribute('aria-label', 'Build timeline'); vp.tabIndex = -1;
  if (!root.querySelector('#bd-state-live')) {
    const region = document.createElement('p');
    region.id = 'bd-state-live'; region.className = 'sr-only'; region.setAttribute('aria-live', 'polite'); region.setAttribute('aria-atomic', 'true');
    root.appendChild(region);
  }
  life.on(vp, 'keydown', onCardKeydown);
  life.on(vp, 'focusin', onCardFocusIn);
  life.on(vp, 'focusout', onCardFocusOut);
}

onReset(() => {
  if (announceTimer) clearTimeout(announceTimer);
  announceTimer = null; pendingAnnouncements = new Map();
});
