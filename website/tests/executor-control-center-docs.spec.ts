import { expect, test } from '@playwright/test'
import { readFile, readdir } from 'node:fs/promises'
import path from 'node:path'
import { assertSyntheticContent, assertSyntheticMeters } from '../scripts/dashboard-capture-safety.mjs'

// Each surface's screenshot belongs on the page that explains that surface. The
// Dashboard guide keeps exactly one, so it stays a short index rather than a
// duplicate of Concepts.
const surfacePages = {
  'units': 'docs-app/concepts/units.md',
  'commands': 'docs-app/concepts/commands.md',
  'build-orders': 'docs-app/concepts/build-orders.md',
  'streamdeck': 'docs-app/guide/stream-deck.md'
} as const

// One screenshot per documented dashboard surface. Adding a mapping above
// means adding it to website/scripts/capture-dashboard.mjs and recapturing.
const surfaces = Object.keys(surfacePages)
const expectedAssets = surfaces.map((surface) => `${surface}-dark.png`).sort()

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
  expect(dashboard).toContain('| **Commands** | `/commands`')
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
  const meterFixture = await readFile(
    path.join(websiteRoot, '../src/test/manual/executor_control_center_docs_meter_source.exs'),
    'utf8'
  )
  const fixtureSources = `${fixture}\n${meterFixture}`
  const captureScript = await readFile(path.join(websiteRoot, 'scripts/capture-dashboard.mjs'), 'utf8')
  const captureSafety = await readFile(path.join(websiteRoot, 'scripts/dashboard-capture-safety.mjs'), 'utf8')
  const assetsRoot = path.join(websiteRoot, 'public/images/dashboard')
  const assets = (await readdir(assetsRoot)).filter((asset) => asset.endsWith('.png')).sort()

  expect(fixture).toContain('example.test')
  expect(fixture).toContain('EX-142')
  expect(fixture).toContain('kind: memory')
  expect(fixture).toContain('synthetic_workflow')
  expect(fixtureSources).not.toMatch(/\.aiur\/config|github\.com|its-everdred|AIUR-\d+/i)

  // The fixture must never start the live provider-meter probes: they read the
  // operator's real Claude and Codex account quota over HTTP. Synthetic meters
  // are installed through the endpoint's :provider_meter_source seam instead.
  expect(fixture).toContain('provider_meter_source: MeterSource')
  expect(fixtureSources).not.toMatch(/ProviderMeterRefresh\.start_link|ProviderMeterProjection\.start_link/)
  expect(meterFixture).toContain('example-account-codex')
  expect(meterFixture).toContain('example-account-claude')
  // Likewise the GitHub quota card: started, but with refreshing disabled.
  expect(fixture).toContain('refresh?: false')
  // Build Order and Stream Deck render from fixture data, never a live source.
  expect(fixture).toContain('build_order_planning_pack')
  expect(fixture).toContain('streamdeck_snapshot_fun')

  expect(captureScript).toContain('allocatePort')
  expect(captureScript).toContain('assertSyntheticContent')
  expect(captureScript).toContain('AIUR_DOCS_TMP: docsTmp')
  expect(captureScript).toContain('rm(fixture.docsTmp')
  expect(captureScript).toContain('AIUR_DASHBOARD_USERNAME: ""')
  expect(captureScript).toContain('GITHUB_TOKEN: _githubToken')
  expect(captureScript).toContain('ELEVENLABS_API_KEY: _elevenLabsApiKey')
  expect(captureScript).toContain('OPENROUTER_MANAGEMENT_KEY: _openRouterManagementKey')
  expect(captureScript).toContain('assertMetersAreSynthetic')
  expect(captureSafety).toContain('forbiddenPatterns')
  expect(captureSafety).toContain('its-everdred')
  expect(captureSafety).toContain('its-applekid')
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

test('capture safety rejects operator-shaped data', () => {
  const synthetic = {
    url: 'http://127.0.0.1:4099/',
    html: '<main>example-account EX-142 example/repository</main>',
    visibleText: 'EX-142 example/repository',
    marker: 'example/repository'
  }

  expect(() => assertSyntheticContent(synthetic)).not.toThrow()
  expect(() => assertSyntheticContent({ ...synthetic, html: '<main>EX-142</main>' })).toThrow('synthetic fixture markers are missing')
  expect(() => assertSyntheticContent({ ...synthetic, visibleText: 'its-applekid EX-142' })).toThrow('matched real operator state')
  expect(() => assertSyntheticContent({ ...synthetic, visibleText: 'REAL-142 example/repository' })).toThrow('non-fixture ticket identifiers')
  const modelRows = [
    '<div class="rs-model"><span class="rs-name">Codex</span><i style="width:61%"></i><i style="width:47%"></i></div>',
    '<div class="rs-model"><span class="rs-name">Claude</span><i style="width:34%"></i><i style="width:58%"></i></div>'
  ]
  expect(() => assertSyntheticMeters({ url: synthetic.url, modelRows, required: true })).not.toThrow()
  expect(() => assertSyntheticMeters({ url: synthetic.url, modelRows: [], required: false })).not.toThrow()
  expect(() => assertSyntheticMeters({ url: synthetic.url, modelRows: [], required: true })).toThrow('Codex model meter does not match')
  expect(() => assertSyntheticMeters({ url: synthetic.url, modelRows: [modelRows[0], modelRows[1].replace('58%', '57%')], required: true })).toThrow('Claude model meter does not match')
})

