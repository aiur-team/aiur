import { test, expect } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { mountConversation, scenario } from './support/build-conversation.mjs'

// #7424: the ticket modal composer on a phone must not trigger iOS focus zoom, and the
// feed stays pinned to the latest row only while the reader is at the bottom.
test.use({ httpCredentials: dashboardCredentials, viewport: { width: 390, height: 844 }, reducedMotion: 'reduce' })
test.beforeEach(async ({ page }, info) => {
  await mountConversation(page, info)
  await page.evaluate(async () => { (await import('/build-home/state.js')).ctx.snap.writable = true })
  await scenario(page, 'kinds', { entries: Array.from({ length: 40 }, (_, i) => ({
    id: 'row:' + i, k: 'say', text: 'Transcript row ' + i + ' ' + 'message '.repeat(12), at: null,
  })), reply: { live: true, composer: 'ready' }, ticket: { agent: { state: 'active', name: 'Worker' } } })
  await expect(page.locator('#cv-in textarea')).toBeVisible()
  await expect(page.locator('#cv-log [data-eid="row:39"]')).toHaveCount(1)
})
const log = page => page.locator('#cv-log')
const box = page => page.locator('#cv-in textarea')
const lastVisible = page => log(page).evaluate(el =>
  [...el.querySelectorAll('[data-k]')].at(-1).getBoundingClientRect().bottom <= el.getBoundingClientRect().bottom + 1)
const toBottom = page => log(page).evaluate(el => { el.scrollTop = el.scrollHeight; el.dispatchEvent(new Event('scroll')) })
async function push(page, entries) {
  await page.evaluate(async entries => {
    const { fx } = await import('/build-home/state.js'), { MS } = await import('/build-home/modal/frame.js')
    fx.receiveConversation({ v: 1, id: MS.t.id, kind: 'conversation-append', entries })
  }, entries)
}

test('focusing the composer keeps a 16px font and the page scale', async ({ page }) => {
  const scale = await page.evaluate(() => window.visualViewport.scale)
  await box(page).focus()
  expect(await box(page).evaluate(el => parseFloat(getComputedStyle(el).fontSize))).toBeGreaterThanOrEqual(16)
  expect(await page.evaluate(() => window.visualViewport.scale)).toBe(scale)
})

test('a visualViewport shrink and a growing composer keep the last row in view', async ({ page }) => {
  await toBottom(page)
  await expect.poll(() => lastVisible(page)).toBe(true)
  // Model the iOS keyboard: only the visual viewport shrinks; the layout viewport keeps its height.
  const keyboardTop = 508
  await page.evaluate(top => {
    Object.defineProperty(window.visualViewport, 'height', { configurable: true, get: () => top })
    window.visualViewport.dispatchEvent(new Event('resize'))
  }, keyboardTop)
  const aboveKeyboard = () => page.evaluate(top => {
    const rows = document.querySelectorAll('#cv-log [data-k]'), composer = document.querySelector('#cv-in')
    return rows[rows.length - 1].getBoundingClientRect().bottom <= top + 1 && composer.getBoundingClientRect().bottom <= top + 1
  }, keyboardTop)
  await expect.poll(aboveKeyboard).toBe(true)
  expect(await lastVisible(page)).toBe(true)
  await box(page).fill('A longer draft that grows the composer. '.repeat(12))
  await expect.poll(() => box(page).evaluate(el => el.getBoundingClientRect().height)).toBeGreaterThan(38)
  expect(await box(page).evaluate(el => el.getBoundingClientRect().height)).toBeLessThanOrEqual(140)
  await expect.poll(() => lastVisible(page)).toBe(true)
  expect(await aboveKeyboard()).toBe(true)
})

// Regression guard: append pinning already held on main; this keeps it true at 390px.
test('new rows keep a pinned reader at the bottom and never move a reader who scrolled up', async ({ page }) => {
  await toBottom(page)
  await push(page, [{ id: 'pinned', k: 'say', text: 'Arrives while pinned', at: null }])
  await expect.poll(() => lastVisible(page)).toBe(true)
  await expect(page.locator('#cv-new')).toBeHidden()

  await log(page).evaluate(el => { el.scrollTop = el.scrollHeight - el.clientHeight - 400; el.dispatchEvent(new Event('scroll')) })
  const anchor = log(page).locator('[data-eid="row:30"]')
  const before = await anchor.evaluate(el => el.getBoundingClientRect().top)
  await push(page, [{ id: 'up', k: 'say', text: 'Arrives while reading up', at: null }])
  expect(Math.abs(await anchor.evaluate(el => el.getBoundingClientRect().top) - before)).toBeLessThan(1)
  await expect(page.locator('#cv-new')).toBeVisible()
  await page.locator('#cv-new').click()
  await expect.poll(() => log(page).evaluate(el => el.scrollHeight - el.scrollTop - el.clientHeight)).toBeLessThanOrEqual(1)
})
