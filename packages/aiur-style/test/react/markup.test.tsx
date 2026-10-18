// @vitest-environment jsdom
import React from 'react';
import { readFileSync } from 'node:fs';
import { renderToString } from 'react-dom/server';
import { expect, it } from 'vitest';
import { AiurShell, PageFrame, ThemeToggle, Button } from '../../src/react/index.js';

function fixture(name: string) {
  return new DOMParser().parseFromString(readFileSync(`markup/${name}.html`, 'utf8'), 'text/html');
}
// Compare every tag, class, accessibility attribute and text node. IDs are instance-specific.
function contract(element: Element): unknown {
  return [element.localName, Array.from(element.attributes)
    .filter(a => a.name === 'class' || a.name.startsWith('aria-') && a.name !== 'aria-controls' || ['href', 'role', 'data-nav-collapsed'].includes(a.name))
    .map(a => [a.name, a.value.replace(/\s+/g, ' ').trim()]).sort(),
  Array.from(element.childNodes).flatMap(child => child.nodeType === 1 ? [contract(child as Element)]
    : child.textContent?.trim() ? [child.textContent.replace(/\s+/g, ' ').trim()] : [])];
}
function raw(element: Element) {
  return <span dangerouslySetInnerHTML={{ __html: element.innerHTML }} />;
}
function rendered(content: React.ReactNode) {
  return new DOMParser().parseFromString(renderToString(content), 'text/html').body.firstElementChild!;
}

it('SSR shell matches every fixture class and aria-current in both navigations', () => {
  const doc = fixture('shell');
  const expected = doc.querySelector('.aiur-shell')!;
  const items = Array.from(doc.querySelectorAll('.aiur-shell__nav--sidebar .aiur-shell__item'), item => ({
    href: item.getAttribute('href') ?? '', label: item.querySelector('.aiur-shell__label')!.textContent!,
    icon: raw(item.querySelector('.aiur-shell__icon')!),
    count: item.querySelector('.aiur-shell__count') ? Number(item.querySelector('.aiur-shell__count')!.textContent) : undefined,
    attention: !!item.querySelector('.is-attention'), current: item.hasAttribute('aria-current'), unavailable: item.hasAttribute('aria-disabled'),
  }));
  // Normalize only consumer-owned slots, leaving all wrapper markup in the comparison.
  for (const selector of ['.aiur-shell__brand', '.aiur-shell__controls', '.aiur-shell__nav-controls', '.aiur-shell__icon', '.aiur-page__icon']) {
    expected.querySelectorAll(selector).forEach(el => { el.innerHTML = `<span>${el.innerHTML}</span>`; });
  }
  const actual = rendered(<AiurShell navItems={items} brand={raw(doc.querySelector('.aiur-shell__brand span')!)}
    controls={raw(doc.querySelector('.aiur-shell__controls span')!)} mobileControls={raw(doc.querySelector('.aiur-shell__nav-controls span')!)}>
    <PageFrame title="Units" icon={raw(doc.querySelector('.aiur-page__icon span')!)}
      banner="Three units running. Two commands need your attention."><p>Follow your units and commands from one place.</p></PageFrame>
  </AiurShell>);
  expect(contract(actual)).toEqual(contract(expected));
});

it('PageFrame supports Khala model and preserves its accessible heading ID', () => {
  const result = rendered(<PageFrame model={{ title: 'Channels', description: 'Choose a channel', labelledBy: 'channels-title' }} banner="Connected">Body</PageFrame>);
  expect(result.getAttribute('aria-labelledby')).toBe('channels-title');
  expect(result.querySelector('h1')!.id).toBe('channels-title');
  expect(result.querySelector('.aiur-page__description')!.textContent).toBe('Choose a channel');
  expect(result.querySelector('[role="status"]')!.textContent).toBe('Connected');
});

it('ThemeToggle SSR matches the theme-toggle fixture classes and accessibility', () => {
  expect(contract(rendered(<ThemeToggle />))).toEqual(contract(fixture('theme-toggle').querySelector('button')!));
});

it('Button maps modifiers, forwards native props and defaults to a non-submit button', () => {
  const button = rendered(<Button variant="danger" size="sm" shape="rounded" disabled>Delete</Button>);
  expect(button.className).toBe('aiur-button aiur-button--danger aiur-button--sm aiur-button--rounded');
  expect(button.getAttribute('type')).toBe('button');
  expect(button.hasAttribute('disabled')).toBe(true);
  const link = rendered(<Button as="a" href="/channels" variant="ghost" size="lg" shape="icon">Channels</Button>);
  expect(link.outerHTML).toContain('href="/channels"');
  expect(link.className).toBe('aiur-button aiur-button--ghost aiur-button--lg aiur-button--icon');
  expect(link.hasAttribute('type')).toBe(false);
});
