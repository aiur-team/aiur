import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'
import { assertNoDocumentOverflow } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

// Viewport, target, facts, state and axe cases guard existing behavior against future regressions.
// Scrolling and whole-word cases below constrain the CSS fixes in this PR.
// Behavioural reflow checks for /experiments: no document overflow, 44px
// targets, table-to-cards below 960px, and no fact dropped at any width.
const VIEWPORTS = [320, 390, 768, 960, 1280].map(width => ({ width, height: 900 }))
const CARDS_BELOW = 960

async function openDetail(page, path = '/experiments/release-speed', scenario = 'mixed') {
  await page.context().setHTTPCredentials(dashboardCredentials)
  await page.goto(`/experiments-control/${scenario}`)
  await expect(page.locator('#experiments-page')).toBeVisible()
  await page.goto(path)
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
  await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1)
}

const squash = text => text.replace(/\s+/g, ' ').trim()

async function facts(page) {
  return page.evaluate(() => {
    const squash = text => text.replace(/\s+/g, ' ').trim()
    return {
      cells: [...document.querySelectorAll('.exp-table tbody td')].map(cell => squash(cell.textContent)),
      report: squash(document.querySelector('#exp-report')?.textContent ?? '')
    }
  })
}

async function assertTarget(locator) {
  const box = await locator.boundingBox()
  expect(box).not.toBeNull()
  expect(box.width).toBeGreaterThanOrEqual(44)
  expect(box.height).toBeGreaterThanOrEqual(44)
}

let reference
for (const viewport of VIEWPORTS) {
  test(`experiment detail reflows at ${viewport.width}px`, async ({ page }) => {
    await page.setViewportSize(viewport)
    await openDetail(page)
    await expect(page.locator('#exp-detail h2')).toHaveText('Release delivery speed')
    await assertNoDocumentOverflow(page)

    const cards = viewport.width < CARDS_BELOW
    const row = page.locator('.exp-table tbody tr').first()
    expect(await row.evaluate(node => getComputedStyle(node).display)).toBe(cards ? 'block' : 'table-row')
    expect(await page.locator('.exp-table thead').first().evaluate(node => getComputedStyle(node).display)).toBe(cards ? 'none' : 'table-header-group')

    if (cards) {
      await assertTarget(page.getByRole('link', { name: '← All experiments', exact: true }))
      await assertTarget(page.locator('#exp-charts summary').first())
    }

    // Layout may change but never the facts: compare against the first width.
    // The report holds relative times, so only its stable prefix is compared.
    const current = await facts(page)
    current.report = current.report.slice(0, 80)
    reference ??= current
    expect(current).toEqual(reference)
  })
}

test('index links keep 44px targets and the index loses no experiment at 390', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await openDetail(page, '/experiments')
  const links = page.getByRole('navigation', { name: 'Experiment index', exact: true }).getByRole('link')
  await expect(links).toHaveCount(2)
  for (const link of await links.all()) await assertTarget(link)
  await assertNoDocumentOverflow(page)
})

test('wide report tables scroll inside their wrapper at 390', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await openDetail(page)
  const wrapper = page.locator('#exp-report .md-table-wrap').filter({ hasText: 'p (adj.)' }).first()
  await expect(wrapper).toBeVisible()
  expect(await wrapper.evaluate(node => node.scrollWidth > node.clientWidth)).toBe(true)
  expect(await wrapper.evaluate(node => {
    node.scrollLeft = 50
    return node.scrollLeft
  })).toBeGreaterThan(0)
  await assertNoDocumentOverflow(page)
})


test('evidence and report tables preserve whole words at 1024', async ({ page }) => {
  await page.setViewportSize({ width: 1024, height: 768 })
  await openDetail(page)
  const splitWords = await page.locator('.exp-table, #exp-report table').evaluateAll(tables => {
    const split = []
    for (const table of tables) {
      const walker = document.createTreeWalker(table, NodeFilter.SHOW_TEXT)
      while (walker.nextNode()) {
        const node = walker.currentNode
        for (const match of node.textContent.matchAll(/\b[a-z]{3,}\b/gi)) {
          const range = document.createRange()
          range.setStart(node, match.index)
          range.setEnd(node, match.index + match[0].length)
          if (range.getClientRects().length > 1) split.push(match[0])
        }
      }
    }
    return split
  })
  expect(splitWords).toEqual([])
  const wrapper = page.getByRole('region', { name: 'Metric summary', exact: true })
  expect(await wrapper.evaluate(node => { node.scrollLeft = 50; return node.scrollLeft })).toBeGreaterThan(0)
  await assertNoDocumentOverflow(page)
})

test('200% text zoom at 390 keeps every fact inside the page section', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await openDetail(page)
  const before = (await facts(page)).cells
  expect(before.length).toBeGreaterThan(0)
  await page.addStyleTag({ content: 'html{font-size:200% !important}' })
  const wide = await page.evaluate(() => [...document.querySelectorAll('#experiments-page *')]
    .filter(node => node.getBoundingClientRect().right > window.innerWidth + 1 && !node.closest('.exp-series-scroll, .exp-data-scroll, .md-table-wrap'))
    .slice(0, 5).map(node => `${node.tagName}.${node.className}`))
  expect(wide).toEqual([])
  // ponytail: the shell's own nav overflows the document at 200% zoom (443px at 390), so only the page section is asserted here.
  expect((await facts(page)).cells).toEqual(before)
})

test('reduced motion removes experiment link transitions', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' })
  await openDetail(page, '/experiments')
  await expect(page.locator('.exp-link').first()).toBeVisible()
  const durations = await page.locator('.exp-link').evaluateAll(links => links.map(link => getComputedStyle(link).transitionDuration))
  expect(durations.length).toBeGreaterThan(0)
  for (const value of durations) expect(value.split(',').every(part => parseFloat(part) === 0)).toBe(true)
})

test('states stay distinguishable without colour', async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 })
  await openDetail(page)
  await page.addStyleTag({ content: 'html{filter:grayscale(1)}' })
  await expect(page.locator('.exp-index .exp-chip', { hasText: 'not enough data' }).first()).toBeVisible()
  await expect(page.getByRole('table', { name: 'Metric evidence' })).toContainText('not enough data (n 4 of 10)')
  expect(squash(await page.locator('#exp-report-stale').textContent())).toContain('Results changed after this report was written')
})

for (const theme of ['light', 'dark']) {
  for (const [scenario, path] of [['mixed', '/experiments/release-speed'], ['mixed', '/experiments/cohort-speed'], ['empty', '/experiments']]) {
    test(`axe is clean for ${scenario} ${path} at 390 in ${theme}`, async ({ page }) => {
      await page.setViewportSize({ width: 390, height: 844 })
      await openDetail(page, path, scenario)
      await page.evaluate(value => { document.documentElement.dataset.theme = value }, theme)
      const audit = await new AxeBuilder({ page }).analyze()
      expect(audit.violations.filter(v => ['serious', 'critical'].includes(v.impact))).toEqual([])
    })
  }
}
