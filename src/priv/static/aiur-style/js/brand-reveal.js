function resolve(target) {
    return typeof target === 'string' ? document.querySelector(target) : target ?? null;
}
export function initBrandReveal(topbar, { after }) {
    const brand = topbar.querySelector('.aiur-brand');
    const hero = resolve(after);
    let observer;
    function setTucked(tucked) {
        topbar.classList.toggle('is-logo-tucked', tucked);
        if (!brand)
            return;
        if (tucked) {
            brand.setAttribute('aria-hidden', 'true');
            brand.setAttribute('tabindex', '-1');
            // never strand keyboard focus on a control that is sliding out of view
            if (document.activeElement === brand)
                brand.blur();
        }
        else {
            brand.removeAttribute('aria-hidden');
            brand.removeAttribute('tabindex');
        }
    }
    if (hero && brand && 'IntersectionObserver' in window) {
        // the bar floats over the hero, so "past the hero" means its bottom edge is behind the bar
        const barHeight = Math.round(topbar.getBoundingClientRect().height);
        setTucked(hero.getBoundingClientRect().bottom > barHeight);
        observer = new IntersectionObserver(entries => entries.forEach(entry => setTucked(entry.isIntersecting)), { rootMargin: `-${barHeight}px 0px 0px 0px` });
        observer.observe(hero);
    }
    return { destroy() { observer?.disconnect(); } };
}
export function initTopbarPin(topbar, { banner } = {}) {
    const strip = resolve(banner);
    // a dismissed banner is display:none, so its rect collapses and the bar pins from the top
    const update = () => topbar.classList.toggle('is-pinned', (strip?.getBoundingClientRect().bottom ?? 0) <= 0);
    addEventListener('scroll', update, { passive: true });
    update();
    return { destroy() { removeEventListener('scroll', update); } };
}
