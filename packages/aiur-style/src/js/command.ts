import { initTabs } from './tabs.js';

export interface CommandOptions {
  onCopy?: (text: string, kind: 'prompt' | 'command') => void;
  copiedMs?: number;
  labels?: { prompt?: string; command?: string };
}

const instances = new WeakMap<HTMLElement, { destroy(): void }>();

async function copyText(text: string): Promise<void> {
  try {
    if (navigator.clipboard) { await navigator.clipboard.writeText(text); return; }
  } catch { /* Insecure contexts and denied permissions use the legacy path. */ }
  const focused = document.activeElement as HTMLElement | null;
  const textarea = document.createElement('textarea');
  textarea.value = text;
  textarea.readOnly = true;
  textarea.style.position = 'fixed';
  textarea.style.opacity = '0';
  document.body.append(textarea);
  textarea.select();
  try {
    if (!document.execCommand('copy')) throw new Error('Copy failed');
  } finally { textarea.remove(); focused?.focus(); }
}

export function initCommand(el: HTMLElement, options: CommandOptions = {}): { destroy(): void } {
  const existing = instances.get(el);
  if (existing) return existing;
  const text = el.querySelector<HTMLElement>('.aiur-command__text')!;
  const row = el.querySelector<HTMLElement>('.aiur-command__row')!;
  const prompt = el.querySelector<HTMLElement>('.aiur-command__prompt');
  const button = el.querySelector<HTMLButtonElement>('.aiur-command__copy')!;
  const status = el.querySelector<HTMLElement>('[role="status"]')!;
  const soon = el.classList.contains('aiur-command--soon') || el.getAttribute('aria-disabled') === 'true';
  if (soon) {
    el.setAttribute('aria-disabled', 'true');
    el.querySelectorAll('button').forEach(control => { control.disabled = true; });
  }
  let timer: ReturnType<typeof setTimeout> | undefined;
  let destroyed = false;
  let revision = 0;
  function reset() {
    clearTimeout(timer);
    button.classList.remove('is-copied');
    status.textContent = '';
  }
  function update(tab?: HTMLButtonElement) {
    revision++;
    reset();
    const kind = tab ? tab.dataset.aiurKind ?? 'command' : el.dataset.aiurKind ?? 'command';
    el.dataset.aiurKind = kind;
    if (tab) {
      text.textContent = tab.dataset.aiurText ?? '';
      row.setAttribute('aria-labelledby', tab.id);
    }
    if (prompt) {
      prompt.hidden = kind === 'prompt';
      prompt.textContent = tab?.dataset.aiurPrompt ?? el.dataset.aiurPrompt ?? '$';
    }
    button.setAttribute('aria-label', kind === 'prompt' ? options.labels?.prompt ?? 'Copy prompt'
      : options.labels?.command ?? 'Copy command');
  }
  update();
  let initializing = true;
  const tablist = el.querySelector<HTMLElement>('[role="tablist"]');
  const tabs = tablist ? initTabs(tablist, tab => {
    update(tab);
    if (!initializing) el.dispatchEvent(new CustomEvent('aiur:layoutchange', { bubbles: true }));
  }) : undefined;
  initializing = false;
  async function copy() {
    if (soon || destroyed) return;
    const value = text.textContent ?? '';
    const kind = el.dataset.aiurKind === 'prompt' ? 'prompt' : 'command';
    const copiedRevision = revision;
    try { await copyText(value); }
    catch { if (!destroyed) status.textContent = 'Copy failed'; return; }
    if (destroyed || copiedRevision !== revision) return;
    reset();
    button.classList.add('is-copied');
    status.textContent = 'Copied';
    timer = setTimeout(reset, options.copiedMs ?? 1500);
    options.onCopy?.(value, kind);
  }
  button.addEventListener('click', copy);
  const instance = {
    destroy() {
      if (instances.get(el) !== instance) return;
      destroyed = true;
      reset();
      tabs?.destroy();
      button.removeEventListener('click', copy);
      instances.delete(el);
    },
  };
  instances.set(el, instance);
  return instance;
}
