import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'
import { assertNoDocumentOverflow, captureConfiguredScreenshot } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

// The Build Order route renders a synchronous CSS-grid graph (epic columns ×
// execution-wave rows of ticket cards) drawn by the `BuildOrderGrid` client
// hook. There is no layout worker, no ELK geometry round-trip, and no
// `data-layout-*` health state: the semantic cards are always in document flow,
// and the hook only measures rendered card boxes to route dependency edges and
// owns zoom/pan/fit. These specs assert the route's catalog, selected-graph
// truth, ticket-context navigation, URL history, and access control against
// that rendered contract.

async function openCatalog(page) {
  const stylesheet = page.waitForResponse((response) => new URL(response.url()).pathname === '/dashboard.css')
  await page.goto('/build-orders')
  await expect((await stylesheet).status()).toBe(200)
  await expect(page.locator('#build-order-page')).toHaveAttribute('data-build-order-catalog-state', 'ready')
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
  await expect(page.locator('.dashboard-shell')).toHaveCSS('display', 'grid')
}

async function openCatalogEntry(page, title) {
  await page.locator('.bo-catalog-link', { hasText: title }).click()
}

async function openSelectedGraph(page, title) {
  await openCatalogEntry(page, title)
  const graph = page.locator('#selected-build-order-graph')
  await expect(graph.locator('[data-bo-card]').first()).toBeVisible()
  return graph
}

test('production dependency context relationships remain clickable', async ({ page }) => {
  await page.context().setHTTPCredentials(dashboardCredentials)
  await openCatalog(page)
  const graph = await openSelectedGraph(page, 'Release dashboard')

  await graph.locator('.bo-node', { hasText: 'Readiness target' }).click()

  const dialog = page.getByRole('dialog', { name: 'Readiness target' })
  await expect(dialog).toBeVisible()
  const dependency = dialog.getByRole('button', { name: 'Completed dependency', exact: true })
  await expect(dependency).toBeVisible()
  await dependency.click()
  await expect(page.getByRole('dialog', { name: 'Completed dependency' })).toBeVisible()
})

