import { test, expect } from '@playwright/test';

// Imported by gallery.visual.spec.ts so the package's existing visual runner collects these tests.
for (const theme of ['light', 'dark']) {
  test(`footer contrast and semantics ${theme}`, async ({ page }) => {
    await page.goto(`./?theme=${theme}`);
    await expect(page.locator('#footer .aiur-footer').first()).toHaveCSS('padding-top', '32px');
    const credit = page.locator('.aiur-footer__credit');
    await expect(credit).toHaveText('built with Aiur');
    await expect(credit).toHaveClass(/aiur-keepout/);
    await expect(credit).toHaveCSS('font-size', '12px');
    const ratios = await credit.evaluate(element => {
      const canvas = document.createElement('canvas');
      canvas.width = canvas.height = 1;
      const context = canvas.getContext('2d')!;
      const background = getComputedStyle(document.documentElement).getPropertyValue('--aiur-color-bg');
      const luminance = (color: string) => {
        context.fillStyle = background;
        context.fillRect(0, 0, 1, 1);
        context.fillStyle = color;
        context.fillRect(0, 0, 1, 1);
        const channels = Array.from(context.getImageData(0, 0, 1, 1).data).slice(0, 3).map(value => {
          const channel = value / 255;
          return channel <= .04045 ? channel / 12.92 : ((channel + .055) / 1.055) ** 2.4;
        });
        return channels[0] * .2126 + channels[1] * .7152 + channels[2] * .0722;
      };
      const bg = luminance(background);
      return [element, element.querySelector('a')!].map(node => {
        const fg = luminance(getComputedStyle(node).color);
        return (Math.max(fg, bg) + .05) / (Math.min(fg, bg) + .05);
      });
    });
    for (const ratio of ratios) expect(ratio).toBeGreaterThanOrEqual(4.5);
    console.log(`${theme} footer credit contrast: ${ratios[0].toFixed(2)}:1`);
    const link = credit.locator('a');
    await expect(link).toHaveAttribute('href', 'https://aiur.team');
    await expect(link).toHaveCSS('text-decoration-line', 'underline');
    const brand = page.locator('.aiur-footer__brand');
    await expect(brand).toHaveCSS('letter-spacing', '2.16px');
    await expect(brand).toHaveCSS('text-transform', 'uppercase');
    await expect(brand.locator('.aiur-footer__dot')).toHaveCSS('width', '7px');
    await expect(brand.locator('.aiur-footer__dot')).toHaveAttribute('aria-hidden', 'true');
    await expect(page.getByRole('link', { name: 'Aiur on GitHub' })).toBeVisible();
    await page.setViewportSize({ width: 390, height: 844 });
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
  });

  for (const [index, variant] of ['brand-links', 'credit-only'].entries()) {
    test(`footer ${variant} screenshot ${theme}`, async ({ page }) => {
      await page.goto(`./?theme=${theme}`);
      await page.evaluate(() => document.fonts.ready);
      // Isolate component shots and align them to the pixel grid.
      await page.locator('#footer').evaluate(section => {
        document.getElementById('tokens')!.after(section);
        const top = section.getBoundingClientRect().top;
        section.style.transform = `translateY(${Math.floor(top) - top}px)`;
      });
      await expect(page.locator('#footer .aiur-footer').nth(index)).toHaveScreenshot(`footer-${variant}-${theme}.png`);
    });
  }
}
