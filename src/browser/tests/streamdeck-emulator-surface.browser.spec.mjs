import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'
import { anchor, dragDialThroughAngles, openStreamdeck } from './support/streamdeck-emulator.mjs'

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

test('clicking a logs event key positions the flattened transcript at that event', async ({ page }) => {
  await openStreamdeck(page)

  await page.locator('.sd-key:not(.is-empty)').first().click()
  const dialD = page.locator('.sd-knob').nth(3)
  await anchor(dialD)
  const box = await dialD.boundingBox()
  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2)
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'logs')

  const logKeys = page.locator('#sd-log-keys')
  await expect(logKeys.locator('.sd-key')).toHaveCount(8)

  // The surface reads oldest-left to newest-right, so the window opens at the
  // right-hand end: LIVE is the last key, and the origin anchor at index 0 is
  // off-screen behind it.
  const liveIndex = await logKeys.locator('.sd-live-key').getAttribute('data-log-event-index')
  await expect(logKeys.locator('.sd-live-key')).toContainText('LIVE')
  await expect(logKeys.locator('.sd-live-key svg rect').first()).toHaveAttribute('fill', '#14291f')
  await expect(logKeys.locator('.sd-live-key [data-dir]')).toHaveAttribute('data-dir', '')
  await expect(logKeys.locator('.sd-live-key')).toHaveAttribute('aria-current', 'true')

  // The fixture's bus kinds cover four of the five directions on the four
  // newest events — the ones inside the window as it opens — and the origin
  // anchor carries the fifth. Direction comes from the marker kind, not the
  // topic, so this is asserting the kind -> badge mapping end to end.
  const directions = { 7: 'AGENT', 8: 'CONSUME', 9: 'SYSTEM', 10: 'EMIT' }
  const inks = new Set()
  for (const [index, direction] of Object.entries(directions)) {
    const badge = logKeys.locator(`[data-log-event-index="${index}"] [data-dir]`)
    await expect(badge).toContainText(direction)
    await expect(badge).toHaveAttribute('data-dir', direction)
    inks.add(await badge.evaluate((el) => getComputedStyle(el).fill))
  }
  // EMIT and AGENT share one blue by design; the other two are distinct.
  expect(inks.size).toBe(3)

  // The origin anchor is the far-left key and always exists. Page the window
  // fully left to reach it — that is also the only way an operator sees the
  // beginning of a long ticket.
  const dialDKnob = page.locator('.sd-knob').nth(3)
  for (let i = 0; i < 6; i += 1) await dragDialThroughAngles(page, dialDKnob, [90, 0, -90])
  await expect(logKeys).toHaveAttribute('data-offset', '0')
  const origin = logKeys.locator('[data-log-event-index="0"] [data-dir]')
  await expect(origin).toContainText('INFO')
  await expect(logKeys.locator('[data-log-event-index="0"]')).toHaveAttribute('aria-label', /Ticket opened/)
  inks.add(await origin.evaluate((el) => getComputedStyle(el).fill))
  expect(inks.size).toBe(4)
  // LIVE is pinned: even scrolled fully left to the origin, it still occupies
  // the last (bottom-right) key rather than scrolling away.
  await expect(logKeys.locator('.sd-live-key')).toHaveCount(1)
  await expect(logKeys.locator('.sd-key').last()).toHaveClass(/sd-live-key/)

  // Back to where it opened, so the assertions below read the live end.
  for (let i = 0; i < 6; i += 1) await dragDialThroughAngles(page, dialDKnob, [-90, 0, 90])
  await expect(logKeys).toHaveAttribute('data-offset', String(Number(await logKeys.getAttribute('data-max-offset'))))

  const strip = page.locator('#sd-screen')
  const transcript = page.locator('#sd-log-transcript')
  const maxOffset = await transcript.getAttribute('data-max-offset')
  // Requirement: logs opens where the agent is working, not at the ticket's
  // first line.
  await expect(strip).toHaveAttribute('data-transcript-offset', maxOffset)

  // Three entry shapes, not a single flattened line per row.
  await expect(page.locator('[data-log-kind="message"]').first()).toBeVisible()

  // Dial A's hint arrows are state: pinned at the newest end there is nothing
  // newer, so the down arrow is hidden and the up one is not.
  await expect(page.locator('#sd-transcript-hint-down')).toHaveAttribute('aria-hidden', 'true')
  await expect(page.locator('#sd-transcript-hint-up')).toHaveAttribute('aria-hidden', 'false')

  // Pressing an event key makes it the active one and LIVE inactive, and moves
  // the strip to that event's own header. Keys 7 and 8 are inside the window
  // as it opens; the far-left ones were reached by paging, above.
  await logKeys.locator('[data-log-event-index="8"]').click()
  await expect(logKeys.locator('[data-log-event-index="8"]')).toHaveAttribute('aria-current', 'true')
  await expect(logKeys.locator('.sd-live-key')).toHaveAttribute('aria-current', 'false')
  await expect(strip).not.toHaveAttribute('data-transcript-offset', maxOffset)
  await expect(page.locator('[data-log-kind="evhdr"]').first()).toBeVisible()
  const atEventEight = await transcript.getAttribute('data-offset')

  // A different event key moves it somewhere else again.
  await logKeys.locator('[data-log-event-index="7"]').press('Enter')
  await expect(logKeys.locator('[data-log-event-index="7"]')).toHaveAttribute('aria-current', 'true')
  await expect(transcript).not.toHaveAttribute('data-offset', atEventEight)

  // Returning to LIVE reverses it: back to the newest end, LIVE active again.
  await logKeys.locator('.sd-live-key').click()
  await expect(strip).toHaveAttribute('data-transcript-offset', maxOffset)
  await expect(logKeys.locator('.sd-live-key')).toHaveAttribute('aria-current', 'true')
  await expect(logKeys.locator(`[data-log-event-index="${liveIndex}"]`)).toHaveAttribute('aria-current', 'true')
})

