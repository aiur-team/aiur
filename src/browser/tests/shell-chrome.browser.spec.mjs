import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'
import { openFixture, assertNoDocumentOverflow } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

let pageErrors

test.beforeEach(async ({ page }) => {
  pageErrors = []
  page.on('pageerror', error => pageErrors.push(error.message))
  await page.setViewportSize({ width: 1440, height: 900 })
})

test.afterEach(() => expect(pageErrors).toEqual([]))

async function openProbe(page, query = 'paused=false&writable=true') {
  await openFixture(page, 'writable')
  await page.context().setHTTPCredentials(dashboardCredentials)
  await page.goto(`/palette-probe?${query}`)
  await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1)
}

async function startDrag(page, x) {
  const box = await page.locator('#ax-drag').boundingBox()
  await page.mouse.move(box.x + box.width / 2, box.y + Math.min(box.height / 2, 100))
  await page.mouse.down()
  await page.mouse.move(x, box.y + Math.min(box.height / 2, 100), { steps: 4 })
}

async function collapsed(page, value) {
  await expect(page.locator('#ax-drag')).toHaveAttribute('data-nav-collapsed', String(value))
  await expect(page.locator('#ax-drag')).toHaveAttribute('aria-valuenow', value ? '60' : '188')
  expect(await page.evaluate(() => localStorage.getItem('aiur-nav-collapsed'))).toBe(String(value))
}

test('B-1 collapse is restored before socket connection and round-trips to the server', async ({ page }) => {
  await page.addInitScript(() => {
    localStorage.setItem('aiur-nav-collapsed', 'true')
    document.addEventListener('DOMContentLoaded', () => {
      window.firstShellPaint = {
        collapsed: document.documentElement.classList.contains('nav-collapsed'),
        connected: window.liveSocket?.isConnected() === true
      }
    }, { once: true })
  })
  await openProbe(page)
  expect(await page.evaluate(() => window.firstShellPaint)).toEqual({ collapsed: true, connected: false })
  await collapsed(page, true)
})

test('B-2 drag clamps to boolean rails, click toggles and resize follows release', async ({ page }) => {
  await openProbe(page)
  await page.evaluate(() => {
    window.shellResizeTimes = []
    window.addEventListener('resize', () => window.shellResizeTimes.push(performance.now()))
  })
  await startDrag(page, 100)
  await expect(page.locator('html')).toHaveClass(/nav-drag/)
  expect(await page.locator('html').evaluate(node => getComputedStyle(node).cursor)).toBe('col-resize')
  const releasedAt = await page.evaluate(() => performance.now())
  await page.mouse.up()
  await collapsed(page, true)
  await expect.poll(() => page.evaluate(() => window.shellResizeTimes.length)).toBeGreaterThan(0)
  const delay = await page.evaluate(start => window.shellResizeTimes.at(-1) - start, releasedAt)
  expect(delay).toBeGreaterThanOrEqual(200)
  expect(delay).toBeLessThan(600)
  await startDrag(page, 180)
  await page.mouse.up()
  await collapsed(page, false)
  await page.locator('#ax-drag').click()
  await collapsed(page, true)
})

test('B-2 pointer cancellation cleans up width and restores the server mirror', async ({ page }) => {
  await openProbe(page)
  await startDrag(page, 100)
  await expect(page.locator('html')).toHaveClass(/nav-drag/)
  await page.locator('#ax-drag').dispatchEvent('pointercancel', { pointerId: 1 })
  await expect(page.locator('html')).not.toHaveClass(/nav-drag/)
  expect(await page.locator('html').evaluate(node => node.style.getPropertyValue('--navw'))).toBe('')
  await expect(page.locator('#ax-drag')).toHaveAttribute('data-nav-collapsed', 'false')
  await expect(page.locator('html')).not.toHaveClass(/nav-collapsed/)
  await page.mouse.up()
})

