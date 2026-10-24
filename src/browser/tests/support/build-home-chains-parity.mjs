import { expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { alignBoard, primeBoardPaint } from '../../support/build-home-band-canvas.mjs'

export async function largestRoot(page, dataset, section) {
  const snapshot = JSON.parse(await readFile(new URL('../../../test/fixtures/build_home/' + dataset + '.json', import.meta.url), 'utf8'))
  const all = Object.values(snapshot.sections).flat()
  const data = { byId: Object.fromEntries(all.map(t => [t.id, t])), children: Object.fromEntries(all.map(t => [t.id, t.children])) }
  return page.evaluate(async ({ all, data, section }) => {
    const { chainOf } = await import('/build-home/chains.js')
    return all.filter(t => section ? t.sec === section : ['hist', 'plan'].includes(t.sec))
      .map(t => ({ ...t, size: chainOf(data, t.id).size }))
      .sort((a, b) => b.size - a.size || a.num - b.num)[0]
  }, { all, data, section })
}

export async function hoverRoot(page, root, product) {
  await page.locator('#bd-vp').evaluate((vp, history) => {
    const anchor = document.querySelector(history ? '#bd-sec-hist' : '#bd-sec-plan')
    vp.scrollTop = anchor.offsetTop + (history ? anchor.offsetHeight : 0) - 300
  }, root.sec === 'hist' && page.viewportSize().width === 390)
  await page.waitForTimeout(800)
  const card = page.locator(`.bd-card[data-id="${root.id}"], .bd-card[data-id="AIUR-${root.num}"]`).first()
  // Narrow layouts stack history rows; walk the real scrollport until the root is rendered.
  for (let step = 0; step < 50 && !await card.count(); step++) {
    const moved = await page.locator('#bd-vp').evaluate((vp, direction) => {
      const before = vp.scrollTop
      vp.scrollTop += direction * vp.clientHeight
      return vp.scrollTop !== before
    }, root.sec === 'hist' ? -1 : 1)
    if (!moved) break
    await page.waitForTimeout(300)
  }
  await expect(card).toHaveCount(1)
  await card.evaluate(el => {
    const vp = document.querySelector('#bd-vp')
    vp.scrollTop += el.getBoundingClientRect().top - vp.getBoundingClientRect().top - 180
  })
  await page.waitForTimeout(800)
  await expect(page.locator('.bd-content')).not.toHaveClass(/\bscrolling\b/)
  await card.dispatchEvent(product ? 'pointerover' : 'mouseover', { pointerType: 'mouse' })
  await expect(page.locator('.bd-lt.show')).toHaveCount(1)
  // Cards can sit behind the sticky band. The visible tab explicitly preserves hover.
  const control = await page.locator('.bd-lt.show [data-lt="lock"]').boundingBox()
  await page.mouse.move(control.x + control.width / 2, control.y + control.height / 2)
  await page.waitForTimeout(250)
}

function chainPaint(page, root) {
  return page.evaluate(root => {
    const ref = el => el.dataset.id.replace(/^AIUR-/, '')
    const vp = document.querySelector('#bd-vp').getBoundingClientRect()
    const visible = el => { const b = el.getBoundingClientRect(); return b.bottom > vp.top && b.top < vp.bottom }
    const source = document.querySelector(`.bd-card[data-id="${root.id}"], .bd-card[data-id="AIUR-${root.num}"]`)
    const tab = document.querySelector('.bd-lt'), content = document.querySelector('.bd-content')
    const box = source.getBoundingClientRect(), origin = content.getBoundingClientRect()
    return {
      highlighted: [...document.querySelectorAll('.bd-card.hl')].map(ref).sort(),
      dimmed: [...document.querySelectorAll('.bd-card.hdim')].filter(visible).map(ref).sort(),
      hovering: content.classList.contains('hovering'),
      locked: tab.classList.contains('locked'),
      position: [parseFloat(tab.style.left), parseFloat(tab.style.top)],
      expected: [box.right - origin.left - 1, box.top - origin.top + Math.max(0, box.height / 2 - 14)],
    }
  }, root)
}

export async function assertChainPaint(pair, root, locked) {
  const [design, product] = await Promise.all([chainPaint(pair.design, root), chainPaint(pair.product, root)])
  for (const state of [design, product]) {
    expect(state.hovering).toBe(true)
    expect(state.locked).toBe(locked)
    expect(state.highlighted.length).toBeGreaterThan(0)
    expect(state.dimmed.length).toBeGreaterThan(0)
    for (let i = 0; i < 2; i++) expect(state.position[i]).toBeCloseTo(state.expected[i], 1)
  }
  expect(product.highlighted).toEqual(design.highlighted)
  expect(product.dimmed).toEqual(design.dimmed)
  for (let i = 0; i < 2; i++) expect(product.position[i]).toBeCloseTo(design.position[i], 1)
}

export function fitState(page) {
  return page.evaluate(() => ({
    url: Object.fromEntries([...new URLSearchParams(location.search)].filter(([key]) => ['span', 'from'].includes(key))),
    scroll: document.querySelector('#bd-vp').scrollTop,
    zoom: document.querySelector('.bd-zv')?.textContent,
    locked: document.querySelector('.bd-lt').classList.contains('locked'),
  }))
}

export async function installFitObserver(page) {
  await page.evaluate(async () => {
    const { fx } = await import('/build-home/state.js')
    const toggle = fx.toggleLock
    fx.toggleLock = button => {
      const result = toggle(button)
      if (button.dataset.lt === 'fit') {
        if (typeof result?.then !== 'function') throw new Error('Fit handler must return its pending operation')
        window.chainParityFit = result
      }
      return result
    }
  })
}

export async function waitForFit(page) {
  await page.evaluate(async () => {
    if (!window.chainParityFit) throw new Error('Fit click did not invoke the observed operation')
    await window.chainParityFit
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))
  })
  await expect(page.locator('#build-root')).toHaveAttribute('data-bd-paging', 'idle')
  await expect(page.locator('.bd-lt.locked.show')).toHaveCount(1)
}

export const treeRecord = page => page.locator('#bd-tree').evaluate(host => ({
  header: host.querySelector('.bd-tree-h span').textContent,
  transform: host.querySelector('.bd-tree-in').style.transform,
  size: ['width', 'height'].map(k => host.querySelector('.bd-tree-in').style[k]),
  nodes: [...host.querySelectorAll('.bd-tn')].map(el => ({ ref: el.querySelector('b').textContent,
    title: el.querySelector('.bd-tn1 > span').textContent, status: el.querySelector('em').textContent,
    pos: ['left', 'top', 'width', 'height'].map(k => el.style[k]) })).sort((a,b) => a.ref.localeCompare(b.ref))
}))

// Compare the live band and chain/tab/tree pixels without ETA masks.
export async function prepareChainParity(pair) {
  // Capture both scrollbars after their activity interval, not on either side of its expiry.
  for (const page of [pair.design, pair.product]) await expect(page.locator('#bd-sb')).not.toHaveClass(/\bact\b/)
  // Date is frozen, but the live clock's monotonic elapsed time keeps advancing.
  await pair.product.evaluate(async now => {
    const { setNow } = await import('/build-home/clock.js')
    const { fx } = await import('/build-home/state.js')
    setNow(now); fx.refreshBandClock()
  }, await pair.design.evaluate(() => Date.now()))
  await primeBoardPaint(pair, '#bd-lanes')
}

export async function prepareChainCanvas(pair) {
  // Use the band's canonical canvas for every width, clear of unrelated page chrome.
  await alignBoard(pair)
}
