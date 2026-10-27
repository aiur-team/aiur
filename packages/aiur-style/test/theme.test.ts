// @vitest-environment jsdom
import { beforeEach, afterEach, expect, test, vi } from 'vitest';
import { getTheme, setTheme, onThemeChange, initThemeToggle } from '../src/js/theme.js';
import { readStorage, writeStorage } from '../src/js/storage.js';

let media: EventTarget & { matches: boolean };
beforeEach(() => {
  document.documentElement.removeAttribute('data-theme');
  document.head.replaceChildren();
  document.body.replaceChildren();
  localStorage.clear();
  media = Object.assign(new EventTarget(), { matches: false });
  vi.stubGlobal('matchMedia', () => media);
});
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); });

test('resolves explicit choices and the system preference', () => {
  expect(getTheme()).toBe('light');
  media.matches = true;
  expect(getTheme()).toBe('dark');
  document.documentElement.setAttribute('data-theme', 'light');
  expect(getTheme()).toBe('light');
});

test('setTheme persists and dispatches exactly one event per attribute change', () => {
  const callback = vi.fn();
  const unsubscribe = onThemeChange(callback);
  setTheme('dark');
  setTheme('dark');
  expect(document.documentElement.getAttribute('data-theme')).toBe('dark');
  expect(localStorage.getItem('aiur-theme')).toBe('dark');
  expect(callback.mock.calls).toEqual([['dark']]);
  setTheme('light', { persist: false });
  expect(localStorage.getItem('aiur-theme')).toBe('dark');
  expect(callback.mock.calls).toEqual([['dark'], ['light']]);
  unsubscribe();
  setTheme('dark');
  expect(callback).toHaveBeenCalledTimes(2);
});

test('uses the initializer custom storage key', () => {
  const script = document.createElement('script');
  script.dataset.storageKey = 'custom-theme';
  document.head.append(script);
  setTheme('dark');
  expect(localStorage.getItem('custom-theme')).toBe('dark');
  expect(localStorage.getItem('aiur-theme')).toBeNull();
});

test('system changes notify only in system mode and unsubscribe removes both listeners', () => {
  const callback = vi.fn();
  const unsubscribe = onThemeChange(callback);
  media.matches = true;
  media.dispatchEvent(new Event('change'));
  expect(callback.mock.calls).toEqual([['dark']]);
  setTheme('light');
  media.dispatchEvent(new Event('change'));
  expect(callback.mock.calls).toEqual([['dark'], ['light']]);
  unsubscribe();
  document.documentElement.removeAttribute('data-theme');
  media.dispatchEvent(new Event('change'));
  setTheme('dark');
  expect(callback).toHaveBeenCalledTimes(2);
});

test('initializing twice binds once; destroy removes click and theme listeners', () => {
  const button = document.createElement('button');
  button.hidden = true;
  media.matches = true;
  const control = initThemeToggle(button);
  initThemeToggle(button);
  expect(button.hidden).toBe(false);
  expect(button.getAttribute('aria-pressed')).toBe('true');
  button.click();
  expect(getTheme()).toBe('light');
  expect(button.getAttribute('aria-pressed')).toBe('false');
  control.destroy();
  setTheme('dark');
  expect(button.getAttribute('aria-pressed')).toBe('false');
  button.click();
  expect(getTheme()).toBe('dark');
  const rebound = initThemeToggle(button);
  button.click();
  expect(getTheme()).toBe('light');
  rebound.destroy();
});

test('toggle tracks system changes before an explicit choice', () => {
  const button = document.createElement('button');
  const control = initThemeToggle(button);
  media.matches = true;
  media.dispatchEvent(new Event('change'));
  expect(button.getAttribute('aria-pressed')).toBe('true');
  control.destroy();
});

test('blocked storage still changes the theme and notifies listeners', () => {
  vi.spyOn(window, 'localStorage', 'get').mockImplementation(() => { throw new Error('blocked'); });
  const callback = vi.fn();
  const unsubscribe = onThemeChange(callback);
  expect(readStorage('aiur-theme')).toBeNull();
  expect(() => writeStorage('aiur-theme', 'dark')).not.toThrow();
  expect(() => setTheme('dark')).not.toThrow();
  expect(getTheme()).toBe('dark');
  expect(callback.mock.calls).toEqual([['dark']]);
  unsubscribe();
});
