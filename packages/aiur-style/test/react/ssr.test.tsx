// @vitest-environment node
import React from 'react';
import { renderToString } from 'react-dom/server';
import { expect, it } from 'vitest';
import { AiurShell, PageFrame, Button, ThemeToggle } from 'aiur-style/react';

it('the published React subpath imports and renders without browser globals', () => {
  expect(typeof window).toBe('undefined');
  const html = renderToString(<AiurShell navItems={[{ href: '/channels', label: 'Channels', current: true }]}>
    <PageFrame title="Channels"><Button>Join</Button><ThemeToggle /></PageFrame>
  </AiurShell>);
  expect(html).toContain('class="aiur-shell"');
  expect(html).toContain('aria-current="page"');
  expect(html).toContain('class="aiur-page__title"');
  expect(html).toContain('class="aiur-button"');
  expect(html).toContain('data-aiur="theme-toggle"');
});
