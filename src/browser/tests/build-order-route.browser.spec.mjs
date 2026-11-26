import { expect, test } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'

// The Build Order pages retired into the Build home. Old links (bookmarks,
// ticket comments, handoff notes) must still land on the right home view: a
// root opens its imported feature `bo-<root>`, and the catalog opens home.

async function urlState(page) {
  const root = page.locator('#build-root')
  await expect(root).toBeVisible()
  return JSON.parse(await root.getAttribute('data-url-state'))
}

test('an old Build Order root link opens the home page focused on its feature', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()

  try {
    await page.goto('/commands')
    await page.goto('/build-orders/42')
    await expect(page).toHaveURL(/\/\?feature=bo-42$/)
    const redirected = await urlState(page)
    expect(redirected.feature).toBe('bo-42')

    // The redirect adds no state of its own: it matches a direct load.
    const direct = await context.newPage()
    await direct.goto('/?feature=bo-42')
    expect(await urlState(direct)).toEqual(redirected)
    await direct.close()

    // A 301 is not a history entry: Back returns to the page before the old link.
    await page.goBack()
    await expect(page).toHaveURL(/\/commands$/)
  } finally {
    await context.close()
  }
})

test('the old Build Order catalog and invalid roots open the unfocused home page', async ({ browser }) => {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage()

  try {
    for (const path of ['/build-orders', '/build-orders/01', '/build-orders/abc']) {
      await page.goto(path)
      await expect(page).toHaveURL(/\/$/)
      expect((await urlState(page)).feature).toBeNull()
    }
  } finally {
    await context.close()
  }
})
