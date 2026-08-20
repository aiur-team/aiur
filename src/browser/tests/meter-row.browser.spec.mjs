import { expect, test } from '@playwright/test'
import { assertNoDocumentOverflow } from './support/browser-helpers.mjs'

async function openMeterRow(page, query = '') {
  await page.goto('/auth/read_only')
  await page.goto(`/meter-row${query}`)
  await expect(page.locator('[data-meter-row-fixture="true"]')).toBeVisible()
}

const closeEnough = (left, right) => Math.abs(left - right) <= 0.25

async function expectVisibleMetadata(row, variant, expected) {
  const visible = row.locator(`.rs-limit-meta-${variant}`)
  const hidden = row.locator(`.rs-limit-meta-${variant === 'wide' ? 'compact' : 'wide'}`)

  await expect(visible).toBeVisible()
  await expect(visible).toContainText(expected)
  await expect(hidden).toBeHidden()
}

// A provider limit is one fixed logo-height line: the label and its meta sit on
// the line directly above the standard thin bar, close enough that adding them
// does not grow the row. Every limit — model or API — shares this geometry.
// The extraction lives inline in each evaluateAll below because Playwright runs
// it in the browser, outside this module's scope.
function expectStandardLimit(row, identityHeight, width) {
  // The row keeps the fixed logo-height line the aligned design established.
  expect(closeEnough(row.rowHeight, identityHeight), `limit row must keep its logo-height identity at ${width}px`).toBe(true)
  // The bar is the standard thin progress bar, not the tall fill that replaced it.
  expect(row.barHeight, `bar must render at ${width}px`).toBeGreaterThan(0)
  expect(row.barHeight, `bar must be the standard thin bar at ${width}px`).toBeLessThan(identityHeight / 2)
  // The label sits above the bar…
  expect(row.labelHeight, `label must render above the bar at ${width}px`).toBeGreaterThan(0)
  expect(row.labelTop, `label must sit above its bar at ${width}px`).toBeLessThan(row.barTop)
  // …close enough that the row height does not expand.
  const gap = row.barTop - row.labelBottom
  expect(gap, `label must not overlap its bar at ${width}px`).toBeGreaterThanOrEqual(-1)
  expect(gap, `label must sit close above its bar at ${width}px`).toBeLessThanOrEqual(8)
  // The bar stays inside the fixed row.
  expect(row.barBottom, `bar must stay inside its fixed row at ${width}px`).toBeLessThanOrEqual(row.rowBottom + 0.5)
}

async function providerGeometry(page) {
  return page.locator('.rs-model').evaluateAll((rows) => rows.map((row) => {
    const identity = row.querySelector('.rs-head').getBoundingClientRect()
    const meter = row.querySelector('.rs-limit').getBoundingClientRect()
    const track = row.querySelector('.rs-meter').getBoundingClientRect()
    const body = row.querySelector('.rs-provider-body').getBoundingClientRect()
    const meta = Array.from(row.querySelectorAll('.rs-limit-meta')).find((element) => element.getBoundingClientRect().height > 0)

    return {
      name: row.querySelector('.rs-name').textContent.trim(),
      identityLeft: identity.left,
      nameLeft: row.querySelector('.rs-name').getBoundingClientRect().left,
      identityHeight: identity.height,
      meterLeft: meter.left,
      meterHeight: meter.height,
      trackWidth: track.width,
      trackRight: track.right,
      bodyRight: body.right,
      metaHeight: meta?.getBoundingClientRect().height ?? null
    }
  }))
}

