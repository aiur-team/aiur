import { test, expect } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'

// MP-E8-C11-T08: the ticket modal's Command card on fixture ticket 601 (design J:206 `a3`).
test.setTimeout(120_000)
test.use({ httpCredentials: dashboardCredentials, viewport: { width: 1440, height: 900 }, timezoneId: 'America/Los_Angeles' })

async function open(page, scenario) {
  const seeded = await page.request.get('/build-command-control/' + scenario)
  expect(seeded.status(), await seeded.text()).toBe(200)
  page.on('pageerror', error => { throw error })
  await page.goto('/build-fixture/live')
  await expect.poll(() => page.evaluate(async () => !!(await import('/build-home/state.js')).ctx.D?.byId['601'])).toBe(true)
  await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'), { openModal } = await import('/build-home/modal/frame.js')
    const original = ctx.push
    window.answerCalls = []; window.holdAnswer = null
    ctx.push = async (event, payload) => {
      if (event === 'answer-decision') {
        window.answerCalls.push(payload)
        if (window.holdAnswer) await window.holdAnswer
      }
      return original(event, payload)
    }
    openModal(ctx.D.byId['601'])
  })
  await expect(page.locator('#bd-cmd')).toBeVisible()
}
const card = page => page.locator('#bd-cmd')
const proof = async (page, name) => test.info().attach(name, { body: await page.locator('#tk-modal').screenshot({ animations: 'disabled' }), contentType: 'image/png' })
const state = async page => (await page.request.get('/build-command-control/state')).json()

test('answering records through the server and appends the answer only after it is accepted', async ({ page }) => {
  await open(page, 'answerable')
  const buttons = card(page).locator('.row button')
  await expect(buttons).toHaveCount(2)
  await expect(buttons.nth(0)).toHaveClass('btn sm')
  await expect(buttons.nth(0).locator('.rec')).toHaveText('recommended')
  await expect(buttons.nth(1)).toHaveClass('btn secondary sm')
  await expect(card(page).locator('p').first()).toHaveText('Should in-flight retries be restored after a daemon restart, or stay process-local?')
  await proof(page, 'command-open')

  const ops = await page.locator('#cv-log .cv-op').count()
  await page.evaluate(() => { window.holdAnswer = new Promise(resolve => { window.releaseAnswer = resolve }) })
  await buttons.nth(0).click()
  await expect(card(page)).toHaveAttribute('aria-busy', 'true')
  await expect(buttons.nth(0)).toBeDisabled(); await expect(buttons.nth(1)).toBeDisabled()
  expect(await page.evaluate(() => document.activeElement?.id)).toBe('bd-cmd')
  await expect(page.locator('#cv-log .cv-op')).toHaveCount(ops)
  await buttons.nth(1).click({ force: true })
  await page.evaluate(() => window.releaseAnswer())

  await expect(card(page)).toHaveCount(0)
  await expect(page.locator('#cv-log .cv-op')).toHaveCount(ops + 1)
  const row = page.locator('#cv-log .cv-op').last()
  await expect(row.locator('p')).toHaveText('Answered: Persist to disk, rehydrate on boot')
  expect(await row.getAttribute('data-eid')).toMatch(/^answer:/)
  await expect(page.locator('#cv-typing')).toBeHidden()
  expect(await page.evaluate(() => window.answerCalls.length)).toBe(1)
  const [stored] = await state(page)
  expect(stored).toMatchObject({ status: 'decided', option_id: 'persist' })
  expect(stored.actor).not.toBe('elsewhere')

  // A fresh open of the now-answered ticket never shows a settled card.
  await page.locator('#bd-tk-close').click()
  await page.evaluate(async () => { const { ctx } = await import('/build-home/state.js'), { openModal } = await import('/build-home/modal/frame.js'); openModal(ctx.D.byId['601']) })
  await expect(page.locator('#cv-log')).toBeVisible()
  // The fixture row still says `command`, so the card reports the disagreement; it never re-offers the answered Command.
  await expect(card(page).locator('p').first()).toHaveText('This agent is waiting on a Command this page cannot load.')
  await expect(card(page).locator('button')).toHaveCount(0)
})

test('an answer recorded elsewhere settles the open card and marks the winner', async ({ page }) => {
  await open(page, 'answerable')
  await page.request.get('/build-command-control/answer/local')
  await expect(card(page).locator('.st[role=status]')).toHaveText(/^Answered: Keep process-local · \d\d:\d\d$/)
  await expect(card(page).locator('button[data-ans=local] .rec')).toHaveText('answered')
  for (const button of await card(page).locator('button').all()) await expect(button).toBeDisabled()
  await proof(page, 'command-settled')
})

test('a stale click after another answer won shows the settled card, not a second answer', async ({ page }) => {
  await open(page, 'answerable')
  // Hold the signal back: the click reaches the server before the push.
  await page.evaluate(async () => { const { fx } = await import('/build-home/state.js'); window.realRender = fx.renderCommand; fx.renderCommand = () => {} })
  await page.request.get('/build-command-control/answer/local')
  await card(page).locator('button[data-ans=persist]').click()
  await expect(card(page).locator('.st')).toHaveText(/^Answered: Keep process-local/)
  expect((await state(page))[0].option_id).toBe('local')
})

test('a read-only dashboard shows the reason as text and disables every option', async ({ page }) => {
  await open(page, 'read_only')
  for (const button of await card(page).locator('button').all()) {
    await expect(button).toBeDisabled(); await expect(button).toHaveAttribute('title', 'Read-only dashboard')
    expect(await button.evaluate(el => getComputedStyle(el).opacity)).toBe('0.5')
  }
  await expect(card(page).locator('.st[role=status]')).toHaveText('Read-only dashboard')
  await proof(page, 'command-read-only')
})

test('hostile Command text stays text', async ({ page }) => {
  await open(page, 'hostile')
  await expect(card(page).locator('p').first()).toHaveText('<img src=x onerror=window.__x=1>')
  await expect(card(page).locator('img')).toHaveCount(0)
  expect(await page.evaluate(() => window.__x)).toBeUndefined()
})

test('a Command with no options links to the Commands page', async ({ page }) => {
  await open(page, 'zero')
  await expect(card(page).locator('.row button')).toHaveCount(0)
  await expect(card(page).locator('.row a[href="/commands"]')).toHaveText('Open Commands')
})

test('keyboard reaches each option and an error returns focus with an alert', async ({ page }) => {
  await open(page, 'answerable')
  await card(page).locator('button[data-ans=persist]').focus()
  await page.keyboard.press('Tab')
  expect(await page.evaluate(() => document.activeElement?.dataset.ans)).toBe('local')
  // A forged option id is refused by the server; the card stays open.
  await page.evaluate(() => { document.querySelector('#bd-cmd button[data-ans=local]').dataset.ans = 'nope' })
  await page.keyboard.press('Enter')
  await expect(card(page).locator('.st.bad[role=alert]')).toHaveText('That option is no longer available.')
  expect(await page.evaluate(() => document.activeElement?.closest('#bd-cmd') != null)).toBe(true)
  for (const button of await card(page).locator('button').all()) await expect(button).toBeEnabled()
  await proof(page, 'command-error')
})
