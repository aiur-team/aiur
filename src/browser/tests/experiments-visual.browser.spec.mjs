import { test, expect } from '@playwright/test'
import { getMaskConfig, openVisualRoute } from '../support/visual.mjs'

// Baseline cases deliberately guard existing page states against future visual regressions.
test.use({ reducedMotion: 'reduce' })
// The experiments project shares one worker across both scenario-changing files.

// Real fixture ids: release-speed (line, evidence, guarded n, report) and
// cohort-speed (A/B, no evidence or report yet). Scenario seeding is a
// redirecting control route, so each state seeds first and then navigates.
const STATES = [
  { name: 'line', scenario: 'mixed', path: '/experiments/release-speed', target: '#exp-detail', ready: '#exp-charts' },
  { name: 'charts', scenario: 'mixed', path: '/experiments/release-speed', target: '#exp-charts', ready: '#exp-charts' },
  { name: 'report', scenario: 'mixed', path: '/experiments/release-speed', target: '#exp-report', ready: '#exp-report' },
  { name: 'not-enough-data', scenario: 'mixed', path: '/experiments', target: '.exp-index', ready: '.exp-index' },
  { name: 'cohort-pending', scenario: 'mixed', path: '/experiments/cohort-speed', target: '#exp-detail', ready: '[data-empty-reason="evidence_pending"]' },
  { name: 'empty', scenario: 'empty', path: '/experiments', target: '#experiments-page', ready: '[data-empty-reason="no_experiments"]' },
  { name: 'custom-pack', scenario: 'custom-pack', path: '/experiments/custom-latency', target: '#exp-detail', ready: '#exp-detail' }
]
const VIEWPORTS = [{ width: 1440, height: 900 }, { width: 1024, height: 768 }, { width: 390, height: 844 }]

async function open(page, { theme, palette, scenario, path }) {
  await openVisualRoute(page, { theme, palette, route: `/experiments-control/${scenario}` })
  if (path !== '/experiments') await page.goto(path)
  await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1)
  await page.evaluate(() => document.fonts.ready)
  // Element shots taller than the viewport scroll under the fixed shell chrome.
  await page.addStyleTag({ content: '.ax-top, .sidenav { visibility: hidden !important } .readonly-banner:has(b) { display: none !important } #exp-report time { visibility: hidden !important; display: inline-block; width: 5ch; white-space: nowrap }' })
}

for (const theme of ['light', 'dark']) {
  for (const viewport of VIEWPORTS) {
    const size = `${viewport.width}x${viewport.height}`
    const mobile = viewport.width <= 959
    test.describe(`experiments ${theme} ${size}`, () => {
      test.use({ viewport, deviceScaleFactor: mobile ? 3 : 1, isMobile: mobile, hasTouch: mobile })
      for (const state of STATES) {
        test(state.name, async ({ page }) => {
          await open(page, { theme, ...state })
          // Phones show index and detail on separate screens.
          const target = page.locator(state.target).first()
          if (mobile && state.path === '/experiments' && state.scenario === 'mixed') {
            await expect(page.locator(state.ready).first()).toBeVisible()
          } else {
            await expect(page.locator(state.ready).first()).toBeAttached()
          }
          await expect(target).toBeVisible()
          await expect(target).toHaveScreenshot(`${theme}-${size}-${state.name}.png`, { mask: getMaskConfig(page) })
        })
      }
      if (mobile) {
        test('mobile-index', async ({ page }) => {
          await open(page, { theme, scenario: 'mixed', path: '/experiments' })
          await expect(page.locator('.exp-index')).toBeVisible()
          await expect(page).toHaveScreenshot(`${theme}-${size}-mobile-index.png`, { fullPage: true, mask: getMaskConfig(page) })
        })
      }
    })
  }
}

test.describe('aiur palette', () => {
  test.use({ viewport: VIEWPORTS[0] })
  test('dark 1440 line experiment', async ({ page }) => {
    await open(page, { theme: 'dark', palette: 'aiur', scenario: 'mixed', path: '/experiments/release-speed' })
    await expect(page.locator('html')).toHaveAttribute('data-palette', 'aiur')
    await expect(page.locator('#exp-detail')).toHaveScreenshot('aiur-dark-1440x900-line.png', { mask: getMaskConfig(page) })
  })
})

// Sign-off sheet: not a comparison. Composes live shots into one image and
// attaches it so CI keeps it for the ticket.
test('contact sheet', async ({ page, browser }, testInfo) => {
  const cells = []
  for (const theme of ['light', 'dark']) {
    for (const viewport of [VIEWPORTS[0], VIEWPORTS[2]]) {
      await page.setViewportSize(viewport)
      for (const state of [STATES[0], STATES[5]]) {
        await open(page, { theme, ...state })
        const shot = await page.screenshot({ fullPage: true, mask: getMaskConfig(page) })
        cells.push({ label: `${theme} ${viewport.width} ${state.name}`, src: `data:image/png;base64,${shot.toString('base64')}` })
      }
    }
  }
  const sheet = await browser.newPage({ viewport: { width: 1600, height: 900 } })
  const figures = cells.map(c => `<figure style="margin:0;max-width:380px"><figcaption>${c.label}</figcaption><img src="${c.src}" style="width:100%;border:1px solid #888"></figure>`)
  await sheet.setContent(`<body style="margin:8px;font:12px sans-serif;display:flex;flex-wrap:wrap;gap:8px;align-items:flex-start">${figures.join('')}</body>`)
  await sheet.evaluate(() => Promise.all([...document.images].map(image => image.decode())))
  const path = testInfo.outputPath('experiments-contact-sheet.png')
  await sheet.screenshot({ path, fullPage: true })
  await sheet.close()
  await testInfo.attach('experiments-contact-sheet', { path, contentType: 'image/png' })
  expect(cells).toHaveLength(8)
})
