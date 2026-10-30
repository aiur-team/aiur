import { test, expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ httpCredentials: dashboardCredentials })
for (const { width, unknown = false } of [{ width: 1440 }, { width: 390 }, { width: 1440, unknown: true }]) test(`held native question card and modal at ${width}px${unknown ? " with unknown age" : ""}`, async ({ page }, info) => {
  await page.setViewportSize({ width, height: 900 })
  page.on('pageerror', error => { throw error })
  // Mutation runs route only the reverted asset from an isolated worktree.
  for (const [asset, path] of Object.entries(info.project.metadata.holdAssets || {})) {
    await page.route('**/build-home/' + asset, route => readFile(path, 'utf8').then(body => route.fulfill({ body, contentType: 'text/javascript' })))
  }
  await page.goto('/build-fixture/live')
  await expect.poll(() => page.evaluate(async () => (await import('/build-home/state.js')).ctx.D?.now.length)).toBeGreaterThan(0)
  await expect.poll(() => page.evaluate(async () => (await import('/build-home/history.js')).H.state)).toBe('idle')
  const id = await page.evaluate(async unknown => {
    const { ctx } = await import('/build-home/state.js')
    const { receive } = await import('/build-home/hook.js')
    const snap = structuredClone(ctx.snap), row = snap.sections.now.find(row => row.agent?.state === 'active')
    window.heldId = row.id
    row.agent = { ...row.agent, state: 'native_question', native_hold: { decision_id: 'decision-held', since: unknown ? null : snap.now - 420000 } }
    snap.generation += 1
    receive(snap)
    return row.id
  }, unknown)
  const card = page.locator('.bd-card[data-id="' + id + '"]').first()
  await card.scrollIntoViewIfNeeded()
  const link = card.locator('a[href="/commands/decision-held"]')
  await expect(link).toHaveText('Waiting for your answer · ' + (unknown ? 'duration unavailable' : 'for 7 min'))
  await expect(link).toBeVisible()
  expect(await link.evaluate(el => el.parentElement.scrollWidth <= el.parentElement.clientWidth)).toBe(true)
  await page.screenshot({ path: info.outputPath(`held-card-${width}.png`) })
  await card.locator('.bd-title').click()
  const modal = page.locator('#tk-head')
  await expect(modal.locator('a[href="/commands/decision-held"]')).toHaveText('Waiting for your answer · ' + (unknown ? 'duration unavailable' : 'for 7 min'))
  await expect(modal.locator('a[href="/commands/decision-held"]')).toBeVisible()
  await page.screenshot({ path: info.outputPath(`held-${width}.png`) })

  await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'), { receive } = await import('/build-home/hook.js')
    const row = ctx.D.byId[window.heldId]
    receive({ v: 1, kind: 'diff', epoch: ctx.snap.epoch, generation: ctx.snap.generation + 1, now: ctx.snap.now,
      upsert: [{ ...row, agent: { ...row.agent, state: 'active', native_hold: null } }], remove: [], set: {} })
  })
  await expect(modal).toContainText('Running')
  await expect(modal.locator('a[href="/commands/decision-held"]')).toHaveCount(0)
  await page.locator('#bd-tk-close').click()
  await expect(card).toContainText('Running')
  await expect(card.locator('a[href="/commands/decision-held"]')).toHaveCount(0)
})
