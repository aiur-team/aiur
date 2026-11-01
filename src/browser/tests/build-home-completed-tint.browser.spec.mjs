import { test, expect } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'

for (const width of [1440, 390]) for (const theme of ['dark', 'light']) {
  test(`completed ticket tint at ${width}px in ${theme} theme`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 })
    await page.goto('/build-fixture/unknowns')
    await expect(page.locator('#bd-content')).toHaveCount(1)
    await page.evaluate(async theme => {
      document.documentElement.dataset.theme = theme
      const { ctx } = await import('/build-home/state.js')
      const { makeCard } = await import('/build-home/cards.js')
      const completed = structuredClone(ctx.D.hist.find(ticket => ticket.status === 'done'))
      const running = structuredClone(ctx.D.now[0])
      const card = (ticket, id) => {
        const element = makeCard({ t: ticket, sec: ticket.sec, h: 180 })
        element.id = id
        Object.assign(element.style, { position: 'fixed', left: '8px', top: '100px', width: '300px', height: '180px', zIndex: '9999' })
        document.body.append(element)
        return element
      }
      card(completed, 'completed-fixture-card')
      running.sec = 'hist'
      running.status = 'closed'
      card(running, 'running-fixture-card')
      const { stClass } = await import('/build-home/list.js')
      const row = document.createElement('div')
      row.className = 'lr hist ' + (stClass(completed) === 'merged' ? 'completed' : '')
      row.id = 'completed-timeline-row'
      row.style.cssText = 'position:fixed;left:8px;top:300px;width:300px;height:44px'
      document.body.append(row)
    }, theme)
    const completed = page.locator('#completed-fixture-card .bd-in')
    const running = page.locator('#running-fixture-card .bd-in')
    const row = page.locator('#completed-timeline-row')
    await expect(completed).toBeVisible()
    await expect(completed.locator('.bd-status')).toContainText('Merged')
    const colors = await page.evaluate(() => ({
      token: getComputedStyle(document.querySelector('#completed-fixture-card .bd-in')).backgroundColor,
      expected: getComputedStyle(document.documentElement).getPropertyValue('--good-soft').trim(),
      running: getComputedStyle(document.querySelector('#running-fixture-card .bd-in')).backgroundColor,
    }))
    expect(colors.token).not.toBe(colors.running)
    expect(colors.token).toBe(await page.evaluate(() => {
      const probe = document.createElement('div')
      probe.style.backgroundColor = getComputedStyle(document.documentElement).getPropertyValue('--good-soft')
      document.body.append(probe)
      return getComputedStyle(probe).backgroundColor
    }))
    expect(colors.expected).not.toBe('')
    const rowBackground = await row.evaluate(element => getComputedStyle(element).backgroundColor)
    expect(rowBackground).toBe(colors.token)
  })
}

test.use({ httpCredentials: dashboardCredentials })
