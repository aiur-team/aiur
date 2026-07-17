import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'
import { assertNoDocumentOverflow } from './support/browser-helpers.mjs'
import { nextPaint } from './support/measurements.mjs'

async function loadTicketContextFixture(page) {
  await page.goto('/auth/read_only')
  await page.goto('/ticket-context')
  await expect(page.locator('[data-ticket-context-fixture="true"]')).toBeVisible()
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
  await expect(page.getByRole('dialog')).toHaveCount(0)
}

async function openConfiguredTicket(page) {
  const origin = page.locator('button[data-ticket-identifier="42"]')
  await origin.focus()
  await page.keyboard.press('Enter')

  const dialog = page.getByRole('dialog', { name: 'Configured ticket' })
  await expect(dialog).toBeVisible()
  await expect(dialog.getByRole('heading', { name: 'Configured ticket' })).toBeFocused()
  return { dialog, origin }
}

test('ticket context keeps semantic content, touch targets, and origin focus accessible at responsive sizes', async ({ browser }) => {
  test.setTimeout(60_000)

  for (const { width, isMobile, forcedColors } of [
    { width: 320, isMobile: true, forcedColors: 'active' },
    { width: 768, isMobile: false, forcedColors: 'none' },
    { width: 1440, isMobile: false, forcedColors: 'none' }
  ]) {
    const context = await browser.newContext({
      viewport: { width, height: 844 },
      hasTouch: isMobile,
      isMobile,
      reducedMotion: 'reduce',
      forcedColors
    })
    const page = await context.newPage()

    try {
      await loadTicketContextFixture(page)
      const { dialog, origin } = await openConfiguredTicket(page)
      const heading = dialog.getByRole('heading', { name: 'Configured ticket' })
      const close = dialog.getByRole('button', { name: 'Close' })
      const commands = dialog.getByRole('link', { name: 'Commands' })

      await expect(dialog.getByRole('status')).toContainText('Ticket detail is current.')
      await expect(dialog.getByText('Progress updated')).toBeVisible()
      await expect(dialog.getByRole('heading', { name: 'Blocked by' })).toBeVisible()
      await expect(dialog.getByRole('heading', { name: 'Blocking' })).toBeVisible()
      await expect(dialog.getByText('Pull request', { exact: true })).toHaveAttribute('aria-disabled', 'true')
      await expect(dialog.getByText('Pull request has not been opened.')).toBeVisible()
      await expect(dialog.getByRole('link', { name: 'Issue' })).toHaveAttribute('href', 'https://github.com/owner/repo/issues/42')
      await expect(dialog.getByRole('link', { name: 'Chat' })).toHaveAttribute('href', '/chat/42')
      await expect(commands).toHaveAttribute('href', '/decisions/42')
      await expect.poll(() => page.evaluate(() => window.matchMedia('(prefers-reduced-motion: reduce)').matches)).toBe(true)
      await expect.poll(() => page.evaluate(() => getComputedStyle(document.querySelector('.ticket-context-panel')).transitionProperty)).toBe('none')
      await expect.poll(() => page.evaluate(() => window.matchMedia('(forced-colors: active)').matches)).toBe(forcedColors === 'active')

      const targetHeights = await dialog.locator('button, a[href], .link-pill[aria-disabled="true"]').evaluateAll((elements) =>
        elements.map((element) => element.getBoundingClientRect().height)
      )
      expect(targetHeights.length).toBeGreaterThan(0)
      expect(targetHeights.every((height) => height >= 44)).toBe(true)

      await page.evaluate(() => { document.documentElement.dataset.theme = 'light' })
      await expect(page.locator('html')).toHaveAttribute('data-theme', 'light')

      await page.keyboard.press('Shift+Tab')
      await expect(commands).toBeFocused()
      await page.keyboard.press('Tab')
      await expect(close).toBeFocused()

      await page.evaluate(() => { document.documentElement.style.fontSize = '200%' })
      await nextPaint(page)
      await assertNoDocumentOverflow(page)

      const accessibility = await new AxeBuilder({ page }).analyze()
      expect(accessibility.violations).toEqual([])

      if (isMobile) {
        await close.tap()
      } else {
        await heading.focus()
        await page.keyboard.press('Escape')
      }

      await expect(page.getByRole('dialog')).toHaveCount(0)
      await expect(page.locator('#ticket-context-fixture-status')).toHaveText('Ticket context closed.')
      await expect(origin).toBeFocused()

      await page.reload()
      await expect(page.locator('[data-ticket-context-fixture="true"]')).toBeVisible()
      await expect(page.getByRole('dialog')).toHaveCount(0)
    } finally {
      await context.close()
    }
  }
})

