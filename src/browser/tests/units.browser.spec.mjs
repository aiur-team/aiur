import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'
import { assertNoDocumentOverflow } from './support/browser-helpers.mjs'
import { nextPaint } from './support/measurements.mjs'

async function openUnits(page) {
  await page.goto('/auth/read_only')
  await page.goto('/units')
  await expect(page.locator('[data-units-fixture="true"]')).toBeVisible()
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
}

// Rows in the compact Units table open the ticket-context dialog via a click on
// the ID cell (which carries phx-click="inspect-unit"); there is no per-row
// "Inspect ticket" button anymore.

test('Units keeps complete semantic rows, named actions, and 44px targets across required widths and zoom', async ({ browser }) => {
  test.setTimeout(60_000)

  for (const width of [320, 390, 768, 960, 1440]) {
    const mobile = width <= 390
    const context = await browser.newContext({
      viewport: { width, height: 900 },
      hasTouch: mobile,
      isMobile: mobile,
      reducedMotion: 'reduce'
    })
    const page = await context.newPage()

    try {
      await openUnits(page)

      const rows = page.locator('#units-rows tr.units-row')
      const first = rows.first()

      // The live scope shows the running Unit (#1110) plus the paused Unit (#1111).
      await expect(rows).toHaveCount(2)
      await expect(first).toHaveAttribute('data-github-url', 'https://github.com/its-everdred/aiur/issues/1110')
      await expect(first.locator('.ut-id-num')).toHaveText('1110')
      await expect(first).toContainText('Responsive Units interface')
      await expect(first).toContainText('gpt-5.6-terra')
      await expect(first).toContainText('L2')
      // Latest evidence is the branch push, rendered as its bare name with a branch glyph.
      await expect(first.locator('.ut-latest-text')).toHaveText('feature pushed')
      await expect(first.locator('.ut-pbar i')).toHaveAttribute('style', /width:50%/)

      // The paused Unit has unknown progress, rendered as an em dash, not a percentage.
      const paused = rows.nth(1)
      await expect(paused.locator('.ut-latest-meta').first()).toContainText('—')

      // Rows open via a click on the ID cell (the ticket-context origin), not a button.
      await expect(first.locator('td.ut-id-cell[phx-click="inspect-unit"][data-ticket-context-origin]')).toHaveCount(1)
      await expect(first).not.toHaveAttribute('phx-click')

      // Named, accessible row actions live in the Command column.
      const actions = first.locator('nav.units-actions')
      await expect(actions).toHaveAttribute('aria-label', 'Actions for its-everdred/aiur #1110')
      // The running Unit exposes a chat button (which carries the agent log
      // beneath the conversation); the standalone agent-log row action is gone.
      await expect(first.getByRole('button', { name: 'Open chat for its-everdred/aiur #1110' })).toBeVisible()

      // Live-region status is a single polite, atomic node.
      await expect(page.locator('#units-status')).toHaveCount(1)
      await expect(page.locator('#units-status')).toHaveAttribute('aria-atomic', 'true')
      await expect(page.locator('[role="status"][aria-live="polite"]#units-status')).toHaveCount(1)

      // Genuine a11y: every icon-only row action offers a >=44px tap target even
      // though the visible control stays compact (a transparent centered overlay
      // supplies the hit area).
      const hitAreas = await first.locator('.units-icon-action').evaluateAll((buttons) =>
        buttons.map((button) => {
          const overlay = getComputedStyle(button, '::after')
          return {
            width: Number.parseFloat(overlay.width),
            height: Number.parseFloat(overlay.height)
          }
        })
      )
      expect(hitAreas.length).toBeGreaterThan(0)
      expect(hitAreas.every(({ width: w, height: h }) => w >= 44 && h >= 44)).toBe(true)

      if (mobile) {
        await page.getByRole('button', { name: 'Select no filters' }).tap()
        const resetSize = await page.getByRole('button', { name: 'Reset Units filters' }).evaluate((button) => {
          const box = button.getBoundingClientRect()
          return { width: box.width, height: box.height }
        })
        expect(resetSize.width).toBeGreaterThanOrEqual(44)
        expect(resetSize.height).toBeGreaterThanOrEqual(44)
        await page.getByRole('button', { name: 'Reset Units filters' }).tap()
      }

      // Compact layout: the row flows as flex on true phones and stays a single
      // table row on wider viewports.
      const rowDisplay = await first.evaluate((row) => getComputedStyle(row).display)
      expect(rowDisplay).toBe(mobile ? 'flex' : 'table-row')
      await expect.poll(() => page.evaluate(() => window.matchMedia('(prefers-reduced-motion: reduce)').matches)).toBe(true)

      await page.evaluate(() => { document.documentElement.style.fontSize = '200%' })
      await nextPaint(page)
      await assertNoDocumentOverflow(page)

      if (width === 390 || width === 1440) {
        const accessibility = await new AxeBuilder({ page }).analyze()
        expect(accessibility.violations).toEqual([])
      }

      if (mobile) {
        await first.locator('td.ut-id-cell').tap()
        await expect(page.getByRole('dialog', { name: 'Responsive Units interface' })).toBeVisible()
        await page.getByRole('button', { name: 'Close' }).tap()
      }
    } finally {
      await context.close()
    }
  }
})

