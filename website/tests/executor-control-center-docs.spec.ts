import { expect, test } from '@playwright/test'
import { readFile, readdir } from 'node:fs/promises'
import path from 'node:path'

// One screenshot per documented dashboard surface. Adding a surface here means
// adding it to website/scripts/capture-dashboard.mjs and recapturing.
const surfaces = ['build-orders', 'commands', 'streamdeck', 'units']
const expectedAssets = surfaces.map((surface) => `${surface}-dark.png`).sort()

// Each surface's screenshot belongs on the page that explains that surface. The
// Dashboard guide keeps exactly one, so it stays a short index rather than a
// duplicate of Concepts.
const surfacePages: Record<string, string> = {
  'units': 'docs-app/concepts/units.md',
  'commands': 'docs-app/concepts/commands.md',
  'build-orders': 'docs-app/concepts/build-orders.md',
  'streamdeck': 'docs-app/guide/stream-deck.md'
}

function imagePathsIn(markdown: string): string[] {
  return [...markdown.matchAll(/<img src="(\/images\/dashboard\/[a-z-]+-dark\.png)"/g)].map(
    ([, imagePath]) => imagePath
  )
}

test('every dashboard surface screenshot is published on the page that explains it', async () => {
  const websiteRoot = path.resolve(import.meta.dirname, '..')

  for (const [surface, page] of Object.entries(surfacePages)) {
    const markdown = await readFile(path.join(websiteRoot, page), 'utf8')
    const imagePaths = imagePathsIn(markdown)

    expect(imagePaths, `${page} must show ${surface}-dark.png`).toContain(
      `/images/dashboard/${surface}-dark.png`
    )
    expect(markdown, `${page} must label its screenshot as fixture data`).toContain('synthetic')

    for (const imagePath of imagePaths) {
      const bytes = await readFile(path.join(websiteRoot, 'public', imagePath))
      expect(bytes.byteLength).toBeGreaterThan(1_000)
    }
  }
})

test('the Dashboard guide keeps exactly one screenshot', async () => {
  const websiteRoot = path.resolve(import.meta.dirname, '..')
  const guide = await readFile(path.join(websiteRoot, 'docs-app/guide/executor-control-center.md'), 'utf8')
  const imagePaths = imagePathsIn(guide)

  expect(guide).toContain('# Dashboard')
  expect(guide).toContain('Every screenshot on this page was captured')
  expect(imagePaths).toEqual(['/images/dashboard/units-dark.png'])

  const bytes = await readFile(path.join(websiteRoot, 'public', imagePaths[0]))
  expect(bytes.byteLength).toBeGreaterThan(1_000)
})

test('parity guides are linked and contain their operational contracts', async () => {
  const websiteRoot = path.resolve(import.meta.dirname, '..')
  const [index, quickStart, dashboard, streamDeck, sidecarRunbook, cli, operating, config] = await Promise.all([
    readFile(path.join(websiteRoot, 'docs-app/index.md'), 'utf8'),
    readFile(path.join(websiteRoot, 'docs-app/guide/quick-start.md'), 'utf8'),
    readFile(path.join(websiteRoot, 'docs-app/guide/executor-control-center.md'), 'utf8'),
    readFile(path.join(websiteRoot, 'docs-app/guide/stream-deck.md'), 'utf8'),
    readFile(path.join(websiteRoot, '../packages/streamdeck/README.md'), 'utf8'),
    readFile(path.join(websiteRoot, 'docs-app/reference/cli.md'), 'utf8'),
    readFile(path.join(websiteRoot, 'docs-app/concepts/operating-aiur.md'), 'utf8'),
    readFile(path.join(websiteRoot, 'docs-app/.vitepress/config.ts'), 'utf8')
  ])

  expect(index).toContain('[Operate the Stream Deck](/guide/stream-deck)')
  expect(quickStart).toContain('[Dashboard](/guide/executor-control-center)')
  expect(config).toContain("{ text: 'Dashboard', link: '/guide/executor-control-center' }")
  expect(config).toContain("{ text: 'Stream Deck', link: '/guide/stream-deck' }")
  expect(dashboard).toContain('| **Units** | `/`')
  expect(dashboard).toContain('| **Commands** | `/decisions`')
  expect(dashboard).toContain('| **Build Order** | `/build-orders`')
  expect(dashboard).toContain('| **Analytics** | `/analytics`')
  expect(dashboard).toContain('| **Streamdeck+** | `/streamdeck`')
  expect(dashboard).toContain('same live projection used by the authenticated physical Stream Deck + sidecar')
  expect(streamDeck).toContain('Mic is press-and-hold, not a click')
  expect(streamDeck).toContain('`alert` → `stuck` → `running` → `paused` → `queued`')
  expect(streamDeck).toContain('The supported transport deployment is Arch Linux on x64 glibc 2.28+')
  expect(streamDeck).toContain('## Physical sidecar status')
  expect(streamDeck).toContain('`STREAMDECK_BRIGHTNESS`')
  expect(streamDeck).toContain('`~/.config/aiur/streamdeck.env`')
  expect(streamDeck).toContain('connects to the authenticated Phoenix channel')
  expect(streamDeck).toContain('routes physical key controls through AgentChat')
  expect(streamDeck).toContain('short-lived token is renewed after channel disconnects')
  expect(streamDeck).toContain('https://github.com/aiur-team/aiur/issues/1358')
  expect(streamDeck).not.toContain('pair the sidecar by creating')
  expect(streamDeck).not.toContain('the sidecar renders device bitmaps')
  expect(sidecarRunbook).toMatch(/production\s+sidecar opens the device, connects to the\s+authenticated Aiur Phoenix channel/)
  expect(sidecarRunbook).toContain('`AIUR_PHOENIX_URL`')
  expect(sidecarRunbook).toContain('`AIUR_DASHBOARD_USERNAME`')
  expect(sidecarRunbook).toContain('`AIUR_DASHBOARD_PASSWORD`')
  expect(sidecarRunbook).toContain('physically replug')
  expect(sidecarRunbook).toContain('does not recover a failed image transfer or issue a device reset on this path')
  expect(sidecarRunbook).not.toContain('let the sidecar perform its key-stream reset and device reset')
  expect(cli).toContain('## Dashboard page commands')
  expect(cli).toContain('it never becomes `0`, `[]`, or `{}` merely because the command could not measure it')
  expect(cli).toContain('`aiur ask --done ASK-ID`')
  expect(cli).toContain('An open **blocking** ask is also printed by plain `aiur status`')
  expect(cli).toContain('**Dispatch needs `agent:todo`.**')
  expect(cli).toContain('**Global pause is durable.**')
  expect(cli).toContain('**CI readiness uses an operator-only token.**')
  expect(cli).toContain('**A base refresh affects approval ownership.**')
  expect(operating).toContain('## Hourly meta-check')
  expect(operating).toContain('**before dispatching**')
  expect(operating).toContain('inspect its durable follow-up with `aiur findings`')
  expect(operating).toContain('`aiur findings --unfiled`')
  expect(operating).toContain('`~/.aiur/repo/<owner>/<repo>/meta/retros/<boot-id>.md`')
  expect(operating).toContain("`aiur findings --record '<json>' --repo <owner>/<repo>`")
})

