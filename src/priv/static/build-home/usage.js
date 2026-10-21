import { ctx, fx, onReset } from './state.js';
import { nowMs } from './clock.js';
import { $, $$, esc } from './dom.js';
import { stripHTML } from './usage-render.js';
export { fmtLeft, avgKnown, stripHTML } from './usage-render.js';

let lastHTML = null, axPop = null, axOver = null, bound = false;
onReset(() => { axPop?.remove(); axPop = axOver = lastHTML = null; bound = false; });
function hide() { axPop?.classList.remove('show'); }
function show(line) {
  axOver = line;
  const [head, rows] = JSON.parse(line.dataset.tip);
  axPop.innerHTML = `<b>${esc(head)}</b>` + rows.map(([k, v]) => `<div><span>${esc(k)}</span><em>${esc(v)}</em></div>`).join('');
  const r = line.getBoundingClientRect();
  axPop.style.left = (r.left + 28) + 'px'; axPop.style.top = (r.top - 6) + 'px'; axPop.classList.add('show');
}
function wireUsagePop(host) {
  bound = true;
  axPop = document.createElement('div'); axPop.className = 'ax-pop'; document.body.appendChild(axPop);
  for (const event of ['mouseover', 'focusin']) ctx.life.on(host, event, e => {
    const line = e.target.closest('.ax-ln'); if (line) show(line);
  });
  for (const event of ['mouseout', 'focusout']) ctx.life.on(host, event, e => {
    const line = e.target.closest('.ax-ln');
    if (!line || line.contains(e.relatedTarget)) return;
    axOver = null; ctx.life.later('ax-pop-hide', 60, () => { if (axOver === null) hide(); });
  });
  ctx.life.on(window, 'scroll', hide, { passive: true, capture: true });
  ctx.life.on(window, 'pagehide', hide);
  // The lifetime already owns cleanup functions; keep body nodes with their listeners.
  const pop = axPop;
  ctx.life.cleanup(() => pop.remove());
  ctx.life.every(30_000, () => { if (!document.hidden && needsTick(ctx.snap?.usage)) renderUsage(); });
}
function needsTick(u) {
  return u?.state === 'authorized' && [...u.apis, ...u.providers].some(p =>
    (p.stale && p.observed_at != null) || [p.session, p.weekly, ...(p.lines ?? [])].some(w => w && (w.reset_at != null || w.hold_until != null)));
}
export function fitResets() {
  $$('.ax-uc', $('#bd-usage', ctx.root)).forEach(sec => {
    let w = 0;
    $$('.ax-rs', sec).forEach(e => { e.style.width = 'max-content'; w = Math.max(w, e.getBoundingClientRect().width); e.style.width = ''; });
    sec.style.setProperty('--rsw', Math.ceil(w) + 'px');
  });
}
export function renderUsage() {
  const u = ctx.snap?.usage;
  if (!u || !ctx.root) return;
  const host = $('#bd-usage', ctx.root);
  if (!host) return;
  if (!bound) wireUsagePop(host);
  const html = stripHTML(u, nowMs());
  if (html === lastHTML) return;
  const key = axPop.classList.contains('show') ? axOver?.dataset.k : null;
  const focused = host.contains(document.activeElement) ? document.activeElement.dataset.k : null;
  lastHTML = html; host.innerHTML = html; fitResets();
  const life = ctx.life;
  document.fonts?.ready?.then(() => { if (ctx.life === life && !life.disposed) fitResets(); });
  const find = k => $$('.ax-ln', host).find(line => line.dataset.k === k);
  if (focused && find(focused)) find(focused).focus();
  const line = key && find(key);
  if (line) show(line); else { axOver = null; hide(); axPop.replaceChildren(); }
}
Object.assign(fx, { renderUsage });
