import { test, expect, type Page } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

const names = ['Prompt', 'npm', 'bun', 'pnpm', 'yarn'];
const commands = ["Let's run parallel agents with: https://aiur.team/", 'npm i -g aiur-cli',
  'bun add -g aiur-cli', 'pnpm add -g aiur-cli', 'yarn global add aiur-cli'];
const root = '#command-tabs';

async function width(page: Page) {
  return page.locator(root).evaluate(el => {
    const tabs = el.querySelector('[role="tablist"]')!;
    const row = el.querySelector('.aiur-command__row')!;
    return { box: el.getBoundingClientRect().width, content: Math.max(tabs.scrollWidth, row.scrollWidth) };
  });
}
async function tabWidths(page: Page) {
  const widths: number[] = [];
  for (let i = 0; i < names.length; i++) {
    await page.getByRole('tab', { name: names[i], exact: true }).click();
    await expect(page.locator(`${root} .aiur-command__text`)).toHaveText(commands[i]);
    const measured = await width(page);
    expect(Math.abs(measured.box - measured.content)).toBeLessThanOrEqual(1);
    widths.push(measured.box);
  }
  return widths;
}

test.beforeEach(async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.goto('./command.html?theme=dark');
  await page.evaluate(() => document.fonts.ready);
  await expect(page.locator(`${root} .aiur-command__prompt`)).toBeHidden();
});

test('active content controls width and each change emits one bubbling layout event', async ({ page }) => {
  await page.evaluate(() => {
    (window as any).layoutChanges = [];
    document.addEventListener('aiur:layoutchange', event => (window as any).layoutChanges.push((event.target as Element).id));
  });
  const widths = await tabWidths(page);
  expect(widths[0] - widths[1]).toBeGreaterThan(40);
  expect(await page.evaluate(() => (window as any).layoutChanges)).toEqual(Array(4).fill('command-tabs'));
  await page.getByRole('tab', { name: 'yarn', exact: true }).click();
  expect(await page.evaluate(() => (window as any).layoutChanges.length)).toBe(4);
});

test('width assertion rejects a box pinned to the Prompt width', async ({ page }) => {
  const promptWidth = (await width(page)).box;
  await page.locator(root).evaluate((el, fixed) => {
    (el as HTMLElement).style.setProperty('--fixed', `${fixed}px`);
  }, promptWidth);
  await page.addStyleTag({ content: '.aiur-command { min-width: var(--fixed); }' });
  const widths = await tabWidths(page);
  expect(() => expect(widths[0] - widths[1]).toBeGreaterThan(40)).toThrow();
});

test('keyboard wraps, Home/End, Enter/Space, roving focus and panel relationships', async ({ page }) => {
  const tabs = page.getByRole('tab');
  await tabs.first().focus();
  for (const [key, index] of [['ArrowLeft', 4], ['ArrowRight', 0], ['End', 4], ['Home', 0], ['ArrowRight', 1]] as const) {
    await page.keyboard.press(key);
    await expect(tabs.nth(index)).toBeFocused();
    await expect(tabs.nth(index)).toHaveAttribute('aria-selected', 'true');
    await expect(page.locator('[role="tabpanel"]')).toHaveAttribute('aria-labelledby', await tabs.nth(index).getAttribute('id') as string);
    await expect(page.locator('[role="tab"][tabindex="0"]')).toHaveCount(1);
    await expect(page.locator(`${root} .aiur-command__text`)).toHaveText(commands[index]);
  }
  await expect(tabs.nth(1)).toHaveCSS('outline-style', 'solid');
  await tabs.nth(2).focus();
  await page.keyboard.press('Enter');
  await expect(tabs.nth(2)).toHaveAttribute('aria-selected', 'true');
  await tabs.nth(3).focus();
  await page.keyboard.press('Space');
  await expect(tabs.nth(3)).toHaveAttribute('aria-selected', 'true');
  await page.keyboard.press('Tab');
  await expect(page.getByRole('tabpanel')).toBeFocused();
  await page.keyboard.press('Tab');
  await expect(page.locator(`${root} .aiur-command__copy`)).toBeFocused();
});

test('copy writes every active tab and announces success for 1500ms', async ({ page, context }) => {
  await context.grantPermissions(['clipboard-read', 'clipboard-write']);
  await page.clock.install();
  await page.clock.pauseAt(new Date());
  for (let i = 0; i < names.length; i++) {
    await page.getByRole('tab', { name: names[i], exact: true }).click();
    const copy = page.locator(`${root} .aiur-command__copy`);
    await expect(copy).toHaveAccessibleName(i === 0 ? 'Copy prompt' : 'Copy command');
    if (i > 0) await expect(page.locator(`${root} .aiur-command__prompt`)).toBeVisible();
    await copy.click();
    await expect(page.locator(`${root} [role="status"]`)).toHaveText('Copied');
    expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(commands[i]);
    await expect(copy).toHaveClass(/is-copied/);
    await page.clock.runFor(1499);
    await expect(copy).toHaveClass(/is-copied/);
    await page.clock.runFor(1);
    await expect(copy).not.toHaveClass(/is-copied/);
    await expect(page.locator(`${root} [role="status"]`)).toBeEmpty();
  }
});

