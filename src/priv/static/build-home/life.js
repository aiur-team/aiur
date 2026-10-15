export function createLife() {
  const offs = new Set(), timers = new Map(), frames = new Map();
  let disposed = false;
  const own = off => { offs.add(off); return () => { off(); offs.delete(off); }; };
  return {
    get disposed() { return disposed; },
    on(target, type, fn, opts) {
      target.addEventListener(type, fn, opts);
      return own(() => target.removeEventListener(type, fn, opts));
    },
    every(ms, fn) { const id = setInterval(fn, ms); return own(() => clearInterval(id)); },
    later(key, ms, fn) {
      clearTimeout(timers.get(key));
      timers.set(key, setTimeout(() => { timers.delete(key); fn(); }, ms));
    },
    frame(key, fn) {
      if (frames.has(key)) return;
      frames.set(key, requestAnimationFrame(() => { frames.delete(key); fn(); }));
    },
    observe(el, fn) {
      const ro = new ResizeObserver(fn); ro.observe(el);
      return own(() => ro.disconnect());
    },
    media(query, fn) {
      const m = matchMedia(query); m.addEventListener('change', fn);
      return own(() => m.removeEventListener('change', fn));
    },
    dispose() {
      disposed = true;
      for (const off of offs) off();
      offs.clear();
      timers.forEach(clearTimeout); timers.clear();
      frames.forEach(cancelAnimationFrame); frames.clear();
    },
  };
}
