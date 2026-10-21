// Ported from ticket-context-dialog-hook.js:48–90; this dialog is hook-owned.
export function trap(event, modal) {
  if (event.key !== 'Tab') return;
  const controls = [...modal.querySelectorAll('a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])')]
    .filter(el => !el.hidden && el.getAttribute('aria-hidden') !== 'true' && el.getAttribute('aria-disabled') !== 'true' && el.getClientRects().length);
  const first = controls[0], last = controls.at(-1), active = document.activeElement;
  if (!first) { event.preventDefault(); modal.querySelector('[data-dialog-heading]')?.focus(); }
  else if (event.shiftKey && (active === first || active === modal.querySelector('[data-dialog-heading]'))) {
    event.preventDefault(); last.focus();
  } else if (!event.shiftKey && active === last) { event.preventDefault(); first.focus(); }
}
export function restorable(el) {
  return el instanceof HTMLElement && el.isConnected && el !== document.body && el !== document.documentElement &&
    !el.hasAttribute('disabled') && el.getAttribute('aria-disabled') !== 'true';
}
export function restore(origin, id) {
  const card = [...document.querySelectorAll('.bd-card[data-id], .lr[data-id]')].find(el => el.dataset.id === id);
  if (restorable(origin)) origin.focus(); else if (restorable(card)) card.focus();
}
