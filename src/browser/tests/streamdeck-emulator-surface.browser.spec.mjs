import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'
import { anchor, dragDialThroughAngles, openStreamdeck } from './support/streamdeck-emulator.mjs'

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
  await expect(logKeys.locator('.sd-live-key .sd-live-dot')).toHaveCount(1)
  await expect(logKeys.locator('.sd-live-key .sd-log-dir')).toHaveCount(0)
  await expect(logKeys.locator('.sd-live-key')).toHaveAttribute('aria-current', 'true')

  // The fixture's bus kinds cover four of the five directions on the four
  // newest events — the ones inside the window as it opens — and the origin
  // anchor carries the fifth. Direction comes from the marker kind, not the
  // topic, so this is asserting the kind -> badge mapping end to end.
  const directions = { 7: 'AGENT', 8: 'CONSUME', 9: 'SYSTEM', 10: 'EMIT' }
  const inks = new Set()
  for (const [index, direction] of Object.entries(directions)) {
    const badge = logKeys.locator(`[data-log-event-index="${index}"] .sd-log-dir`)
    await expect(badge).toContainText(direction)
    await expect(badge).toHaveAttribute('data-dir', direction)
    inks.add(await badge.evaluate((el) => getComputedStyle(el).color))
  }
  // EMIT and AGENT share one blue by design; the other two are distinct.
  expect(inks.size).toBe(3)

  // The origin anchor is the far-left key and always exists. Page the window
  // fully left to reach it — that is also the only way an operator sees the
  // beginning of a long ticket.
  const dialDKnob = page.locator('.sd-knob').nth(3)
  for (let i = 0; i < 6; i += 1) await dragDialThroughAngles(page, dialDKnob, [90, 0, -90])
  await expect(logKeys).toHaveAttribute('data-offset', '0')
  const origin = logKeys.locator('[data-log-event-index="0"] .sd-log-dir')
  await expect(origin).toContainText('INFO')
  await expect(logKeys.locator('[data-log-event-index="0"]')).toContainText('Ticket opened')
  inks.add(await origin.evaluate((el) => getComputedStyle(el).color))
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
  await expect(page.locator('.sd-log-entry-message').first()).toBeVisible()

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
  await expect(page.locator('.sd-log-entry-evhdr').first()).toBeVisible()
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

