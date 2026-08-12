import { expect, test } from '@playwright/test'
import { readFile, readdir } from 'node:fs/promises'
import path from 'node:path'

const surfaces = ['analytics-link', 'decision-inbox', 'decision', 'fleet', 'history', 'overview', 'recent-outcomes']
const expectedAssets = surfaces.map((surface) => `${surface}-dark.png`).sort()

test('Dashboard guide publishes one desktop screenshot for every surface', async () => {
  const websiteRoot = path.resolve(import.meta.dirname, '..')
  const guide = await readFile(path.join(websiteRoot, 'docs-app/guide/executor-control-center.md'), 'utf8')
  const imagePaths = [...guide.matchAll(/<img src="(\/images\/dashboard\/[a-z-]+-dark\.png)"/g)].map(
    ([, imagePath]) => imagePath
  )

  expect(guide).toContain('# Dashboard')
  expect(guide).toContain('Every screenshot on this page was captured')
  expect(imagePaths).toHaveLength(7)
  expect(imagePaths.map((imagePath) => path.basename(imagePath)).sort()).toEqual(expectedAssets)

  for (const imagePath of imagePaths) {
    const bytes = await readFile(path.join(websiteRoot, 'public', imagePath))
    expect(bytes.byteLength).toBeGreaterThan(1_000)
  }
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

  expect(captureScript).toContain('allocatePort')
  expect(captureScript).toContain('syntheticMarkerPresent')
  expect(captureScript).toContain('AIUR_DOCS_TMP: docsTmp')
  expect(captureScript).toContain('rm(fixture.docsTmp')
  expect(captureScript).toContain('AIUR_DASHBOARD_USERNAME: ""')
  expect(captureScript).not.toContain('4099')
  expect(captureScript).not.toContain('mobile')
  expect(assets).toEqual(expectedAssets)

  for (const surface of surfaces) {
    const bytes = await readFile(path.join(assetsRoot, `${surface}-dark.png`))
    const dimensions = pngDimensions(bytes)
    expect(dimensions.width).toBeGreaterThan(390)
    expect(dimensions.height).toBeGreaterThan(0)
    expect(bytes.byteLength).toBeGreaterThan(1_000)
  }
})

function pngDimensions(bytes: Buffer): { width: number, height: number } {
  expect(bytes.subarray(0, 8).toString('hex')).toBe('89504e470d0a1a0a')
  return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) }
}
