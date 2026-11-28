import { expect, test } from '@playwright/test'
import { openFixture } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

async function ready(page, reset = '/conversation-fixture/reset?empty=true') {
  await openFixture(page)
  await page.context().setHTTPCredentials(dashboardCredentials)
  expect((await page.request.post(reset)).ok()).toBe(true)
}

for (const [width, height, maxPanel] of [[1440, 900, 360], [390, 844, 844 / 2]]) {
  test(`${width} px: Executor footer on every dashboard page expands within bounds and Esc closes it`, async ({ page }) => {
    await page.setViewportSize({ width, height })
    await ready(page)
    for (const path of ['/', '/analytics', '/streamdeck']) {
      await page.goto(path)
      const footer = page.locator('#executor-footer')
      await expect(footer.locator('.executor-footer__label')).toHaveText('Executor')
      await expect(page.locator('#executor-footer-state')).toHaveText('not attached')
      await expect(page.locator('#executor-footer-toggle')).toBeVisible()
    }
    await expect(page.locator('a.snav[href="/executor"]')).toHaveCount(0)

    const toggle = page.locator('#executor-footer-toggle')
    const box = await toggle.boundingBox()
    expect(Math.abs(box.width - box.height)).toBeLessThan(1)
    await toggle.click()
    const panel = page.locator('#executor-footer-panel')
    await expect(panel).toBeVisible()
    await expect(toggle).toHaveAttribute('aria-expanded', 'true')
    await expect(panel).toContainText('aiur executor-attach --harness claude')
    const panelHeight = (await panel.boundingBox()).height
    expect(panelHeight).toBeLessThanOrEqual(Math.min(maxPanel, height * (width > 960 ? 0.4 : 0.5)) + 1)

    if (width <= 960) {
      const nav = await page.locator('.aiur-shell__sidebar').boundingBox()
      const footerBox = await page.locator('#executor-footer').boundingBox()
      expect(footerBox.y + footerBox.height).toBeLessThanOrEqual(nav.y + 1)
    }
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)

    await page.keyboard.press('Escape')
    await expect(panel).toBeHidden()
    await expect(toggle).toHaveAttribute('aria-expanded', 'false')
  })
}

test('open state survives navigation and reload; /executor opens the footer expanded', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 })
  await ready(page, '/conversation-fixture/reset')
  await page.goto('/executor')
  await expect(page).toHaveURL(/\/$/)
  await expect(page.locator('#executor-footer-panel')).toBeVisible()
  await expect(page.locator('#executor-footer[data-state="ended"]')).toBeAttached()
  await expect(page.locator('#executor-footer-events')).toContainText('PR #42 merged')

  await page.locator('#executor-footer-toggle').click()
  await expect(page.locator('#executor-footer-panel')).toBeHidden()
  await page.getByRole('link', { name: 'Analytics', exact: true }).click()
  await expect(page).toHaveURL(/\/analytics$/)
  await expect(page.locator('#executor-footer-panel')).toBeHidden()
  await page.locator('#executor-footer-toggle').click()
  await page.reload()
  await expect(page.locator('#executor-footer-panel')).toBeVisible()
})

test('background agents report unavailable when the harness does not expose a roster', async ({ page }) => {
  await ready(page)
  await page.goto('/executor')
  const background = page.getByRole('region', { name: 'Background agents' })
  await expect(background).toContainText('Not available for this harness (no_attached_harness)')
  await expect(background.getByRole('listitem')).toHaveCount(0)
  await expect(background).not.toContainText('No background agents')
})

test('answer an Executor Command from Blockers at 390 px', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await ready(page)
  const seeded = await page.request.get('/command-answer-control/answerable?executor=true')
  expect(seeded.ok()).toBe(true)
  await page.goto('/executor')

  const card = page.locator('#executor-blockers').getByRole('article', { name: 'Inline Command' })
  await expect(card).toHaveAttribute('data-command-state', 'pending')
  await card.getByRole('radio', { name: 'Approve' }).check()
  await card.getByRole('button', { name: 'Decision', exact: true }).click()
  await expect(card).toHaveAttribute('data-command-state', 'answered')
  await expect(card.locator('.decision-answer-summary')).toContainText('Approve')
  await expect(card.getByRole('button', { name: 'Decision', exact: true })).toHaveCount(0)
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)

  const stored = await (await page.request.get('/command-answer-state')).json()
  expect(stored).toMatchObject({ selected_option_id: 'approve', actor: { kind: 'operator' } })
})
