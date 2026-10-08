import { expect } from '@playwright/test'
import { spawn } from 'node:child_process'
import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { allocatePort, runBrowserTests } from '../scripts/run-browser-tests.mjs'
import { openFixture } from '../tests/support/browser-helpers.mjs'
import { dashboardCredentials } from '../tests/support/layout-worker.mjs'

// These selectors name production markup, rather than invented test IDs.
// Mask only live values; navigation, controls and their geometry stay visible.
export const VISUAL_MASKS = [
  { selector: '.rs-limit-meta', reason: 'Quota resets, observed ages and live usage numbers' },
  { selector: '.rs-meter', reason: 'Live usage meter fill' },
  { selector: '.rs-stat-val', reason: 'Live run counts and spend' },
  { selector: 'td[data-label="Elapsed"]', reason: 'Agent runtime duration' },
  { selector: '.run-summary-badge', reason: 'Observation freshness' },
  { selector: '.an-source-age', reason: 'Analytics observation age' },
  { selector: '.ut-latest-meta:not(.ut-agent-context) > span:last-child', reason: 'Units runtime duration' },
  { selector: '.bo-provider-health > .status-badge.mono', reason: 'Build order observation age' }
]

export function getMaskConfig(page) {
  return VISUAL_MASKS.map(({ selector }) => page.locator(selector))
}

export async function openVisualRoute(page, { theme, palette, route, collapsed = false, mode = 'read_only' }) {
  await openFixture(page, mode)
  await page.context().setHTTPCredentials(dashboardCredentials)
  if (mode === 'writable') await page.goto('/streamdeck-control/writable')
  await page.evaluate(({ theme, palette, collapsed }) => {
    localStorage.setItem('aiur-theme', theme)
    if (palette !== undefined) localStorage.setItem('aiur-palette', palette)
    localStorage.setItem('aiur-nav-collapsed', String(collapsed))
  }, { theme, palette, collapsed })
  // The synthetic fixture layout lacks production's early theme restore.
  // Read the seeded storage before mounting its LiveView hooks.
  await page.addInitScript(() => {
    document.addEventListener('DOMContentLoaded', () => {
      const stored = localStorage.getItem('aiur-theme')
      if (stored === 'light' || stored === 'dark') document.documentElement.dataset.theme = stored
    }, { once: true })
  })
  // A full navigation mounts NavToggle, whose restore-nav pushEvent applies
  // the persisted state to the server. A document event does not invoke it.
  await page.goto(route)
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
  await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1)
  await expect(page.locator('html')).toHaveAttribute('data-theme', theme)
  await expect(page.locator('.dashboard-shell')).toHaveAttribute('data-nav-collapsed', String(collapsed))
  await page.evaluate(() => document.fonts.ready)
}

function startPinnedChromium(browserRoot, port) {
  const name = `aiur-visual-${process.pid}-${port}`
  const child = spawn('docker', [
    'run', '--rm', '--name', name, '--network', 'host', '--ipc', 'host',
    '--user', `${process.getuid()}:${process.getgid()}`,
    '-v', `${browserRoot}:/work:ro`, '-w', '/work',
    'mcr.microsoft.com/playwright:v1.61.1-noble',
    'node', 'node_modules/playwright/cli.js', 'run-server', '--port', String(port), '--host', '127.0.0.1'
  ], { stdio: ['ignore', 'pipe', 'inherit'] })
  return { name, child }
}

function browserEndpoint(child) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Pinned Chromium server did not start within 30s')), 30_000)
    child.once('error', (error) => { clearTimeout(timer); reject(error) })
    child.once('exit', (code) => { clearTimeout(timer); reject(new Error(`Pinned Chromium server exited: ${code}`)) })
    child.stdout.on('data', (data) => {
      const match = String(data).match(/Listening on (ws:\/\/\S+)/)
      if (match) { clearTimeout(timer); resolve(match[1]) }
    })
  })
}

async function dockerConfig(scratch, browserRoot, endpoint) {
  const configPath = path.join(scratch, 'playwright.docker.config.mjs')
  const configUrl = new URL('../playwright.config.mjs', import.meta.url).href
  await writeFile(configPath, `import config from ${JSON.stringify(configUrl)};\nexport default { ...config, testDir: ${JSON.stringify(path.join(browserRoot, 'tests'))}, use: { ...config.use, connectOptions: { wsEndpoint: ${JSON.stringify(endpoint)} } }, webServer: { ...config.webServer, cwd: ${JSON.stringify(browserRoot)} } };\n`)
  return configPath
}

async function stopPinnedChromium({ name, child }) {
  await new Promise((resolve) => {
    const stop = spawn('docker', ['stop', '--time', '3', name], { stdio: 'ignore' })
    stop.once('error', resolve)
    stop.once('exit', resolve)
  })
  child.kill()
}

// Keep the existing fixture on the host and only rasterize in CI's image.
// The shared runner still scrubs credentials and sanitizes failure evidence.
async function runVisualDocker(args) {
  const browserRoot = fileURLToPath(new URL('../', import.meta.url))
  const scratch = await mkdtemp(path.join(tmpdir(), 'visual-docker-'))
  const server = startPinnedChromium(browserRoot, await allocatePort())
  try {
    const configPath = await dockerConfig(scratch, browserRoot, await browserEndpoint(server.child))
    console.log('Visual Chromium runtime: mcr.microsoft.com/playwright:v1.61.1-noble')
    const result = await runBrowserTests(['tests/visual-shell.browser.spec.mjs', '--config', configPath, ...args])
    process.exitCode = result.code ?? 1
    if (process.exitCode !== 0) console.error(`Visual evidence: ${result.artifactRoot}`)
  } finally {
    await stopPinnedChromium(server)
    await rm(scratch, { recursive: true, force: true })
  }
}

if (process.argv[2] === '--docker') {
  await runVisualDocker(process.argv.slice(3))
}