test('B-3 menu opens, closes outside and restores cog focus on Escape', async ({ page }) => {
  await openProbe(page)
  const menu = page.locator('#ax-menu')
  await expect(menu).toHaveAttribute('inert', '')
  await page.locator('#ax-cog').click()
  await expect(page.locator('#ax-set')).toHaveClass(/open/)
  await expect(page.locator('#ax-cog')).toHaveAttribute('aria-expanded', 'true')
  await expect(menu).not.toHaveAttribute('inert')
  await page.locator('#ax-title').click()
  await expect(page.locator('#ax-cog')).toHaveAttribute('aria-expanded', 'false')
  await expect(menu).toHaveAttribute('inert', '')
  await page.locator('#ax-cog').click()
  const palette = await page.locator('html').getAttribute('data-palette')
  await page.locator('#ax-palette').click()
  await expect(page.locator('html')).toHaveAttribute('data-palette', palette === 'gruvbox' ? 'aiur' : 'gruvbox')
  await expect(page.locator('#ax-palette')).toHaveAttribute('aria-checked', palette === 'gruvbox' ? 'false' : 'true')
  const theme = await page.locator('html').getAttribute('data-theme')
  await page.locator('#theme-toggle').click()
  await expect(page.locator('html')).toHaveAttribute('data-theme', theme === 'dark' ? 'light' : 'dark')
  await page.keyboard.press('Escape')
  await expect(menu).toHaveAttribute('inert', '')
  await expect(page.locator('#ax-cog')).toBeFocused()
})

test('B-4 a server pause patch keeps the menu open and its focused item intact', async ({ page }) => {
  await openProbe(page)
  await page.locator('#ax-cog').focus()
  await page.keyboard.press('ArrowDown')
  await expect(page.locator('#ax-pause')).toBeFocused()
  await page.keyboard.press('Enter')
  await expect(page.locator('#ax-pause')).toHaveAttribute('aria-checked', 'true')
  await expect(page.locator('#ax-paused')).toHaveClass(/show/)
  await expect(page.locator('#ax-set')).toHaveClass(/open/)
  await expect(page.locator('#ax-cog')).toHaveAttribute('aria-expanded', 'true')
  await expect(page.locator('#ax-menu')).not.toHaveAttribute('inert')
  await expect(page.locator('#ax-pause')).toBeFocused()
  await expect.poll(() => page.locator('#ax-pause .ax-sw').evaluate(node => getComputedStyle(node, '::after').transform)).toBe('matrix(1, 0, 0, 1, 11, 0)')
})

test('B-5 keyboard wraps menu items and collapses navigation without a pointer', async ({ page }) => {
  await openProbe(page)
  // Traverse actual tab order to prove the inert menu contributes no tab stop.
  await page.keyboard.press('Tab')
  await expect(page.locator('#ax-cog')).toBeFocused()
  await page.keyboard.press('Tab')
  expect(await page.evaluate(() => !!document.activeElement.closest('#ax-menu'))).toBe(false)
  await page.locator('#ax-cog').focus()
  await page.keyboard.press('ArrowDown')
  await expect(page.locator('#ax-pause')).toBeFocused()
  await page.keyboard.press('End')
  await expect(page.locator('#ax-palette')).toBeFocused()
  await page.keyboard.press('ArrowDown')
  await expect(page.locator('#ax-pause')).toBeFocused()
  await page.keyboard.press('Escape')
  await expect(page.locator('#ax-cog')).toBeFocused()
  await page.locator('#ax-drag').focus()
  await page.keyboard.press('ArrowLeft')
  await collapsed(page, true)
  await page.keyboard.press('ArrowRight')
  await collapsed(page, false)
  await openProbe(page, 'paused=false&writable=false')
  await page.locator('#ax-cog').focus()
  await page.keyboard.press('ArrowDown')
  await expect(page.locator('#theme-toggle')).toBeFocused()
})

