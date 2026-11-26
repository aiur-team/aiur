// @vitest-environment node
import { execFileSync } from 'node:child_process';
import { expect, it } from 'vitest';

it('the published React subpath imports and renders without browser globals', () => {
  const html = execFileSync(process.execPath, ['--input-type=module', '-e', `
    import { createElement as h } from 'react';
    import { renderToString } from 'react-dom/server';
    import { AiurShell, PageFrame, Button, ThemeToggle } from 'aiur-style/react';
    if (typeof window !== 'undefined') throw new Error('Expected a server process');
    console.log(renderToString(h(AiurShell, {
      navItems: [{ href: '/channels', label: 'Channels', current: true }],
    }, h(PageFrame, { title: 'Channels' }, h(Button, null, 'Join'), h(ThemeToggle)))));
  `], { encoding: 'utf8' });
  expect(html).toContain('class="aiur-shell"');
  expect(html).toContain('aria-current="page"');
  expect(html).toContain('class="aiur-page__title"');
  expect(html).toContain('class="aiur-button"');
  expect(html).toContain('data-aiur="theme-toggle"');
});
