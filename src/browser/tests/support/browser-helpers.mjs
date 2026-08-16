import { expect } from '@playwright/test'

const fixtureAccessModes = new Set(['read_only', 'writable'])

export async function assertFixtureAccessDenied(page) {
  const response = await page.goto('/fixture')

  expect(response?.status()).toBe(401)
  await expect(page.getByText('synthetic fixture authentication required')).toBeVisible()
}

export async function openFixture(page, mode = 'read_only') {
  if (!fixtureAccessModes.has(mode)) throw new Error(`unsupported synthetic fixture access mode: ${mode}`)

  await page.goto(`/auth/${mode}`)
  await expect(page).toHaveURL(/\/fixture$/)
  await expect(page.locator('[data-fixture-ready="true"]')).toBeVisible()
  await expect(page.locator('#worker-status')).toHaveAttribute('data-worker-ready', 'true')
  await expect(page.locator('#mode-status')).toHaveText(mode)

  const session = (await page.context().cookies()).find((cookie) => cookie.name === '_aiur_browser_harness')

  expect(session).toMatchObject({ httpOnly: true, sameSite: 'Lax' })
}

export async function assertNoDocumentOverflow(page) {
  const dimensions = await page.evaluate(() => ({ width: window.innerWidth, scrollWidth: document.documentElement.scrollWidth }))
  expect(dimensions.scrollWidth).toBeLessThanOrEqual(dimensions.width)
}

export async function assertControlsRemainReachable(page) {
  const { controls, width } = await page.evaluate(() => {
    const insideHorizontalScroller = (element) => {
      for (let ancestor = element.parentElement; ancestor; ancestor = ancestor.parentElement) {
        if (ancestor.scrollWidth > ancestor.clientWidth) return true
      }
      return false
    }

    return {
      controls: Array.from(document.querySelectorAll('button')).map((button) => ({
        right: button.getBoundingClientRect().right,
        scrollReachable: insideHorizontalScroller(button)
      })),
      width: window.innerWidth
    }
  })
  expect(controls.every(({ right, scrollReachable }) => right <= width || scrollReachable)).toBe(true)
}

// Assert an axe run found nothing, counting what it could not grade.
//
// axe never reports a contrast failure it could not compute — a node whose
// background chain it cannot resolve is filed under `incomplete` instead. A
// scan that asserts only on `violations` is therefore green both when the
// contrast is fine and when it was never graded, which is precisely the hole a
// re-armed `color-contrast` rule is supposed to close. Assert on both.
//
// `bgGradient` is the one exception, because it is not a gap this suite can
// close: axe cannot grade text over a gradient at all, and the design system
// tints several panels that way (`.decision-revision` washes --super-soft over
// --surface). Those pairs are graded arithmetically instead, in
// `dashboard_css_theme_test.exs` — which is strictly better than axe here,
// since it can measure both ends of the gradient. Grading one of them that way
// is what turned up the revision caution at 4.16:1.
const UNGRADABLE = new Set(['bgGradient'])

export function expectAuditClean(results, rule = 'color-contrast') {
  expect(results.violations).toEqual([])

  const ungraded = results.incomplete
    .filter((result) => result.id === rule)
    .flatMap((result) => result.nodes)
    .filter((node) => !node.any.every((check) => UNGRADABLE.has(check.data?.messageKey)))

  expect(ungraded).toEqual([])
}

// Wait out the CSS transitions and entry animations under `selector`.
//
// axe reads *computed* colour, so a scan that starts while something is still
// moving measures a blend that belongs to no theme and no state, and reports it
// as a contrast violation against a token nobody wrote. Two scans were scoped
// around exactly that: the Units heading sampled #b8b7b7 (1.7:1) partway
// through `body`'s 0.35s theme fade, and the Command action panel's labels
// sampled #569560 (3.94:1) partway through `.decision-detail`'s `detail-open`.
//
// Only ever call this where motion is actually enabled. A context created with
// `reducedMotion: 'reduce'` already collapses every duration to 0.01ms, so the
// call would be inert there and would only mislead the next reader.
//
// Infinite animations — the live pulses and shimmers — never settle, so they
// are skipped rather than awaited, as is an animation with no effect (its
// `finished` never resolves). A cancelled animation rejects; that is a settled
// state too, so it is swallowed.
//
// Not settling is a failure, not something to absorb: an element frozen partway
// through an opacity animation is scored by axe as indeterminate and quietly
// lands in `incomplete` rather than `violations`, so scanning anyway would go
// green over the very node that is wrong. The budget exists so that shows up as
// this assertion rather than as a spec-wide timeout.
export async function settleAnimations(page, selector = 'body', budget = 1500) {
  const settled = await page.evaluate(async ({ target, budget: cap }) => {
    const root = document.querySelector(target)
    if (!root) throw new Error(`settleAnimations: no element matches ${target}`)

    const running = root
      .getAnimations({ subtree: true })
      .filter((animation) => animation.effect && animation.effect.getComputedTiming().iterations !== Infinity)
      .map((animation) => animation.finished.catch(() => {}))

    return Promise.race([
      Promise.all(running).then(() => true),
      new Promise((resolve) => setTimeout(() => resolve(false), cap))
    ])
  }, { target: selector, budget })

  expect(settled, `animations under ${selector} did not settle within ${budget}ms`).toBe(true)
}

export async function reconnectLiveView(page) {
  await page.evaluate(() => window.liveSocket.disconnect())
  await expect(page.locator('#worker-status')).toHaveAttribute('data-live-status', 'disconnected')
  await page.evaluate(() => window.liveSocket.connect())
  await expect(page.locator('#worker-status')).toHaveAttribute('data-live-status', 'reconnected')
}

export async function captureConfiguredScreenshot(page, testInfo) {
  if (process.env.AIUR_BROWSER_SCREENSHOTS !== '1') return null

  const destination = testInfo.outputPath('fixture.png')
  await page.screenshot({ path: destination, fullPage: true })
  await testInfo.attach('fixture screenshot', { path: destination, contentType: 'image/png' })
  return destination
}
