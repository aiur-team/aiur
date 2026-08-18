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

async function providerGeometry(page) {
  return page.locator('.rs-model').evaluateAll((rows) => rows.map((row) => {
    const identity = row.querySelector('.rs-head').getBoundingClientRect()
    const meter = row.querySelector('.rs-limit').getBoundingClientRect()
    const track = row.querySelector('.rs-meter').getBoundingClientRect()
    const meta = Array.from(row.querySelectorAll('.rs-limit-meta')).find((element) => element.getBoundingClientRect().height > 0).getBoundingClientRect()
    const token = row.querySelector('.rs-token-ic, .rs-token-na')?.getBoundingClientRect()

    return {
      name: row.querySelector('.rs-name').textContent.trim(),
      identityLeft: identity.left,
      nameLeft: row.querySelector('.rs-name').getBoundingClientRect().left,
      identityHeight: identity.height,
      meterLeft: meter.left,
      meterHeight: meter.height,
      trackWidth: track.width,
      trackHeight: track.height,
      metaHeight: meta.height,
      tokenHeight: token?.height ?? null
    }
  }))
}

// The strip keeps the GitHub API card in its own pane and combines every model
// provider into a single second pane, so the model count no longer changes the
// pane count or trips a compressed form. The fixture carries four model
// providers (plus the GitHub pane) to exercise that combined pane.
test('Models and APIs use aligned fixed-height rows without narrow overflow', async ({ browser }, testInfo) => {
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
      await expect(elevenlabs.locator('.rs-stat-label')).toHaveText('Next invoice due')
      await expect(elevenlabs.locator('.rs-stat-val')).toHaveText('$5.00')
      await expect(elevenlabs.locator('.rs-meter > i')).toHaveAttribute('style', /width:25\.0%/)
      await expect(elevenlabs.locator('img')).toHaveAttribute('src', '/elevenlabs-symbol.svg')
      await expect.poll(() => elevenlabs.locator('img').evaluate((img) => img.naturalWidth)).toBeGreaterThan(0)

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

      for (const row of geometry) {
        expect(closeEnough(row.identityHeight, row.meterHeight), `${row.name} meter row must equal its logo-height identity at ${width}px`).toBe(true)
        expect(closeEnough(row.trackHeight, row.identityHeight), `${row.name} bar height must equal its logo at ${width}px`).toBe(true)
        expect(closeEnough(row.metaHeight, row.identityHeight), `${row.name} percentage/reset height must equal its logo at ${width}px`).toBe(true)
        if (row.tokenHeight !== null) expect(closeEnough(row.tokenHeight, row.identityHeight), `${row.name} token image height changed at ${width}px`).toBe(true)
      }

      const apiGeometry = await page.locator('.rs-api .rs-limit').evaluateAll((rows) => rows.map((row) => {
        const meta = Array.from(row.querySelectorAll('.rs-limit-meta')).find((element) => element.getBoundingClientRect().height > 0)

        return {
          height: row.getBoundingClientRect().height,
          trackWidth: row.querySelector('.rs-meter').getBoundingClientRect().width,
          trackHeight: row.querySelector('.rs-meter').getBoundingClientRect().height,
          metaHeight: meta.getBoundingClientRect().height,
          labelHeight: row.querySelector('.rs-limit-label').getBoundingClientRect().height
        }
      }))
      expect(apiGeometry.every(({ height }) => closeEnough(height, geometry[0].identityHeight))).toBe(true)
      expect(apiGeometry.every(({ trackWidth }) => trackWidth > 0)).toBe(true)
      expect(apiGeometry.every(({ trackHeight, metaHeight, labelHeight }) => [trackHeight, metaHeight, labelHeight].every((height) => closeEnough(height, geometry[0].identityHeight)))).toBe(true)

      const githubBackoff = page.locator('.github-quota-backoff')
      await expect(githubBackoff.locator('.rs-limit-label')).toHaveText('Core backoff')
      await expect(githubBackoff.locator('.rs-meter > i')).toHaveClass(/is-warning/)
      await expectVisibleMetadata(githubBackoff, 'compact', '45s left')

      const apiIdentityGeometry = await page.locator('.rs-api .rs-head').evaluateAll((identities) => identities.map((identity) => ({
        logoLeft: identity.querySelector('.rs-logo').getBoundingClientRect().left,
        nameLeft: identity.querySelector('.rs-name').getBoundingClientRect().left
      })))
      expect(new Set(apiIdentityGeometry.map(({ logoLeft }) => logoLeft)).size).toBe(1)
      expect(new Set(apiIdentityGeometry.map(({ nameLeft }) => nameLeft)).size).toBe(1)
      await expect(page.locator('.rs-models-rows, .rs-apis-rows').locator('[role="columnheader"], th')).toHaveCount(0)

      // Identity survives the grouping: one logo per row, and it leads the row.
      const codex = page.locator('.rs-model').filter({ hasText: 'Codex' })
      await expect(codex.locator('.rs-logo')).toHaveCount(1)

      for (const name of ['Codex', 'Claude', 'DeepSeek', 'Kimi']) {
        const row = page.locator('.rs-model').filter({ hasText: name })
        await expect(row.locator('.rs-head > :first-child')).toHaveClass(/rs-logo/)
      }

      // Only Claude and Codex carry a second, right-hand token glyph.
      await expect(page.locator('.rs-model').filter({ hasText: 'Codex' }).locator('.rs-token-ic')).toHaveCount(1)
      await expect(page.locator('.rs-model').filter({ hasText: 'Claude' }).locator('.rs-token-ic')).toHaveCount(1)
      await expect(page.locator('.rs-model').filter({ hasText: 'DeepSeek' }).locator('.rs-token-ic, .rs-token-na')).toHaveCount(0)
      await expect(page.locator('.rs-model').filter({ hasText: 'Kimi' }).locator('.rs-token-ic, .rs-token-na')).toHaveCount(0)

      // Every freshness state stays distinguishable on the meter's own meta
      // line, now that the head-row chip is gone.
      await expect(page.locator('.rs-state')).toHaveCount(0)
      const modelMetaVariant = width <= 720 ? 'compact' : 'wide'
      await expectVisibleMetadata(page.locator('.rs-model').filter({ hasText: 'Claude' }), modelMetaVariant, 'stale')
      await expectVisibleMetadata(page.locator('.rs-model').filter({ hasText: 'DeepSeek' }), modelMetaVariant, '0%')
      await expectVisibleMetadata(elevenlabs, 'compact', '75.0K')
      await expect(page.locator('.rs-model').filter({ hasText: 'Kimi' }).locator('.rs-limit-meta')).toHaveText('Unavailable')
      await expect(page.locator('.rs-models')).not.toContainText(/Limits|Primary/i)

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
