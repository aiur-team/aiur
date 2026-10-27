// MP-E8-C11-T08: the conversation foot's Command card (design J:1406). Answers go
// through the server's durable Command path; nothing here is optimistic.
import { ctx, fx, onReset } from '../state.js';
import { $, esc } from '../dom.js';
import { fmtT } from '../util.js';
import { MS, onModalClose } from './frame.js';

let latest = null, pending = null;
const forget = () => { latest = null; pending = null; };
onModalClose(forget); onReset(forget);

const rec = word => '<span class="rec">' + word + '</span>';
const link = '<a class="btn secondary sm" href="/commands">Open Commands</a>';
function optionHTML(card, o, settled) {
  const primary = o.recommended;
  const badge = settled ? (o.id === card.option_id ? rec('answered') : '') : o.recommended ? rec('recommended') : '';
  const title = !settled && !card.writable ? card.disabled_reason : o.title;
  return '<button class="btn ' + (primary ? '' : 'secondary ') + 'sm" type="button" data-ans="' + esc(o.id) + '"' +
    (title == null ? '' : ' title="' + esc(title) + '"') + (settled || !card.writable ? ' disabled' : '') + '>' + esc(o.label) + badge + '</button>';
}
function line(card, error) {
  if (error) return '<p class="st bad" role="alert">' + esc(error) + '</p>';
  if (card.state === 'settled') return '<p class="st" role="status" aria-live="polite">' + esc(card.text + (Number.isFinite(card.at_ms) ? ' · ' + fmtT(card.at_ms) : '')) + '</p>';
  if (card.state === 'open' && !card.writable) return '<p class="st" role="status" aria-live="polite">' + esc(card.disabled_reason) + '</p>';
  return '';
}
function cardEl(card, error) {
  const el = document.createElement('div');
  el.className = 'cv-cmd'; el.id = 'bd-cmd'; el.tabIndex = -1; el.setAttribute('role', 'group'); el.setAttribute('aria-labelledby', 'bd-cmd-q');
  if (card.decision_id) el.dataset.decision = card.decision_id;
  const question = card.state === 'unavailable' ? card.text : card.question;
  const settled = card.state === 'settled', options = card.state === 'unavailable' ? [] : card.options || [];
  const row = options.length ? options.map(o => optionHTML(card, o, settled)).join('') : link;
  el.innerHTML = '<p id="bd-cmd-q">' + esc(question) + '</p><div class="row">' + row + '</div>' + line(card, error);
  el.addEventListener('click', event => {
    const button = event.target.closest('button[data-ans]');
    if (button && card.state === 'open' && card.writable) answer(card, button);
  });
  return el;
}
function place(error) {
  const old = $('#bd-cmd'), main = $('#cv-log')?.parentElement;
  const card = latest && MS.t?.id === latest.ticket ? latest.card : null;
  if (!card || !main) { old?.remove(); return null; }
  const el = cardEl(card, error);
  if (old) old.replaceWith(el);
  // Before the footer slot: the composer inserts its form right after that slot, so the card stays above it.
  else { const slot = main.querySelector('#cv-footer'); if (slot) slot.before(el); else main.append(el); }
  return el;
}
export function renderCommand(msg) {
  if (!msg || MS.t?.id !== msg.ticket) return;
  if (pending) { latest = msg; return; }
  const shown = $('#bd-cmd')?.dataset.decision;
  // A pushed settled card for a decision that is not on screen is ignored.
  if (msg.card?.state === 'settled' && shown !== msg.card.decision_id) return;
  latest = msg; place();
}
function placeAfterRender() { pending = null; place(); }
function focusAfter(button) {
  const ans = button.dataset.ans;
  const again = [...($('#bd-cmd')?.querySelectorAll('button[data-ans]') || [])].find(b => b.dataset.ans === ans && !b.disabled);
  (again || $('#bd-cmd'))?.focus();
}
async function answer(card, button) {
  const box = $('#bd-cmd'); if (pending || !box) return;
  const token = pending = {}, ticket = latest.ticket;
  box.tabIndex = -1; box.focus();
  box.querySelectorAll('button').forEach(b => { b.disabled = true; });
  box.setAttribute('aria-busy', 'true');
  let reply;
  try { reply = await ctx.push('answer-decision', { decision_id: card.decision_id, answer: { choice: 'option:' + button.dataset.ans } }); }
  catch { reply = null; }
  if (pending !== token || MS.t?.id !== ticket) return;
  pending = null;
  if (reply?.status === 'accepted') {
    $('#bd-cmd')?.remove();
    fx.appendEntries([{ id: 'answer:' + (reply.action_id || card.decision_id), k: 'op', text: reply.text, at: reply.at_ms }]);
    latest = { ticket, card: reply.card || null }; place();
    ($('#cv-in textarea') || $('#bd-tk-close'))?.focus();
  } else if (reply?.status === 'settled') {
    latest = { ticket, card: reply.card || null }; (place() || $('#bd-tk-close'))?.focus();
  } else {
    if (reply && Object.hasOwn(reply, 'card')) latest = { ticket, card: reply.card };
    if (place(reply?.message || 'Connection lost. Try again.')) focusAfter(button); else $('#bd-tk-close')?.focus();
  }
}
Object.assign(fx, { renderCommand, placeCommand: placeAfterRender });
