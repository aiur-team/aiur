import { expect, test } from '@playwright/test'
import { openDesign, parityContextOptions, PARITY_VIEWPORTS, FIXTURE_META, expectDesignParity, loadAllowlist, applyAllowlist } from '../support/design-parity.mjs'
import { openVisualRoute } from '../support/visual.mjs'

const properties = [
  'width', 'height', 'padding', 'margin', 'fontFamily', 'fontSize', 'fontWeight',
  'lineHeight', 'letterSpacing', 'color', 'backgroundColor', 'backgroundImage',
  'border', 'borderRadius', 'boxShadow', 'transition', 'transform', 'position'
]

async function equalStyle(pair, selector, keys = properties, pseudo = null) {
  const read = (node, { keys, pseudo }) => {
    const style = getComputedStyle(node, pseudo)
    return Object.fromEntries(keys.map(key => [key, style[key]]))
  }
  const input = { keys, pseudo }
  expect(await pair.product.locator(selector).evaluate(read, input), selector).toEqual(await pair.design.locator(selector).evaluate(read, input))
}

async function compareNavRegion(pair, name, selector) {
  // The allowed route subset changes phone positions, including text raster phase.
  const originals = []
  const origin = await pair.design.locator(selector).boundingBox()
  const backdrops = []
  if (pair.cell.viewport.width <= 960) {
    for (const page of [pair.design, pair.product]) {
      backdrops.push(await page.addStyleTag({ content: 'body { background: var(--bg) !important; } .sidenav-nav { visibility: hidden !important; }' }))
      originals.push(await page.locator(selector).evaluate((node, top) => {
        const original = node.style.cssText
        const box = node.getBoundingClientRect()
        Object.assign(node.style, { position: 'fixed', left: '100px', top: `${top}px`, width: `${box.width}px`, height: `${box.height}px`, margin: '0', translate: 'none' })
        node.style.setProperty('visibility', 'visible', 'important')
        return original
      }, Math.round(origin.y)))
    }
  }
  try { await expectDesignParity(pair, { name, region: selector }) }
  finally {
    for (const backdrop of backdrops) await backdrop.evaluate(node => node.remove())
    for (const [index, page] of [pair.design, pair.product].entries()) {
      if (originals.length) await page.locator(selector).evaluate((node, value) => { node.style.cssText = value }, originals[index])
    }
  }
}

async function finishTransitions(pair) {
  for (const page of [pair.design, pair.product]) {
    await page.evaluate(() => document.getAnimations().forEach(animation => {
      if (Number.isFinite(animation.effect?.getComputedTiming().endTime)) animation.finish()
    }))
  }
}