test('production Build Order route keeps catalog, graph truth, context, and URL history scoped', async ({ browser }) => {
  const context = await browser.newContext({
    httpCredentials: dashboardCredentials,
    viewport: { width: 1280, height: 900 },
    reducedMotion: 'reduce'
  })
  const page = await context.newPage()

  try {
    await openCatalog(page)

    // The catalog is a table: every healthy root is a navigable link, an
    // unqualified root stays visible but is not linkable.
    await expect(page.locator('.bo-catalog-table tbody tr')).toHaveCount(4)
    await expect(page.locator('.bo-catalog-link')).toHaveCount(3)
    await expect(page.locator('.bo-catalog-invalid', { hasText: 'Untitled Build Order' })).toBeVisible()
    await expect(page.getByRole('link', { name: 'Release dashboard' })).toHaveAttribute('href', '/build-orders/42')

    const graph = await openSelectedGraph(page, 'Release dashboard')
    await expect(page).toHaveURL(/\/build-orders\/42$/)
    await expect(page.locator('#build-order-page')).toHaveAttribute('data-build-order-status', 'selected')
    await expect(page.getByRole('heading', { name: 'Release dashboard' })).toBeVisible()

    // Every planning member renders as a semantic card in document flow.
    await expect(graph.locator('[data-bo-card]')).toHaveCount(7)
    await expect(graph).toHaveAttribute('data-bo-grid-key', '42:7')

    // The dependency summary reports the graph truth (Phase renamed to Wave).
    const summaryPair = (label) => page.locator('.bo-summary-grid div', { has: page.locator('dt', { hasText: label }) }).locator('dd')
    await expect(summaryPair('Members')).toHaveText('7')
    await expect(summaryPair('External')).toHaveText('1')
    await expect(summaryPair('Waves')).toHaveText('1')

    // Runtime dependency edges carry both cleared and blocking states, and the
    // epic columns / execution waves are labelled.
    for (const state of ['cleared', 'blocking']) {
      await expect(graph.locator(`[data-bo-edge-state="${state}"]`).first()).toBeVisible()
    }
    await expect(graph.locator('.bo-epic-label', { hasText: 'Dashboard UI' })).toBeVisible()
    await expect(graph.locator('.bo-wave-n', { hasText: 'W1' })).toBeVisible()

    // The readiness target card exposes its progress and status word.
    const target = graph.locator('.bo-node', { hasText: 'Readiness target' })
    await expect(target).toHaveAttribute('data-bo-state', 'plain')
    await expect(target.locator('.bo-node-pct')).toHaveText('60%')

    // Enter on a focused, openable card opens its ticket context dialog.
    await target.focus()
    await page.keyboard.press('Enter')

    const dialog = page.getByRole('dialog', { name: 'Readiness target' })
    await expect(dialog).toBeVisible()
    await expect(dialog.getByRole('heading', { name: 'Readiness target' })).toBeFocused()
    await expect(dialog.getByRole('heading', { name: 'Blocked by' })).toBeVisible()
    await expect(dialog.getByRole('link', { name: /Open in GitHub/ })).toHaveAttribute('href', 'https://github.com/owner/repo/issues/5')

    // Following a relationship replaces the dialog subject; Back restores it.
    await dialog.getByRole('button', { name: 'Completed dependency', exact: true }).click()
    const replacement = page.getByRole('dialog', { name: 'Completed dependency' })
    await expect(replacement).toBeVisible()
    await replacement.getByRole('button', { name: 'Back' }).click()
    await expect(page.getByRole('dialog', { name: 'Readiness target' })).toBeVisible()

    // Focus stays trapped on the dialog title while it is open.
    //
    // This previously also polled the topbar clock to prove the LiveView kept
    // ticking behind the dialog. That clock has been removed — it claimed its
    // own line above the route title on narrow viewports — and the route
    // renders no other self-advancing element, so the liveness half of this
    // assertion has no subject. Polling the absent element hung for the full
    // test timeout rather than failing.
    await expect(dialog.getByRole('heading', { name: 'Readiness target' })).toBeFocused()

    // Escape closes the dialog and restores focus to the origin card.
    await page.keyboard.press('Escape')
    await expect(dialog).toHaveCount(0)
    await expect(target).toBeFocused()

    // Navigating back to the catalog and into a stale root swaps the graph.
    await page.getByRole('link', { name: 'Back to all Build Orders' }).click()
    await expect(page).toHaveURL(/\/build-orders$/)
    await openCatalogEntry(page, 'Stale planning lane')

    await expect(page).toHaveURL(/\/build-orders\/43$/)
    await expect(page.locator('#build-order-page')).toHaveAttribute('data-build-order-status', 'selected_stale')
    await expect(page.getByRole('heading', { name: 'Stale last-known-good graph' })).toBeVisible()
    await expect(page.locator('#selected-build-order-graph [data-bo-card]')).toHaveCount(1)

    await page.goBack()
    await expect(page).toHaveURL(/\/build-orders$/)
    await expect(page.locator('.bo-catalog-table')).toBeVisible()
    await page.goForward()
    await expect(page).toHaveURL(/\/build-orders\/43$/)
    await expect(page.getByRole('heading', { name: 'Stale planning lane' })).toBeVisible()

    await page.reload()
    await expect(page.locator('#build-order-page')).toHaveAttribute('data-build-order-root', '43')
    await expect(page.locator('#selected-build-order-graph [data-bo-card]')).toHaveCount(1)

    // The read-only route never mutates. Context navigation and the shell's
    // sidebar collapse toggle are the only permitted phx-clicks — neither writes
    // data; `toggle-nav` flips a per-session view preference held in assigns.
    // Anything else appearing here means a real mutation reached a read-only
    // route, which is what this assertion exists to catch.
    // `toggle-global-pause` is shell chrome, not a route action: it lives in the
    // sidebar on every route, mutates daemon-wide provisioning rather than any
    // Build Order data, and is disabled unless the dashboard is writable.
    const readOnlyEvents = ['open-ticket-context', 'toggle-nav', 'toggle-global-pause']
    const mutationEvents = await page.locator('[phx-click]').evaluateAll((elements) =>
      elements.map((element) => element.getAttribute('phx-click')).filter(Boolean)
    )
    expect(mutationEvents.every((event) => readOnlyEvents.includes(event))).toBe(true)
    await expect(page.locator('form')).toHaveCount(0)
    await assertNoDocumentOverflow(page)

    const accessibility = await new AxeBuilder({ page }).analyze()
    expect(accessibility.violations).toEqual([])
  } finally {
    await context.close()
  }
})

test('production route renders semantic graph cards without a layout round-trip', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()

  try {
    await page.goto('/build-orders/42')
    const graph = page.locator('#selected-build-order-graph')

    // The semantic cards are in document flow immediately — there is no worker
    // geometry to await and no fallback health state to degrade to. Even before
    // the LiveView socket connects, the server-rendered grid carries every card.
    await expect(graph.locator('[data-bo-card]')).toHaveCount(7)
    await expect(graph.getByRole('heading', { name: 'Build order graph' })).toBeAttached()

    // The dependency edge data is embedded for the client hook to route; no SVG
    // path exists until the hook measures the rendered cards.
    await expect(graph.locator('[data-bo-grid-edge-data] [data-bo-edge-source]')).toHaveCount(6)
  } finally {
    await context.close()
  }
})

