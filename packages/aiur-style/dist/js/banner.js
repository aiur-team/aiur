import { writeStorage } from './storage.js';
function focusAfter(banner) {
    const candidates = document.querySelectorAll('a[href], button, input, select, textarea, [tabindex], [contenteditable="true"]');
    for (const candidate of Array.from(candidates)) {
        if (banner.contains(candidate) || !(banner.compareDocumentPosition(candidate) & Node.DOCUMENT_POSITION_FOLLOWING))
            continue;
        if (candidate.tabIndex < 0 || candidate.matches(':disabled') || candidate.closest('[inert]') || !candidate.checkVisibility())
            continue;
        candidate.focus();
        if (document.activeElement === candidate)
            return;
    }
    const fallback = document.querySelector('main') ?? document.body;
    const tabindex = fallback.getAttribute('tabindex');
    fallback.setAttribute('tabindex', '-1');
    fallback.focus();
    fallback.addEventListener('blur', () => {
        if (tabindex === null)
            fallback.removeAttribute('tabindex');
        else
            fallback.setAttribute('tabindex', tabindex);
    }, { once: true });
}
export function initBanner(el) {
    const close = el.querySelector('.aiur-banner__close');
    function dismiss() {
        writeStorage(`aiur-banner:${el.dataset.aiurBanner}`, 'dismissed');
        document.documentElement.setAttribute('data-aiur-banner', 'dismissed');
        focusAfter(el);
        el.dispatchEvent(new CustomEvent('aiur:bannerdismiss', { bubbles: true }));
    }
    close?.addEventListener('click', dismiss);
    return { destroy() { close?.removeEventListener('click', dismiss); } };
}
