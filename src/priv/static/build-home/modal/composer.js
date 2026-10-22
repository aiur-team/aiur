import { ctx, fx, onReset } from '../state.js';
import { $, esc } from '../dom.js';
import { MI } from '../icons.js';
import { modelInfo } from '../agents.js';
import { modelLabel } from '../now-state.js';
import { onModalClose } from './frame.js';

// Port of the design's composer (J:1407–1408, J:1485–1500) without its mock reply,
// optimistic row or optimistic resume: a row appears only after Aiur accepts the
// message, and "delivered" only from the server's delivery read.
export const PAUSED = 'Message the agent — it resumes when you send';
export const AMBIGUOUS = 'Agent actions are unavailable because this display identifier is not a unique writable target.';
const NO_ANSWER = 'No answer from the dashboard, so the message may still be queued. Check the log before you send again.';
const STATUS = {
  queued: ['Queued · waiting for the agent', ''], delivered: null, unconfirmed: ['Queued · delivery unconfirmed', ''],
  failed: ['Not delivered (failed)', 'bad'], superseded: ['Not delivered (superseded)', 'bad'],
};
let drafts = new Map(), st = null, offs = [], localOps = [], appending = false;
const fresh = t => ({ id: t.id, pending: false, last: null, sent: '', line: null, ended: false });
function unbind() { offs.forEach(off => off()); offs = []; }
onReset(() => { unbind(); drafts = new Map(); st = null; localOps = []; });
onModalClose(() => { unbind(); st = null; localOps = []; });

