import { initBanner } from './banner.js';
import { initScrollCue } from './scrollcue.js';
import { initBrandReveal, initTopbarPin } from './brand-reveal.js';
import { initThemeToggle } from './theme.js';

function init() {
  document.querySelectorAll<HTMLElement>('[data-aiur="banner"]').forEach(el => initBanner(el));
  document.querySelectorAll<HTMLElement>('[data-aiur="scrollcue"]').forEach(el => initScrollCue(el));
  document.querySelectorAll<HTMLElement>('[data-aiur="topbar"]').forEach(el => {
    if (el.dataset.aiurRevealAfter) initBrandReveal(el, { after: el.dataset.aiurRevealAfter });
    if (el.dataset.aiurPinBanner) initTopbarPin(el, { banner: el.dataset.aiurPinBanner });
  });
  document.querySelectorAll<HTMLButtonElement>('[data-aiur="theme-toggle"]').forEach(el => initThemeToggle(el));
}

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init, { once: true });
else init();
