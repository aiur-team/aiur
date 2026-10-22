import { writeStorage } from './storage.js';
const query = '(prefers-color-scheme: dark)';
const toggles = new WeakSet();
export function getTheme() {
    const theme = document.documentElement.getAttribute('data-theme');
    return theme === 'light' || theme === 'dark' ? theme :
        matchMedia(query).matches ? 'dark' : 'light';
}
export function setTheme(theme, { persist = true } = {}) {
    const html = document.documentElement;
    const changed = html.getAttribute('data-theme') !== theme;
    html.setAttribute('data-theme', theme);
    if (persist) {
        const script = document.querySelector('script[data-storage-key]');
        writeStorage(script?.dataset.storageKey || 'aiur-theme', theme);
    }
    if (changed)
        document.dispatchEvent(new CustomEvent('aiur:themechange', { detail: { theme } }));
}
export function onThemeChange(callback) {
    const media = matchMedia(query);
    const explicit = (event) => callback(event.detail.theme);
    const system = () => {
        if (!document.documentElement.hasAttribute('data-theme'))
            callback(getTheme());
    };
    document.addEventListener('aiur:themechange', explicit);
    media.addEventListener('change', system);
    return () => {
        document.removeEventListener('aiur:themechange', explicit);
        media.removeEventListener('change', system);
    };
}
export function initThemeToggle(button) {
    if (toggles.has(button))
        return { destroy() { } };
    toggles.add(button);
    const sync = () => button.setAttribute('aria-pressed', String(getTheme() === 'dark'));
    const click = () => setTheme(getTheme() === 'dark' ? 'light' : 'dark');
    sync();
    button.hidden = false;
    button.addEventListener('click', click);
    const unsubscribe = onThemeChange(sync);
    return { destroy() {
            button.removeEventListener('click', click);
            unsubscribe();
            toggles.delete(button);
        } };
}
