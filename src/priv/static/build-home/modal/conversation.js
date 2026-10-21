import { ctx, fx, onReset } from '../state.js';
import { $, esc } from '../dom.js';
import { MI } from '../icons.js';
import { modelInfo } from '../agents.js';
import { MS, registerBody, bodyRenderer, onModalClose } from './frame.js';
import { itemEl } from './conversation-items.js';
import { footer, notRetainedCue } from './conversation-footer.js';
export { itemEl, notRetainedCue };
export const MAX_DOM = 500;
let open = null, sequence = 0;
export const trimmedBottom = () => open?.trimmed || false;
const current = ref => ref === open && ref.req === sequence && MS.t?.id === ref.id && ctx.life === ref.life && !ref.life.disposed;
function close() {
  const previous = open; open = null; sequence++;
  previous?.renderOff?.(); previous?.offs.forEach(off => off());
  if (previous && ctx.socket === 'up') ctx.push('conversation-close', { id: previous.id }).catch(() => {});
}
onModalClose(close); onReset(() => { open?.renderOff?.(); open?.offs.forEach(off => off()); open = null; sequence++; });
function rows() { return Array.from($('#cv-log')?.children || []).filter(el => el.hasAttribute('data-k')); }
function trim(from) {
  const items = rows();
  while (items.length > MAX_DOM) (from === 'top' ? items.shift() : items.pop()).remove();
  if (from === 'top' && items.length) { open.before = items[0].dataset.cursor; open.more = true; }
}
function find(id) { return rows().find(el => el.dataset.eid === id); }
export function appendEntries(entries) {
  const ref = open, log = $('#cv-log');
  if (!ref || !log || ref.trimmed) return [];
  const added = [];
  for (const entry of entries) {
    const el = itemEl(entry, ref.model); if (!el) continue;
    const existing = find(entry.id) || (entry.k === 'op' ? fx.claimLocalOp(entry) : null);
    if (existing) existing.replaceWith(el); else log.append(el);
    added.push(el);
  }
  if (rows().length > MAX_DOM) trim('top');
  if (rows().length) log.querySelector('[data-empty]')?.remove();
  fx.scheduleMap(); return added;
}
export const appendItem = entry => fx.appendEntries([entry]);
export function prependEntries(msg) {
  const log = $('#cv-log'); if (!open || !log) return;
  const height = log.scrollHeight, top = log.scrollTop, fragment = document.createDocumentFragment();
  for (const entry of msg.entries) { if (!find(entry.id)) { const el = itemEl(entry, open.model); if (el) fragment.append(el); } }
  open.loadingRow?.remove(); open.loadingRow = null;
  log.prepend(fragment); open.before = msg.before; open.more = msg.more;
  const anchored = top + log.scrollHeight - height;
  if (rows().length > MAX_DOM) { trim('bottom'); open.trimmed = true; }
  log.scrollTop = anchored; fx.scheduleMap();
}
function state(msg) {
  if (!open) return;
  open.msg = { ...open.msg, ...msg };
  const slot = $('#cv-footer'); if (!slot) return;
  const value = footer(open.ticket, open.msg);
  slot.className = value.text ? 'cv-end' : ''; slot.textContent = value.text; slot.title = value.title || '';
  const log = $('#cv-log');
  if (msg.state === 'known_empty' && !rows().length && !log.querySelector('[data-empty]')) {
    const row = document.createElement('div'); row.className = 'cv-end'; row.dataset.empty = ''; row.textContent = 'No messages yet'; log.append(row);
  } else if (msg.state !== 'known_empty') log.querySelector('[data-empty]')?.remove();
}
export function renderConversation(msg, t = open?.ticket, model = open?.model) {
  if (!open || !t) return;
  const body = $('#tk-body'); open.renderOff?.();
  if (msg.state === 'not_retained') {
    const doc = bodyRenderer('doc');
    if (doc) doc(t, body, { note: 'Conversation not retained' }); else body.innerHTML = notRetainedCue();
    return;
  }
  body.innerHTML = '<div class="cv"><div class="cv-main"><div class="cv-log" id="cv-log"></div>' +
    '<button class="cv-new" type="button" id="cv-new" hidden>' + MI.down + 'New activity</button>' +
    '<div class="cv-typing" id="cv-typing" hidden><i></i><i></i><i></i>' + esc(model.name) + ' is working</div><div id="cv-footer"></div></div>' +
    '<div class="cv-map" id="cv-map" title=""><div class="mm" id="cv-mm"></div><div class="mm-vw" id="cv-vw"></div><div class="mm-tip" id="cv-tip"></div></div></div>';
  open.pending = false; open.failed = false; open.trimmed = false; open.before = msg.before; open.more = msg.more; open.msg = msg;
  const fragment = document.createDocumentFragment();
  for (const entry of msg.entries) { const el = itemEl(entry, model); if (el) fragment.append(el); }
  $('#cv-log').append(fragment); renderNote(msg); if (rows().length > MAX_DOM) trim('top'); state(msg);
  const ref = open;
  ref.renderOff = ref.life.on($('#cv-log'), 'scroll', () => {
    if (current(ref) && $('#cv-log').scrollTop <= 120 && ref.more && !ref.pending && !ref.failed) older();
  }, { passive: true });
  ref.life.frame('conversation-bottom', () => { if (current(ref) && $('#cv-log')) $('#cv-log').scrollTop = $('#cv-log').scrollHeight; });
  fx.wireLive(t, model);
}
async function request(ref, before) {
  const serial = ++ref.serial;
  try {
    const reply = await ctx.push('conversation-page', { id: ref.id, before });
    if (!current(ref) || serial !== ref.serial) return null;
    if (reply?.v === 1 && reply.kind === 'error') return reply;
    if (reply?.id !== ref.id || reply.v !== 1) return null;
    return reply;
  } catch { return null; }
}
export async function requestTail() {
  const ref = open; if (!ref) return; ref.pending = true;
  const reply = await request(ref, null);
  if (current(ref)) ref.pending = false;
  if (reply?.kind === 'conversation') renderConversation(reply);
  else if (current(ref) && !$('#cv-log')) $('#tk-body').innerHTML = '<div class="cv-end">Conversation unavailable</div>';
}
async function older() {
  const ref = open; if (!ref || ref.pending || !ref.more) return;
  ref.pending = true; ref.failed = false;
  const row = document.createElement('div'); row.className = 'cv-end'; row.setAttribute('role', 'status'); row.textContent = 'Loading earlier…';
  ref.loadingRow?.remove(); ref.loadingRow = row; $('#cv-log').prepend(row);
  const reply = await request(ref, ref.before);
  if (!current(ref)) return;
  ref.pending = false;
  if (reply?.kind === 'conversation-earlier') prependEntries(reply);
  else if (reply?.kind === 'conversation') renderConversation(reply);
  else if (reply?.reason === 'invalid_params') requestTail();
  else {
    ref.failed = true; row.textContent = 'Could not load earlier entries ';
    const button = document.createElement('button'); button.type = 'button'; button.textContent = 'Retry';
    ref.offs.push(ref.life.on(button, 'click', older)); row.append(button);
  }
}
export function receiveConversation(msg) {
  if (!open || !current(open) || msg?.v !== 1 || msg.id !== open.id) return;
  if (msg.kind === 'conversation') renderConversation(msg);
  else if (msg.kind === 'conversation-append') { fx.appendEntries(msg.entries); if (msg.entries.length) state({ entries: msg.entries }); }
  else if (msg.kind === 'conversation-state') {
    if (msg.state === 'not_retained') renderConversation({ ...open.msg, ...msg, entries: [] }); else state(msg);
  }
  else return;
  fx.onConversation({ id: msg.id, entries: msg.entries || [], state: msg.state, gap: msg.gap || false });
}
function renderNote(msg) {
  const words = { live_window: 'Only the latest messages are shown', legacy_log: 'Older entries are in a legacy log and are not shown', remote_window: (msg.evicted || 0) + ' earlier messages are not kept for remote workers' };
  if (!Object.hasOwn(words, msg.note)) return;
  const row = document.createElement('div'); row.className = 'cv-end'; row.textContent = words[msg.note]; $('#cv-log').prepend(row);
}
function start(t) {
  close();
  open = { id: t.id, ticket: t, model: modelInfo(t.agent?.model), req: ++sequence, serial: 0, life: ctx.life, offs: [], trimmed: false };
  const ref = open;
  ref.offs.push(ctx.life.every(60000, () => { if (current(ref)) state(ref.msg || {}); }));
  requestTail();
}
registerBody('conversation', start);
Object.assign(fx, { appendEntries, appendItem, receiveConversation, reconnectConversation: requestTail });