for (const viewport of PARITY_VIEWPORTS) for (const theme of ['dark', 'light']) for (const palette of ['aiur', 'gruvbox']) {
  const cell = { ...viewport, theme, palette, dataset: 'live' }
  const label = `${viewport.viewport.width}-${theme}-${palette}`
  test(`shell regions match design: ${label}`, async ({ browser }) => {
    test.setTimeout(90_000)
    const designContext = await browser.newContext(parityContextOptions(cell))
    const productContext = await browser.newContext({ ...parityContextOptions(cell), baseURL: test.info().project.use.baseURL })
    const pair = { design: await designContext.newPage(), product: await productContext.newPage(), cell }
    try {
      await openDesign(pair.design, cell, { phase: 'shell' })
      await pair.design.evaluate(() => window.AiurHost.switchTab('fleet'))
      await pair.product.clock.setFixedTime(FIXTURE_META.now)
      await openVisualRoute(pair.product, { theme, palette, route: '/palette-probe?paused=false&writable=true&awaiting=3', mode: 'writable' })
      pair.allowlist = await loadAllowlist()
      await applyAllowlist(pair, cell)
      // Transparent chrome must not sample the unrelated demo table beneath it.
      const shellBackdrops = await Promise.all([pair.design, pair.product].map(page => page.addStyleTag({ content: 'section.dashboard-shell { visibility: hidden !important; }' })))
      await finishTransitions(pair)
      await equalStyle(pair, 'header.ax-top')
      await equalStyle(pair, '.ax-brand')
      await expectDesignParity(pair, { name: `top-${label}`, region: 'header.ax-top' })
      // Transparent menu corners expose page content outside this shell region.
      const menuBackdrops = []
      for (const page of [pair.design, pair.product]) menuBackdrops.push(await page.addStyleTag({ content: 'body { background: var(--bg) !important; } section.dashboard-shell, .sidenav-nav { visibility: hidden !important; }' }))
      for (const page of [pair.design, pair.product]) await page.locator('#ax-cog').click()
      await finishTransitions(pair)
      await equalStyle(pair, '#ax-menu')
      expect(await pair.product.locator('#ax-menu').boundingBox()).toEqual(await pair.design.locator('#ax-menu').boundingBox())
      await equalStyle(pair, '#ax-pause')
      for (const page of [pair.design, pair.product]) await page.addStyleTag({ content: '.brand-logo, .wm, #ax-cog, #ax-title, #ax-paused { visibility: hidden !important; }' })
      await expectDesignParity(pair, { name: `menu-${label}`, region: '#ax-menu' })
      for (const page of [pair.design, pair.product]) await page.locator('#ax-pause').hover()
      await finishTransitions(pair)
      await equalStyle(pair, '#ax-pause')
      await expectDesignParity(pair, { name: `menu-hover-${label}`, region: '#ax-menu' })
      for (const page of [pair.design, pair.product]) await page.locator('#ax-pause').click()
      await expect(pair.product.locator('#ax-paused')).toHaveClass(/show/)
      for (const page of [pair.design, pair.product]) await page.keyboard.press('Escape')
      for (const backdrop of menuBackdrops) await backdrop.evaluate(node => node.remove())
      for (const page of [pair.design, pair.product]) await page.addStyleTag({ content: '.brand-logo, .wm, #ax-cog, #ax-title, #ax-paused { visibility: visible !important; }' })
      // Pointer and keyboard focus are not a design region's paused state.
      for (const page of [pair.design, pair.product]) await page.locator('#ax-title').click()
      await finishTransitions(pair)
      await expectDesignParity(pair, { name: `top-paused-${label}`, region: 'header.ax-top' })

      if (cell.viewport.width > 960) {
        for (const page of [pair.design, pair.product]) await page.locator('#ax-drag').click()
        await expect(pair.product.locator('#ax-drag')).toHaveAttribute('data-nav-collapsed', 'true')
        await finishTransitions(pair)
        await equalStyle(pair, '.ax-brand')
        await expectDesignParity(pair, { name: `top-collapsed-${label}`, region: 'header.ax-top' })
        for (const page of [pair.design, pair.product]) await page.locator('#ax-drag').click()
        await expect(pair.product.locator('#ax-drag')).toHaveAttribute('data-nav-collapsed', 'false')
        // Settle the expanding handle before placing the pointer in its final bounds.
        await finishTransitions(pair)
        for (const page of [pair.design, pair.product]) await page.locator('#ax-drag').hover()
        await finishTransitions(pair)
        await expect.poll(() => Promise.all([pair.design, pair.product].map(page =>
          page.locator('#ax-drag').evaluate(node => node.matches(':hover'))))).toEqual([true, true])
        await equalStyle(pair, '#ax-drag', ['width', 'position', 'top', 'bottom', 'right', 'cursor'])
        await equalStyle(pair, '#ax-drag', ['width', 'backgroundColor', 'opacity', 'transition'], '::after')
        // Clip just the handle; whole desktop nav differs until C12-T01.
        await expectDesignParity(pair, { name: `drag-hover-${label}`, region: '#ax-drag' })
      } else {
        await equalStyle(pair, 'aside.sidenav', ['position', 'bottom', 'height', 'padding', 'backgroundColor', 'border', 'boxShadow'])
      }

      for (const backdrop of shellBackdrops) await backdrop.evaluate(node => node.remove())
      await pair.design.addStyleTag({ content: '.sidenav-nav { visibility: visible !important; }' })
      await pair.design.evaluate(() => {
        window.AiurHost.switchTab('analytics')
      })
      await openVisualRoute(pair.product, { theme, palette, route: '/analytics', mode: 'writable' })
      const commandDot = pair.product.locator('a.snav[href="/commands"] .snav-c.attn')
      const commandCount = await commandDot.count() ? await commandDot.textContent() : '0'
      await pair.design.locator('#tabcount-inbox').evaluate((node, count) => {
        node.textContent = count
        node.classList.toggle('attn', Number(count) > 0)
        node.style.display = Number(count) > 0 ? '' : 'none'
      }, commandCount)
      const navPairs = [
        '.snav[data-tab="inbox"], a.snav[href="/commands"]',
        '.snav[data-tab="analytics"], a.snav[href="/analytics"]',
        '.snav[data-tab="streamdeck"], a.snav[href="/streamdeck"]'
      ]
      for (const [index, selector] of navPairs.entries()) {
        for (const page of [pair.design, pair.product]) await page.mouse.move(cell.viewport.width - 20, 80)
        await finishTransitions(pair)
        await equalStyle(pair, selector)
        await compareNavRegion(pair, `nav-${index}-${label}`, selector)
      }
      await pair.design.locator('#tabcount-inbox').evaluate(node => { node.textContent = '3'; node.style.display = ''; node.classList.add('attn') })
      await openVisualRoute(pair.product, { theme, palette, route: '/palette-probe?paused=false&writable=true&awaiting=3', mode: 'writable' })
      await equalStyle(pair, navPairs[0])
      await compareNavRegion(pair, `commands-attention-${label}`, navPairs[0])
      await pair.design.locator('#tabcount-inbox').evaluate(node => node.style.display = 'none')
      await openVisualRoute(pair.product, { theme, palette, route: '/palette-probe?paused=false&writable=true&awaiting=0', mode: 'writable' })
      await equalStyle(pair, navPairs[0])
      await compareNavRegion(pair, `commands-empty-${label}`, navPairs[0])
    } finally {
      await designContext.close()
      await productContext.close()
    }
  })
}