test('relationship replacement, stale completion, generation, root, and removal transitions stay scoped', async ({ page }) => {
  await loadTicketContextFixture(page)
  let { dialog } = await openConfiguredTicket(page)

  const external = dialog.getByRole('link', { name: /Ticket 9/ })
  await expect(external).toHaveAttribute('href', 'https://github.com/other/repo/issues/9')
  await expect(external).toHaveAttribute('target', '_blank')
  await expect(external).toHaveAttribute('rel', 'noopener noreferrer')
  await expect(dialog.getByText('Dependency is outside the configured repository.')).toBeVisible()
  await expect(dialog.getByText('Ticket 8', { exact: true })).toBeVisible()
  await expect(dialog.getByRole('link', { name: 'Ticket 8' })).toHaveCount(0)
  await expect(dialog.getByRole('button', { name: 'Ticket 8' })).toHaveCount(0)

  await dialog.getByRole('button', { name: 'Upstream ticket' }).click()
  dialog = page.getByRole('dialog', { name: 'Upstream ticket' })
  await expect(dialog.getByRole('heading', { name: 'Upstream ticket' })).toBeFocused()

  await page.locator('#fixture-stale-completion').evaluate((element) => element.click())
  await expect(page.locator('#ticket-context-fixture-status')).toHaveText('Stale completion rejected.')
  await expect(dialog.getByRole('heading', { name: 'Upstream ticket' })).toBeVisible()

  await dialog.getByRole('button', { name: 'Back' }).click()
  dialog = page.getByRole('dialog', { name: 'Configured ticket' })
  await expect(dialog.getByRole('heading', { name: 'Configured ticket' })).toBeFocused()

  await dialog.getByRole('button', { name: 'Downstream ticket' }).click()
  dialog = page.getByRole('dialog', { name: 'Downstream ticket' })
  await expect(dialog.getByRole('heading', { name: 'Downstream ticket' })).toBeFocused()
  await expect(dialog.getByRole('status')).toContainText('Ticket detail is stale.')
  await expect(dialog.getByText('Chat is stale.')).toBeVisible()
  await expect(dialog.getByText('Commands are unauthorized.')).toBeVisible()

  await dialog.getByRole('button', { name: 'Back' }).click()
  dialog = page.getByRole('dialog', { name: 'Configured ticket' })
  await expect(dialog.getByRole('heading', { name: 'Configured ticket' })).toBeFocused()
  const chat = dialog.getByRole('link', { name: 'Chat' })
  await chat.focus()

  await page.locator('#fixture-generation').evaluate((element) => element.click())
  await expect(page.locator('#ticket-context-fixture-status')).toHaveText('Graph generation reconciled.')
  await expect(chat).toBeFocused()
  await expect(dialog.getByRole('heading', { name: 'Configured ticket' })).toBeVisible()

  await page.locator('#fixture-tick').evaluate((element) => element.click())
  await expect(page.locator('#ticket-context-fixture-status')).toHaveText('Unrelated LiveView patch applied.')
  await expect(chat).toBeFocused()

  await page.locator('#fixture-root').evaluate((element) => element.click())
  await expect(page.getByRole('dialog')).toHaveCount(0)
  await expect(page.locator('#ticket-context-fixture-status')).toHaveText('Build Order root changed.')
  const newRootOrigin = page.locator('button[data-ticket-identifier="42"]')
  await expect(newRootOrigin).not.toBeFocused()

  await newRootOrigin.focus()
  await page.keyboard.press('Enter')
  await expect(page.getByRole('dialog', { name: 'Configured ticket' })).toBeVisible()

  await page.locator('#fixture-remove-selected').evaluate((element) => element.click())
  await expect(page.getByRole('dialog')).toHaveCount(0)
  await expect(page.locator('#ticket-context-fixture-status')).toHaveText('Selected member removed.')
  await expect(page.locator('button[data-ticket-identifier="42"]')).toHaveCount(0)
})