test('docs group operator surfaces and API guidance without dense prose', async () => {
  const websiteRoot = path.resolve(import.meta.dirname, '..')
  const docsRoot = path.join(websiteRoot, 'docs-app')
  const markdownPaths = await markdownFiles(docsRoot)
  const markdown = await Promise.all(markdownPaths.map(async (file) => [file, await readFile(file, 'utf8')] as const))
  const byRelativePath = new Map(markdown.map(([file, contents]) => [path.relative(docsRoot, file), contents]))
  const sidebar = await readFile(path.join(docsRoot, '.vitepress/config.ts'), 'utf8')
  const configuration = byRelativePath.get('reference/configuration.md') ?? ''
  const github = byRelativePath.get('apis/github.md') ?? ''
  const elevenLabs = byRelativePath.get('apis/elevenlabs.md') ?? ''
  const streamDeck = byRelativePath.get('guide/stream-deck.md') ?? ''

  expect(sidebar).toContain("text: 'Usage'")
  expect(sidebar).toContain("text: 'APIs'")
  expect(sidebar).toMatch(/text: 'Usage'[\s\S]*text: 'TUI'[\s\S]*text: 'CLI'[\s\S]*text: 'Dashboard'[\s\S]*text: 'Stream Deck'/)
  expect(sidebar).toMatch(/text: 'Concepts'[\s\S]*text: 'Skills'/)
  expect(sidebar).toMatch(/text: 'APIs'[\s\S]*text: 'GitHub'[\s\S]*text: 'ElevenLabs'/)

  expect(configuration).not.toContain('## GitHub webhook receiver')
  expect(configuration).not.toContain('### Choosing a poll interval')
  expect(configuration).not.toContain('### How widening interacts with polling')
  expect(github).toContain('`POST /api/v1/github/webhook`')
  expect(github).toContain('`AIUR_GITHUB_WEBHOOK_SECRET`')
  expect(github).toContain('`hooks.aiur.dev`')
  expect(github).toContain('catch-all `404`')
  expect(github).toContain('No inbound firewall rule')
  expect(elevenLabs).toContain('Speech to Text')
  expect(elevenLabs).toContain('`User`')
  expect(elevenLabs).toContain('Text to Speech')
  expect(elevenLabs).toContain('audio-minute')
  expect(elevenLabs).toContain('character pool')
  expect(streamDeck).not.toContain('## Shared key-face contract')
  expect(streamDeck).not.toContain('### Audio path')

  for (const [file, contents] of markdown) {
    for (const paragraph of proseParagraphs(contents)) {
      expect(paragraph.length, `${path.relative(docsRoot, file)} has a dense paragraph: ${paragraph}`).toBeLessThanOrEqual(360)
    }

    for (const paragraph of proseBeforeTables(contents)) {
      expect(sentenceCount(paragraph), `${path.relative(docsRoot, file)} has more than one sentence above a table: ${paragraph}`).toBeLessThanOrEqual(1)
    }
  }
})

async function markdownFiles(root: string): Promise<string[]> {
  const entries = await readdir(root, { withFileTypes: true })
  const nested = await Promise.all(entries.map(async (entry) => {
    const absolute = path.join(root, entry.name)
    if (entry.name === 'node_modules') return []
    if (entry.isDirectory()) return markdownFiles(absolute)
    return entry.isFile() && entry.name.endsWith('.md') ? [absolute] : []
  }))
  return nested.flat()
}

function proseParagraphs(markdown: string): string[] {
  return markdown
    .split(/\n\s*\n/)
    .map((block) => block.replace(/\n/g, ' ').trim())
    .filter((block) => block !== '')
    .filter((block) => !/^(#|\||```|:::|<|[-*+] |\d+\. )/.test(block))
}

function proseBeforeTables(markdown: string): string[] {
  const blocks = markdown.split(/\n\s*\n/).map((block) => block.replace(/\n/g, ' ').trim())
  return blocks.filter((block, index) => proseParagraphs(block).length === 1 && blocks[index + 1]?.startsWith('|'))
}

function sentenceCount(paragraph: string): number {
  return paragraph.match(/[.!?](?=\s|$)/g)?.length ?? 0
}

function pngDimensions(bytes: Buffer): { width: number, height: number } {
  expect(bytes.subarray(0, 8).toString('hex')).toBe('89504e470d0a1a0a')
  return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) }
}
