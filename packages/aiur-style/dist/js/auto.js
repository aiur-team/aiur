import { initBanner } from './banner.js';
import { initScrollCue } from './scrollcue.js';
function init() {
    document.querySelectorAll('[data-aiur="banner"]').forEach(el => initBanner(el));
    document.querySelectorAll('[data-aiur="scrollcue"]').forEach(el => initScrollCue(el));
}
if (document.readyState === 'loading')
    document.addEventListener('DOMContentLoaded', init, { once: true });
else
    init();
