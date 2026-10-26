// @vitest-environment jsdom
import React, { StrictMode } from 'react';
import { cleanup, fireEvent, render } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { AiurShell, ThemeToggle } from '../../src/react/index.js';

beforeEach(() => {
  localStorage.clear();
  document.documentElement.setAttribute('data-theme', 'light');
  vi.stubGlobal('matchMedia', vi.fn(() => ({ matches: false, addEventListener: vi.fn(), removeEventListener: vi.fn() })));
});
afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

it('uncontrolled collapse calls the latest callback once per click and disposes on unmount', () => {
  const first = vi.fn();
  const second = vi.fn();
  const view = render(<StrictMode><AiurShell navItems={[]} onCollapsedChange={first}>Body</AiurShell></StrictMode>);
  const button = view.getByRole('button', { name: 'Collapse navigation' });
  fireEvent.click(button);
  expect(first.mock.calls).toEqual([[true]]);
  expect(view.container.firstElementChild!.getAttribute('data-nav-collapsed')).toBe('true');
  expect(button.getAttribute('aria-pressed')).toBe('true');
  expect(localStorage.getItem('aiur-nav-collapsed')).toBe('true');
  view.rerender(<StrictMode><AiurShell navItems={[]} onCollapsedChange={second}>Body</AiurShell></StrictMode>);
  fireEvent.click(button);
  expect(first.mock.calls).toEqual([[true]]);
  expect(second.mock.calls).toEqual([[false]]);
  view.unmount();
  fireEvent.click(button);
  expect(second.mock.calls).toEqual([[false]]);
});

it('controlled collapse overrides storage and waits for the parent to accept a change', () => {
  localStorage.setItem('aiur-nav-collapsed', 'true');
  const changed = vi.fn();
  const view = render(<AiurShell navItems={[]} collapsed={false} onCollapsedChange={changed}>Body</AiurShell>);
  const button = view.getByRole('button', { name: 'Collapse navigation' });
  fireEvent.click(button);
  fireEvent.click(button);
  expect(changed.mock.calls).toEqual([[true], [true]]);
  expect(button.getAttribute('aria-pressed')).toBe('false');
  expect(view.container.firstElementChild!.getAttribute('data-nav-collapsed')).toBe('false');
  view.rerender(<AiurShell navItems={[]} collapsed onCollapsedChange={changed}>Body</AiurShell>);
  expect(button.getAttribute('aria-label')).toBe('Expand navigation');
  expect(view.container.firstElementChild!.getAttribute('data-nav-collapsed')).toBe('true');
});

it('defaultCollapsed initializes uncontrolled state when storage has no preference', () => {
  const view = render(<AiurShell navItems={[]} defaultCollapsed>Body</AiurShell>);
  expect(view.container.firstElementChild!.getAttribute('data-nav-collapsed')).toBe('true');
  fireEvent.click(view.getByRole('button', { name: 'Expand navigation' }));
  expect(view.container.firstElementChild!.getAttribute('data-nav-collapsed')).toBe('false');
});

it('Khala hosted mode renders only themed content and updates on host changes', () => {
  const theme = { theme: 'dark' as const, onThemeChange: vi.fn() };
  const view = render(<AiurShell mode="hosted-content" navigation={[]} theme={theme} className="embedded">Channel</AiurShell>);
  expect(view.container.innerHTML).toBe('<div class="aiur-shell-content-root embedded" data-theme="dark">Channel</div>');
  view.rerender(<AiurShell mode="hosted-content" navigation={[]} theme={{ ...theme, theme: 'light' }}>Channel</AiurShell>);
  expect(view.container.firstElementChild!.getAttribute('data-theme')).toBe('light');
});

it('hosted content follows vanilla theme changes and releases the listener', () => {
  const view = render(<AiurShell mode="hosted-content">Channel</AiurShell>);
  const root = view.container.firstElementChild!;
  expect(root.getAttribute('data-theme')).toBe('light');
  document.documentElement.setAttribute('data-theme', 'dark');
  document.dispatchEvent(new CustomEvent('aiur:themechange', { detail: { theme: 'dark' } }));
  expect(root.getAttribute('data-theme')).toBe('dark');
  view.unmount();
  document.documentElement.setAttribute('data-theme', 'light');
  document.dispatchEvent(new CustomEvent('aiur:themechange', { detail: { theme: 'light' } }));
  expect(root.getAttribute('data-theme')).toBe('dark');
});

it('ThemeToggle initializes, switches once under StrictMode and destroys its listeners', () => {
  const view = render(<StrictMode><ThemeToggle /></StrictMode>);
  const button = view.getByRole('button', { name: 'Dark mode' });
  fireEvent.click(button);
  expect(document.documentElement.getAttribute('data-theme')).toBe('dark');
  expect(button.getAttribute('aria-pressed')).toBe('true');
  expect(localStorage.getItem('aiur-theme')).toBe('dark');
  view.unmount();
  fireEvent.click(button);
  expect(document.documentElement.getAttribute('data-theme')).toBe('dark');
  document.dispatchEvent(new CustomEvent('aiur:themechange', { detail: { theme: 'light' } }));
  expect(button.getAttribute('aria-pressed')).toBe('true');
});
