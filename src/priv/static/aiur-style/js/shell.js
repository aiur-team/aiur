import { readStorage, writeStorage } from './storage.js';
/** Enhance a shell; return a disposer for hosts that unmount their page. */
export function initShellNav(shell, { storageKey = 'aiur-nav-collapsed', onToggle } = {}) {
    const toggle = shell.querySelector('.aiur-shell__toggle');
    if (!toggle)
        return () => { };
    const apply = (collapsed) => {
        shell.dataset.navCollapsed = String(collapsed);
        toggle.setAttribute('aria-pressed', String(collapsed));
        const label = collapsed ? 'Expand navigation' : 'Collapse navigation';
        toggle.setAttribute('aria-label', label);
        toggle.title = label;
    };
    const stored = readStorage(storageKey);
    let collapsed = stored === 'true' || stored === 'false'
        ? stored === 'true' : shell.dataset.navCollapsed === 'true';
    apply(collapsed);
    const click = () => {
        collapsed = shell.dataset.navCollapsed !== 'true';
        apply(collapsed);
        writeStorage(storageKey, String(collapsed));
        onToggle?.(collapsed);
    };
    toggle.addEventListener('click', click);
    return () => toggle.removeEventListener('click', click);
}
