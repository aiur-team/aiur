import { createFlowField } from '../dist/js/field.js';

const params = new URLSearchParams(location.search);
document.documentElement.dataset.theme = params.get('theme') ?? 'dark';
if (params.has('no-hug')) document.querySelector('.hug').remove();
const canvas = document.querySelector('canvas');
// A stable, public fixture handle for browser acceptance checks.
window.field = params.has('legacy') ? null : createFlowField(canvas);
for (const tab of document.querySelectorAll('[role="tab"]')) {
  tab.addEventListener('click', () => {
    for (const other of document.querySelectorAll('[role="tab"]')) {
      const selected = other === tab;
      other.setAttribute('aria-selected', String(selected));
      document.getElementById(other.getAttribute('aria-controls')).hidden = !selected;
    }
    document.querySelector('#command').dispatchEvent(new CustomEvent('aiur:layoutchange', { bubbles: true }));
  });
}
