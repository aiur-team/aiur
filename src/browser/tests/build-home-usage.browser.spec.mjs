import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { openFixture } from './support/browser-helpers.mjs'
const fixture = name => JSON.parse(readFileSync(new URL(`../../test/fixtures/build_home/usage/${name}.json`, import.meta.url)))
const NOW = 1791408000000

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    localStorage.setItem('aiur-theme', 'light')
    localStorage.setItem('aiur-palette', 'gruvbox')
  })
  await openFixture(page)
  await page.context().setHTTPCredentials(dashboardCredentials)
  await page.clock.install({ time: NOW-1000 })
  await page.clock.pauseAt(NOW)
  await page.goto('/build-fixture/live')
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-generation', /\d+/)
  await expect(page.locator('.ax-usage')).toBeVisible()
  await page.evaluate(async now => {
    window.usage = await import('/build-home/usage.js'); window.state = await import('/build-home/state.js')
    const clock = await import('/build-home/clock.js'); clock.setNow(now); state.fx.renderUsage()
  }, NOW)
})
async function paint(page, block) {
  await page.evaluate(block => { state.ctx.snap.usage = block; usage.renderUsage() }, block)
}

test('duration formatting and mean preserve design labels and unknowns', async ({ page }) => {
  expect(await page.evaluate(() => [87,250,10020,1560,182,4560,58,7260,161,6300,135,3240,37,20,31680].map(m => usage.fmtLeft(m*60000))))
    .toEqual(['1h 27m','4h 10m','6d 23h','1d 2h','3h 02m','3d 4h','58m','5d 1h','2h 41m','4d 9h','2h 15m','2d 6h','37m','20m','22d'])
  expect(await page.evaluate(() => [[null,40],[null],[0]].map(usage.avgKnown))).toEqual([40,null,0])
})
test('unknown, partial, zero and thresholds render distinct values and segments', async ({ page }) => {
  await paint(page, fixture('unknown'))
  const model = page.locator('.mdl .ax-r2')
  await expect(model.locator('.ax-pc')).toHaveText('')
  await expect(model.locator('.ax-seg.none')).toHaveCount(1)
  await expect(model.locator('i')).toHaveCount(0)
  await expect(model.locator('.ax-ln')).toHaveAttribute('data-tip', /not observed/)
  await paint(page, fixture('partial'))
  await expect(model.locator('.ax-pc')).toHaveText('40%')
  await expect(model.locator('.ax-x')).toHaveText('×2')
  await expect(model.locator('.ax-seg.none i')).toHaveCount(0)
  await expect(model.locator('.ax-seg i')).toHaveAttribute('style','width:40%')
  for (const [n, cls] of [[0,'z'],[79,''],[80,' hi'],[95,' max']]) {
    const u = fixture('unknown'); u.providers[0].session.acc = [n]; await paint(page,u)
    await expect(model.locator('.ax-pc')).toHaveText(`${n}%`)
    await expect(model.locator('.ax-seg i')).toHaveAttribute('class',cls)
    await expect(model.locator('.ax-pc')).toHaveAttribute('class','ax-pc'+(n >= 95 ? ' max' : n >= 80 ? ' hi' : ''))
  }
})
test('unknown and ended resets, stale ages, holds and notes are truthful', async ({ page }) => {
  await paint(page, fixture('unknown'))
  await expect(page.locator('.mdl .ax-rs')).toHaveText('reset unknown')
  await expect(page.locator('.mdl .ax-rs em')).toHaveCount(0)
  await paint(page, fixture('ended'))
  await expect(page.locator('.mdl .ax-ln')).toHaveClass(/stale/)
  await expect(page.locator('.mdl .ax-rs')).toHaveText('window ended')
  await paint(page, fixture('stale'))
  await expect(page.locator('.mdl .ax-r2')).toHaveClass(/stale/)
  await expect(page.locator('.mdl .ax-ln').first()).toHaveAttribute('data-tip', /12m ago/)
  const u = fixture('stale'); u.providers[0].observed_at = null; await paint(page,u)
  await expect(page.locator('.mdl .ax-ln').first()).toHaveAttribute('data-tip', /never/)
  await paint(page, fixture('hold'))
  await expect(page.locator('.api .ax-ln').first()).toHaveAttribute('data-tip', /Held for.*37m/)
  await paint(page, fixture('none'))
  await expect(page.locator('.mdl .ax-bar.none')).toHaveCount(2)
  await expect(page.locator('.mdl .ax-ln').first()).toHaveAttribute('data-tip', /Awaiting first observation/)
  await expect(page.locator('.mdl .ax-ln').last()).toHaveAttribute('data-tip', /Last known 40%.*Observed/)
})
test('credits, absent windows, counters, empty and locked states', async ({ page }) => {
  await paint(page, fixture('credits'))
  await expect(page.locator('.mdl .ax-usd')).toHaveText('$10.40')
  await expect(page.locator('.mdl .ax-seg.none')).toHaveCount(2)
  await expect(page.locator('.mdl .ax-no')).toHaveText('unknown')
  await expect(page.locator('.api .ax-ln')).toHaveAttribute('data-tip', /ElevenLabs · renews in/)
  await expect(page.locator('.api em')).toHaveCount(0)
  await paint(page, fixture('onewin'))
  await expect(page.locator('.mdl .ax-r2').first().locator('.ax-ln')).toHaveCount(1)
  await expect(page.locator('.mdl .ax-r2').last().locator('.ax-no')).toHaveText('not observed')
  await paint(page, fixture('one'))
  await expect(page.locator('.api .ax-uh')).toHaveText('APIs1 API')
  await expect(page.locator('#ax-cnt')).toHaveText('1 model')
  expect(await page.locator('#ax-cnt').evaluate(e => [e.tagName,e.tabIndex,e.getAttribute('title'),getComputedStyle(e).cursor])).toEqual(['SPAN',-1,null,'default'])
  const before = await page.locator('#bd-usage').innerHTML(), url = page.url()
  await page.locator('#ax-cnt').click()
  expect(await page.locator('#bd-usage').innerHTML()).toBe(before); expect(page.url()).toBe(url)
  await paint(page, fixture('empty'))
  await expect(page.locator('#ax-cnt')).toHaveText('0 models')
  await expect(page.locator('.mdl .ax-no')).toHaveText('No providers configured')
  await paint(page, fixture('locked'))
  await expect(page.locator('#bd-usage [role=status]')).toContainText('Financial data locked. Authentication is required to access financial data. Sign in with the configured dashboard credentials.')
  await expect(page.locator('#bd-usage .ax-ln')).toHaveCount(0)
  await paint(page, fixture('unavailable'))
  await expect(page.locator('#bd-usage')).toContainText('Usage unavailable. The usage source failed.')
})
test('payload text and logo/icon keys cannot inject markup, including hover content', async ({ page }) => {
  await paint(page, fixture('hostile'))
  await expect(page.locator('#bd-usage img')).toHaveCount(0)
  await expect(page.locator('.mdl .ax-mono').first()).toHaveText('<img src=x onerror="window.__xss=1">')
  await page.locator('.api .ax-ln').first().hover()
  await expect(page.locator('body > .ax-pop img')).toHaveCount(0)
  expect(await page.evaluate(() => window.__xss)).toBeUndefined()
  const u = fixture('one'); Object.assign(u.providers[0],{logo:'muse',mono:null,icon:'toString',name:'Zed'})
  await paint(page,u); await expect(page.locator('.mdl .ax-mono')).toHaveText('Z')
})
test('popover mouse and keyboard, offsets, hide delay, scroll and live diff replacement', async ({ page }) => {
  const line = page.locator('.mdl .ax-ln').first(), pop = page.locator('body > .ax-pop')
  await line.hover(); await expect(pop).toHaveClass('ax-pop show')
  const r = await line.boundingBox()
  const [left,top] = await pop.evaluate(el => [parseFloat(el.style.left),parseFloat(el.style.top)])
  expect(left).toBeCloseTo(r.x+28,2); expect(top).toBeCloseTo(r.y-6,2)
  await page.mouse.move(0,0); await page.clock.runFor(50); await expect(pop).toHaveClass('ax-pop show')
  await page.clock.runFor(20); await expect(pop).toHaveClass('ax-pop')
  await line.focus(); await expect(pop).toHaveClass('ax-pop show')
  await expect(line).toHaveAttribute('aria-label', /Claude.*Max · work 1%/)
  await page.evaluate(() => window.dispatchEvent(new Event('scroll'))); await expect(pop).toHaveClass('ax-pop')
  await line.hover()
  await page.clock.resume()
  expect((await page.request.get('/build-control/usage?name=stale')).status()).toBe(200); await expect(pop).toContainText('Observed')
  expect((await page.request.get('/build-control/usage?name=locked')).status()).toBe(200)
  await expect(pop).toHaveClass('ax-pop'); await expect(pop).toBeEmpty(); await expect(page.locator('.ax-ln')).toHaveCount(0)
})
test('visible ticks advance labels, preserve unchanged DOM, fit resets and dispose body nodes', async ({ page }) => {
  const stable=fixture('unknown'); stable.apis=[]
  stable.providers[0].session.reset_at=NOW+(22*24*60+90)*60000
  await paint(page,stable)
  await page.evaluate(() => { window.originalUsage=document.querySelector('.ax-usage') })
  await page.clock.runFor(30000)
  expect(await page.evaluate(() => originalUsage === document.querySelector('.ax-usage'))).toBe(true)
  const u = fixture('unknown'); u.providers[0].session.reset_at = NOW+120000
  await paint(page,u); await expect(page.locator('.mdl .ax-rs')).toHaveText('1m/5h')
  await page.clock.runFor(60000); await expect(page.locator('.mdl .ax-rs')).toHaveText('0m/5h')
  expect(await page.locator('.mdl').evaluate(sec => {
    const max = Math.max(...[...sec.querySelectorAll('.ax-rs')].map(e => { e.style.width='max-content'; const w=e.getBoundingClientRect().width; e.style.width=''; return w }))
    return sec.style.getPropertyValue('--rsw') === Math.ceil(max)+'px'
  })).toBe(true)
  await page.evaluate(() => state.ctx.life.dispose())
  await expect(page.locator('body > .ax-pop')).toHaveCount(0)
})