async function sampleMotion(page, selector, event, nodes) {
  await page.locator(selector).evaluate((node, { event, nodes }) => {
    window.shellMotion = null
    const targets = nodes.map(([selector]) => document.querySelector(selector))
    node.addEventListener(event, () => setTimeout(() => {
      // Seek paused native curves at identical times, independent of host frame delays.
      targets.forEach(target => getComputedStyle(target).width)
      const animations = targets.flatMap(target => target.getAnimations()).filter(animation => Number.isFinite(animation.effect.getComputedTiming().endTime))
      window.shellTiming = animations.map(animation => ({ property: animation.transitionProperty, duration: animation.effect.getTiming().duration, easing: animation.effect.getTiming().easing, endTime: animation.effect.getComputedTiming().endTime }))
      animations.forEach(animation => { animation.pause(); animation.currentTime = 0 })
      const frames = []
      for (let t = 0; t <= 500; t += 10) {
        animations.forEach(animation => { animation.currentTime = t })
        frames.push({ t, values: nodes.map(([selector, property]) => getComputedStyle(document.querySelector(selector))[property]) })
      }
      animations.forEach(animation => animation.finish())
      window.shellMotion = frames
    }, 0), { once: true, capture: true })
  }, { event, nodes })
}

function assertMotion(design, product, properties) {
  expect(design.length).toBeGreaterThan(10)
  expect(product.length).toBeGreaterThan(10)
  for (const frames of [design, product]) {
    expect(frames.map(frame => frame.t), 'load-independent sample times').toEqual(Array.from({ length: 51 }, (_, index) => index * 10))
    expect(frames.at(-1).values, 'native styles progress along the curve').not.toEqual(frames[0].values)
    expect(frames[0].t, "first transition frame").toBeLessThanOrEqual(20)
    expect(frames.at(-1).t, "settled transition tail").toBeGreaterThanOrEqual(400)
  }
  for (const sample of design) {
    const nearby = product.filter(frame => frame.t === sample.t)
    expect(nearby.length, `no product frame at ${sample.t}ms`).toBeGreaterThan(0)
    for (let index = 0; index < properties.length; index += 1) {
      const numbers = value => [...value.matchAll(/-?\d+(?:\.\d+)?/g)].map(match => Number(match[0]))
      const expected = numbers(sample.values[index])
      const nearest = nearby.map(frame => numbers(frame.values[index]))
      // Compare the same native animation time without a neighboring-frame allowance.
      const aligned = nearest.filter(values => values.length === expected.length)
      expect(aligned.length).toBeGreaterThan(0)
      for (let i = 0; i < expected.length; i += 1) {
        expect(expected[i], JSON.stringify(sample)).toBeGreaterThanOrEqual(Math.min(...aligned.map(values => values[i])) - properties[index])
        expect(expected[i], JSON.stringify(sample)).toBeLessThanOrEqual(Math.max(...aligned.map(values => values[i])) + properties[index])
      }
    }
  }
}

