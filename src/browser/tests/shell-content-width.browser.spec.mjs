import { expect, test } from '@playwright/test'
import { assertControlsRemainReachable, assertNoDocumentOverflow, openFixture } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

// Every route that renders through the shared dashboard shell, each paired with
// the route heading it must show. `/` and `/commands` are served by the
// harness' own route-shell LiveView; `/build-orders`, `/analytics` and
// `/streamdeck` fall through to the real production LiveViews. Testing the real
// routes is the point: the `/fixture` page wraps itself in its own container,
// which is exactly what hid page-level overflow the last time this was
// measured. The heading is asserted so a redirect, a 404 or an error page
// cannot be measured as if it were the route under test.
//
// The real production Units page (`AiurWeb.DashboardLive`) is a known gap: the
// harness claims `/` for its own stub, and its `/units` fixture renders the
// Units markup outside the shell entirely, so no harness route puts real Units
// content inside `.shell-content`. The shell rule under test is content-blind,
// which is the whole point of the fix, but this spec cannot prove that for the
// one page it cannot render.
const routes = [
  { path: '/', title: 'Units' },
  { path: '/commands', title: 'Commands' },
  { path: '/commands/decision-123', title: 'Commands' },
  { path: '/build-orders', title: 'Build Order' },
  // The graph canvas is the most width-forcing element in the dashboard, so the
  // detail route is worth its own measurement rather than the catalog alone.
  { path: '/build-orders/42', title: 'Build Order #42' },
  { path: '/analytics', title: 'Analytics' },
  { path: '/streamdeck', title: 'Streamdeck+' }
]

// A spread rather than the two comfortable ends: 360/390 phones, 768/900 the
// tablet range below the sidebar breakpoint, 1100 the awkward middle where the
// sidebar exists but the window is too narrow to mirror its rail, and 1280 up
// through the widths where the shared measure caps the column. The sub-960
// widths are not regression cover for the grid-stretch fix (that rule is inside
// the >=960px block) — they hold the mobile half of the contract: no sideways
// scroll and no route-to-route jump on a phone. 959/960 straddle the sidebar
// breakpoint itself, so an off-by-one in the media query cannot slip through
// the gap between 900 and 1100.
const viewports = [360, 390, 768, 900, 959, 960, 1100, 1280, 1440, 1920, 2560]

// The sidebar only exists at >=960px, so only there is there a collapsed state,
// and only below it does the suite emulate a touch device.
const sidebarBreakpoint = 960

// The nav toggle's hook restores this key on mount. Seeding it beats clicking
// through the toggle on each route: a click races that restore (the server
// renders the default, then the hook pushes the stored value back), and this
// spec is about widths — `route-shell.browser.spec.mjs` owns the toggle itself.
const navCollapsedStorageKey = 'aiur-nav-collapsed'

async function newShellContext(browser, { width, collapsed }) {
  const context = await browser.newContext({
    viewport: { width, height: 900 },
    reducedMotion: 'reduce',
    httpCredentials: dashboardCredentials,
    ...(width < sidebarBreakpoint ? { isMobile: true, hasTouch: true } : {})
  })

  await context.addInitScript(
    ({ key, value }) => {
      window.localStorage.setItem(key, value)

      // Routes differ in content height, and a classic overlay-less scrollbar
      // appearing on the tall ones alone would shrink their viewport by a
      // scrollbar's width and make an honest cross-route comparison fail. Hold
      // the gutter open everywhere so the routes are measured against the same
      // available width.
      document.addEventListener('DOMContentLoaded', () => {
        document.documentElement.style.overflowY = 'scroll'
      }, { once: true })
    },
    { key: navCollapsedStorageKey, value: String(collapsed) }
  )

  return context
}

async function openRoute(page, route, collapsed) {
  const response = await page.goto(route.path)

  expect(response?.status(), route.path).toBe(200)
  await expect(page.locator('#route-title')).toHaveText(route.title)
  await expect(page.locator('.shell-content')).toBeVisible()

  // Measure the live page, not the dead first paint. The heavy routes render
  // their graph, charts and provider grid only after the socket connects, and
  // those are exactly the elements that can overflow — an overflow assertion
  // against the static render would pass on a page that had not been built yet.
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)

  // `data-nav-collapsed="false"` is already the server's default, so asserting
  // the attribute alone would prove nothing in the expanded case. Checking the
  // seeded key round-tripped is what catches the hook's storage contract being
  // renamed out from under this spec.
  expect(await page.evaluate((key) => window.localStorage.getItem(key), navCollapsedStorageKey)).toBe(String(collapsed))
  await expect(page.locator('.dashboard-shell')).toHaveAttribute('data-nav-collapsed', String(collapsed))

  // The server-owned attribute can arrive before the browser has reflected its
  // collapsed geometry. Force layout and wait for the narrow rail itself, so
  // the measurement below cannot sample the expanded shell between round trips.
  if (collapsed) {
    await expect.poll(() => page.locator('.shell-main').evaluate((main) => main.getBoundingClientRect().x)).toBeLessThan(100)
  }
}

function collectPageErrors(page) {
  const errors = []

  page.on('pageerror', (error) => errors.push(error.message))
  return errors
}

