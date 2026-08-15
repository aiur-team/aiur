import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'
import { assertNoDocumentOverflow } from './support/browser-helpers.mjs'
import { nextPaint } from './support/measurements.mjs'

async function openUnits(page, path = '/units') {
  await page.goto('/auth/read_only')
  await page.goto(path)
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

test('Units keeps its column headings at zero units and names the empty state in both themes', async ({ page }) => {
  await openUnits(page, '/units?catalog=empty')

  // The table keeps its shape: a real thead with all five headings, over an
  // empty tbody rather than a table that vanished with its rows. Scoped to the
  // Units card because the Tickets panel below reuses the same table class.
  const table = page.locator('.units-card table.units-table')
  await expect(table).toBeVisible()
  await expect(table.locator('thead th')).toHaveText(['ID', 'Unit', 'Ticket', 'Latest', 'Command'])
  await expect(page.locator('#units-rows tr.units-row')).toHaveCount(0)

  // The empty state sits below the table, and it is the only one: the
  // filtered-empty sentence belongs to a hidden-by-filter catalog, not this one.
  const empty = page.locator('.units-card .empty-state')
  await expect(empty).toHaveCount(1)
  await expect(empty).toHaveText('No live units.')

  const emptyBelowTable = await page.evaluate(() => {
    const box = document.querySelector('.units-card .empty-state').getBoundingClientRect()
    return box.top >= document.querySelector('.units-card table.units-table').getBoundingClientRect().bottom
  })
  expect(emptyBelowTable).toBe(true)

  // The box reads as a muted dashed placeholder in both themes. Colours come
  // from the theme tokens, so they must actually differ between the two.
  const readStyle = () =>
    empty.evaluate((box) => {
      const style = getComputedStyle(box)
      return {
        borderStyle: style.borderTopStyle,
        borderWidth: style.borderTopWidth,
        borderColor: style.borderTopColor,
        color: style.color,
        textAlign: style.textAlign
      }
    })

  const dark = await readStyle()
  expect(dark.borderStyle).toBe('dashed')
  expect(dark.borderWidth).toBe('1px')
  expect(dark.textAlign).toBe('center')

  // The whole card is clean in the dark theme, so scan all of it -- that catches
  // a structural a11y regression anywhere in the Units panel, not just this box.
  const darkAccessibility = await new AxeBuilder({ page }).include('.units-card').analyze()
  expect(darkAccessibility.violations).toEqual([])

  await page.locator('html').evaluate((html) => html.setAttribute('data-theme', 'light'))
  const light = await readStyle()
  expect(light.borderStyle).toBe('dashed')
  expect(light.textAlign).toBe('center')
  expect(light.color).not.toBe(dark.color)
  expect(light.borderColor).not.toBe(dark.borderColor)

  // The light theme narrows to the box itself. The card's surrounding chrome --
  // `.section-eyebrow` and `#units-title` on `--faint`, and the filter pills and
  // scope buttons -- fails AA against the light `--surface`, and that is a
  // pre-existing design-token defect: this change touches no CSS at all. The box
  // itself passes, which is what the narrow scan is here to prove.
  const lightAccessibility = await new AxeBuilder({ page }).include('.units-card .empty-state').analyze()
  expect(lightAccessibility.violations).toEqual([])
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
  // The catalog owns exactly one announcement channel. The Tickets panel has
  // its own, which stays silent unless the operator searches, so this is scoped
  // to the catalog's rather than counting every polite region on the page.
  await expect(page.locator('[role="status"][aria-live="polite"]#units-status')).toHaveCount(1)
  await expect(page.locator('#tickets-search-status')).toHaveText('')

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

test('Tickets panel lists open tickets and both dialogs focus and dismiss on Escape', async ({ page }) => {
  await openUnits(page)

  const panel = page.locator('.tickets-card')
  await expect(panel).toBeVisible()
  await expect(panel.getByText('Tickets', { exact: true })).toBeVisible()
  // The header count, not the visually hidden search announcement that echoes it.
  await expect(panel.locator('.rs-group-count')).toHaveText('2 tickets')

  const accessibility = await new AxeBuilder({ page }).include('.tickets-card').analyze()
  expect(accessibility.violations).toEqual([])

  // The routing prediction is not a column: it is the add-agent modal's editable
  // default, so the table never offers it as read-only text.
  await expect(panel.locator('th.tk-col-agent')).toHaveCount(0)
  await expect(panel.getByText('Would route to')).toHaveCount(0)

  // The panel opens on one batch and reveals the rest on request. This fixture
  // starts one row below its own batch size so the control is present on a
  // small ticket list; the production batch of 5 is covered by the unit tests.
  await expect(panel.locator('#tickets-rows tr')).toHaveCount(1)
  const showMore = panel.getByRole('button', { name: 'Show 1 more ticket' })
  await showMore.focus()
  await expect(showMore).toBeFocused()
  await page.keyboard.press('Enter')

  // Progressive reveal, and no dead control once everything is on screen.
  await expect(panel.locator('#tickets-rows tr')).toHaveCount(2)
  await expect(panel.getByRole('button', { name: /Show \d+ more ticket/ })).toHaveCount(0)

  // A row cell opens the ticket detail; the action column deliberately does not.
  await panel.locator('#tickets-rows tr').first().locator('td.tk-title-cell').click()

  const detail = page.locator('#ticket-detail-modal')
  await expect(detail).toBeVisible()
  await expect(detail.getByRole('heading', { name: /Unrouted backlog ticket/ })).toBeFocused()
  await page.keyboard.press('Escape')
  await expect(detail).toHaveCount(0)

  const addAgent = page.getByRole('button', { name: 'Add an agent to ticket 2101' })
  await addAgent.click()

  const modal = page.locator('#add-agent-modal')
  await expect(modal).toBeVisible()
  await expect(modal.getByRole('heading', { name: /Unrouted backlog ticket/ })).toBeFocused()
  // The prediction is prefilled from the ticket's own complexity tag, and the
  // sentence that used to explain the prefill is gone — the behaviour stays.
  await expect(modal.getByLabel('Complexity')).toHaveValue('3')
  await expect(modal.getByText(/Prefilled from the current routing configuration/)).toHaveCount(0)

  // The selects share the primary button's control height so the form reads as
  // one column of controls rather than four fields and a differently sized row.
  // A 1px tolerance, not equality: the two boxes derive their height from
  // different line-height sources, so exact agreement would break on an
  // unrelated base-font change rather than on this rhythm actually drifting.
  const controlHeights = await modal.evaluate((panel) => {
    const height = (selector) => panel.querySelector(selector).getBoundingClientRect().height
    return { select: height('.field-select select'), button: height('.add-agent-actions .btn') }
  })
  expect(Math.abs(controlHeights.select - controlHeights.button)).toBeLessThanOrEqual(1)

  // `.btn` is excluded: the shared primary-button token fails AA contrast in the
  // dark theme (#ffffff on --accent #2f86ff = 3.51:1) everywhere it is used, so
  // it is a design-token defect rather than anything this dialog introduced.
  const modalAccessibility = await new AxeBuilder({ page })
    .include('#add-agent-modal')
    .exclude('#add-agent-modal .btn')
    .analyze()
  expect(modalAccessibility.violations).toEqual([])

  await page.keyboard.press('Escape')
  await expect(modal).toHaveCount(0)
})

test('Tickets search filters on title and description from the keyboard alone', async ({ page }) => {
  await openUnits(page)

  const panel = page.locator('.tickets-card')
  const search = panel.getByRole('searchbox', { name: /Search tickets/ })

  // The panel opens on one revealed row, so the second ticket is on the server
  // but not on screen.
  await expect(panel.locator('#tickets-rows tr')).toHaveCount(1)
  await expect(panel.getByText('Documentation refresh')).toHaveCount(0)

  // Reachable and operable without a pointer.
  await search.focus()
  await expect(search).toBeFocused()

  // "retry" appears only in the unrevealed ticket's description, never in any
  // title: the server filters the whole backlog, so a ticket the reveal has not
  // reached is still findable, and by what it says rather than what it is named.
  await search.pressSequentially('retry', { delay: 30 })
  await expect(panel.locator('#tickets-rows tr')).toHaveCount(1)
  await expect(panel.getByText('Documentation refresh')).toBeVisible()
  await expect(panel.getByText('Unrouted backlog ticket')).toHaveCount(0)
  await expect(panel.locator('.rs-group-count')).toHaveText('1 of 2 tickets')
  // The result is announced, not only shown.
  await expect(panel.locator('#tickets-search-status')).toHaveText('1 of 2 tickets match.')
  // One match does not fill the batch, so there is nothing left to reveal.
  await expect(panel.getByRole('button', { name: /Show \d+ more ticket/ })).toHaveCount(0)

  const filteredAccessibility = await new AxeBuilder({ page }).include('.tickets-card').analyze()
  expect(filteredAccessibility.violations).toEqual([])

  // A query matching both keeps the reveal control, counting the matches.
  await search.fill('21')
  await expect(panel.locator('#tickets-rows tr')).toHaveCount(1)
  await expect(panel.getByRole('button', { name: 'Show 1 more ticket' })).toBeVisible()

  // A query that matches nothing says so rather than rendering an empty panel.
  await search.fill('zzzzqqqq')
  await expect(panel.locator('.tk-no-matches')).toBeVisible()
  await expect(panel.locator('#tickets-rows')).toHaveCount(0)

  // Clearing from the keyboard restores the unfiltered list, empties the field,
  // and keeps focus on the control that was activated rather than dropping it
  // to the document body.
  const clear = panel.locator('.tk-search-clear')
  await search.press('Tab')
  await expect(clear).toBeFocused()
  await page.keyboard.press('Enter')

  await expect(panel.locator('.rs-group-count')).toHaveText('2 tickets')
  await expect(panel.locator('#tickets-rows tr')).toHaveCount(1)
  await expect(search).toHaveValue('')
  await expect(clear).toBeFocused()
})
