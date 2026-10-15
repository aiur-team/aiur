export interface ScrollCueOptions {
  hideAfter?: number;
  hideWhen?: () => boolean;
}

const instances = new WeakMap<HTMLElement, { destroy(): void }>();

export function initScrollCue(el: HTMLElement, { hideAfter = 60, hideWhen }: ScrollCueOptions = {}): { destroy(): void } {
  const existing = instances.get(el);
  if (existing) return existing;
  const update = () => el.classList.toggle('is-gone', window.scrollY > hideAfter || Boolean(hideWhen?.()));
  window.addEventListener('scroll', update, { passive: true });
  update();
  const instance = {
    destroy() {
      if (instances.get(el) !== instance) return;
      window.removeEventListener('scroll', update);
      instances.delete(el);
    },
  };
  instances.set(el, instance);
  return instance;
}
