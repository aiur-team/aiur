import { spawnSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { chromium } from '@playwright/test'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

function fail(stage, error) {
  const detail = error?.stack ?? error?.message ?? String(error)
  process.stderr.write(`Browser self-check failed during ${stage}:\n${detail}\n`)
  process.stderr.write('Install dependencies with npm ci --prefix src/browser, then install Chromium with npx --prefix src/browser playwright install chromium.\n')
  process.exitCode = 1
}

const cli = fileURLToPath(new URL('../node_modules/@playwright/test/cli.js', import.meta.url))
if (!existsSync(cli)) {
  fail('finding the project-pinned Playwright dependency', new Error('src/browser/node_modules is missing; run npm ci --prefix src/browser'))
} else {
  const install = spawnSync(process.execPath, [cli, 'install', '--list'], { encoding: 'utf8' })
  if (install.error || install.status !== 0) {
    fail(`checking the project Playwright browser installation (${process.env.PLAYWRIGHT_BROWSERS_PATH ?? '~/.cache/ms-playwright'})`, install.error ?? install.stderr ?? install.stdout)
  } else {
    let browser
    try {
      browser = await chromium.launch({ headless: true })
      const page = await browser.newPage()
      await page.setContent('<title>Aiur browser self-check</title>')
      const title = await page.title()
      if (title !== 'Aiur browser self-check') throw new Error(`unexpected page title: ${title}`)
      process.stdout.write(`Browser self-check passed: Chromium ${browser.version()} launched and rendered a page.\n`)
    } catch (error) {
      fail('launching Chromium and rendering a page', error)
    } finally {
      await browser?.close()
    }
  }
}
