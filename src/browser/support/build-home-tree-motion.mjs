import { alignBoard, primeBoardPaint } from './build-home-band-canvas.mjs'

export async function prepareTreeMotion(pair) {
  await alignBoard(pair)
}

export async function prepareTreeFrame(pair, region) {
  await primeBoardPaint(pair, '#bd-lanes')
  await primeBoardPaint(pair, '#bd-sb')
  // Transparent overlay frames include the board behind their sibling host.
  return region === '#bd-tree' ? '.bd-vpw' : region
}

async function scrollTree(page, centerCard = false) {
  await page.locator('#bd-vp').evaluate((el, centerCard) => {
    const card = document.querySelector('.bd-card[data-id="615"], .bd-card[data-id="AIUR-615"]')
    const top = centerCard ? el.scrollTop + card.getBoundingClientRect().top - el.getBoundingClientRect().top - 180
      : document.querySelector('#bd-sec-plan').offsetTop
    const before = el.scrollTop
    return new Promise(resolve => {
      const done = () => resolve()
      el.addEventListener('scroll', done, { once: true })
      el.scrollTop = top
      if (el.scrollTop === before) { el.removeEventListener('scroll', done); resolve() }
    })
  }, centerCard)
  await page.clock.runFor(704)
}

// Both designs expose the same fixture number; the product listens to pointer events.
export async function hoverTreeCard(page) {
  await scrollTree(page)
  const card = page.locator('.bd-card[data-id="615"], .bd-card[data-id="AIUR-615"]').first()
  if (!await card.count()) throw new Error('unreachable tree card 615')
  await scrollTree(page, true)
  await page.locator('.bd-lt').evaluate(el => getComputedStyle(el).opacity)
  await card.evaluate(el => {
    el.dispatchEvent(new PointerEvent('pointerover', { bubbles: true, pointerType: 'mouse' }))
    el.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }))
  })
}
export async function treeTab(page, ctx, { cssMotion }) {
  await hoverTreeCard(page)
  const animation = await cssMotion(page, '.bd-lt', ctx)
  return { animation, samples: [await page.locator('.bd-lt').evaluate(el => ({ shown: el.classList.contains('show'), locked: el.classList.contains('locked') }))] }
}
export async function treeHoverClear(page) {
  await hoverTreeCard(page)
  const state = () => page.locator('#bd-content').evaluate(el => ({ hovering: el.classList.contains('hovering'), tab: el.querySelector('.bd-lt').classList.contains('show') }))
  const samples = [await state()]
  await page.locator('#bd-content').evaluate(el => {
    el.dispatchEvent(new PointerEvent('pointerover', { bubbles: true, pointerType: 'mouse' }))
    el.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }))
  })
  await page.clock.runFor(250); samples.push(await state())
  await page.clock.runFor(70); samples.push(await state())
  await hoverTreeCard(page)
  await page.locator('#bd-content').dispatchEvent('mouseleave')
  await page.clock.runFor(220); samples.push(await state())
  return { samples }
}