test('hidden ticks wait for visibility and remount owns one popover', async ({ page }) => {
  await paint(page, fixture('one'))
  await page.evaluate(() => {
    Object.defineProperty(document,'hidden',{configurable:true,value:true})
    window.lastUsage=document.querySelector('.ax-usage')
  })
  await page.clock.runFor(60000)
  expect(await page.evaluate(() => lastUsage === document.querySelector('.ax-usage'))).toBe(true)
  await page.evaluate(() => Object.defineProperty(document,'hidden',{configurable:true,value:false}))
  await page.clock.runFor(30000)
  expect(await page.evaluate(() => lastUsage === document.querySelector('.ax-usage'))).toBe(false)
  await page.evaluate(async () => {
    state.ctx.life.dispose(); state.resetState()
    const {createLife}=await import('/build-home/life.js')
    state.ctx.root=document.querySelector('#build-root');state.ctx.life=createLife()
    state.ctx.snap={usage:{state:'authorized',apis:[],providers:[]}};usage.renderUsage()
  })
  await expect(page.locator('body > .ax-pop')).toHaveCount(1)
})

test('edge state screenshots for S-50 owner sign-off', async ({ page }, info) => {
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light')
  await expect(page.locator('html')).toHaveAttribute('data-palette', 'gruvbox')
  for (const name of ['unknown','partial','none','credits','onewin','stale','ended','hold','locked','unavailable','hostile','empty','one']) {
    await paint(page,fixture(name))
    await expect(page.locator('#bd-usage')).toHaveScreenshot(`usage-${name}.png`)
  }
})