test('B-6 server patches during a drag preserve the local width and pointer interaction', async ({ page }) => {
  await openProbe(page)
  await startDrag(page, 100)
  const width = await page.locator('html').evaluate(node => node.style.getPropertyValue('--navw'))
  await page.locator('#probe-patch').evaluate(node => node.click())
  await expect(page.locator('#probe-patch')).toHaveAttribute('data-patch', '1')
  await expect(page.locator('html')).toHaveClass(/nav-drag/)
  expect(await page.locator('html').evaluate(node => node.style.getPropertyValue('--navw'))).toBe(width)
  await page.mouse.move(180, 150)
  await page.mouse.up()
  await expect(page.locator('#ax-drag')).toHaveAttribute('data-nav-collapsed', 'false')
  await expect(page.locator('html')).not.toHaveClass(/nav-drag|nav-collapsed/)
  expect(await page.locator('html').evaluate(node => node.style.getPropertyValue('--navw'))).toBe('')
})

test('B-7 disconnected dragging is local and reconnect restores server state', async ({ page }) => {
  await openProbe(page)
  await page.evaluate(() => window.liveSocket.disconnect())
  await expect(page.locator('.ax-title .brand-live')).toBeVisible()
  await startDrag(page, 100)
  await page.mouse.up()
  await expect(page.locator('html')).toHaveClass(/nav-collapsed/)
  await expect(page.locator('#ax-drag')).toHaveAttribute('data-nav-collapsed', 'false')
  await page.locator('#ax-drag').click()
  await expect(page.locator('html')).not.toHaveClass(/nav-collapsed/)
  await page.locator('#ax-drag').click()
  await expect(page.locator('html')).toHaveClass(/nav-collapsed/)
  await page.evaluate(() => window.liveSocket.connect())
  await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1)
  await expect(page.locator('html')).not.toHaveClass(/nav-collapsed/)
})

test('future regression guard: overlapping navigation choices survive older acknowledgements', async ({ page }) => {
  const requests = []
  const replies = new Map()
  let socket
  await page.routeWebSocket('**/live/websocket**', route => {
    socket = route
    const server = route.connectToServer()
    route.onMessage(message => {
      const packet = JSON.parse(message)
      if (packet[3] === 'event' && packet[4].event === 'restore-nav') requests.push({ ref: packet[1], collapsed: packet[4].value.collapsed })
      server.send(message)
    })
    server.onMessage(message => {
      const packet = JSON.parse(message)
      if (packet[3] === 'phx_reply' && requests.some(request => request.ref === packet[1])) replies.set(packet[1], message)
      else route.send(message)
    })
  })
  await openProbe(page)
  const handle = page.locator('#ax-drag')
  await page.evaluate(() => {
    const hook = window.liveSocket.main.getHook(document.querySelector('#ax-drag'))
    const push = hook.pushEvent.bind(hook)
    window.navAcknowledgements = 0
    hook.pushEvent = (name, payload, reply) => push(name, payload, response => {
      window.navAcknowledgements += 1
      reply?.(response)
    })
  })
  await handle.dispatchEvent('keydown', { key: 'Enter' })
  await handle.dispatchEvent('keydown', { key: 'Enter' })
  await expect.poll(() => replies.size).toBe(2)
  expect(requests.map(request => request.collapsed)).toEqual([true, false])
  socket.send(replies.get(requests[0].ref))
  await expect.poll(() => page.evaluate(() => window.navAcknowledgements)).toBe(1)
  await expect(page.locator('html')).not.toHaveClass(/nav-collapsed/)
  await handle.dispatchEvent('keydown', { key: 'Enter' })
  await expect.poll(() => replies.size).toBe(3)
  expect(requests.map(request => request.collapsed)).toEqual([true, false, true])
  socket.send(replies.get(requests[1].ref))
  socket.send(replies.get(requests[2].ref))
  await collapsed(page, true)
})