test('production route swaps the selected graph deterministically across live navigation', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()

  try {
    await page.goto('/build-orders')
    await expect(page.locator('#build-order-page')).toHaveAttribute('data-build-order-catalog-state', 'ready')
    await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)

    const first = await openSelectedGraph(page, 'Release dashboard')
    await expect(first).toHaveAttribute('data-bo-grid-key', '42:7')
    await expect(first.locator('[data-bo-card]')).toHaveCount(7)

    // Live navigation to a different root replaces the whole graph — the old
    // root's cards never bleed into the new selection.
    await page.getByRole('link', { name: 'Back to all Build Orders' }).click()
    await openCatalogEntry(page, 'Stale planning lane')

    const second = page.locator('#selected-build-order-graph')
    await expect(page.locator('#build-order-page')).toHaveAttribute('data-build-order-root', '43')
    await expect(second.locator('[data-bo-card]')).toHaveCount(1)
    await expect(second).toHaveAttribute('data-bo-grid-key', '43:8')
  } finally {
    await context.close()
  }
})

test('production Build Order routes enforce Basic Auth and reject malformed locators', async ({ browser }) => {
  const unauthenticated = await browser.newContext()
  const deniedPage = await unauthenticated.newPage()

  try {
    const response = await deniedPage.goto('/build-orders')
    expect(response?.status()).toBe(401)
  } finally {
    await unauthenticated.close()
  }

  const authenticated = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await authenticated.newPage()

  try {
    await page.goto('/build-orders/01')
    await expect(page.locator('#build-order-page')).toHaveAttribute('data-build-order-status', 'invalid_parameter')
    await expect(page.getByRole('heading', { name: 'Invalid Build Order URL' })).toBeVisible()
    await expect(page.locator('[data-bo-card]')).toHaveCount(0)
  } finally {
    await authenticated.close()
  }
})

test('an unresolvable Build Order renders one copyable page-level error state', async ({ browser }, testInfo) => {
  const context = await browser.newContext({
    httpCredentials: dashboardCredentials,
    viewport: { width: 1280, height: 900 },
    permissions: ['clipboard-read', 'clipboard-write']
  })
  const page = await context.newPage()

  try {
    await page.goto('/build-orders/1567')
    await expect(page.locator('#build-order-page')).toHaveAttribute('data-build-order-status', 'selected_unavailable')

    const card = page.locator('.bo-state-card')
    await expect(card).toHaveCount(1)
    await expect(card.getByRole('heading', { name: 'Could not fetch planning graph' })).toBeVisible()
    await expect(page.locator('.bo-summary-grid, .bo-breakdown, .bo-analytics, .bo-usage, .bo-diagnostics')).toHaveCount(0)

    const prompt = page.locator('#build-order-debug-prompt')
    // The prompt must name the specific reported fault, the root, and what was
    // being read — enough that pasting it to an agent starts real work.
    await expect(prompt).toHaveValue(
      "Investigate why Build Order #1567's planning graph could not be fetched. " +
      'The selected-root provider reports `rate_limited` ' +
      '(reading the selected-root graph for owner/repo, provider generation 9); ' +
      'graph counts are unresolved.'
    )
    await expect(card).toContainText('Reported fault: rate_limited')

    await page.getByRole('button', { name: 'Copy debug prompt' }).click()
    await expect(page.locator('[data-copy-status]')).toHaveText('Copied')
    await expect.poll(() => page.evaluate(() => navigator.clipboard.readText())).toBe(await prompt.inputValue())

    await assertNoDocumentOverflow(page)
    const accessibility = await new AxeBuilder({ page }).analyze()
    expect(accessibility.violations).toEqual([])
    await captureConfiguredScreenshot(page, testInfo)
  } finally {
    await context.close()
  }
})

test('copying the debug prompt falls back when the Clipboard API rejects', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  await context.addInitScript(() => {
    window.__clipboardFallback = { writeAttempts: 0, execCommands: [] }

    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: {
        writeText: async () => {
          window.__clipboardFallback.writeAttempts += 1
          throw new Error('clipboard permission denied')
        }
      }
    })

    document.execCommand = (command) => {
      window.__clipboardFallback.execCommands.push(command)
      return command === 'copy'
    }
  })
  const page = await context.newPage()

  try {
    await page.goto('/build-orders/1567')
    await page.getByRole('button', { name: 'Copy debug prompt' }).click()

    await expect(page.locator('[data-copy-status]')).toHaveText('Copied')
    await expect.poll(() => page.evaluate(() => window.__clipboardFallback)).toEqual({
      writeAttempts: 1,
      execCommands: ['copy']
    })
  } finally {
    await context.close()
  }
})
