import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'
import { assertNoDocumentOverflow, expectAuditClean, openFixture, settleAnimations } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

const answeredRow = '#history-answered-command'
const answeredPanel = '#history-detail-history-answered-command'

async function openCommands (page) {
  await openFixture(page)
  await page.context().setHTTPCredentials(dashboardCredentials)
  await page.goto('/decisions')
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
}

test('a history row expands in place and reports the recorded decision honestly', async ({ page }) => {
  await openCommands(page)

  const table = page.locator('table.history-table')
  await expect(table).toBeVisible()

  // "Outcome" became "Decision", and the per-row Open button is gone: the row
  // itself is the control.
  await expect(table.locator('thead')).toContainText('Decision')
  await expect(table.locator('thead')).not.toContainText('Outcome')
  await expect(table.getByRole('link', { name: 'Open' })).toHaveCount(0)

  // An answered Command quotes what the operator actually said; an expired one
  // reports that nobody decided anything.
  await expect(page.locator(`${answeredRow} .history-decision`))
    .toHaveText('“it is the executor\'s job to review”')
  await expect(page.locator('#history-expired-command .history-decision')).toHaveText('N/A')

  const toggle = page.locator(`${answeredRow} button.history-row-toggle`)
  await expect(toggle).toHaveAttribute('aria-expanded', 'false')
  await expect(page.locator(answeredPanel)).toHaveCount(0)

  // The collapsed table gets an unrestricted axe pass, contrast included —
  // this is where the status chips live, and one of them ("Expired") is the
  // reason the light-theme attention ink was too pale to read.
  const collapsedAudit = await new AxeBuilder({ page }).include('.command-history').analyze()
  expectAuditClean(collapsedAudit)

  // Clicking the row — not a button inside it — opens the accordion, and the
  // context arrives beneath that row rather than at the top of the page.
  await page.locator(`${answeredRow} .history-when`).click()

  await expect(page).toHaveURL(/\/decisions\/answered-command$/)
  await expect(toggle).toHaveAttribute('aria-expanded', 'true')
  const panel = page.locator(answeredPanel)
  await expect(panel).toBeVisible()
  await expect(panel).toContainText('The retained Command context lives here.')
  await expect(panel).toContainText('Event timeline')

  // Both rects are read in one evaluation: focusing the opened panel scrolls
  // the page, so two separate reads would compare different viewport origins.
  const placement = await page.evaluate(([rowSelector, panelSelector]) => {
    const row = document.querySelector(rowSelector).getBoundingClientRect()
    const detail = document.querySelector(panelSelector).getBoundingClientRect()
    return { rowBottom: row.bottom, detailTop: detail.top, previousRowId: document.querySelector(panelSelector).previousElementSibling.id }
  }, [answeredRow, answeredPanel])

  expect(placement.previousRowId).toBe('history-answered-command')
  expect(placement.detailTop).toBeGreaterThanOrEqual(placement.rowBottom - 1)

  await assertNoDocumentOverflow(page)

  // Expanded, contrast is audited too. `color-contrast` used to be disabled
  // here because the `.decision-answer-summary` labels failed it — but the
  // panel opens on a 0.22s `detail-open` fade, and the scan was reading those
  // labels part-way through it (#569560 at 3.94:1, a partly transparent
  // --good-ink). Settled, they measure 7.07:1 and the rule can stay on.
  await settleAnimations(page, answeredPanel)
  const expandedAudit = await new AxeBuilder({ page }).include('.command-history').analyze()
  expectAuditClean(expandedAudit)

  // A click inside the panel must not bubble into a row toggle. The panel is a
  // sibling row, deliberately outside the clickable one — the operator has to
  // be able to work in there without the thing closing under them.
  await panel.getByText('The retained Command context lives here.').click()
  await expect(toggle).toHaveAttribute('aria-expanded', 'true')
  await expect(panel).toBeVisible()

  await page.locator(`${answeredRow} .history-when`).click()
  await expect(toggle).toHaveAttribute('aria-expanded', 'false')
  await expect(page.locator(answeredPanel)).toHaveCount(0)
})

// Enter and Space are asserted from a freshly loaded page each time. Opening a
// row moves focus into the panel, so reusing one page would mean wrestling
// focus back from the app between presses and asserting a race, not a keymap.
for (const key of ['Enter', ' ']) {
  test(`a history row accordion opens from the keyboard with ${key === ' ' ? 'Space' : key}`, async ({ page }) => {
    await openCommands(page)

    const toggle = page.locator(`${answeredRow} button.history-row-toggle`)

    // Reachable, not just clickable: the control takes focus in the tab order.
    await toggle.focus()
    await expect(toggle).toBeFocused()

    await page.keyboard.press(key)

    await expect(toggle).toHaveAttribute('aria-expanded', 'true')
    await expect(page.locator(answeredPanel)).toBeVisible()
    await expect(page).toHaveURL(/\/decisions\/answered-command$/)

    // Opening moves focus into the panel; wait for that before taking focus
    // back, or the close press below lands on whatever the race left focused.
    await expect(page.locator('#decision-detail-answered-command')).toBeFocused()

    await toggle.focus()
    await page.keyboard.press(key)

    // Closing removes the panel and whatever inside it held focus, so the row's
    // control has to get it back — otherwise the keyboard user is dropped to
    // <body> and has to tab in from the top of the page again.
    await expect(toggle).toHaveAttribute('aria-expanded', 'false')
    await expect(page.locator(answeredPanel)).toHaveCount(0)
    await expect(toggle).toBeFocused()
  })
}
