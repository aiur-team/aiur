import { test, expect } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ httpCredentials: dashboardCredentials })

test('fixture dataset stays scoped to its page during a competing switch', async ({ browser }) => {
  const dense = await browser.newContext({ httpCredentials: dashboardCredentials })
  const other = await browser.newContext({ httpCredentials: dashboardCredentials })
  const densePage = await dense.newPage()
  const otherPage = await other.newPage()

  await densePage.goto('/auth/read_only')
  await otherPage.goto('/auth/read_only')
  await densePage.goto('/build-fixture/dense')
  await expect.poll(() => densePage.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js')
    return ctx.snap?.sections.now.some(row => row.id === '1301')
  })).toBe(true)

  await otherPage.goto('/build-fixture/live')
  await expect.poll(() => otherPage.evaluate(async () => (await import('/build-home/state.js')).ctx.snap != null)).toBe(true)
  await otherPage.goto('/build-fixture/unknowns')
  await expect.poll(() => otherPage.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js')
    return ctx.snap?.sections.now.some(row => row.id === '9001')
  })).toBe(true)

  await densePage.goto('/build?fixture_dataset=dense')
  await expect(densePage.locator('#bd-content')).toHaveCount(1)
  await expect.poll(() => densePage.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js')
    return ctx.snap?.sections.now.some(row => row.id === '1301')
  })).toBe(true)

  await dense.close()
  await other.close()
})
