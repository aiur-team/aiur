/** A single panel whose content is supplied by the selected tab. */
export function initTabs(el: HTMLElement, activate: (tab: HTMLButtonElement) => void): { destroy(): void } {
  const tabs = Array.from(el.querySelectorAll<HTMLButtonElement>('[role="tab"]'));
  function select(tab: HTMLButtonElement) {
    if (tab.disabled || tab.getAttribute('aria-selected') === 'true') return;
    for (const item of tabs) {
      item.setAttribute('aria-selected', String(item === tab));
      item.tabIndex = item === tab ? 0 : -1;
    }
    activate(tab);
  }
  function click(event: MouseEvent) {
    const tab = (event.target as Element).closest<HTMLButtonElement>('[role="tab"]');
    if (tab && tabs.includes(tab)) select(tab);
  }
  function keydown(event: KeyboardEvent) {
    const enabled = tabs.filter(tab => !tab.disabled);
    const index = enabled.indexOf(event.target as HTMLButtonElement);
    if (index < 0) return;
    const next = event.key === 'Home' ? 0 : event.key === 'End' ? enabled.length - 1
      : event.key === 'ArrowRight' ? (index + 1) % enabled.length
      : event.key === 'ArrowLeft' ? (index + enabled.length - 1) % enabled.length : -1;
    if (next < 0) return;
    event.preventDefault();
    enabled[next].focus();
    select(enabled[next]);
  }
  const selected = tabs.find(tab => tab.getAttribute('aria-selected') === 'true')
    ?? tabs.find(tab => !tab.disabled);
  for (const tab of tabs) {
    tab.tabIndex = tab === selected && !tab.disabled ? 0 : -1;
    tab.setAttribute('aria-selected', String(tab === selected));
  }
  if (selected) activate(selected);
  el.addEventListener('click', click);
  el.addEventListener('keydown', keydown);
  return { destroy() { el.removeEventListener('click', click); el.removeEventListener('keydown', keydown); } };
}
