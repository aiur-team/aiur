import { S, ctx, fx, onReset } from '../state.js';
import { writeURL } from '../url.js';
import { $, $$ } from '../dom.js';
import { trap, restore } from './focus.js';
import { bodyKind, headerHTML, errorHTML } from './header.js';

export const MS = { t: null, req: 0, origin: null, state: null };
const closers = new Set();
let id = null, originId = null, pendingTimer = null;
export const onModalClose = fn => { closers.add(fn); return () => closers.delete(fn); };
const shown = () => $('#tk-backdrop')?.classList.contains('show');
function cleanup() {
  clearTimeout(pendingTimer); pendingTimer = null;
  closers.forEach(fn => fn()); $('#tk-body')?.replaceChildren();
}
function begin(nextId, origin) {
  if (!shown() && !MS.origin) { MS.origin = origin || null; originId = origin?.dataset.id || null; }
  cleanup(); id = nextId; MS.t = null;
  return ++MS.req;
}
function remember(nextId) {
  const ticket = /^[0-9]{1,10}$/.test(nextId) && Number(nextId) > 0 ? String(Number(nextId)) : '';
  if (S.ticket !== (ticket || null)) writeURL({ ticket });
}
function show({ focusTitle = true } = {}) {
  const modal = $('#tk-modal');
  modal.classList.add('bdm'); modal.removeAttribute('aria-label'); modal.setAttribute('aria-labelledby', 'bm-title');
  $('#tk-backdrop').classList.add('show'); document.body.style.overflow = 'hidden';
  if (focusTitle) ctx.life.frame('modal-focus', () => { if (shown()) $('#bm-title')?.focus(); });
}
export function renderHead(t) {
  const active = document.activeElement, inside = $('#tk-head').contains(active);
  const key = inside ? { id: active.id, action: active.dataset.a } : null;
  $('#tk-head').innerHTML = headerHTML(t);
  if (key) {
    const candidate = $$('#tk-head [id], #tk-head [data-a]').find(el => key.id ? el.id === key.id : el.dataset.a === key.action);
    if (candidate) candidate.focus(); else $('#bm-title').focus();
  }
}
function renderRow(t, opts) {
  MS.t = t; MS.state = 'row'; id = t.id;
  const preserveHeaderFocus = shown() && $('#tk-head').contains(document.activeElement);
  renderHead(t);
  fx[bodyKind(t) === 'conversation' ? 'renderConversation' : 'renderDocBody'](t, $('#tk-body'), opts);
  show({ focusTitle: !preserveHeaderFocus }); remember(t.id);
}
function error(nextId, state, reason) {
  MS.t = null; MS.state = state; id = nextId;
  $('#tk-head').innerHTML = errorHTML(nextId, state, reason);
  $('#tk-body').replaceChildren(); show(); remember(nextId);
}
function notice(event, payload) {
  if (ctx.socket === 'up') ctx.push(event, payload).catch(() => {
    if (ctx.root) ctx.root.dataset.modalNotice = 'disconnected';
  });
}
export function openModal(t, opts = {}) {
  if (!t) return;
  begin(t.id, opts.origin); renderRow(t, opts);
  notice('open-ticket', { id: t.id, loaded: true });
}
export async function openById(nextId, opts = {}) {
  const row = ctx.D?.byId[nextId];
  if (row) return openModal(row, opts);
  const req = begin(nextId, opts.origin), life = ctx.life;
  if (ctx.socket !== 'up') { error(nextId, 'unavailable', 'disconnected'); return; }
  let reply;
  try {
    reply = await Promise.race([ctx.push('open-ticket', { id: nextId }), new Promise(resolve => {
      pendingTimer = setTimeout(() => resolve({ kind: 'error', reason: 'client_timeout' }), 10_000);
    })]);
  } catch { reply = { kind: 'error', reason: 'disconnected' }; }
  if (req !== MS.req || life !== ctx.life || life.disposed) return;
  clearTimeout(pendingTimer); pendingTimer = null;
  const t = ctx.D?.byId[nextId] || (reply?.kind === 'ticket' && reply.row?.id === nextId ? reply.row : null);
  if (t) renderRow(t, opts);
  else error(nextId, reply?.reason === 'not_found' ? 'not_found' : 'unavailable', reply?.reason);
}
export function openFromURL() { if (S.ticket) return openById(S.ticket); }
export function closeModal({ url = true, notify = true, focus = true } = {}) {
  const origin = MS.origin, savedId = originId;
  MS.req++; cleanup();
  $('#tk-backdrop')?.classList.remove('show'); $('#tk-modal')?.classList.remove('bdm');
  document.body.style.overflow = '';
  MS.t = null; MS.origin = null; MS.state = null; id = null; originId = null;
  if (focus) restore(origin, savedId);
  if (notify) notice('close-ticket', {});
  if (url && S.ticket) writeURL({ ticket: '' });
}
export function syncTicket(nextId) { if (nextId) return openById(nextId); closeModal({ url: false }); }
export function modalSync(msg) {
  if (!shown() || !id) return;
  if (msg.upsert?.some(t => t.id === id)) {
    MS.t = ctx.D.byId[id]; MS.state = 'row'; renderHead(MS.t);
  } else if (msg.remove?.includes(id)) { cleanup(); error(id, 'not_found'); }
  else if (MS.t && ['repo', 'epics', 'features'].some(key => Object.hasOwn(msg.set || {}, key))) renderHead(MS.t);
}
async function copyLink(button) {
  const req = MS.req, url = new URL(location.href);
  if (Number.isFinite(MS.t?.num)) url.searchParams.set('ticket', String(MS.t.num)); else url.searchParams.delete('ticket');
  let copied = false;
  try { await navigator.clipboard.writeText(url.href); copied = true; } catch { /* Plain HTTP uses the selection fallback. */ }
  if (req !== MS.req || !shown()) return;
  if (!copied) {
    const input = document.createElement('textarea'), active = document.activeElement;
    input.value = url.href; input.style.cssText = 'position:fixed;left:-9999px'; document.body.append(input); input.select();
    try { copied = document.execCommand('copy'); } catch { copied = false; }
    input.remove(); active?.focus();
  }
  if (!button.isConnected) return;
  button.classList.toggle('ok', copied); button.title = copied ? 'Copied' : 'Copy failed · ' + url.href;
  button.setAttribute('aria-label', copied ? 'Link copied' : 'Copy link');
}
export function initModal() {
  const back = $('#tk-backdrop');
  ctx.life.on(back, 'click', event => {
    if (event.target === back || event.target.closest('#bd-tk-close')) closeModal();
    else if (event.target.closest('[data-goto]')) { event.preventDefault(); openById(event.target.closest('[data-goto]').dataset.goto); }
    else if (event.target.closest('[data-a="link"]')) copyLink(event.target.closest('[data-a="link"]'));
  });
  ctx.life.on(document, 'keydown', event => {
    if (!shown()) return;
    if (event.key === 'Escape') { event.preventDefault(); closeModal(); } else trap(event, $('#tk-modal'));
  }, { capture: true });
  ctx.life.cleanup(() => closeModal({ url: false, notify: false, focus: false }));
}
onReset(() => {
  MS.req++; clearTimeout(pendingTimer); pendingTimer = null;
  MS.t = null; MS.origin = null; MS.state = null; id = null; originId = null;
  if (typeof document !== 'undefined') {
    document.body.style.overflow = ''; $('#tk-backdrop')?.classList.remove('show'); $('#tk-modal')?.classList.remove('bdm');
  }
});
Object.assign(fx, { initModal, openModal, closeModal, openFromURL, syncTicket, modalSync });
