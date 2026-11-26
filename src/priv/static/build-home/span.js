import { S, ctx, fx, SPANS, onReset } from './state.js';
import { writeURL } from './url.js';
import { $ } from './dom.js';
import { sv } from './icons.js';

const CALI = {
  '1': '<rect x="4" y="4" width="16" height="16" rx="2.5"/><path d="M4 9h16"/>',
  '7': '<rect x="3" y="4" width="18" height="16" rx="2.5"/><path d="M3 9h18M9 9v11M15 9v11"/>',
  '31': '<rect x="3" y="4" width="18" height="16" rx="2.5"/><path d="M3 9h18M3 14.5h18M9 9v11M15 9v11"/>',
};
export const calIc = n => sv(CALI[n], 1.9);
export const calNear = () => [1, 7, 30].reduce((a, b) => Math.abs(Math.log(b / S.span)) < Math.abs(Math.log(a / S.span)) ? b : a);
export const dotSize = span => Math.max(14, 30 - 16 * Math.log(span) / Math.log(3)).toFixed(1) + 'px';
const days = () => S.span + ' day' + (S.span === 1 ? '' : 's') + ' in view';
const percent = () => Math.round(100 / S.span) + '%';

function focusedRangeControl() {
  const button = document.activeElement;
  if (!$('#bd-tools', ctx.root)?.contains(button)) return null;
  if (button.matches('[data-z]')) return `[data-z="${button.dataset.z}"]`;
  if (button.matches('[data-span]')) return `[data-span="${button.dataset.span}"]`;
  return null;
}
function restoreFocus(selector) {
  if (!selector) return;
  let button = $(selector, ctx.root);
  if (button?.disabled) button = $('[data-z]:not(:disabled)', ctx.root);
  button?.focus({ preventScroll: true });
}
function announce() {
  let region = $('#bd-range-live', ctx.root);
  if (!region) {
    region = document.createElement('p'); region.id = 'bd-range-live'; region.className = 'sr-only';
    region.setAttribute('aria-live', 'polite'); region.setAttribute('aria-atomic', 'true');
    ctx.root.appendChild(region);
  }
  region.textContent = days() + ', zoom ' + percent();
}
export function setSpan(sp) {
  if (!SPANS.includes(sp) || sp === S.span) return;
  const refocus = focusedRangeControl();
  S.span = sp; writeURL(); fx.renderTools();
  restoreFocus(refocus); announce();
  // An unavailable board also stays loading until its first snapshot arrives.
  if (S.loading) return;
  fx.relayout(); fx.jumpNow(true);
}
export function spanToolsHTML() {
  if (S.view === 'list') return '';
  return '<div class="bd-seg ic bd-cal" role="group" aria-label="Range">' +
    [[1, 'Day'], [7, 'Week'], [30, 'Month']].map(([sp, label]) => `<button type="button" data-span="${sp}" class="${calNear() === sp ? 'on' : ''}" title="${label}" aria-label="${label}" aria-pressed="${calNear() === sp}">${calIc(sp === 30 ? '31' : String(sp))}</button>`).join('') + '</div>' +
    `<div class="bd-seg bd-zoom" role="group" aria-label="Zoom"><button type="button" data-z="1" title="Zoom out · more days" aria-label="Zoom out"${S.span >= 30 ? ' disabled' : ''}>−</button><span class="bd-zv" title="${days()}">${percent()}</span><button type="button" data-z="-1" title="Zoom in · fewer days" aria-label="Zoom in"${S.span <= 1 ? ' disabled' : ''}>+</button></div>`;
}
let wired = new WeakSet();
onReset(() => { wired = new WeakSet(); });
export function wireSpanTools(host) {
  if (wired.has(host)) return;
  wired.add(host);
  ctx.life.on(host, 'click', e => {
    const z = e.target.closest('[data-z]'), d = e.target.closest('[data-span]');
    if (z && host.contains(z)) {
      const i = SPANS.indexOf(S.span), j = Math.max(0, Math.min(SPANS.length - 1, (i < 0 ? 0 : i) + (+z.dataset.z)));
      setSpan(SPANS[j]);
    } else if (d && host.contains(d)) setSpan(+d.dataset.span);
  });
}
Object.assign(fx, { spanToolsHTML, wireSpanTools });
