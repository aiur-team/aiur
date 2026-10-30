import { ctx, fx, onReset, rmOn } from '../state.js';
import { $, esc } from '../dom.js';
import { createLife } from '../life.js';
import { MS, onModalClose } from './frame.js';
import { appendEntries, trimmedBottom, requestTail } from './conversation.js';

const STICK = 60;
let V = null, life = null, live = false, detach = null;
export function disposeLive() {
  const off = detach; detach = null;
  life?.dispose(); life = null; V = null; live = false;
  off?.();
}
onReset(disposeLive); onModalClose(disposeLive);
export function typingVisible(t, conversationLive, linkLive) {
  return t?.sec === 'now' && t.agent?.state === 'active' && conversationLive === true && linkLive === true;
}
export function updateTyping() {
  const el = $('#cv-typing'); if (!el || !MS.t) return;
  const t = ctx.D?.byId?.[MS.t.id] ?? MS.t;
  el.hidden = !typingVisible(t, live, ctx.offline?.isLive() === true);
  const text = (t.agent?.name || 'Agent') + ' is working';
  if (el.lastChild?.nodeType === Node.TEXT_NODE) el.lastChild.textContent = text;
}
export function appendLive(entries) {
  if (!V || !MS.t) return [];
  const { log } = V, stick = log.scrollHeight - log.scrollTop - log.clientHeight < STICK;
  const anchor = stick ? null : [...log.children].find(el => el.offsetTop + el.offsetHeight > log.scrollTop);
  const offset = anchor ? anchor.offsetTop - log.scrollTop : 0, eid = anchor?.dataset.eid;
  const fresh = appendEntries(entries);
  if (!stick) {
    const retained = anchor?.isConnected ? anchor : [...log.children].find(el => eid && el.dataset.eid === eid);
    if (retained) log.scrollTop = retained.offsetTop - offset;
  }
  if (fresh.length) {
    fresh.forEach(el => el.classList.add('in'));
    if (stick) { log.scrollTop = log.scrollHeight; $('#cv-new').hidden = true; }
    else $('#cv-new').hidden = false;
  } else if (trimmedBottom() && entries.length) $('#cv-new').hidden = false;
  scheduleMap(); return fresh;
}
export const appendItem = entry => appendLive([entry]);
export function conversationApplied(msg) {
  if (msg.kind === 'conversation') wireLive();
  if (msg.kind === 'conversation' || msg.kind === 'conversation-state') live = msg.live === true;
  updateTyping(); scheduleMap();
}
export function scheduleMap() { life?.frame('map', buildMap); }
export function syncView() {
  if (!V) return;
  V.vw.style.top = (V.log.scrollTop * V.s) + 'px';
  V.vw.style.height = Math.max(8, V.log.clientHeight * V.s) + 'px';
}
export function buildMap() {
  if (!V) return;
  const { log, map, mm } = V, H0 = log.scrollHeight, s = Math.min(0.14, map.clientHeight / Math.max(1, H0));
  V.s = s;
  let html = '';
  for (let i = 0; i < log.children.length; i++) {
    const el = log.children[i], k = el.dataset.k; if (!k) continue;
    const top = (el.offsetTop * s).toFixed(1);
    if (k === 'ev') html += '<button type="button" tabindex="-1" class="mm-e' + (el.classList.contains('bad') ? ' bad' : '') + '" data-i="' + i + '" style="top:' + top + 'px;--eh:' + esc(el.style.getPropertyValue('--eh')) + '" aria-label="' + esc(el.dataset.label) + '"></button>';
    else {
      const h = Math.max(1.5, el.offsetHeight * s - 1.5).toFixed(1);
      const w = k === 'say' ? 62 + (i * 37 % 30) : k === 'tool' ? 42 + (i * 23 % 24) : k === 'op' ? 46 : k === 'sys' ? 36 : 84;
      html += '<i class="mm-b k-' + esc(k) + '" style="top:' + top + 'px;height:' + h + 'px;width:' + w + '%"></i>';
    }
  }
  mm.innerHTML = html; mm.style.height = (H0 * s) + 'px'; syncView();
}
export function wireLive() {
  disposeLive();
  const log = $('#cv-log'), map = $('#cv-map'); if (!log || !map) return;
  life = createLife(); detach = ctx.life.cleanup(disposeLive);
  V = { log, map, mm: $('#cv-mm'), vw: $('#cv-vw'), tip: $('#cv-tip'), s: 1 };
  const { tip } = V;
  log.tabIndex = 0; log.setAttribute('aria-label', 'Conversation');
  life.on(log, 'scroll', () => {
    syncView();
    if (!trimmedBottom() && log.scrollHeight - log.scrollTop - log.clientHeight < STICK) $('#cv-new').hidden = true;
  }, { passive: true });
  life.on($('#cv-new'), 'click', () => {
    if (trimmedBottom()) requestTail();
    else log.scrollTo({ top: log.scrollHeight, behavior: rmOn() ? 'auto' : 'smooth' });
  });
  const source = tick => tick && log.children[+tick.dataset.i]?.dataset.k === 'ev' ? log.children[+tick.dataset.i] : null;
  const toY = ev => { if (V.s > 0) log.scrollTop = (ev.clientY - map.getBoundingClientRect().top) / V.s - log.clientHeight / 2; };
  let drag = false;
  life.on(map, 'pointerdown', ev => {
    const tick = ev.target.closest('.mm-e'), el = source(tick);
    if (tick) {
      if (el) {
        log.scrollTo({ top: Math.max(0, el.offsetTop - 16), behavior: rmOn() ? 'auto' : 'smooth' });
        el.classList.remove('flash'); void el.offsetWidth; el.classList.add('flash');
      }
      return;
    }
    drag = true; map.setPointerCapture(ev.pointerId); toY(ev);
  });
  life.on(map, 'pointermove', ev => {
    if (drag) { toY(ev); return; }
    const tick = ev.target.closest('.mm-e'), el = source(tick);
    if (!el) { tip.classList.remove('show'); return; }
    const swatch = document.createElement('i'), time = document.createElement('time');
    swatch.style.setProperty('--eh', tick.style.getPropertyValue('--eh')); time.textContent = el.dataset.at || '—';
    tip.replaceChildren(swatch, document.createTextNode(el.dataset.label || ''), time);
    tip.style.top = tick.offsetTop + 'px'; tip.classList.add('show');
  });
  for (const event of ['pointerup', 'pointercancel', 'lostpointercapture']) life.on(map, event, () => { drag = false; });
  life.on(map, 'pointerleave', () => tip.classList.remove('show'));
  life.observe(log, scheduleMap); life.observe(map, scheduleMap);
  scheduleMap();
}
Object.assign(fx, { appendLive, appendItem, conversationApplied, scheduleMap, updateTyping, disposeLive });