test('touch strip renders two provider meters and design segment geometry', async ({ page }) => {
  await openStreamdeck(page)

  const providers = page.locator('[data-segment="provider"]')
  const providerCount = await providers.count()
  expect(providerCount).toBeGreaterThan(0)

  for (let index = 0; index < providerCount; index += 1) {
    const provider = providers.nth(index)
    await expect(provider.locator('[data-meter="session"]')).toHaveCount(1)
    await expect(provider.locator('[data-meter="weekly"]')).toHaveCount(1)
    await expect(provider.locator('.sd-mini')).toHaveCount(2)
  }

  await expect(providers.filter({ hasText: 'Claude' }).locator('[data-meter="session"]')).toContainText('30% · 22m')
  await expect(providers.filter({ hasText: 'Claude' }).locator('[data-meter="weekly"]')).toContainText('47% · Thu 6PM')
  await expect(providers.filter({ hasText: 'Codex' }).locator('[data-meter="session"]')).toContainText('50% · 1h')
  await expect(providers.filter({ hasText: 'Codex' }).locator('[data-meter="weekly"]')).toContainText('75% · Fri 8PM')

  const pagerDots = page.locator('[data-segment="pager"] .sd-pager-dot')
  const pageCount = parseInt(await page.locator('#sd-keys').getAttribute('data-grid-page-count'), 10)
  await expect(pagerDots).toHaveCount(pageCount)

  const segmentRows = await page.locator('#sd-screen > [data-segment]').evaluateAll((segments) => segments.map((segment) => Math.round(segment.getBoundingClientRect().top)))
  expect(new Set(segmentRows)).toEqual(new Set([segmentRows[0]]))

  const geometry = await providers.first().evaluate((segment) => {
    const heading = segment.querySelector('.sd-info-hd')
    const mini = segment.querySelector('.sd-mini')

    return {
      direction: getComputedStyle(segment).flexDirection,
      padding: getComputedStyle(segment).padding,
      headingFont: getComputedStyle(heading).fontFamily,
      barHeight: getComputedStyle(mini.querySelector('.sd-mini-bar')).height
    }
  })

  expect(geometry.direction).toBe('column')
  expect(geometry.padding).toBe('5.12px 8px')
  expect(geometry.headingFont).toContain('JetBrains Mono')
  expect(geometry.barHeight).toBe('8px')

  // Both segment headings hold one ink. The design specifies 0.42, which
  // measures under 4.5:1 here and fails the axe check below, so they sit at
  // 0.55 together rather than one heading drifting from the other.
  expect(await providers.first().locator('.sd-info-hd').evaluate((heading) => getComputedStyle(heading).color)).toBe('rgba(255, 255, 255, 0.55)')

  // The pager is the design's dial segment (.sd-seg-d, streamdeck.design.css:153-154):
  // a centred column on the brighter 0.04 ground, labelled by its own text and
  // carrying no logo header.
  const pagerShape = await page.locator('[data-segment="pager"]').evaluate((segment) => {
    const label = segment.querySelector('.sd-seg-dlabel')

    return {
      align: getComputedStyle(segment).alignItems,
      gap: getComputedStyle(segment).gap,
      background: getComputedStyle(segment).backgroundColor,
      labelSize: getComputedStyle(label).fontSize,
      labelWeight: getComputedStyle(label).fontWeight,
      labelColor: getComputedStyle(label).color,
      headings: segment.querySelectorAll('.sd-info-hd').length,
      logos: segment.querySelectorAll('.sd-hd-logo').length
    }
  })

  expect(pagerShape.align).toBe('center')
  expect(pagerShape.gap).toBe('5.12px')
  expect(pagerShape.background).toBe('rgba(255, 255, 255, 0.04)')
  expect(pagerShape.labelSize).toBe('8.64px')
  expect(pagerShape.labelWeight).toBe('700')
  expect(pagerShape.labelColor).toBe('rgba(255, 255, 255, 0.55)')
  expect(pagerShape.headings).toBe(0)
  expect(pagerShape.logos).toBe(0)
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
      states: Object.fromEntries(['running', 'paused', 'stuck', 'alert', 'queued'].map((state) => {
        const key = document.createElement('div')
        const face = document.createElement('div')
        key.className = `sd-key st-${state}`
        face.className = 'sd-key-face'
        key.appendChild(face)
        document.body.appendChild(key)
        const styles = [getComputedStyle(key).backgroundImage, getComputedStyle(face).backgroundImage]
        key.remove()
        return [state, styles]
      })),
      pressShadow: (() => {
        const knob = document.querySelector('.sd-knob')
        knob.classList.add('press')
        const boxShadow = getComputedStyle(knob).boxShadow
        knob.classList.remove('press')
        return boxShadow
      })()
    }
  })

  expect(desktopGeometry.device.width).toBeCloseTo(620, 0)
  expect(desktopGeometry.device.maxWidth).toBe('620px')
  expect(desktopGeometry.device.borderRadius).toBe('34px')
  expect(desktopGeometry.device.borderColor).toBe('rgba(255, 255, 255, 0.06)')
  expect(desktopGeometry.device.backgroundImage).toContain('rgb(42, 43, 46)')
  expect(desktopGeometry.device.backgroundImage).toContain('0%')
  expect(desktopGeometry.device.backgroundImage).toContain('rgb(32, 31, 34) 55%')
  expect(desktopGeometry.device.backgroundImage).toContain('rgb(22, 21, 23)')
  expect(desktopGeometry.device.boxShadow).toContain('rgba(0, 0, 0, 0.5) 0px 30px 70px 0px')
  expect(desktopGeometry.device.boxShadow).toContain('rgba(255, 255, 255, 0.06) 0px 1px 0px 0px inset')
  expect(desktopGeometry.columns).toBe(4)
  expect(desktopGeometry.columnGap).toBe('30.4px')
  expect(desktopGeometry.rowGap).toBe('16px')
  expect(desktopGeometry.keyRatio).toBeCloseTo(1, 2)
  expect(desktopGeometry.states.running[0]).toContain('rgb(63, 139, 255)')
  expect(desktopGeometry.states.running[1]).toContain('rgb(24, 33, 45)')
  expect(desktopGeometry.states.paused[0]).toContain('rgb(74, 77, 85)')
  expect(desktopGeometry.states.paused[1]).toContain('rgb(30, 32, 37)')
  expect(desktopGeometry.states.stuck[0]).toContain('rgb(255, 106, 94)')
  expect(desktopGeometry.states.stuck[1]).toContain('rgb(39, 19, 23)')
  expect(desktopGeometry.states.alert[0]).toContain('rgb(255, 192, 97)')
  expect(desktopGeometry.states.alert[1]).toContain('rgb(36, 29, 14)')
  expect(desktopGeometry.states.queued[0]).toContain('rgb(58, 63, 71)')
  expect(desktopGeometry.states.queued[1]).toContain('rgb(25, 27, 33)')
  expect(desktopGeometry.pressShadow).toContain('rgba(0, 0, 0, 0.6) 0px 3px 7px 0px')
  expect(desktopGeometry.pressShadow).toContain('rgba(255, 255, 255, 0.5) 0px 0px 0px 2px inset')
  await device.screenshot({ path: testInfo.outputPath('streamdeck-desktop.png') })

  const darkSurface = await page.evaluate(() => ['.sd-device', '.sd-key.st-running', '.sd-key.st-running .sd-key-face', '.sd-screen', '.sd-well', '.sd-knob'].map((selector) => {
    const style = getComputedStyle(document.querySelector(selector))
    return [selector, style.backgroundImage, style.borderColor, style.boxShadow]
  }))
  await page.locator('html').evaluate((html) => html.setAttribute('data-theme', 'light'))
  const lightSurface = await page.evaluate(() => ['.sd-device', '.sd-key.st-running', '.sd-key.st-running .sd-key-face', '.sd-screen', '.sd-well', '.sd-knob'].map((selector) => {
    const style = getComputedStyle(document.querySelector(selector))
    return [selector, style.backgroundImage, style.borderColor, style.boxShadow]
  }))
  expect(lightSurface).toEqual(darkSurface)
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
    const agentFace = agentKey.querySelector('.sd-key-face')
    const agentFaceStyle = getComputedStyle(agentFace)
    const faceBox = agentFace.getBoundingClientRect()
    const agentIcon = agentKey.querySelector('.sd-ag-ic')
    const agentIconSvg = agentIcon.querySelector('svg')
    const agentTicket = agentKey.querySelector('.sd-ag-id')
    const agentElements = Array.from(agentKey.querySelectorAll('.sd-agent-top > *, .sd-ag-title, .sd-ag-foot'))
    const agentFaceFits = agentElements.every((element) => {
      const box = element.getBoundingClientRect()
      return box.left >= faceBox.left && box.right <= faceBox.right && box.top >= faceBox.top && box.bottom <= faceBox.bottom
    })

    return {
      paddingTop: style.paddingTop,
      borderRadius: style.borderRadius,
      gap: style.gap,
      wellPadding: wellStyle.padding,
      columns: keysStyle.gridTemplateColumns.split(' ').filter(Boolean).length,
      columnGap: keysStyle.columnGap,
      rowGap: keysStyle.rowGap,
      keyRatio: keyBox.width / keyBox.height,
      agentIcon: { width: getComputedStyle(agentIcon).width, height: getComputedStyle(agentIcon).height },
      agentIconSvg: { width: getComputedStyle(agentIconSvg).width, height: getComputedStyle(agentIconSvg).height },
      agentTicketSize: getComputedStyle(agentTicket).fontSize,
      agentPadding: {
        top: agentFaceStyle.paddingTop,
        right: agentFaceStyle.paddingRight,
        bottom: agentFaceStyle.paddingBottom
      },
      agentFaceFits
    }
  })

  expect(mobileGeometry.paddingTop).toBe('17.6px')
  expect(mobileGeometry.borderRadius).toBe('24px')
  expect(mobileGeometry.gap).toBe('16px')
  expect(mobileGeometry.wellPadding).toBe('14.4px 12.8px')
  expect(mobileGeometry.columns).toBe(4)
  expect(mobileGeometry.columnGap).toBe('8.8px')
  expect(mobileGeometry.rowGap).toBe('8.8px')
  expect(mobileGeometry.keyRatio).toBeCloseTo(1, 2)
  expect(mobileGeometry.agentIcon).toEqual({ width: '26px', height: '26px' })
  expect(mobileGeometry.agentIconSvg).toEqual({ width: '17px', height: '17px' })
  expect(mobileGeometry.agentTicketSize).toBe('16px')
  // The design's mobile block (streamdeck.design.css:198-208) scales the icon and
  // ticket number only; .sd-agent keeps its desktop padding at both breakpoints.
  expect(mobileGeometry.agentPadding).toEqual({ top: '8px', right: '8.8px', bottom: '8.8px' })
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