test('B-8 blocked storage keeps expanded navigation and working controls', async ({ page }) => {
  await page.addInitScript(() => {
    if (location.pathname !== '/palette-probe') return
    Storage.prototype.getItem = () => { throw Error('storage denied') }
    Storage.prototype.setItem = () => { throw Error('storage denied') }
  })
  await openProbe(page)
  await expect(page.locator('#ax-drag')).toHaveAttribute('data-nav-collapsed', 'false')
  await page.locator('#ax-drag').click()
  await expect(page.locator('#ax-drag')).toHaveAttribute('data-nav-collapsed', 'true')
  await page.locator('#ax-drag').click()
  await expect(page.locator('#ax-drag')).toHaveAttribute('data-nav-collapsed', 'false')
  await page.locator('#ax-cog').click()
  await expect(page.locator('#ax-cog')).toHaveAttribute('aria-expanded', 'true')
})

test('B-9 phone ignores stored collapse and shows each route in its fixed bottom navigation', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await page.addInitScript(() => localStorage.setItem('aiur-nav-collapsed', 'true'))
  await openProbe(page)
  await expect(page.locator('#ax-cog')).toBeInViewport()
  await expect(page.locator('html')).not.toHaveClass(/nav-collapsed/)
  const position = await page.locator('aside.sidenav').evaluate(node => {
    const style = getComputedStyle(node)
    return { position: style.position, bottom: style.bottom }
  })
  expect(position).toEqual({ position: 'fixed', bottom: '0px' })
  const paths = await page.locator('a.snav').evaluateAll(nodes => nodes.map(node => node.getAttribute('href')))
  expect(paths.length).toBeGreaterThanOrEqual(5)
  for (const path of paths) {
    const route = page.locator(`a.snav[href="${path}"]`)
    await expect(route).toBeInViewport()
    await route.click()
    await expect.poll(() => new URL(page.url()).pathname).toBe(path)
    await page.goto('/palette-probe?paused=false&writable=true')
    await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1)
  }
  await assertNoDocumentOverflow(page)
})

test('B-10 hiding the decisions banner preserves the unavailable-count notice and Commands dot', async ({ page }) => {
  await openProbe(page, 'paused=false&writable=true&awaiting=unknown')
  await expect(page.getByText('Command counts unavailable', { exact: false })).toBeVisible()
  await expect(page.locator('.snav-c.attn')).toHaveCount(0)
  await openProbe(page, 'paused=false&writable=true&awaiting=3')
  await expect(page.locator('#decisions-banner')).toHaveCSS('display', 'none')
  const dot = await page.locator('.snav-c.attn').boundingBox()
  expect(dot.width).toBe(8)
  expect(dot.height).toBe(8)
  await expect(page.locator('a.snav[href="/commands"]')).toHaveAccessibleName(/3 need a command/)
})

test('B-11 sticky descendants retain the viewport as their scroll container', async ({ page }) => {
  await openProbe(page)
  await page.evaluate(() => {
    const sticky = document.createElement('div')
    sticky.id = 'sticky-probe'
    sticky.style.cssText = 'position:sticky;top:0;height:20px;background:red'
    const spacer = document.createElement('div')
    spacer.style.height = '2000px'
    document.body.append(sticky, spacer)
    window.scrollTo(0, sticky.offsetTop + 400)
  })
  await expect.poll(() => page.locator('#sticky-probe').evaluate(node => node.getBoundingClientRect().top)).toBe(0)
})

for (const theme of ['dark', 'light']) for (const paused of ['false', 'unknown']) {
  test(`shell chrome accessibility is clean in ${theme} with pause ${paused}`, async ({ page }) => {
    await page.emulateMedia({ colorScheme: theme })
    await openProbe(page, `paused=${paused}&writable=true&awaiting=3`)
    await page.locator('#ax-cog').click()
    const menuAudit = await new AxeBuilder({ page }).include('header.ax-top').include('aside.sidenav').analyze()
    expect(menuAudit.violations).toEqual([])
    await page.keyboard.press('Escape')
    await page.locator('#ax-drag').click()
    await collapsed(page, true)
    await expect(page.getByRole('link', { name: 'Analytics', exact: true })).toBeVisible()
    const collapsedAudit = await new AxeBuilder({ page }).include('header.ax-top').include('aside.sidenav').analyze()
    expect(collapsedAudit.violations).toEqual([])
  })
}
