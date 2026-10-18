import { test, expect } from '@playwright/test'
import { openParityPair, expectDesignParity, PARITY_VIEWPORTS } from '../support/design-parity.mjs'

async function isolateList(pair) {
  // Keep the real scroller and inherited paint; capture outside the toolbar's containing block.
  for (const page of [pair.design, pair.product]) {
    const paint = await page.locator('#bd-vp').evaluate(vp => {
    const box = vp.getBoundingClientRect(), root = vp.closest('.bd-root'), top = vp.scrollTop, style = getComputedStyle(vp);
    const fields = ['backgroundColor', 'backgroundImage', 'backgroundSize', 'fontFamily', 'fontSize', 'lineHeight'];
    const before = fields.map(key => style[key]);
    const inherited = ['--board-bg', '--dot'].map(key => [key, style.getPropertyValue(key)]);
    const host = document.createElement('div'); host.className = root.className;
    Object.assign(host.style, { position: 'fixed', top: '0', left: '0', width: box.width + 'px', height: box.height + 'px', background: 'var(--bg)', zIndex: '9999' });
    for (const [key, value] of inherited) if (value) host.style.setProperty(key, value);
    document.body.append(host); host.append(vp);
    Object.assign(vp.style, { width: box.width + 'px', height: box.height + 'px', minHeight: '0', flex: 'none', margin: '0' });
    vp.scrollTop = top;
    document.documentElement.style.scrollBehavior = 'auto'; window.scrollTo({ top: 0, behavior: 'instant' });
    return [before, fields.map(key => getComputedStyle(vp)[key])];
    });
    expect(paint[1]).toEqual(paint[0]);
  }
}

const cells = [
  ...[1440, 1024, 390].map(width => ({ dataset: 'live', width, theme: 'dark', palette: 'gruvbox' })),
  { dataset: 'live', width: 1440, theme: 'light', palette: 'aiur' },
  ...['dense', 'newrepo', 'noqueue', 'offline'].map(dataset => ({ dataset, width: 1440, theme: 'dark', palette: 'gruvbox' })),
]
for (const cell of cells) test(`list parity ${Object.values(cell).join(' ')}`, async ({ browser }) => {
  test.setTimeout(120000)
  const pair = await openParityPair(browser, { ...cell, ...PARITY_VIEWPORTS.find(v => v.viewport.width === cell.width) }, { query: 'view=list' })
  try {
    for (const side of [pair.design, pair.product]) {
      await expect(side.locator('.bd-list')).toHaveCount(1)
      await side.locator('#bd-vp').evaluate(vp => { vp.scrollTop = 0 })
    }
    await isolateList(pair)
    if (cell.width === 1024) await expect(pair.product.locator('.lr-h .c-ep')).toHaveCSS('display', 'none')
    if (cell.width === 390) await expect(pair.product.locator('.lr-h .c-ag')).toHaveCSS('display', 'none')
    await expectDesignParity(pair, { name: `list-top-${Object.values(cell).join('-')}`, region: '#bd-vp' })
    if (['live', 'dense'].includes(cell.dataset) && cell.theme === 'dark') {
      for (const side of [pair.design, pair.product]) await side.locator('#bd-vp').evaluate(vp => { vp.scrollTop = vp.scrollHeight })
      await expectDesignParity(pair, { name: `list-bottom-${Object.values(cell).join('-')}`, region: '#bd-vp' })
    }
    if (cell.width === 1440 && cell.dataset === 'live' && cell.theme === 'dark') {
      for (const side of [pair.design, pair.product]) { await side.locator('#bd-vp').evaluate(vp => { vp.scrollTop = 0 }); await side.locator('.lr[data-id]').nth(2).hover() }
      await expectDesignParity(pair, { name: 'list-hover', region: '#bd-vp' })
    }
  } finally { await pair.close() }
})