test('dial A pointer direction controls transcript scroll direction in logs mode', async ({ page }) => {
  await openStreamdeck(page)

  await page.locator('.sd-key:not(.is-empty)').first().click()
  const dialD = page.locator('.sd-knob').nth(3)
  await dialD.click()
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'logs')

  // The surface opens pinned at the newest end, so the only way to move is
  // back into history first; dragging the other way returns to the end.
  const strip = page.locator('#sd-screen')
  const maxOffset = await page.locator('#sd-log-transcript').getAttribute('data-max-offset')
  await expect(strip).toHaveAttribute('data-transcript-offset', maxOffset)

  const dialA = page.locator('.sd-knob').first()
  await dragDialThroughAngles(page, dialA, [90, 0, -90])
  await expect(strip).toHaveAttribute('data-transcript-offset', String(Number(maxOffset) - 1))

  await dragDialThroughAngles(page, dialA, [-90, 0, 90])
  await expect(strip).toHaveAttribute('data-transcript-offset', maxOffset)
})

test('dial D pointer direction controls event scroll direction in logs mode', async ({ page }) => {
  await openStreamdeck(page)

  await page.locator('.sd-key:not(.is-empty)').first().click()
  const dialD = page.locator('.sd-knob').nth(3)
  await dialD.click()
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'logs')

  // Same direction contract on the key window, which also opens at its end.
  const logKeys = page.locator('#sd-log-keys')
  const maxOffset = await logKeys.getAttribute('data-max-offset')
  await expect(logKeys).toHaveAttribute('data-offset', maxOffset)

  await dragDialThroughAngles(page, dialD, [90, 0, -90])
  await expect(logKeys).toHaveAttribute('data-offset', String(Number(maxOffset) - 1))

  await dragDialThroughAngles(page, dialD, [-90, 0, 90])
  await expect(logKeys).toHaveAttribute('data-offset', maxOffset)
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
