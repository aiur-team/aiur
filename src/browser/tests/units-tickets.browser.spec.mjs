import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'
import { expectAuditClean } from './support/browser-helpers.mjs'
import { openUnits, openWritableUnits } from './support/units-helpers.mjs'

test('Tickets panel keeps details readable and gates Add an agent by dashboard mode', async ({ page }) => {
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

  const readOnlyAddAgent = panel.getByRole('button', { name: 'Add an agent to ticket 2101 unavailable on this read-only dashboard' })
  await expect(panel.locator('#tickets-agent-readonly')).toContainText('aiur --todo <ticket-id>')
  await expect(readOnlyAddAgent).toBeDisabled()
  await expect(readOnlyAddAgent).toHaveAttribute('aria-describedby', 'tickets-agent-readonly')
  expect(await readOnlyAddAgent.getAttribute('phx-click')).toBeNull()
  await expect(page.locator('#add-agent-modal')).toHaveCount(0)

  await openWritableUnits(page)
  await expect(page.locator('#tickets-agent-readonly')).toHaveCount(0)
  const addAgent = page.getByRole('button', { name: 'Add an agent to ticket 2101' })
  await expect(addAgent).toBeEnabled()
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

  // `.btn` is back in scope: the primary button used to paint white straight
  // onto the bright `--accent` (3.51:1 in the dark theme), and now takes its
  // fill and ink from `--accent-strong`/`--on-accent` instead.
  const modalAccessibility = await new AxeBuilder({ page }).include('#add-agent-modal').analyze()
  expectAuditClean(modalAccessibility)

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