test('shell collapse and menu motion follow the design frame curves', async ({ browser }) => {
  test.setTimeout(60_000)
  const cell = { viewport: { width: 1440, height: 900 }, theme: 'dark', palette: 'gruvbox', dataset: 'live' }
  const designContext = await browser.newContext(parityContextOptions(cell))
  const productContext = await browser.newContext({ ...parityContextOptions(cell), baseURL: test.info().project.use.baseURL })
  const pair = { design: await designContext.newPage(), product: await productContext.newPage(), cell }
  try {
    await openDesign(pair.design, cell, { phase: 'shell' })
    await pair.design.evaluate(() => window.AiurHost.switchTab('fleet'))
    await pair.product.clock.setFixedTime(FIXTURE_META.now)
    await openVisualRoute(pair.product, { theme: cell.theme, palette: cell.palette, route: '/palette-probe?paused=false&writable=true', mode: 'writable' })
    await finishTransitions(pair)
    await equalStyle(pair, '.app-layout', ['transition'])
    await equalStyle(pair, '.ax-brand', ['transition'])
    for (const page of [pair.design, pair.product]) {
      await page.bringToFront()
      await sampleMotion(page, '#ax-drag', 'pointerup', [['.app-layout', 'gridTemplateColumns'], ['.ax-brand', 'width']])
      await page.locator('#ax-drag').click()
      await expect.poll(() => page.evaluate(() => window.shellMotion)).not.toBeNull()
    }
    expect(await pair.product.evaluate(() => window.shellTiming)).toEqual(await pair.design.evaluate(() => window.shellTiming))
    expect(await pair.product.evaluate(() => window.shellTiming.length)).toBeGreaterThan(0)
    assertMotion(await pair.design.evaluate(() => window.shellMotion), await pair.product.evaluate(() => window.shellMotion), [1, 1])
    for (const page of [pair.design, pair.product]) await page.locator('#ax-drag').click()
    await expect(pair.product.locator('#ax-drag')).toHaveAttribute('data-nav-collapsed', 'false')
    await finishTransitions(pair)
    await equalStyle(pair, '#ax-menu', ['transition'])
    for (const page of [pair.design, pair.product]) {
      await page.bringToFront()
      await sampleMotion(page, '#ax-cog', 'click', [['#ax-menu', 'opacity'], ['#ax-menu', 'transform']])
      await page.locator('#ax-cog').click()
      await expect.poll(() => page.evaluate(() => window.shellMotion)).not.toBeNull()
    }
    expect(await pair.product.evaluate(() => window.shellTiming)).toEqual(await pair.design.evaluate(() => window.shellTiming))
    expect(await pair.product.evaluate(() => window.shellTiming.length)).toBeGreaterThan(0)
    assertMotion(await pair.design.evaluate(() => window.shellMotion), await pair.product.evaluate(() => window.shellMotion), [0.02, 0.2])
  } finally {
    await designContext.close()
    await productContext.close()
  }
})