export function placeholder(t) {
  if (t.agent?.state === 'paused') return PAUSED;
  const name = modelLabel(t.agent) || (t.agent?.model ? modelInfo(t.agent.model).name : null);
  return 'Message ' + (name || 'the agent') + '…';
}
const live = () => ctx.socket === 'up' && (ctx.offline?.isLive?.() ?? true);
function setLine(text, tone = '') {
  st.line = text ? [text, tone] : null;
  const el = $('#cv-in-st'); if (!el) return;
  el.hidden = !text; el.textContent = text || ''; el.className = 'cv-in-st' + (tone ? ' ' + tone : '');
}
function refresh() {
  const button = $('#cv-in .cv-send'); if (!st || !button) return;
  button.disabled = st.pending || st.ended || !live();
  if (st.ended) setLine(st.ended, 'bad');
  else if (!live() && !st.pending) setLine('Offline · reconnect to send');
  else if (st.line?.[0] === 'Offline · reconnect to send') setLine(null);
}
function grow(ta) { ta.style.height = 'auto'; ta.style.height = Math.min(140, ta.scrollHeight) + 'px'; }
export function renderComposer(t, msg) {
  unbind(); $('#cv-in')?.remove(); $('#cv-in-st')?.remove(); $('#cv-in-off')?.remove();
  const slot = $('#cv-footer');
  if (!slot || t.sec === 'hist' || ctx.snap?.writable !== true || !msg.composer) return;
  if (st?.id !== t.id) st = fresh(t);
  if (msg.composer !== 'ready') {
    const row = document.createElement('div'); row.className = 'cv-end'; row.id = 'cv-in-off'; row.textContent = AMBIGUOUS; slot.after(row); return;
  }
  const hint = placeholder(t);
  slot.insertAdjacentHTML('afterend', '<form class="cv-in" id="cv-in" data-voice-composer><textarea rows="1" placeholder="' + esc(hint) +
    '" aria-label="' + esc(hint.replace(/…$/, '')) + '" enterkeyhint="send" data-voice-input></textarea>' +
    '<button class="cv-mic" type="button" id="cv-mic" title="Dictate" aria-label="Dictate" aria-disabled="true">' + MI.mic + '</button>' +
    '<button class="cv-send" type="submit" aria-label="Send">' + MI.send + '</button></form>' +
    '<p class="cv-in-st" id="cv-in-st" role="status" aria-live="polite" hidden></p>');
  const form = $('#cv-in'), ta = $('textarea', form);
  ta.value = drafts.get(t.id) || ''; if (ta.value) grow(ta);
  if (st.line) setLine(...st.line);
  if (msg.state === 'ended') st.ended = 'Agent is no longer running.';
  offs.push(ctx.life.on(ta, 'input', () => { grow(ta); drafts.set(t.id, ta.value); }));
  offs.push(ctx.life.on(ta, 'keydown', ev => {
    if (ev.key !== 'Enter' || ev.shiftKey || ev.isComposing || ev.keyCode === 229) return;
    ev.preventDefault(); form.requestSubmit();
  }));
  offs.push(ctx.life.on(form, 'submit', ev => { ev.preventDefault(); submit(); }));
  offs.push(ctx.life.every(1000, refresh));
  refresh();
}
const timeout = ms => new Promise(resolve => setTimeout(() => resolve(null), ms));
async function submit() {
  const ref = st, ta = $('#cv-in textarea');
  if (!ref || !ta || ref.pending || ref.ended || !live()) return;
  const raw = ta.value; if (!raw.trim()) return;
  ref.pending = true; $('#cv-in').setAttribute('aria-busy', 'true'); refresh();
  let reply;
  try { reply = await Promise.race([ctx.push('send', { id: ref.id, text: raw }), timeout(15000)]); } catch { reply = null; }
  ref.pending = false;
  if (st !== ref) return;
  $('#cv-in')?.removeAttribute('aria-busy');
  if (reply?.v === 1 && reply.kind === 'send' && reply.id === ref.id && reply.ok === true) accepted(ref, raw, reply);
  else if (reply?.v === 1 && reply.kind === 'send' && reply.id === ref.id) setLine(reply.message, reply.unknown ? '' : 'bad');
  else if (reply?.v === 1 && reply.kind === 'error' && reply.reason === 'read_only') renderComposer({ id: ref.id, sec: 'hist' }, {});
  else setLine(NO_ANSWER);
  refresh();
}
function accepted(ref, raw, reply) {
  const ta = $('#cv-in textarea');
  if (ta && ta.value === raw) { ta.value = ''; ta.style.height = 'auto'; drafts.delete(ref.id); }
  ref.last = reply.request_id; ref.sent = reply.text; setLine(null);
  const log = $('#cv-log'); if (log) log.scrollTop = log.scrollHeight;
  // The composer's own row must not claim an earlier local row with the same text.
  appending = true;
  let el;
  try { [el] = fx.appendItem({ id: reply.entry_id, k: 'op', text: reply.text, at: reply.at }) || []; } finally { appending = false; }
  if (el) { el.dataset.opLocal = ''; localOps.push({ el, text: reply.text }); }
}
// A local worker's transcript echoes the message with its own id and a body cut at
// 1 600 characters plus "\n...", so the echo claims the local row by text, oldest first.
export function claimLocalOp(entry) {
  if (appending) return null;
  const text = String(entry.text ?? ''), cut = text.endsWith('\n...') ? text.slice(0, -4) : null;
  const i = localOps.findIndex(op => op.el.isConnected && (op.text === text || (cut !== null && op.text.startsWith(cut))));
  if (i < 0) return null;
  return localOps.splice(i, 1)[0].el;
}
export function sendStatus(msg) {
  if (!st || msg?.v !== 1 || msg.id !== st.id || msg.request_id !== st.last || !Object.hasOwn(STATUS, msg.status)) return;
  const words = STATUS[msg.status];
  setLine(words?.[0], words?.[1]);
  const ta = $('#cv-in textarea');
  if (msg.status === 'failed' && ta && !ta.value) { ta.value = st.sent; drafts.set(st.id, st.sent); grow(ta); }
}
export function composerState(msg) {
  if (!st || msg?.state !== 'ended') return;
  st.ended = 'Agent is no longer running.'; refresh();
}
Object.assign(fx, { renderComposer, claimLocalOp, sendStatus, composerState });