test('clipboard fallback restores focus and failure never announces success', async ({ page }) => {
  await page.evaluate(() => {
    Object.defineProperty(navigator, 'clipboard', { value: { writeText: () => Promise.reject(new Error('denied')) }, configurable: true });
    document.execCommand = command => {
      (window as any).fallback = [command, (document.activeElement as HTMLTextAreaElement).value];
      return true;
    };
  });
  const copy = page.locator(`${root} .aiur-command__copy`);
  await copy.click();
  expect(await page.evaluate(() => (window as any).fallback)).toEqual(['copy', commands[0]]);
  await expect(copy).toBeFocused();
  await expect(page.locator('textarea')).toHaveCount(0);
  await page.getByRole('tab', { name: 'npm', exact: true }).click();
  await page.evaluate(() => { document.execCommand = () => false; });
  await copy.click();
  await expect(page.locator(`${root} [role="status"]`)).toHaveText('Copy failed');
  await expect(copy).not.toHaveClass(/is-copied/);
});

test('custom options, prompt glyph and destroy clean up behavior', async ({ page }) => {
  await page.clock.install();
  await page.clock.pauseAt(new Date());
  await page.evaluate(async () => {
    const { initCommand } = await import('../dist/js/index.js');
    const single = document.querySelector<HTMLElement>('#command-single')!;
    const clone = single.cloneNode(true) as HTMLElement;
    clone.id = 'custom';
    single.after(clone);
    (window as any).command = initCommand(clone, { copiedMs: 20, labels: { command: 'Take command' }, onCopy: (text: string, kind: string) => { (window as any).copied = [text, kind]; } });
  });
  await page.context().grantPermissions(['clipboard-read', 'clipboard-write']);
  await expect(page.locator('#custom .aiur-command__prompt')).toHaveText('>');
  await page.getByRole('button', { name: 'Take command' }).click();
  await expect.poll(() => page.evaluate(() => (window as any).copied)).toEqual([commands[1], 'command']);
  await page.clock.runFor(19);
  await expect(page.locator('#custom .is-copied')).toHaveCount(1);
  await page.clock.runFor(1);
  await expect(page.locator('#custom .is-copied')).toHaveCount(0);
  await page.evaluate(() => { (window as any).command.destroy(); (window as any).copied = null; });
  await page.getByRole('button', { name: 'Take command' }).click();
  expect(await page.evaluate(() => (window as any).copied)).toBeNull();
});

test('soon controls are disabled and small widths wrap without overflowing', async ({ page }) => {
  await expect(page.locator('#command-soon')).toHaveAttribute('aria-disabled', 'true');
  await expect(page.locator('#command-soon button')).toBeDisabled();
  await page.evaluate(async () => {
    const { initCommand } = await import('../dist/js/index.js');
    const clone = document.querySelector('#command-tabs')!.cloneNode(true) as HTMLElement;
    clone.id = 'soon-tabs';
    clone.classList.add('aiur-command--soon');
    document.querySelector('main')!.append(clone);
    initCommand(clone);
  });
  await expect(page.locator('#soon-tabs')).toHaveAttribute('aria-disabled', 'true');
  for (const button of await page.locator('#soon-tabs button').all()) await expect(button).toBeDisabled();
  await expect(page.locator('#soon-tabs [role="tab"][aria-selected="true"]')).toHaveCount(1);
  await page.locator('#soon-tabs').evaluate(el => el.remove());
  for (const size of [390, 240]) {
    await page.setViewportSize({ width: size, height: 900 });
    for (const name of names) {
      await page.getByRole('tab', { name, exact: true }).click();
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(size);
    }
  }
});

for (const theme of ['light', 'dark']) {
  test(`command screenshots and axe ${theme}`, async ({ page, context }) => {
    await page.goto(`./command.html?theme=${theme}`);
    await expect(page.locator('html')).toHaveAttribute('data-theme', theme);
    await page.evaluate(() => document.fonts.ready);
    await context.grantPermissions(['clipboard-read', 'clipboard-write']);
    for (const name of names) {
      await page.getByRole('tab', { name, exact: true }).click();
      await page.mouse.move(0, 0);
      await expect(page.locator(root)).toHaveScreenshot(`command-${name}-${theme}.png`, { animations: 'disabled', maxDiffPixelRatio: .002 });
    }
    await expect(page.locator('#command-soon')).toHaveScreenshot(`command-soon-${theme}.png`);
    await page.locator(`${root} .aiur-command__copy`).click();
    await expect(page.locator(`${root} .is-copied`)).toHaveCount(1);
    await page.mouse.move(0, 0);
    await expect(page.locator(root)).toHaveScreenshot(`command-copied-${theme}.png`);
    expect((await new AxeBuilder({ page }).include('#commands').analyze()).violations).toEqual([]);
  });
}
