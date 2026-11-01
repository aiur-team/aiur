import { test, expect } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ httpCredentials: dashboardCredentials })

for (const width of [1440, 390]) for (const theme of ['dark', 'light']) {
  test(`completed ticket tint at ${width}px in ${theme} theme`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 })
    await page.goto('/build-fixture/unknowns')
    await expect(page.locator('#bd-content')).toHaveCount(1)
    await page.evaluate(async theme => {
      document.documentElement.dataset.theme = theme
      const { ctx, S } = await import('/build-home/state.js')
      const { makeCard } = await import('/build-home/cards.js')
      const { H } = await import('/build-home/history.js')
      const { listHTML } = await import('/build-home/list.js')
      const completed = structuredClone(ctx.D.hist.find(ticket => ticket.status === 'done'))
      const notPlanned = structuredClone(ctx.D.hist.find(ticket => ticket.status === 'not_planned'))
      const running = structuredClone(ctx.D.now[0])
      const card = (ticket, id) => {
        const element = makeCard({ t: ticket, sec: ticket.sec, h: 180 })
        element.id = id
        Object.assign(element.style, { position: 'fixed', left: '8px', top: '100px', width: '300px', height: '180px', zIndex: '9999' })
        document.body.append(element)
        return element
      }
      card(completed, 'completed-fixture-card')
      card(notPlanned, 'not-planned-fixture-card')
      card(running, 'running-fixture-card')
      const list = document.createElement('div')
      S.f.tstate = ['merged', 'not planned']
      list.innerHTML = listHTML(ctx.D, S, H, ctx.snap, Date.now())
      const row = list.querySelector(`.lr[data-id="${completed.id}"]`)
      if (!row) throw new Error(`production list renderer omitted completed fixture ticket ${completed.id}`)
      row.id = 'completed-timeline-row'
      row.style.cssText = 'position:fixed;left:8px;top:300px;width:300px;height:44px'
      document.body.append(row)
      const notPlannedRow = list.querySelector(`.lr[data-id="${notPlanned.id}"]`)
      notPlannedRow.id = 'not-planned-timeline-row'
      document.body.append(notPlannedRow)
    }, theme)
    const completed = page.locator('#completed-fixture-card .bd-in')
    const running = page.locator('#running-fixture-card .bd-in')
    const notPlanned = page.locator('#not-planned-fixture-card .bd-in')
    const row = page.locator('#completed-timeline-row')
    const notPlannedRow = page.locator('#not-planned-timeline-row')
    await expect(completed).toBeVisible()
    await expect(completed.locator('.bd-status')).toContainText('Merged')
    await expect(notPlanned.locator('.bd-status')).toContainText('Not planned')
    const colors = await page.evaluate(() => ({
      completed: (() => {
        const { backgroundColor, backgroundImage } = getComputedStyle(document.querySelector('#completed-fixture-card .bd-in'))
        return { backgroundColor, backgroundImage }
      })(),
      expected: (() => {
        const probe = document.createElement('div')
        probe.style.background = 'linear-gradient(var(--good-soft), var(--good-soft)), var(--surface-2)'
        document.body.append(probe)
        const { backgroundColor, backgroundImage } = getComputedStyle(probe)
        return { backgroundColor, backgroundImage }
      })(),
      running: (() => {
        const { backgroundColor, backgroundImage } = getComputedStyle(document.querySelector('#running-fixture-card .bd-in'))
        return { backgroundColor, backgroundImage }
      })(),
      notPlanned: (() => {
        const { backgroundColor, backgroundImage } = getComputedStyle(document.querySelector('#not-planned-fixture-card .bd-in'))
        return { backgroundColor, backgroundImage }
      })(),
      surface: (() => {
        const probe = document.createElement('div')
        probe.style.backgroundColor = 'var(--surface-2)'
        document.body.append(probe)
        return getComputedStyle(probe).backgroundColor
      })(),
    }))
    expect(colors.completed).toEqual(colors.expected)
    expect(colors.completed.backgroundColor).toBe(colors.surface)
    expect(colors.completed.backgroundImage).toContain('linear-gradient')
    expect(colors.completed.backgroundImage).not.toBe(colors.running.backgroundImage)
    expect(colors.completed.backgroundImage).not.toBe(colors.notPlanned.backgroundImage)
    const rowBackground = await row.evaluate(element => {
      const { backgroundColor, backgroundImage } = getComputedStyle(element)
      return { backgroundColor, backgroundImage }
    })
    expect(rowBackground).toEqual(colors.completed)
    const notPlannedBackground = await notPlannedRow.evaluate(element => {
      const { backgroundColor, backgroundImage } = getComputedStyle(element)
      return { backgroundColor, backgroundImage }
    })
    expect(notPlannedBackground).not.toEqual(colors.completed)
  })
}