// The strip keeps the GitHub API card in its own pane and combines every model
// provider into a single second pane, so the model count no longer changes the
// pane count or trips a compressed form. The fixture carries four model
// providers (plus the GitHub pane) to exercise that combined pane.
test('Models and APIs use standard bars with labels above, without narrow overflow', async ({ browser }, testInfo) => {
  test.setTimeout(60_000)

  for (const width of [1440, 1280, 960, 768, 640, 481, 390]) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, reducedMotion: 'reduce' })
    const page = await context.newPage()

    try {
      await openMeterRow(page)

      // Two panes regardless of model count: the GitHub card, then one models pane.
      await expect(page.locator('.run-summary')).toHaveCount(1)
      await expect(page.locator('.rs-block')).toHaveCount(2)
      await expect(page.locator('.rs-block.rs-models')).toHaveCount(1)

      const elevenlabs = page.locator('.rs-elevenlabs')
      await expect(elevenlabs).toContainText('75.0K left · 25% used · resets 3d')
      await expect(elevenlabs.locator('.rs-meter > i')).toHaveAttribute('style', /width:25\.0%/)
      await expect(elevenlabs.locator('img')).toHaveAttribute('src', '/elevenlabs-symbol.svg')
      await expect(elevenlabs.locator('img')).toHaveAttribute('alt', 'ElevenLabs')
      await expect.poll(() => elevenlabs.locator('img').evaluate((img) => img.naturalWidth)).toBeGreaterThan(0)
      await expect(elevenlabs.locator('.rs-head-stats, .rs-stat')).toHaveCount(0)

      const elevenlabsLine = await elevenlabs.locator('.rs-limit').evaluate((line) => ({
        height: line.getBoundingClientRect().height,
        overflow: line.scrollWidth - line.clientWidth
      }))
      const elevenlabsIdentityHeight = await elevenlabs.locator('.rs-head').evaluate((identity) => identity.getBoundingClientRect().height)
      expect(closeEnough(elevenlabsLine.height, elevenlabsIdentityHeight), `ElevenLabs row height changed at ${width}px`).toBe(true)
      expect(elevenlabsLine.overflow, `ElevenLabs metadata overflowed at ${width}px`).toBeLessThanOrEqual(0)

      // All four model providers render inside the one combined pane.
      const models = page.locator('.rs-models .rs-model')
      await expect(models).toHaveCount(4)

      const geometry = await providerGeometry(page)
      expect(new Set(geometry.map(({ identityLeft }) => identityLeft)).size).toBe(1)
      expect(new Set(geometry.map(({ nameLeft }) => nameLeft)).size).toBe(1)
      expect(new Set(geometry.map(({ meterLeft }) => meterLeft)).size).toBe(1)
      expect(new Set(geometry.map(({ trackWidth }) => trackWidth)).size).toBe(1)

      // Every model limit keeps the fixed row height and restores the standard
      // bar with its label directly above it.
      const modelLimits = await page.locator('.rs-model .rs-limit').evaluateAll((limits) => limits.map((limit) => {
        const box = limit.getBoundingClientRect()
        const track = limit.querySelector('.rs-meter').getBoundingClientRect()
        const label = limit.querySelector('.rs-limit-label').getBoundingClientRect()
        const meta = Array.from(limit.querySelectorAll('.rs-limit-meta')).find((element) => element.getBoundingClientRect().height > 0)

        return {
          rowTop: box.top,
          rowBottom: box.bottom,
          rowHeight: box.height,
          barTop: track.top,
          barBottom: track.bottom,
          barHeight: track.height,
          labelTop: label.top,
          labelBottom: label.bottom,
          labelHeight: label.height,
          metaHeight: meta?.getBoundingClientRect().height ?? 0
        }
      }))
      const identityHeight = geometry[0].identityHeight
      for (const limit of modelLimits) {
        expectStandardLimit(limit, identityHeight, width)
      }

      for (const row of geometry) {
        expect(closeEnough(row.identityHeight, row.meterHeight), `${row.name} meter row must equal its logo-height identity at ${width}px`).toBe(true)
        if (row.metaHeight !== null) expect(row.metaHeight, `${row.name} percentage/reset meta must render at ${width}px`).toBeGreaterThan(0)
        // Bars run edge to edge: no right-hand stat/token column remains, so the
        // track must reach the same right edge as the provider body.
        expect(closeEnough(row.trackRight, row.bodyRight), `${row.name} bar must reach the right edge at ${width}px`).toBe(true)
      }

      // API limits use the same standard bar + label-above geometry and keep
      // the same row height; the bars are present again in the API pane.
      const apiGeometry = await page.locator('.rs-api .rs-limit').evaluateAll((limits) => limits.map((limit) => {
        const box = limit.getBoundingClientRect()
        const track = limit.querySelector('.rs-meter').getBoundingClientRect()
        const label = limit.querySelector('.rs-limit-label').getBoundingClientRect()
        const meta = Array.from(limit.querySelectorAll('.rs-limit-meta')).find((element) => element.getBoundingClientRect().height > 0)

        return {
          rowTop: box.top,
          rowBottom: box.bottom,
          rowHeight: box.height,
          barTop: track.top,
          barBottom: track.bottom,
          barHeight: track.height,
          labelTop: label.top,
          labelBottom: label.bottom,
          labelHeight: label.height,
          metaHeight: meta?.getBoundingClientRect().height ?? 0
        }
      }))
      expect(apiGeometry.every(({ rowHeight }) => closeEnough(rowHeight, identityHeight)), `API row height changed at ${width}px`).toBe(true)
      expect(apiGeometry.every(({ barHeight }) => barHeight > 0)).toBe(true)
      for (const limit of apiGeometry) {
        expectStandardLimit(limit, identityHeight, width)
      }

      const githubBackoff = page.locator('.github-quota-backoff')
      await expect(githubBackoff.locator('.rs-limit-label')).toHaveText('Core backoff')
      await expect(githubBackoff.locator('.rs-meter > i')).toHaveClass(/is-warning/)
      await expectVisibleMetadata(githubBackoff, 'compact', '45s left')

      // API identities are a bare logo: the label text was removed and the
      // name now lives in the image alt/title, so no name column breaks the
      // row out of the aligned grid.
      const apiIdentityGeometry = await page.locator('.rs-api .rs-head').evaluateAll((identities) => identities.map((identity) => ({
        logoLeft: identity.querySelector('.rs-logo').getBoundingClientRect().left,
        nameCount: identity.querySelectorAll('.rs-name').length
      })))
      expect(new Set(apiIdentityGeometry.map(({ logoLeft }) => logoLeft)).size).toBe(1)
      expect(apiIdentityGeometry.every(({ nameCount }) => nameCount === 0)).toBe(true)
      await expect(page.locator('.rs-models-rows, .rs-apis-rows').locator('[role="columnheader"], th')).toHaveCount(0)

      // Identity survives the grouping: one logo per row, and it leads the row.
      const codex = page.locator('.rs-model').filter({ hasText: 'Codex' })
      await expect(codex.locator('.rs-logo')).toHaveCount(1)

      for (const name of ['Codex', 'Claude', 'DeepSeek', 'Kimi']) {
        const row = page.locator('.rs-model').filter({ hasText: name })
        await expect(row.locator('.rs-head > :first-child')).toHaveClass(/rs-logo/)
      }

      // The right-hand token glyphs are gone: no second mark sits beside any
      // model's name, so every row is just the logo + bars.
      await expect(page.locator('.rs-token-ic, .rs-token-na')).toHaveCount(0)

      // Every freshness state stays distinguishable on the meter's own meta
      // line, now that the head-row chip is gone.
      await expect(page.locator('.rs-state')).toHaveCount(0)
      const modelMetaVariant = width <= 720 ? 'compact' : 'wide'
      await expectVisibleMetadata(page.locator('.rs-model').filter({ hasText: 'Claude' }), modelMetaVariant, '62%')
      await expectVisibleMetadata(page.locator('.rs-model').filter({ hasText: 'DeepSeek' }), modelMetaVariant, '0%')
      await expectVisibleMetadata(elevenlabs, 'compact', '75.0K')
      // Kimi reported nothing, so its row is just the "Limits" label over an
      // empty bar — the status meta was deleted (operator directive).
      await expect(page.locator('.rs-model').filter({ hasText: 'Kimi' }).locator('.rs-limit-meta')).toHaveCount(0)
      // No staleness wording remains on the strip.
      await expect(page.locator('.run-summary')).not.toContainText(/stale/i)

      // The #2085 label removal is reverted: a label now sits above every model
      // bar, and the SPEND label is deleted from the model rows.
      await expect(page.locator('.rs-model').filter({ hasText: 'DeepSeek' }).locator('.rs-limit-label')).toHaveText('Session')
      await expect(page.locator('.rs-model').filter({ hasText: 'Kimi' }).locator('.rs-limit-label')).toHaveText('Limits')
      await expect(page.locator('.rs-models')).not.toContainText(/Spend/i)

      // Neither the row nor the page body scrolls horizontally.
      await assertNoDocumentOverflow(page)

      const rowOverflow = await page.locator('.run-summary').evaluate((row) => row.scrollWidth - row.clientWidth)
      expect(rowOverflow).toBeLessThanOrEqual(0)

      if (process.env.AIUR_BROWSER_SCREENSHOTS === '1' && [1440, 390].includes(width)) {
        const destination = testInfo.outputPath(`meter-row-${width}.png`)
        await page.screenshot({ path: destination, fullPage: true })
        await testInfo.attach(`meter row at ${width}px`, { path: destination, contentType: 'image/png' })
      }
    } finally {
      await context.close()
    }
  }
})

test('a hypothetical fifth provider adds one row without moving the existing grid', async ({ page }) => {
  await openMeterRow(page)

  const before = await providerGeometry(page)
  const beforePanel = await page.locator('.rs-models').evaluate((panel) => panel.getBoundingClientRect().height)

  await openMeterRow(page, '?extra=true')

  const after = await providerGeometry(page)
  const afterPanel = await page.locator('.rs-models').evaluate((panel) => panel.getBoundingClientRect().height)

  expect(after.map(({ name }) => name)).toEqual([...before.map(({ name }) => name), 'Nova'])

  for (const original of before) {
    const added = after.find(({ name }) => name === original.name)
    expect(added).toMatchObject(original)
  }

  const added = after.at(-1)
  const rowGap = await page.locator('.rs-models-rows').evaluate((rows) => Number.parseFloat(getComputedStyle(rows).rowGap))
  expect(closeEnough(afterPanel - beforePanel, added.meterHeight + rowGap)).toBe(true)
  await assertNoDocumentOverflow(page)
})