test('Units URL history restores independent conditions and copied links', async ({ page, context }) => {
  await openUnits(page)

  // The bulk "All" button selects the unfinished scope plus every condition.
  await page.getByRole('button', { name: 'Select all preceding filters' }).click()
  await expect(page).toHaveURL(/\/units\?v=1&scope=unfinished&conditions=active%2Calert%2Cpaused%2Cqueued%2Cfinished$/)

  // Toggle down to just the paused condition to isolate the paused follow-up Unit.
  await page.getByRole('button', { name: /Active/ }).click()
  await page.getByRole('button', { name: /Alert/ }).click()
  await page.getByRole('button', { name: /Queued/ }).click()
  await page.getByRole('button', { name: /Finished/ }).click()
  await expect(page).toHaveURL(/conditions=paused$/)
  await expect(page.getByText('Paused provider follow-up')).toBeVisible()
  await expect(page.getByText('Responsive Units interface')).toHaveCount(0)

  const copiedUrl = page.url()
  const copied = await context.newPage()
  await copied.goto(copiedUrl)
  await expect(copied.getByRole('button', { name: /Paused/ })).toHaveAttribute('aria-pressed', 'true')
  await expect(copied.getByText('Paused provider follow-up')).toBeVisible()
  await copied.close()

  await page.goBack()
  await page.goBack()
  await page.goBack()
  await page.goBack()
  // Back through each condition toggle to the "All" selection (unfinished scope,
  // every condition), which restores the active Unit alongside the paused one.
  await expect(page).toHaveURL(/scope=unfinished&conditions=active%2Calert%2Cpaused%2Cqueued%2Cfinished$/)
  await expect(page.getByRole('button', { name: /Finished/ })).toHaveAttribute('aria-pressed', 'true')
  await expect(page.getByText('Responsive Units interface')).toBeVisible()
  await expect(page.getByText('Paused provider follow-up')).toBeVisible()

  await page.goBack()
  // Back to the default live scope, which drops the queued/finished Units.
  await expect(page).toHaveURL(/\/units$/)
  await expect(page.getByText('Responsive Units interface')).toBeVisible()

  // "None" clears everything to an empty scope, which surfaces the reset affordance.
  await page.getByRole('button', { name: 'Select no filters' }).click()
  await expect(page.getByRole('button', { name: 'Reset Units filters' })).toBeVisible()
  await page.getByRole('button', { name: 'Reset Units filters' }).click()
  await expect(page).toHaveURL(/\/units\?v=1$/)
  await expect(page.getByText('Responsive Units interface')).toBeVisible()
})

test('Units conversation drawer hook manages focus, Escape, and focus return', async ({ page }) => {
  await openUnits(page)

  const origin = page.getByRole('button', { name: 'Open chat for its-everdred/aiur #1110' })
  await origin.click()

  const drawer = page.getByRole('dialog', { name: 'Responsive Units interface' })
  await expect(drawer).toBeVisible()
  await expect(drawer.getByRole('heading', { name: 'Responsive Units interface' })).toBeFocused()
  await expect(drawer).toContainText('Conversation drawer hook is running.')

  await page.keyboard.press('Escape')

  await expect(drawer).toHaveCount(0)
  await expect(origin).toBeFocused()
})

test('Units preserves focused controls on stable updates and restores dialog focus with a safe fallback', async ({ page }) => {
  await openUnits(page)

  // Focus a real, named row action; a stable same-identity update must not steal focus.
  const agentLog = page.getByRole('button', { name: 'Open chat for its-everdred/aiur #1110' })
  const agentLogId = await agentLog.getAttribute('id')

  // Open the ticket-context dialog by clicking the ID cell (the inspect origin).
  const firstRow = page.locator('#units-rows tr.units-row').first()
  await firstRow.locator('td.ut-id-cell').click()

  let dialog = page.getByRole('dialog', { name: 'Responsive Units interface' })
  await expect(dialog).toBeVisible()
  await expect(dialog.getByRole('heading', { name: 'Responsive Units interface' })).toBeFocused()
  await page.keyboard.press('Escape')
  await expect(dialog).toHaveCount(0)
  // With no restorable click origin the dialog falls back to the Units heading.
  await expect(page.getByRole('heading', { name: 'Units' })).toBeFocused()

  // A stable same-identity update keeps focus on the currently focused control.
  await agentLog.focus()
  await expect(agentLog).toBeFocused()
  const announcementBefore = await page.locator('#units-status').textContent()
  await page.locator('#same-identity-update').evaluate((button) => button.click())
  await expect(page.locator(`#${agentLogId}`)).toBeFocused()
  await expect(page.getByText('Responsive Units interface · updated')).toBeVisible()
  await expect(page.locator('#units-status')).not.toHaveText(announcementBefore)
  await expect(page.locator('#units-status')).toContainText(/Catalog update [a-f0-9]{10}/)
  await expect(page.locator('[role="status"][aria-live="polite"]')).toHaveCount(1)

  // Reopen after the update: the dialog reflects the new title.
  await page.locator('#units-rows tr.units-row').first().locator('td.ut-id-cell').click()
  dialog = page.getByRole('dialog', { name: 'Responsive Units interface · updated' })
  await expect(dialog).toBeVisible()

  // Removing the inspected Unit and closing falls back safely to the Units heading.
  await page.locator('#remove-selected-unit').evaluate((button) => button.click())
  await page.keyboard.press('Escape')
  await expect(dialog).toHaveCount(0)
  await expect(page.getByRole('heading', { name: 'Units' })).toBeFocused()
})
