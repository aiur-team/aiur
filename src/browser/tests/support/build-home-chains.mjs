import { fileURLToPath } from 'node:url'
import { expect } from '@playwright/test'
import { settleAnimations } from './browser-helpers.mjs'

export const card = (page, id) => page.locator(`.bd-card[data-id="${id}"]`).first()
export const tree = page => page.locator('#bd-tree')
export const tray = page => page.locator('.bd-lt')

export async function open(page, { trees = true, dataset = 'chains', modal = false, minimize = true } = {}) {
  if (modal) await page.addInitScript(() => {
    // Register before the hook: a bubble-only tree handler would close both layers.
    document.addEventListener('keydown', e => {
      if (e.key === 'Escape') document.querySelector('#tk-backdrop.show')?.remove()
    })
  })
  await page.route(/\/build-home\/[\w-]+\.js$/, route => route.fulfill({
    path: fileURLToPath(new URL('../../../priv/static/build-home/' + new URL(route.request().url()).pathname.split('/').at(-1), import.meta.url)),
    contentType: 'text/javascript',
  }))
  await page.goto('/build-fixture/' + dataset)
  await expect(page.locator('#build-root')).toHaveAttribute('data-bd-trees', 'ready')
  await page.evaluate(async () => { window.st = await import('/build-home/state.js') })
  if (trees || minimize) {
    // Nested fixture forwarding drops queries; navigate the real LiveView URL.
    await page.evaluate(({ trees, minimize }) => {
      const query = new URLSearchParams()
      if (trees) query.set('trees', '1')
      if (minimize) query.set('live', 'min')
      window.liveSocket.main.pushLinkPatch(new Event('click'), '/build?' + query, null)
    }, { trees, minimize })
    await expect.poll(() => page.evaluate(() => st.S.trees)).toBe(trees)
  }
  await expect.poll(() => page.evaluate(() => !!st.ctx.D?.byId)).toBe(true)
  if (minimize) await expect(page.locator('#bd-now')).toHaveClass(/min/)
  await page.evaluate(() => document.fonts.ready)
  await page.evaluate(() => window.scrollTo(0,
    Math.max(0, document.querySelector('#bd-vp').getBoundingClientRect().top + scrollY - 20)))
  await expect.poll(() => page.evaluate(() => st.ctx.snapping || st.ctx.content.classList.contains('scrolling'))).toBe(false)
  if (modal) await page.evaluate(() => {
    st.fx.openModal = row => {
      window.openedTicket = row.id
      const backdrop = document.createElement('div')
      backdrop.id = 'tk-backdrop'; backdrop.className = 'show'
      document.body.append(backdrop)
    }
  })
}
export async function reveal(page, id) {
  await page.evaluate(id => {
    const { ctx } = st
    for (const sx of ['hist', 'plan', 'nq']) {
      const it = ctx.L.secs[sx].items.find(it => it.t.id === id)
      if (it) st.fx.scrollVP(ctx.secs[sx].el.offsetTop + it.y - 150, false)
    }
    st.fx.update()
  }, String(id))
  await expect(card(page, id)).toBeVisible()
  await expect.poll(() => page.evaluate(() =>
    st.ctx.snapping || st.ctx.content.classList.contains('scrolling'))).toBe(false)
  await page.waitForTimeout(650) // Allow the deferred column update to start.
  await settleAnimations(page, '.bd-content')
  await expect(card(page, id)).toBeVisible()
}
export async function lock(page, id) {
  await reveal(page, id)
  await card(page, id).hover({ trial: true })
  await expect.poll(() => page.evaluate(() => st.ctx.snapping || st.ctx.content.classList.contains('scrolling'))).toBe(false)
  await expect.poll(() => page.evaluate(() => st.ctx.cols.join('|') === st.fx.visibleCols().join('|'))).toBe(true)
  await settleAnimations(page, '.bd-content')
  await card(page, id).hover()
  await expect(tray(page)).toHaveClass(/show/)
  await expect.poll(() => page.evaluate(() => st.ctx.hoverId)).toBe(String(id))
  await page.waitForTimeout(230) // Let the tab finish moving before aiming at its lock button.
  const button = page.locator('[data-lt="lock"]')
  // A dense board can finish shifting after the initial hover. Aim at the live
  // tab bounds and verify the pointer hits the button before pressing it.
  await expect(async () => {
    await card(page, id).hover()
    await expect.poll(() => page.evaluate(() => st.ctx.hoverId), { timeout: 500 }).toBe(String(id))
    await page.waitForTimeout(230)
    const target = await button.boundingBox()
    await page.mouse.move(target.x + target.width / 2, target.y + target.height / 2)
    await expect.poll(() => button.evaluate(el => el.matches(':hover')), { timeout: 500 }).toBe(true)
    await expect.poll(() => page.evaluate(() => st.ctx.hoverId), { timeout: 500 }).toBe(String(id))
  }).toPass({ timeout: 5000 })
  await page.mouse.down(); await page.mouse.up()
  await expect(page.locator('[data-lt="lock"]')).toHaveAttribute('aria-pressed', 'true')
  await expect.poll(() => page.evaluate(() => st.ctx.lockId)).toBe(String(id))
}
export async function whole(page, id) {
  await lock(page, id)
  await page.locator('[data-lt="tree"]').click()
  await expect(tree(page)).toBeVisible()
}