// `assertNoDocumentOverflow` compares against `innerWidth`, which counts the
// classic scrollbar and so tolerates a scrollbar's worth of real overflow —
// the same few-pixel band the shell's `100vw` centring math lives in. Compare
// against `clientWidth` as well so that band is covered.
async function assertNoDocumentOverflowStrict(page) {
  const dimensions = await page.evaluate(() => ({
    clientWidth: document.documentElement.clientWidth,
    scrollWidth: document.documentElement.scrollWidth,
    bodyScrollWidth: document.body.scrollWidth
  }))

  expect(dimensions.scrollWidth).toBeLessThanOrEqual(dimensions.clientWidth)
  expect(dimensions.bodyScrollWidth).toBeLessThanOrEqual(dimensions.clientWidth)
}

// The content column and the column it lives in, plus the shared measure read
// from the custom property rather than restated here — a hardcoded 1200 would
// keep passing after someone retuned `--shell-measure`, which is precisely the
// drift this spec exists to catch.
async function measureShell(page) {
  return page.evaluate(() => {
    const probe = document.createElement('div')

    probe.style.cssText = 'position:absolute;visibility:hidden;width:var(--shell-measure)'
    document.documentElement.append(probe)

    const measure = Math.round(probe.getBoundingClientRect().width)

    probe.remove()

    const content = document.querySelector('.shell-content').getBoundingClientRect()

    return {
      measure,
      content: Math.round(content.width),
      centre: Math.round(content.x + content.width / 2),
      viewportCentre: Math.round(document.documentElement.clientWidth / 2),
      column: Math.round(document.querySelector('.shell-main').getBoundingClientRect().width)
    }
  })
}

for (const width of viewports) {
  const collapsedStates = width >= sidebarBreakpoint ? [false, true] : [false]

  for (const collapsed of collapsedStates) {
    // One test per viewport and sidebar state rather than one long sweep: a
    // failure then names the exact case that broke instead of timing the whole
    // matrix out.
    const label = width >= sidebarBreakpoint ? `${width}px with the sidebar ${collapsed ? 'collapsed' : 'open'}` : `${width}px`

    test(`every route renders the same content width at ${label}`, async ({ browser }) => {
      const context = await newShellContext(browser, { width, collapsed })
      const page = await context.newPage()
      const pageErrors = collectPageErrors(page)

      try {
        await openFixture(page)

        const measured = new Map()

        for (const route of routes) {
          await openRoute(page, route, collapsed)

          // The page body must never scroll sideways, at any width, on any
          // route. This is the assertion that caught 2042px of overflow at
          // 1440px, so it stays first.
          await assertNoDocumentOverflow(page)
          await assertNoDocumentOverflowStrict(page)
          await assertControlsRemainReachable(page)

          measured.set(route.path, await measureShell(page))
        }

        expect(pageErrors).toEqual([])

        // Guards the comparison below against passing vacuously: a shrunken or
        // duplicated route list would otherwise trivially agree with itself.
        expect(measured.size).toBe(routes.length)

        // The whole point of the change: the content column is a property of
        // the shell, not of whatever the route happens to render. One distinct
        // value, or the layout jumps as you navigate.
        const widths = [...measured].map(([path, { content }]) => [path, content])
        const distinct = new Set(widths.map(([, content]) => content))

        expect(distinct.size, `content widths per route: ${JSON.stringify(widths)}`).toBe(1)

        // Not merely "the routes agree" — they must agree on the right number.
        // The column claims the whole space the shell gives it, capped by the
        // shared measure. That is the rule the CSS states, asserted directly,
        // so a column that agreed by collapsing to nothing would still fail.
        for (const [path, { content, column, measure }] of measured) {
          // A missing or unloaded stylesheet leaves `--shell-measure` unresolved
          // and the probe at zero, so this also fails loudly if the dashboard
          // CSS never arrived rather than green on an unstyled page.
          expect(measure, `--shell-measure at ${path}`).toBeGreaterThan(0)
          expect(content, `content column at ${path}`).toBe(Math.min(measure, column))
        }
      } finally {
        await context.close()
      }
    })
  }
}

// Pins the shared measure in one place, and pins the centring the measure sits
// inside: every route could agree on a width while the column drifted off the
// window's midline, because the rail-mirror margin that centres it is separate
// arithmetic from the cap.
test('the content column settles on the shared measure, centred in the window', async ({ browser }) => {
  const context = await newShellContext(browser, { width: 2560, collapsed: false })
  const page = await context.newPage()
  const pageErrors = collectPageErrors(page)

  try {
    await openFixture(page)

    for (const route of routes) {
      await openRoute(page, route, false)

      const { measure, content, centre, viewportCentre } = await measureShell(page)

      // 75rem at the default root font size. Stated once, here, so retuning the
      // token fails in a single obvious place instead of drifting silently.
      expect(measure).toBe(1200)
      expect(content, `content column at ${route.path}`).toBe(measure)

      // A scrollbar the content cannot use biases the mirror a few pixels left;
      // the shell's own comment calls that out, so allow it and nothing more.
      expect(Math.abs(centre - viewportCentre), `centring at ${route.path}`).toBeLessThanOrEqual(20)
    }

    expect(pageErrors).toEqual([])
  } finally {
    await context.close()
  }
})
