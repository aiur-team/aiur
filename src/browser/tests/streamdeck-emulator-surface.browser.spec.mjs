import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'
import { dragDialThroughAngles, openStreamdeck } from './support/streamdeck-emulator.mjs'

test('seeded retained transcript appears as ticket turn keys and pages without repeats', async ({ page }) => {
  await openStreamdeck(page)
  const seed = await page.request.get('/streamdeck-transcript/seed')
  expect(seed.status()).toBe(200)
  try {
    await page.locator('#sd-keys .sd-key:not(.is-empty)').first().click()
    const keys = page.locator('#sd-keys .sd-key')
    await expect(keys).toHaveCount(8)
    await expect(keys.last()).toHaveAttribute('aria-label', 'LIVE')
    await expect(keys.nth(6)).toHaveAttribute('aria-label', /Seeded turn 30/)
    const turns = page.locator('#sd-keys [data-chat-turn]')
    await expect(turns).toHaveCount(7)
    await expect(turns.first()).toHaveAttribute('aria-label', /Seeded turn 24/)
    const firstPage = await turns.evaluateAll(nodes => nodes.map(node => node.dataset.chatTurn))

    await turns.first().click()
    await expect(turns.first()).toHaveAttribute('aria-current', 'true')
    await expect(page.locator('#sd-screen')).toContainText('Seeded turn 24')
    await keys.last().click()
    await expect(keys.last()).toHaveAttribute('aria-current', 'true')
    await expect(page.locator('#sd-screen')).toContainText('Seeded turn 30')

    await dragDialThroughAngles(page, page.locator('.sd-knob').nth(3), [90, 0, -90])
    await expect(turns.last()).toHaveAttribute('aria-label', /Seeded turn 23/)
    await expect(turns.first()).toHaveAttribute('aria-label', /Seeded turn 17/)
    const olderPage = await turns.evaluateAll(nodes => nodes.map(node => node.dataset.chatTurn))
    expect(olderPage.filter(id => firstPage.includes(id))).toEqual([])
    await expect(keys.last()).toHaveAttribute('aria-label', 'LIVE')
    await keys.last().click()
    await expect(page.locator('#sd-screen')).toContainText('Seeded turn 30')
  } finally {
    expect((await page.request.get('/streamdeck-transcript/reset')).status()).toBe(200)
  }
})

test('touch strip renders category and backlog SVG bands at native device coordinates', async ({ page }) => {
  await openStreamdeck(page)
  const strip = page.locator('#sd-screen')
  await expect(strip).toBeVisible()
  const box = await strip.boundingBox()
  expect(box.width).toBe(800)
  expect(box.height).toBe(100)
  await expect(strip.locator('[data-provider]')).toHaveCount(0)
  await expect(strip.locator('[data-streamdeck-region="200"] [data-state="active"]')).toHaveCount(1)
  await expect(strip.locator('[data-streamdeck-region="200"]')).toContainText('Agents')
  const regions = await strip.locator(':scope > [data-streamdeck-region]').evaluateAll((nodes) => nodes.map((node) => ({
    x: Number(node.dataset.streamdeckRegion), left: parseFloat(node.style.left), svgs: node.querySelectorAll('svg').length
  })))
  expect(regions.map((region) => region.x)).toEqual([0, 200, 600])
  expect(regions.every((region) => region.x === region.left && region.svgs === 1)).toBe(true)
  await expect(strip.locator('[data-streamdeck-region="600"]')).toContainText('Queued 15')
  await expect(strip.locator('[data-streamdeck-region="600"]')).toContainText('Not queued 0')
  await expect(strip.locator('[data-streamdeck-region="600"] circle[data-page]')).not.toHaveCount(0)
})

