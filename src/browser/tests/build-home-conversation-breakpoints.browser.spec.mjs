import { test, expect } from '@playwright/test'
import { mountConversation, scenario } from './support/build-conversation.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ httpCredentials: dashboardCredentials, viewport: { width: 1440, height: 900 }, reducedMotion: 'reduce' })

test('milestone dividers and collapsed ticket preamble fit phone and desktop widths', async ({ page }, info) => {
  await mountConversation(page, info)
  await scenario(page, 'kinds', { entries: [
    { id: 'read:1', k: 'say', text: 'Reading the ticket', at: 1791407600000 },
    { id: 'ev:breakpoint:2:implementation_started', k: 'ev', ev: 'milestone', label: 'Implementation started', sub: 'phase.work.start', at: 1791407610000 },
    { id: 'work:1', k: 'say', text: 'Implementation is underway', at: 1791407620000 },
  ] })

  await expect(page.locator('.cv-breakpoint')).toContainText('Implementation started')
  await expect(page.locator('.cv-preamble summary')).toHaveText('Reading ticket')
  await expect(page.locator('.cv-preamble')).not.toHaveAttribute('open', '')

  for (const width of [390, 1440]) {
    await page.setViewportSize({ width, height: 900 })
    const geometry = await page.locator('.cv-breakpoint').evaluate(el => ({
      divider: el.getBoundingClientRect().width,
      log: document.querySelector('#cv-log').getBoundingClientRect().width,
      visible: el.getBoundingClientRect().height > 0,
    }))
    expect(geometry.visible).toBe(true)
    expect(geometry.divider).toBeGreaterThan(0)
    expect(geometry.divider).toBeLessThanOrEqual(geometry.log)
    await expect(page.locator('.cv-preamble')).not.toHaveAttribute('open', '')
    await expect(page.locator('#cv-mm .mm-e[aria-label="Implementation started"]')).toHaveCount(1)
  }
})

test('loading an earlier page moves the collapsed preamble boundary to the first breakpoint', async ({ page }, info) => {
  await mountConversation(page, info)
  const entries = [
    { id: 'read:early', k: 'say', text: 'Earlier reading', at: 1791407600000 },
    { id: 'ev:early', k: 'ev', ev: 'milestone', label: 'Earlier implementation', sub: 'phase.work.start', at: 1791407601000 },
    { id: 'work:early', k: 'say', text: 'Earlier work', at: 1791407602000 },
    { id: 'work:between', k: 'say', text: 'Between breakpoints', at: 1791407603000 },
    { id: 'ev:later', k: 'ev', ev: 'milestone', label: 'Later phase', sub: 'phase.review.start', at: 1791407604000 },
    ...Array.from({ length: 98 }, (_, index) => ({ id: `tail:${index}`, k: 'say', text: `Turn ${index}`, at: 1791407605000 + index })),
  ]
  await scenario(page, 'kinds', { entries })
  await expect(page.locator('.cv-preamble-content')).toContainText('Between breakpoints')
  await page.locator('#cv-log').evaluate(log => { log.scrollTop = 0; log.dispatchEvent(new Event('scroll')) })
  await expect(page.locator('#cv-log [data-k]')).toHaveCount(103)

  await expect(page.locator('.cv-preamble-content')).toHaveText('Earlier reading')
  await expect(page.locator('#cv-log > .cv-breakpoint').first()).toContainText('Earlier implementation')
  await expect(page.locator('#cv-log > [data-eid="work:early"]')).toContainText('Earlier work')
  await expect(page.locator('#cv-log > [data-eid="work:between"]')).toContainText('Between breakpoints')
  await expect(page.locator('.cv-preamble')).not.toHaveAttribute('open', '')
})