test('capture inputs and checked-in assets stay example-only', async () => {
  const websiteRoot = path.resolve(import.meta.dirname, '..')
  const fixture = await readFile(
    path.join(websiteRoot, '../src/test/manual/executor_control_center_docs_fixture.exs'),
    'utf8'
  )
  const captureScript = await readFile(path.join(websiteRoot, 'scripts/capture-dashboard.mjs'), 'utf8')
  const assetsRoot = path.join(websiteRoot, 'public/images/dashboard')
  const assets = (await readdir(assetsRoot)).filter((asset) => asset.endsWith('.png')).sort()

  expect(fixture).toContain('example.test')
  expect(fixture).toContain('EX-142')
  expect(fixture).toContain('kind: memory')
  expect(fixture).toContain('synthetic_workflow')
  expect(fixture).not.toMatch(/\.aiur\/config|github\.com|its-everdred|AIUR-\d+/i)

  // The fixture must never start the live provider-meter probes: they read the
  // operator's real Claude and Codex account quota over HTTP. Synthetic meters
  // are installed through the endpoint's :provider_meter_source seam instead.
  expect(fixture).toContain('provider_meter_source: MeterSource')
  expect(fixture).not.toMatch(/ProviderMeterRefresh\.start_link|ProviderMeterProjection\.start_link/)
  // Likewise the GitHub quota card: started, but with refreshing disabled.
  expect(fixture).toContain('refresh?: false')
  // Build Order and Stream Deck render from fixture data, never a live source.
  expect(fixture).toContain('build_order_planning_pack')
  expect(fixture).toContain('streamdeck_snapshot_fun')

  expect(captureScript).toContain('allocatePort')
  expect(captureScript).toContain('syntheticMarkerPresent')
  expect(captureScript).toContain('AIUR_DOCS_TMP: docsTmp')
  expect(captureScript).toContain('rm(fixture.docsTmp')
  expect(captureScript).toContain('AIUR_DASHBOARD_USERNAME: ""')
  expect(captureScript).toContain('forbiddenPatterns')
  expect(captureScript).toContain('assertMetersAreSynthetic')
  expect(captureScript).toContain('its-everdred')
  expect(captureScript).toContain('its-applekid')
  expect(captureScript).not.toContain('4099')
  expect(captureScript).not.toContain('mobile')
  expect(assets).toEqual(expectedAssets)

  for (const surface of surfaces) {
    const bytes = await readFile(path.join(assetsRoot, `${surface}-dark.png`))
    const dimensions = pngDimensions(bytes)
    // Desktop-width capture. The dashboard shell is a hair narrower than the
    // 1280px viewport (page gutter), so accept any solid desktop width.
    expect(dimensions.width).toBeGreaterThan(1100)
    expect(dimensions.height).toBeGreaterThan(600)
    expect(bytes.byteLength).toBeGreaterThan(20_000)
    // Checked-in documentation assets stay small enough to ship with the site.
    expect(bytes.byteLength).toBeLessThan(500_000)
  }
})

function pngDimensions(bytes: Buffer): { width: number, height: number } {
  expect(bytes.subarray(0, 8).toString('hex')).toBe('89504e470d0a1a0a')
  return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) }
}
