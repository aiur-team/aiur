import { initShellNav, initThemeToggle, setTheme } from '../dist/js/index.js';

const query = new URLSearchParams(location.search);
setTheme(query.get('theme') === 'dark' ? 'dark' : 'light');
initThemeToggle(document.querySelector('[aria-label="Toggle color theme"]'));
const shell = document.querySelector('.aiur-shell');
// AS-02 predates cache navigation and counts. Reproduce its exact route fixture.
if (query.has('as02')) {
  shell.querySelectorAll('[aria-disabled], .aiur-shell__count').forEach(node => node.remove());
  shell.querySelector('.aiur-page__banner').remove();
}
initShellNav(shell, { onToggle: collapsed => {
  shell.dispatchEvent(new CustomEvent('shell-toggle', { detail: collapsed }));
} });