test('Stream Deck design geometry holds at desktop and mobile widths in both themes', async ({ page }, testInfo) => {
  await page.setViewportSize({ width: 1280, height: 900 })
  await openStreamdeck(page)

  const device = page.locator('.sd-device')
  const keys = page.locator('.sd-keys')
  const desktopGeometry = await page.evaluate(() => {
    const device = document.querySelector('.sd-device')
    const keys = document.querySelector('.sd-keys')
    const key = keys.querySelector('.sd-key')
    const deviceStyle = getComputedStyle(device)
    const keysStyle = getComputedStyle(keys)
    const keyBox = key.getBoundingClientRect()

    return {
      device: {
        width: device.getBoundingClientRect().width,
        maxWidth: deviceStyle.maxWidth,
        borderRadius: deviceStyle.borderRadius,
        backgroundImage: deviceStyle.backgroundImage,
        borderColor: deviceStyle.borderColor,
        boxShadow: deviceStyle.boxShadow
      },
      columns: keysStyle.gridTemplateColumns.split(' ').filter(Boolean).length,
      columnGap: keysStyle.columnGap,
      rowGap: keysStyle.rowGap,
      keyRatio: keyBox.width / keyBox.height,
      states: Object.fromEntries(Array.from(keys.querySelectorAll('[data-streamdeck-face]')).map((key) => [
        key.getAttribute('data-streamdeck-face'),
        Array.from(key.querySelectorAll('svg > defs > linearGradient > stop:first-child')).map((stop) => stop.getAttribute('stop-color'))
      ])),
      pressShadow: (() => {
        const knob = document.querySelector('.sd-knob')
        knob.classList.add('press')
        const boxShadow = getComputedStyle(knob).boxShadow
        knob.classList.remove('press')
        return boxShadow
      })()
    }
  })

  expect(desktopGeometry.device.width).toBeCloseTo(860, 0)
  expect(desktopGeometry.device.maxWidth).toBe('860px')
  expect(desktopGeometry.device.borderRadius).toBe('34px')
  expect(desktopGeometry.device.borderColor).toBe('rgba(255, 255, 255, 0.06)')
  expect(desktopGeometry.device.backgroundImage).toContain('rgb(42, 43, 46)')
  expect(desktopGeometry.device.backgroundImage).toContain('0%')
  expect(desktopGeometry.device.backgroundImage).toContain('rgb(32, 31, 34) 55%')
  expect(desktopGeometry.device.backgroundImage).toContain('rgb(22, 21, 23)')
  expect(desktopGeometry.device.boxShadow).toContain('rgba(0, 0, 0, 0.5) 0px 30px 70px 0px')
  expect(desktopGeometry.device.boxShadow).toContain('rgba(255, 255, 255, 0.06) 0px 1px 0px 0px inset')
  expect(desktopGeometry.columns).toBe(4)
  expect(desktopGeometry.columnGap).toBe('0px')
  expect(desktopGeometry.rowGap).toBe('16px')
  expect(desktopGeometry.keyRatio).toBeCloseTo(1, 2)
  const colours = {
    active: ['#3f8bff', '#18212d'], idle: ['#4a4d55', '#1e2025'], unknown: ['#4a4d55', '#1e2025'],
    running: ['#3f8bff', '#18212d'], paused: ['#4a4d55', '#1e2025'],
    stuck: ['#ff6a5e', '#271317'], alert: ['#ffc061', '#241d0e'], queued: ['#3a3f47', '#191b21']
  }
  expect(Object.keys(desktopGeometry.states).length).toBeGreaterThan(0)
  for (const [state, stops] of Object.entries(desktopGeometry.states)) expect(stops).toEqual(colours[state])
  expect(desktopGeometry.pressShadow).toContain('rgba(0, 0, 0, 0.6) 0px 3px 7px 0px')
  expect(desktopGeometry.pressShadow).toContain('rgba(255, 255, 255, 0.5) 0px 0px 0px 2px inset')
  await device.screenshot({ path: testInfo.outputPath('streamdeck-desktop.png') })

  const readAiurInks = () => device.evaluate((el) => ['--fg', '--accent'].map((name) => getComputedStyle(el).getPropertyValue(name).trim()))

  const darkSurface = await page.evaluate(() => ['.sd-device', '[data-streamdeck-state]', '[data-streamdeck-state] > svg', '.sd-screen', '.sd-well', '.sd-knob'].map((selector) => {
    const style = getComputedStyle(document.querySelector(selector))
    return [selector, style.backgroundImage, style.borderColor, style.boxShadow, style.color]
  }))
  await page.locator('html').evaluate((html) => html.setAttribute('data-theme', 'light'))
  const lightSurface = await page.evaluate(() => ['.sd-device', '[data-streamdeck-state]', '[data-streamdeck-state] > svg', '.sd-screen', '.sd-well', '.sd-knob'].map((selector) => {
    const style = getComputedStyle(document.querySelector(selector))
    return [selector, style.backgroundImage, style.borderColor, style.boxShadow, style.color]
  }))
  expect(lightSurface).toEqual(darkSurface)
  const chassisTokens = ['--fg', '--muted', '--accent', '--accent-ink', '--attention', '--attention-ink', '--blocking-ink', '--blocking-soft', '--good', '--good-ink', '--super', '--ack']
  const readTokens = () => page.evaluate((tokens) => {
    const style = getComputedStyle(document.querySelector('.sd-device'))
    return tokens.map((token) => style.getPropertyValue(token).trim())
  }, chassisTokens)
  await page.locator('html').evaluate((html) => { html.setAttribute('data-palette', 'gruvbox'); html.setAttribute('data-theme', 'dark') })
  const gruvboxDarkTokens = await readTokens()
  await page.locator('html').evaluate((html) => html.setAttribute('data-theme', 'light'))
  expect(await readTokens()).toEqual(gruvboxDarkTokens)
  await page.locator('html').evaluate((html) => html.removeAttribute('data-palette'))
  const aiurLightInks = await readAiurInks()
  await page.locator('html').evaluate((html) => html.setAttribute('data-theme', 'dark'))
  expect(await readAiurInks()).toEqual(aiurLightInks)
  await page.locator('html').evaluate((html) => html.setAttribute('data-theme', 'light'))
  await device.screenshot({ path: testInfo.outputPath('streamdeck-desktop-light.png') })

  await page.locator('html').evaluate((html) => html.removeAttribute('data-theme'))
  await page.setViewportSize({ width: 540, height: 900 })
  const mobileGeometry = await page.evaluate(() => {
    const device = document.querySelector('.sd-device')
    const keys = document.querySelector('.sd-keys')
    const key = keys.querySelector('.sd-key')
    const style = getComputedStyle(device)
    const keysStyle = getComputedStyle(keys)
    const keyBox = key.getBoundingClientRect()
    const wellStyle = getComputedStyle(document.querySelector('.sd-well'))
    const agentKey = keys.querySelector('.sd-agent-key:not(.is-empty)')
    const svg = agentKey.querySelector('svg')
    const svgBox = svg.getBoundingClientRect()
    const agentBox = agentKey.getBoundingClientRect()
    const agentFaceFits = svgBox.width === agentBox.width && svgBox.height === agentBox.height

    return {
      paddingTop: style.paddingTop,
      borderRadius: style.borderRadius,
      gap: style.gap,
      wellPadding: wellStyle.padding,
      columns: keysStyle.gridTemplateColumns.split(' ').filter(Boolean).length,
      columnGap: keysStyle.columnGap,
      rowGap: keysStyle.rowGap,
      keyRatio: keyBox.width / keyBox.height,
      svgCount: agentKey.querySelectorAll('svg').length,
      svgViewBox: svg.getAttribute('viewBox'),
      accessibleLabel: agentKey.getAttribute('aria-label'),
      agentFaceFits
    }
  })

  expect(mobileGeometry.paddingTop).toBe('17.6px')
  expect(mobileGeometry.borderRadius).toBe('24px')
  expect(mobileGeometry.gap).toBe('16px')
  expect(mobileGeometry.wellPadding).toBe('14.4px 12.8px')
  expect(mobileGeometry.columns).toBe(4)
  expect(mobileGeometry.columnGap).toBe('0px')
  expect(mobileGeometry.rowGap).toBe('16px')
  expect(mobileGeometry.keyRatio).toBeCloseTo(1, 2)
  expect(mobileGeometry.svgCount).toBe(1)
  expect(mobileGeometry.svgViewBox).toBe('0 0 120 120')
  expect(mobileGeometry.accessibleLabel.length).toBeGreaterThan(0)
  expect(mobileGeometry.agentFaceFits).toBe(true)
  await device.screenshot({ path: testInfo.outputPath('streamdeck-mobile.png') })
  await page.locator('html').evaluate((html) => html.setAttribute('data-theme', 'light'))
  await device.screenshot({ path: testInfo.outputPath('streamdeck-mobile-light.png') })
})

test('Stream Deck emulator passes automated accessibility checks', async ({ page }) => {
  await openStreamdeck(page)

  const accessibility = await new AxeBuilder({ page }).analyze()
  expect(accessibility.violations).toEqual([])

  // The install dialog is a whole second surface — its own heading order, list
  // semantics, contrast and control names — and none of it is reachable by the
  // scan above while the modal is closed.
  await page.getByRole('button', { name: 'Download' }).click()
  await expect(page.locator('#streamdeck-install-modal')).toBeVisible()

  const dialogAccessibility = await new AxeBuilder({ page }).analyze()
  expect(dialogAccessibility.violations).toEqual([])
})
