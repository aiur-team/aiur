import { test, expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { dashboardCredentials } from './support/layout-worker.mjs'

const fixture = JSON.parse(await readFile(new URL('../../test/fixtures/build_home/live.json', import.meta.url), 'utf8'))
test.use({ timezoneId: 'America/Los_Angeles' })

test('index-live serves a real store join through the connected build hook', async ({ page }) => {
  await page.context().setHTTPCredentials(dashboardCredentials)
  const errors = []
  page.on('pageerror', error => errors.push(error.message))
  await page.goto('/build-fixture/index-live')
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-state', 'ready')
  await expect.poll(() => page.evaluate(async () => (await import('/build-home/state.js')).ctx.snap?.sources?.index?.state)).toBe('ok')
  const snapshot = await page.evaluate(async () => (await import('/build-home/state.js')).ctx.snap)
  // Some frozen demo feature owners use a general epic, which the real registry rejects.
  const expectedCounts = { ...fixture.counts }
  for (const row of Object.values(fixture.sections).flat()) {
    if (!row.feature || fixture.features[row.feature].epics.includes(row.epic)) continue
    expectedCounts[row.epic]--
    expectedCounts[fixture.features[row.feature].epics[0]]++
  }
  expect(snapshot.counts).toEqual(expectedCounts)
  expect(snapshot.order).toEqual(fixture.order)
  expect(snapshot.history.total).toBe(fixture.history.total)
  expect(snapshot.history.tz).toBe('America/Los_Angeles')
  expect(snapshot.sections.hist.length).toBeLessThan(snapshot.history.total)
  expect(snapshot.sources.open_tickets.state).toBe('ok')
  expect(snapshot.sections.now.map(row => row.id)).toEqual(fixture.sections.now.map(row => row.id))
  expect(errors).toEqual([])
})
